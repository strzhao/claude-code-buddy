import XCTest
@testable import BuddyCore

/// Integration tests migrated from shell acceptance scripts.
/// These verify the same behavioral contracts as the shell tests but run
/// via SessionManager.handle(message:) — no app binary or socket needed.
final class SessionIntegrationTests: XCTestCase {

    var scene: MockScene!
    var manager: SessionManager!

    override func setUp() {
        super.setUp()
        scene = MockScene()
        manager = SessionManager(scene: scene)
        try? FileManager.default.removeItem(atPath: SessionManager.colorFilePath)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: SessionManager.colorFilePath)
        super.tearDown()
    }

    // MARK: - Migrated from test-session-manager.sh

    func testColorFileClearedOnStartup() throws {
        // Write something to color file
        try "stale".data(using: .utf8)!.write(to: URL(fileURLWithPath: SessionManager.colorFilePath))

        // Calling start() writes empty JSON — but start() also opens socket,
        // so instead verify writeColorFile indirectly: create then end session
        manager.handle(message: TestHelpers.makeMessage(sessionId: "s1", event: "thinking", cwd: "/p"))
        manager.handle(message: TestHelpers.makeMessage(sessionId: "s1", event: "session_end"))

        let data = try Data(contentsOf: URL(fileURLWithPath: SessionManager.colorFilePath))
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: [String: String]]
        )
        XCTAssertTrue(json.isEmpty, "Color file should be empty after all sessions end")
    }

    func testThreeConcurrentSessionsGetDistinctColors() {
        for i in 1...3 {
            manager.handle(message: TestHelpers.makeMessage(
                sessionId: "sess-\(i)", event: "session_start", cwd: "/project-\(i)"
            ))
        }

        let colors = Set((1...3).compactMap { manager.sessions["sess-\($0)"]?.color })
        XCTAssertEqual(colors.count, 3, "Three sessions should have distinct colors")
    }

    func testSetLabelUpdatesColorFile() throws {
        manager.handle(message: TestHelpers.makeMessage(
            sessionId: "s1", event: "session_start", cwd: "/project"
        ))
        manager.handle(message: TestHelpers.makeMessage(
            sessionId: "s1", event: "set_label", label: "custom"
        ))

        let data = try Data(contentsOf: URL(fileURLWithPath: SessionManager.colorFilePath))
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: [String: String]]
        )
        XCTAssertEqual(json["s1"]?["label"], "custom")
    }

    func testSetLabelOnUnknownSessionNoop() {
        manager.handle(message: TestHelpers.makeMessage(
            sessionId: "ghost", event: "set_label", label: "x"
        ))
        XCTAssertTrue(manager.sessions.isEmpty, "No session should be created by set_label")
    }

    // MARK: - Migrated from test-multi-session.sh

    func testMultiSessionIndependentLifecycle() {
        // Create 3 sessions
        for i in 1...3 {
            manager.handle(message: TestHelpers.makeMessage(
                sessionId: "m\(i)", event: "thinking", cwd: "/proj\(i)"
            ))
        }
        XCTAssertEqual(manager.sessions.count, 3)

        // End middle session
        manager.handle(message: TestHelpers.makeMessage(sessionId: "m2", event: "session_end"))
        XCTAssertNil(manager.sessions["m2"])
        XCTAssertNotNil(manager.sessions["m1"])
        XCTAssertNotNil(manager.sessions["m3"])
    }

    func testRapidBurstOfEvents() {
        // Simulate rapid burst from multiple sessions
        let events: [(String, String)] = [
            ("a", "thinking"), ("b", "thinking"), ("c", "thinking"),
            ("a", "tool_start"), ("b", "tool_start"),
            ("a", "tool_end"), ("c", "tool_start"),
            ("b", "tool_end"), ("a", "idle"),
            ("c", "tool_end"), ("b", "idle"),
        ]
        for (sid, event) in events {
            manager.handle(message: TestHelpers.makeMessage(
                sessionId: sid, event: event, cwd: "/\(sid)"
            ))
        }

        XCTAssertEqual(manager.sessions.count, 3)
        XCTAssertEqual(manager.sessions["a"]?.state, .idle)
        XCTAssertEqual(manager.sessions["b"]?.state, .idle)
        XCTAssertEqual(manager.sessions["c"]?.state, .thinking) // tool_end maps to thinking
    }

    // MARK: - Migrated from test-socket-protocol.sh (message routing)

    func testAllEventTypesAccepted() {
        let sid = "robust"
        let events = ["session_start", "thinking", "tool_start", "tool_end",
                      "idle", "permission_request", "set_label", "session_end"]
        for event in events {
            var msg = TestHelpers.makeMessage(sessionId: sid, event: event, cwd: "/p")
            if event == "set_label" {
                msg = TestHelpers.makeMessage(sessionId: sid, event: event, label: "x")
            }
            manager.handle(message: msg)
        }
        // session_end should have cleaned up
        XCTAssertNil(manager.sessions[sid])
    }

    func testSessionSurvivesManyMessagesWithoutLeak() {
        let sid = "stress"
        manager.handle(message: TestHelpers.makeMessage(sessionId: sid, event: "thinking", cwd: "/p"))

        for _ in 0..<100 {
            manager.handle(message: TestHelpers.makeMessage(sessionId: sid, event: "tool_start"))
            manager.handle(message: TestHelpers.makeMessage(sessionId: sid, event: "tool_end"))
        }

        XCTAssertEqual(manager.sessions[sid]?.toolCallCount, 100)
        XCTAssertEqual(manager.sessions.count, 1)
    }

    // MARK: - Color file consistency

    func testColorFileConsistencyAfterComplexOperations() throws {
        // Create 4 sessions
        for i in 1...4 {
            manager.handle(message: TestHelpers.makeMessage(
                sessionId: "c\(i)", event: "thinking", cwd: "/proj\(i)"
            ))
        }
        // End c2, set label on c3
        manager.handle(message: TestHelpers.makeMessage(sessionId: "c2", event: "session_end"))
        manager.handle(message: TestHelpers.makeMessage(
            sessionId: "c3", event: "set_label", label: "renamed"
        ))

        let data = try Data(contentsOf: URL(fileURLWithPath: SessionManager.colorFilePath))
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: [String: String]]
        )

        XCTAssertEqual(json.count, 3, "3 active sessions in color file")
        XCTAssertNil(json["c2"], "Ended session not in file")
        XCTAssertEqual(json["c3"]?["label"], "renamed")
        XCTAssertNotNil(json["c1"])
        XCTAssertNotNil(json["c4"])
    }

    func testEightSessionsAllInColorFile() throws {
        for i in 1...8 {
            manager.handle(message: TestHelpers.makeMessage(
                sessionId: "s\(i)", event: "thinking", cwd: "/p\(i)"
            ))
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: SessionManager.colorFilePath))
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: [String: String]]
        )
        XCTAssertEqual(json.count, 8)

        // All entries have required fields
        for (_, entry) in json {
            XCTAssertNotNil(entry["color"])
            XCTAssertNotNil(entry["hex"])
            XCTAssertNotNil(entry["label"])
        }
    }
}
