import XCTest
@testable import BuddyCore

final class CatStateTests: XCTestCase {

    func testAllCasesCount() {
        XCTAssertEqual(CatState.allCases.count, 5)
    }

    func testRawValues() {
        XCTAssertEqual(CatState.idle.rawValue, "idle")
        XCTAssertEqual(CatState.thinking.rawValue, "thinking")
        XCTAssertEqual(CatState.toolUse.rawValue, "tool_use")
        XCTAssertEqual(CatState.permissionRequest.rawValue, "waiting")
    }

    func testRawValueRoundTrip() {
        for state in CatState.allCases {
            XCTAssertEqual(CatState(rawValue: state.rawValue), state)
        }
    }

    func testInvalidRawValue() {
        XCTAssertNil(CatState(rawValue: "running"))
        XCTAssertNil(CatState(rawValue: ""))
    }
}

final class SessionInfoTests: XCTestCase {

    func testCreation() {
        let info = SessionInfo(
            sessionId: "test-123",
            label: "my-project",
            color: .coral,
            cwd: "/Users/test/my-project",
            pid: 12345,
            terminalId: "UUID-ABC",
            state: .idle,
            lastActivity: Date(),
            toolDescription: nil,
            totalTokens: 0,
            toolCallCount: 0
        )
        XCTAssertEqual(info.sessionId, "test-123")
        XCTAssertEqual(info.label, "my-project")
        XCTAssertEqual(info.color, .coral)
        XCTAssertEqual(info.state, .idle)
        XCTAssertEqual(info.pid, 12345)
        XCTAssertEqual(info.terminalId, "UUID-ABC")
        XCTAssertNil(info.toolDescription)
    }

    func testMutableFields() {
        var info = SessionInfo(
            sessionId: "s1",
            label: "old",
            color: .teal,
            state: .idle,
            lastActivity: Date(),
            totalTokens: 0,
            toolCallCount: 0
        )
        info.label = "new-label"
        info.state = .thinking
        info.toolDescription = "Analyzing code"
        info.cwd = "/tmp"

        XCTAssertEqual(info.label, "new-label")
        XCTAssertEqual(info.state, .thinking)
        XCTAssertEqual(info.toolDescription, "Analyzing code")
        XCTAssertEqual(info.cwd, "/tmp")
    }
}
