import XCTest
@testable import BuddyCore

final class HookMessageTests: XCTestCase {

    // MARK: - Event Parsing

    func testDecodeSessionStart() throws {
        let json = """
        {"session_id":"abc-123","event":"session_start","timestamp":1700000000,"cwd":"/tmp/test"}
        """
        let msg = try JSONDecoder().decode(HookMessage.self, from: Data(json.utf8))
        XCTAssertEqual(msg.sessionId, "abc-123")
        XCTAssertEqual(msg.event, .sessionStart)
        XCTAssertEqual(msg.cwd, "/tmp/test")
        XCTAssertNil(msg.entityState) // sessionStart maps to nil
    }

    func testDecodeToolStart() throws {
        let json = """
        {"session_id":"s1","event":"tool_start","timestamp":1700000000,"tool":"Bash","description":"Run tests"}
        """
        let msg = try JSONDecoder().decode(HookMessage.self, from: Data(json.utf8))
        XCTAssertEqual(msg.event, .toolStart)
        XCTAssertEqual(msg.tool, "Bash")
        XCTAssertEqual(msg.description, "Run tests")
        XCTAssertEqual(msg.entityState, .toolUse)
    }

    func testDecodePermissionRequest() throws {
        let json = """
        {"session_id":"s1","event":"permission_request","timestamp":1700000000,"tool":"Bash","description":"npm install"}
        """
        let msg = try JSONDecoder().decode(HookMessage.self, from: Data(json.utf8))
        XCTAssertEqual(msg.event, .permissionRequest)
        XCTAssertEqual(msg.entityState, .permissionRequest)
        XCTAssertEqual(msg.description, "npm install")
    }

    func testDecodeThinking() throws {
        let json = """
        {"session_id":"s1","event":"thinking","timestamp":1700000000}
        """
        let msg = try JSONDecoder().decode(HookMessage.self, from: Data(json.utf8))
        XCTAssertEqual(msg.entityState, .thinking)
        XCTAssertNil(msg.tool)
    }

    func testDecodeIdle() throws {
        let json = """
        {"session_id":"s1","event":"idle","timestamp":1700000000}
        """
        let msg = try JSONDecoder().decode(HookMessage.self, from: Data(json.utf8))
        XCTAssertEqual(msg.entityState, .idle)
    }

    func testDecodeSessionEnd() throws {
        let json = """
        {"session_id":"s1","event":"session_end","timestamp":1700000000}
        """
        let msg = try JSONDecoder().decode(HookMessage.self, from: Data(json.utf8))
        XCTAssertEqual(msg.event, .sessionEnd)
        XCTAssertNil(msg.entityState)
    }

    func testDecodeWithTerminalId() throws {
        let json = """
        {"session_id":"s1","event":"session_start","timestamp":1700000000,"terminal_id":"UUID-123"}
        """
        let msg = try JSONDecoder().decode(HookMessage.self, from: Data(json.utf8))
        XCTAssertEqual(msg.terminalId, "UUID-123")
    }

    // MARK: - Edge Cases

    func testDecodeMinimalMessage() throws {
        let json = """
        {"session_id":"s1","event":"idle","timestamp":0}
        """
        let msg = try JSONDecoder().decode(HookMessage.self, from: Data(json.utf8))
        XCTAssertEqual(msg.sessionId, "s1")
        XCTAssertNil(msg.tool)
        XCTAssertNil(msg.cwd)
        XCTAssertNil(msg.description)
        XCTAssertNil(msg.terminalId)
        XCTAssertNil(msg.pid)
    }

    func testDecodeWithSpecialCharactersInDescription() throws {
        let json = """
        {"session_id":"s1","event":"permission_request","timestamp":1700000000,"description":"Run: echo \\"hello world\\""}
        """
        let msg = try JSONDecoder().decode(HookMessage.self, from: Data(json.utf8))
        XCTAssertEqual(msg.description, "Run: echo \"hello world\"")
    }

    func testDecodeInvalidEventFails() {
        let json = """
        {"session_id":"s1","event":"unknown_event","timestamp":1700000000}
        """
        XCTAssertThrowsError(try JSONDecoder().decode(HookMessage.self, from: Data(json.utf8)))
    }

    func testDecodeMissingTimestampFails() {
        let json = """
        {"session_id":"s1","event":"idle"}
        """
        XCTAssertThrowsError(try JSONDecoder().decode(HookMessage.self, from: Data(json.utf8)))
    }

    // MARK: - EntityState Mapping

    func testAllEventEntityStateMappings() throws {
        let mappings: [(String, EntityState?)] = [
            ("session_start", nil),
            ("thinking", .thinking),
            ("tool_start", .toolUse),
            ("tool_end", .thinking),
            ("idle", .idle),
            ("session_end", nil),
            ("set_label", nil),
            ("permission_request", .permissionRequest),
            ("task_complete", .taskComplete),
        ]
        for (event, expected) in mappings {
            let json = """
            {"session_id":"s1","event":"\(event)","timestamp":1700000000}
            """
            let msg = try JSONDecoder().decode(HookMessage.self, from: Data(json.utf8))
            XCTAssertEqual(msg.entityState, expected, "Event \(event) should map to \(String(describing: expected))")
        }
    }
}
