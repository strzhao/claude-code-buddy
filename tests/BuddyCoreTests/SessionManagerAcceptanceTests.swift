import XCTest
import Combine
@testable import BuddyCore

// MARK: - SessionManagerAcceptanceTests

/// Acceptance tests for SessionManager.
///
/// These tests verify the critical end-to-end behavioral contracts of SessionManager.
/// They are written against the blue-team's planned internal API surface:
///   - `SessionManager.sessions` (internal)
///   - `SessionManager.usedColors` (internal)
///   - `SessionManager.handle(message:)` (internal)
///   - `SessionManager.checkTimeouts()` (internal)
///   - `SessionManager(scene: any SceneControlling)` initialiser
///   - `MockScene` test double (provided by blue team in MockScene.swift)
///
/// Tests WILL NOT compile until the blue team merges their changes — that is expected.
final class SessionManagerAcceptanceTests: XCTestCase {

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

    // MARK: - 1. Full Session Lifecycle

    /// session_start → thinking → tool_start → tool_end → idle → session_end
    ///
    /// Verifies:
    ///  • Session is created in `sessions` on the first message.
    ///  • State transitions are tracked correctly in SessionInfo.
    ///  • session_end removes the session and releases its color.
    func testFullSessionLifecycle() {
        let sid = "lifecycle-session"

        // session_start — creates session
        manager.handle(message: TestHelpers.makeMessage(
            sessionId: sid, event: "session_start", cwd: "/projects/myapp"
        ))
        XCTAssertNotNil(manager.sessions[sid], "Session should exist after session_start")
        let color = manager.sessions[sid]!.color
        XCTAssertTrue(manager.usedColors.contains(color), "Color should be marked used after session_start")
        XCTAssertEqual(manager.sessions[sid]?.state, .idle,
                       "State should be idle after session_start (no entityState mapping)")

        // thinking
        manager.handle(message: TestHelpers.makeMessage(sessionId: sid, event: "thinking"))
        XCTAssertEqual(manager.sessions[sid]?.state, .thinking)

        // tool_start
        manager.handle(message: TestHelpers.makeMessage(
            sessionId: sid, event: "tool_start", tool: "Bash", description: "run tests"
        ))
        XCTAssertEqual(manager.sessions[sid]?.state, .toolUse)

        // tool_end maps back to thinking
        manager.handle(message: TestHelpers.makeMessage(sessionId: sid, event: "tool_end"))
        XCTAssertEqual(manager.sessions[sid]?.state, .thinking)

        // idle
        manager.handle(message: TestHelpers.makeMessage(sessionId: sid, event: "idle"))
        XCTAssertEqual(manager.sessions[sid]?.state, .idle)

        // session_end — removes session and releases color
        manager.handle(message: TestHelpers.makeMessage(sessionId: sid, event: "session_end"))
        XCTAssertNil(manager.sessions[sid], "Session should be removed after session_end")
        XCTAssertFalse(manager.usedColors.contains(color), "Color should be released after session_end")

        // MockScene should have received matching calls
        XCTAssertEqual(scene.addCatCalls.count, 1, "addCat should have been called exactly once")
        XCTAssertEqual(scene.removeCatCalls, [sid], "removeCat should have been called with the session id")
    }

    // MARK: - 2. 8-Session Color Uniqueness

