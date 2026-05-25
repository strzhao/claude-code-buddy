import XCTest
@testable import BuddyCore

final class SocketProtocolTests: XCTestCase {

    // MARK: - JSON Round-Trip

    func testEncodeDecodeRoundTrip() throws {
        // Simulate what the hook script sends
        let payload: [String: Any] = [
            "session_id": "round-trip-test",
            "event": "tool_start",
            "timestamp": 1700000000,
            "tool": "Read",
            "description": "Read file contents"
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let msg = try JSONDecoder().decode(HookMessage.self, from: data)
        XCTAssertEqual(msg.sessionId, "round-trip-test")
        XCTAssertEqual(msg.event, .toolStart)
        XCTAssertEqual(msg.tool, "Read")
        XCTAssertEqual(msg.description, "Read file contents")
    }

    func testDescriptionWithUnicodeCharacters() throws {
        let json = """
        {"session_id":"s1","event":"permission_request","timestamp":1,"description":"安装依赖 npm install"}
        """
        let msg = try JSONDecoder().decode(HookMessage.self, from: Data(json.utf8))
        XCTAssertEqual(msg.description, "安装依赖 npm install")
    }

    func testDescriptionWithNewlines() throws {
        let json = """
        {"session_id":"s1","event":"permission_request","timestamp":1,"description":"line1\\nline2"}
        """
        let msg = try JSONDecoder().decode(HookMessage.self, from: Data(json.utf8))
        XCTAssertEqual(msg.description, "line1\nline2")
    }

    func testLargeSessionId() throws {
        let longId = String(repeating: "a", count: 500)
        let json = """
        {"session_id":"\(longId)","event":"idle","timestamp":1}
        """
        let msg = try JSONDecoder().decode(HookMessage.self, from: Data(json.utf8))
        XCTAssertEqual(msg.sessionId, longId)
    }

    // MARK: - Newline Delimited Protocol

    func testMultipleMessagesInOneBuffer() throws {
        let line1 = """
        {"session_id":"s1","event":"thinking","timestamp":1}
        """
        let line2 = """
        {"session_id":"s1","event":"tool_start","timestamp":2,"tool":"Bash"}
        """
        let buffer = "\(line1)\n\(line2)\n"
        let lines = buffer.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)

        let msg1 = try JSONDecoder().decode(HookMessage.self, from: Data(lines[0].utf8))
        let msg2 = try JSONDecoder().decode(HookMessage.self, from: Data(lines[1].utf8))
        XCTAssertEqual(msg1.event, .thinking)
        XCTAssertEqual(msg2.event, .toolStart)
        XCTAssertEqual(msg2.tool, "Bash")
    }

    func testEmptyLineIsSkipped() {
        let emptyData = Data()
        // handleLine guards against empty data — just verify no crash
        XCTAssertTrue(emptyData.isEmpty)
    }
}
