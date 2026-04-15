import XCTest
@testable import BuddyCore

final class QueryHandlerTests: XCTestCase {

    private var manager: SessionManager!
    private var scene: MockScene!
    private var eventStore: EventStore!
    private var handler: QueryHandler!

    override func setUp() {
        scene = MockScene()
        let (m, _) = TestHelpers.makeManager(scene: scene)
        manager = m
        eventStore = manager.eventStore
        handler = QueryHandler(sessionManager: manager, scene: scene, eventStore: eventStore)
    }

    // MARK: - Inspect

    func testInspectSessionNotFound() {
        let data = handler.handle(query: ["action": "inspect", "session_id": "nonexistent"])
        let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["status"] as? String, "error")
        XCTAssertTrue((json["message"] as? String)?.contains("not found") == true)
    }

    func testInspectAllEmpty() {
        let data = handler.handle(query: ["action": "inspect"])
        let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["status"] as? String, "ok")

        let dataDict = json["data"] as! [String: Any]
        let sessions = dataDict["sessions"] as! [[String: Any]]
        XCTAssertEqual(sessions.count, 0)
        XCTAssertEqual(dataDict["total"] as? Int, 0)
    }

    func testInspectSingleSession() {
        // Create a session
        let msg = TestHelpers.makeMessage(sessionId: "s1", event: "thinking", cwd: "/tmp/project")
        manager.handle(message: msg)

        let data = handler.handle(query: ["action": "inspect", "session_id": "s1"])
        let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["status"] as? String, "ok")

        let dataDict = json["data"] as! [String: Any]
        let session = dataDict["session"] as! [String: Any]
        XCTAssertEqual(session["id"] as? String, "s1")
        XCTAssertEqual(session["state"] as? String, "thinking")
        XCTAssertEqual(session["cwd"] as? String, "/tmp/project")
    }

    func testInspectAllSessions() {
        let msg1 = TestHelpers.makeMessage(sessionId: "s1", event: "thinking")
        let msg2 = TestHelpers.makeMessage(sessionId: "s2", event: "idle")
        manager.handle(message: msg1)
        manager.handle(message: msg2)

        let data = handler.handle(query: ["action": "inspect"])
        let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        let dataDict = json["data"] as! [String: Any]
        let sessions = dataDict["sessions"] as! [[String: Any]]
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(dataDict["total"] as? Int, 2)
    }

    // MARK: - Events

    func testEventsEmpty() {
        let data = handler.handle(query: ["action": "events"])
        let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["status"] as? String, "ok")

        let dataDict = json["data"] as! [String: Any]
        let events = dataDict["events"] as! [[String: Any]]
        XCTAssertEqual(events.count, 0)
        XCTAssertEqual(dataDict["total_stored"] as? Int, 0)
    }

    func testEventsAfterStateChange() {
        let msg = TestHelpers.makeMessage(sessionId: "s1", event: "thinking")
        manager.handle(message: msg)

        let data = handler.handle(query: ["action": "events"])
        let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        let dataDict = json["data"] as! [String: Any]
        let events = dataDict["events"] as! [[String: Any]]

        // Should have session_started + state_changed
        XCTAssertTrue(events.count >= 2)
        let types = events.compactMap { $0["type"] as? String }
        XCTAssertTrue(types.contains("session_started"))
        XCTAssertTrue(types.contains("state_changed"))
    }

    func testEventsFilteredBySessionId() {
        manager.handle(message: TestHelpers.makeMessage(sessionId: "s1", event: "thinking"))
        manager.handle(message: TestHelpers.makeMessage(sessionId: "s2", event: "idle"))

        let data = handler.handle(query: ["action": "events", "session_id": "s1"])
        let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        let dataDict = json["data"] as! [String: Any]
        let events = dataDict["events"] as! [[String: Any]]

        XCTAssertTrue(events.allSatisfy { $0["session_id"] as? String == "s1" })
    }

    func testEventsWithLast() {
        for i in 0..<5 {
            manager.handle(message: TestHelpers.makeMessage(sessionId: "s1", event: "thinking"))
            // Need to generate different events; but we can just check count
        }

        let data = handler.handle(query: ["action": "events", "last": 3])
        let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        let dataDict = json["data"] as! [String: Any]
        let events = dataDict["events"] as! [[String: Any]]
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(dataDict["count"] as? Int, 3)
    }

    // MARK: - Health

    func testHealth() {
        let data = handler.handle(query: ["action": "health"])
        let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["status"] as? String, "ok")

        let dataDict = json["data"] as! [String: Any]
        XCTAssertNotNil(dataDict["socket"])
        XCTAssertNotNil(dataDict["sessions"])
        XCTAssertNotNil(dataDict["event_store"])
        XCTAssertNotNil(dataDict["scene"])
        XCTAssertNotNil(dataDict["version"])

        let socket = dataDict["socket"] as! [String: Any]
        XCTAssertNotNil(socket["path"])

        let sessions = dataDict["sessions"] as! [String: Any]
        XCTAssertEqual(sessions["max"] as? Int, 8)
    }

    // MARK: - Error Handling

    func testUnknownAction() {
        let data = handler.handle(query: ["action": "unknown"])
        let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["status"] as? String, "error")
        XCTAssertTrue((json["message"] as? String)?.contains("unknown action") == true)
    }

    func testMissingAction() {
        let data = handler.handle(query: [:])
        let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["status"] as? String, "error")
        XCTAssertTrue((json["message"] as? String)?.contains("missing") == true)
    }
}