    /// Creates 8 sessions, asserts all colors are distinct.
    /// Ends one session, starts a new one, asserts the released color is reused.
    func testEightSessionColorUniqueness() {
        var assignedColors: [String: SessionColor] = [:]

        for i in 1...8 {
            let sid = "color-session-\(i)"
            manager.handle(message: TestHelpers.makeMessage(
                sessionId: sid, event: "session_start", cwd: "/projects/proj\(i)"
            ))
            let info = manager.sessions[sid]
            XCTAssertNotNil(info, "Session \(sid) should exist")
            assignedColors[sid] = info!.color
        }

        // All 8 colors should be distinct
        let colorSet = Set(assignedColors.values)
        XCTAssertEqual(colorSet.count, 8, "All 8 sessions should have unique colors")

        // All 8 SessionColor cases should be in use
        XCTAssertEqual(manager.usedColors.count, 8, "All 8 color slots should be occupied")

        // End one session and verify its color is reused
        let removedSid = "color-session-1"
        let releasedColor = assignedColors[removedSid]!
        manager.handle(message: TestHelpers.makeMessage(sessionId: removedSid, event: "session_end"))
        XCTAssertFalse(manager.usedColors.contains(releasedColor),
                       "Released color should no longer be in usedColors")

        // A new (9th) session should pick up the freed color
        let newSid = "color-session-9"
        manager.handle(message: TestHelpers.makeMessage(
            sessionId: newSid, event: "session_start", cwd: "/projects/proj9"
        ))
        XCTAssertNotNil(manager.sessions[newSid])
        XCTAssertEqual(manager.sessions[newSid]?.color, releasedColor,
                       "New session should reuse the just-released color")
    }

    // MARK: - 3. Color File Accuracy

    /// After a full lifecycle, the color file should reflect only active sessions.
    func testColorFileAccuracy() throws {
        let sid1 = "colorfile-session-1"
        let sid2 = "colorfile-session-2"

        manager.handle(message: TestHelpers.makeMessage(
            sessionId: sid1, event: "session_start", cwd: "/projects/alpha"
        ))
        manager.handle(message: TestHelpers.makeMessage(
            sessionId: sid2, event: "session_start", cwd: "/projects/beta"
        ))

        // Color file should contain both sessions
        let data = try Data(contentsOf: URL(fileURLWithPath: SessionManager.colorFilePath))
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: [String: String]]
        )

        XCTAssertNotNil(json[sid1], "Color file should have entry for \(sid1)")
        XCTAssertNotNil(json[sid2], "Color file should have entry for \(sid2)")

        for (id, entry) in [sid1: json[sid1]!, sid2: json[sid2]!] {
            XCTAssertNotNil(entry["color"], "\(id) entry must have 'color' key")
            XCTAssertNotNil(entry["hex"],   "\(id) entry must have 'hex' key")
            XCTAssertNotNil(entry["label"], "\(id) entry must have 'label' key")

            // Hex must be a 7-char #RRGGBB string
            let hex = entry["hex"]!
            XCTAssertTrue(hex.hasPrefix("#") && hex.count == 7,
                          "\(id) hex '\(hex)' should be #RRGGBB format")

            // Label should match the cwd last path component
            let expectedLabel = id == sid1 ? "alpha" : "beta"
            XCTAssertEqual(entry["label"], expectedLabel,
                           "\(id) label should be derived from cwd last component")
        }

        // End sid1 — color file must no longer contain it
        manager.handle(message: TestHelpers.makeMessage(sessionId: sid1, event: "session_end"))

        let data2 = try Data(contentsOf: URL(fileURLWithPath: SessionManager.colorFilePath))
        let json2 = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data2) as? [String: [String: String]]
        )
        XCTAssertNil(json2[sid1], "Ended session should be absent from color file")
        XCTAssertNotNil(json2[sid2], "Active session should remain in color file")
    }

    // MARK: - 4. Timeout Enforcement

    /// Aging lastActivity past 5 min → idle; past 15 min → session removed.
    func testTimeoutEnforcement() {
        let sid = "timeout-session"

        manager.handle(message: TestHelpers.makeMessage(
            sessionId: sid, event: "thinking", cwd: "/projects/timeout"
        ))
        XCTAssertEqual(manager.sessions[sid]?.state, .thinking)

        // Age to just over 5 minutes — should become idle
        let sixMinutesAgo = Date(timeIntervalSinceNow: -(6 * 60))
        manager.sessions[sid]?.lastActivity = sixMinutesAgo

        manager.checkTimeouts()

        XCTAssertNotNil(manager.sessions[sid], "Session should still exist at 6 minutes")
        XCTAssertEqual(manager.sessions[sid]?.state, .idle,
                       "State should transition to idle after 5-minute idle timeout")

        // Age to just over 30 minutes — session should be removed
        let sixteenMinutesAgo = Date(timeIntervalSinceNow: -(31 * 60))
        manager.sessions[sid]?.lastActivity = sixteenMinutesAgo

        manager.checkTimeouts()

        XCTAssertNil(manager.sessions[sid], "Session should be removed after 30-minute remove timeout")
        XCTAssertTrue(manager.usedColors.isEmpty || !manager.usedColors.contains(
            manager.sessions[sid]?.color ?? .coral
        ), "Color should be released after session removed by timeout")
        XCTAssertTrue(scene.removeCatCalls.contains(sid),
                      "MockScene.removeCat should have been called for timed-out session")
    }

    // MARK: - 5. Label Generation Edge Cases

    /// Two sessions with the same cwd get different labels; setLabel overwrites auto-label.
    func testLabelGenerationEdgeCases() {
        let cwd = "/projects/myapp"
        let sid1 = "label-session-1"
        let sid2 = "label-session-2"

        manager.handle(message: TestHelpers.makeMessage(
            sessionId: sid1, event: "session_start", cwd: cwd
        ))
        manager.handle(message: TestHelpers.makeMessage(
            sessionId: sid2, event: "session_start", cwd: cwd
        ))

        let label1 = manager.sessions[sid1]?.label
        let label2 = manager.sessions[sid2]?.label

        XCTAssertNotNil(label1)
        XCTAssertNotNil(label2)
        XCTAssertNotEqual(label1, label2,
                          "Two sessions with identical cwd should get different labels")

        // The first gets "myapp", the second gets "myapp②"
        XCTAssertEqual(label1, "myapp", "First session should get plain last-component label")
        XCTAssertEqual(label2, "myapp②", "Second session with same cwd should get ② suffix")

        // setLabel overwrites the auto-generated label
        let customLabel = "my-custom-label"
        manager.handle(message: TestHelpers.makeMessage(
            sessionId: sid1, event: "set_label", label: customLabel
        ))
        XCTAssertEqual(manager.sessions[sid1]?.label, customLabel,
                       "set_label event should overwrite the auto-generated label")

        // MockScene should have received an updateCatLabel call with the custom label
        let labelUpdate = scene.updateLabelCalls.last
        XCTAssertEqual(labelUpdate?.sessionId, sid1)
        XCTAssertEqual(labelUpdate?.label, customLabel)
    }

    // MARK: - 6. Cat Cap Enforcement (max 8 cats)

    /// Creating 9 sessions should result in only 8 addCat calls to the scene.
    /// The 9th session must still be tracked in sessions dict.
    func testCatCapEnforcement() {
        for i in 1...9 {
            manager.handle(message: TestHelpers.makeMessage(
                sessionId: "cap-session-\(i)",
                event: "session_start",
                cwd: "/projects/proj\(i)"
            ))
        }

        XCTAssertEqual(scene.addCatCalls.count, 8,
                       "addCat should be called at most 8 times (cat cap)")
        XCTAssertNotNil(manager.sessions["cap-session-9"],
                        "9th session should still be tracked in sessions dict even without a cat")
        XCTAssertEqual(manager.sessions.count, 9,
                       "All 9 sessions should be in the sessions dictionary")
    }

    // MARK: - 7. Callbacks Fire Correctly

    /// onSessionCountChanged and onSessionsChanged fire with correct values.
    func testCallbacksFire() {
        var countChanges: [Int] = []
        var sessionsChanges: [[SessionInfo]] = []

        manager.onSessionCountChanged = { countChanges.append($0) }
        manager.onSessionsChanged     = { sessionsChanges.append($0) }

        manager.handle(message: TestHelpers.makeMessage(
            sessionId: "cb-session-1", event: "session_start", cwd: "/projects/a"
        ))

        XCTAssertFalse(countChanges.isEmpty, "onSessionCountChanged should have fired")
        XCTAssertEqual(countChanges.last, 1,
                       "Count should be 1 after first session_start")

        XCTAssertFalse(sessionsChanges.isEmpty, "onSessionsChanged should have fired")
        XCTAssertEqual(sessionsChanges.last?.count, 1,
                       "Sessions list should have 1 entry")
        XCTAssertEqual(sessionsChanges.last?.first?.sessionId, "cb-session-1")

        // Add a second session
        manager.handle(message: TestHelpers.makeMessage(
            sessionId: "cb-session-2", event: "session_start", cwd: "/projects/b"
        ))
        XCTAssertEqual(countChanges.last, 2)
        XCTAssertEqual(sessionsChanges.last?.count, 2)

        // End first session
        let countBefore = countChanges.count
        let sessionsBefore = sessionsChanges.count
        manager.handle(message: TestHelpers.makeMessage(
            sessionId: "cb-session-1", event: "session_end"
        ))
        XCTAssertGreaterThan(countChanges.count, countBefore,
                             "onSessionCountChanged should fire on session_end")
        XCTAssertGreaterThan(sessionsChanges.count, sessionsBefore,
                             "onSessionsChanged should fire on session_end")
        XCTAssertEqual(countChanges.last, 1)
        XCTAssertEqual(sessionsChanges.last?.count, 1)
        XCTAssertEqual(sessionsChanges.last?.first?.sessionId, "cb-session-2")
    }

    // MARK: - 8. CWD Enrichment

    /// First message arrives without cwd; second message carries cwd.
    /// The session should adopt the cwd and derive a label on the second message.
    func testCwdEnrichment() {
        let sid = "enrich-session"

        // First message has no cwd
        manager.handle(message: TestHelpers.makeMessage(
            sessionId: sid, event: "session_start"
        ))
        XCTAssertNil(manager.sessions[sid]?.cwd,
                     "Session should have nil cwd before enrichment")
        XCTAssertEqual(manager.sessions[sid]?.label, "claude",
                       "Session without cwd should get default 'claude' label")

        // Second message brings cwd
        manager.handle(message: TestHelpers.makeMessage(
            sessionId: sid, event: "thinking", cwd: "/projects/enriched"
        ))
        XCTAssertEqual(manager.sessions[sid]?.cwd, "/projects/enriched",
                       "Session should adopt cwd from subsequent message")
        XCTAssertEqual(manager.sessions[sid]?.label, "enriched",
                       "Session label should update to cwd last component after enrichment")
    }

    // MARK: - 9. EventBus Integration

    /// Sending a thinking event should publish a StateChangeEvent on EventBus.shared.stateChanged
    /// with the correct sessionId and newState.
    func testEventBusIntegration() {
        let expectation = XCTestExpectation(description: "StateChangeEvent received on EventBus")
        var receivedEvent: StateChangeEvent?

        var cancellables = Set<AnyCancellable>()
        EventBus.shared.stateChanged
            .sink { event in
                receivedEvent = event
                expectation.fulfill()
            }
            .store(in: &cancellables)

        let sid = "eventbus-session"
        manager.handle(message: TestHelpers.makeMessage(
            sessionId: sid, event: "session_start", cwd: "/projects/eventbus"
        ))
        manager.handle(message: TestHelpers.makeMessage(
            sessionId: sid, event: "thinking"
        ))

        wait(for: [expectation], timeout: 1.0)

        XCTAssertNotNil(receivedEvent, "StateChangeEvent should have been published")
        XCTAssertEqual(receivedEvent?.sessionId, sid,
                       "Event sessionId should match the session that transitioned")
        XCTAssertEqual(receivedEvent?.newState, .thinking,
                       "Event newState should be .thinking")
    }

    // MARK: - Additional Edge Cases

    /// Duplicate session_start messages for the same session id should not create
    /// a second cat or overwrite session identity.
    func testDuplicateSessionStartIsIdempotent() {
        let sid = "dup-session"

        manager.handle(message: TestHelpers.makeMessage(
            sessionId: sid, event: "session_start", cwd: "/projects/dup"
        ))
        let color = manager.sessions[sid]!.color

        // Send session_start again for the same id
        manager.handle(message: TestHelpers.makeMessage(
            sessionId: sid, event: "session_start", cwd: "/projects/dup"
        ))

        XCTAssertEqual(manager.sessions.filter { $0.key == sid }.count, 1,
                       "Duplicate session_start should not create two sessions")
        XCTAssertEqual(manager.sessions[sid]?.color, color,
                       "Color should not change on duplicate session_start")
        XCTAssertEqual(scene.addCatCalls.count, 1,
                       "addCat should only be called once for the same sessionId")
    }

    /// session_end for an unknown session id should be silently ignored.
    func testSessionEndForUnknownSessionIsSilent() {
        XCTAssertNoThrow(
            manager.handle(message: TestHelpers.makeMessage(
                sessionId: "ghost-session", event: "session_end"
            )),
            "session_end for unknown sessionId should not throw or crash"
        )
        XCTAssertTrue(manager.sessions.isEmpty)
        XCTAssertTrue(scene.removeCatCalls.isEmpty)
    }

    /// A permission_request event sets state to .permissionRequest and passes description to scene.
    func testPermissionRequestStatePropagation() {
        let sid = "perm-session"
        let desc = "Run: npm install"

        manager.handle(message: TestHelpers.makeMessage(
            sessionId: sid, event: "session_start", cwd: "/projects/perm"
        ))
        manager.handle(message: TestHelpers.makeMessage(
            sessionId: sid, event: "permission_request", tool: "Bash", description: desc
        ))

        XCTAssertEqual(manager.sessions[sid]?.state, .permissionRequest)
        XCTAssertEqual(manager.sessions[sid]?.toolDescription, desc)

        let stateCall = scene.updateStateCalls.last
        XCTAssertEqual(stateCall?.state, .permissionRequest)
        XCTAssertEqual(stateCall?.desc, desc)
    }

    /// tool_start increments toolCallCount, tool_end does not.
    func testToolCallCountIncrements() {
        let sid = "toolcount-session"

        manager.handle(message: TestHelpers.makeMessage(
            sessionId: sid, event: "session_start", cwd: "/projects/toolcount"
        ))
        XCTAssertEqual(manager.sessions[sid]?.toolCallCount, 0)

        manager.handle(message: TestHelpers.makeMessage(
            sessionId: sid, event: "tool_start", tool: "Read"
        ))
        XCTAssertEqual(manager.sessions[sid]?.toolCallCount, 1)

        manager.handle(message: TestHelpers.makeMessage(
            sessionId: sid, event: "tool_end"
        ))
        XCTAssertEqual(manager.sessions[sid]?.toolCallCount, 1,
                       "tool_end should not increment toolCallCount")

        manager.handle(message: TestHelpers.makeMessage(
            sessionId: sid, event: "tool_start", tool: "Write"
        ))
        XCTAssertEqual(manager.sessions[sid]?.toolCallCount, 2)
    }

    /// Timeout-triggered removal should fire both onSessionCountChanged and onSessionsChanged.
    func testTimeoutRemovalFiresCallbacks() {
        let sid = "timeout-cb-session"
        var countFired = false
        var sessionsFired = false

        manager.handle(message: TestHelpers.makeMessage(
            sessionId: sid, event: "session_start", cwd: "/projects/timeout-cb"
        ))

        manager.onSessionCountChanged = { _ in countFired = true }
        manager.onSessionsChanged     = { _ in sessionsFired = true }

        // Age past remove threshold
        manager.sessions[sid]?.lastActivity = Date(timeIntervalSinceNow: -(31 * 60))
        manager.checkTimeouts()

        XCTAssertTrue(countFired,   "onSessionCountChanged should fire after timeout removal")
        XCTAssertTrue(sessionsFired, "onSessionsChanged should fire after timeout removal")
    }
}
