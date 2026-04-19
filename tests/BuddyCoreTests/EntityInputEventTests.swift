import XCTest
@testable import BuddyCore

final class EntityInputEventTests: XCTestCase {

    func testFromHookEvent_sessionStart() {
        let e = EntityInputEvent.from(hookEvent: .sessionStart, tool: nil, description: nil)
        if case .sessionStart = e { return }
        XCTFail("expected .sessionStart, got \(e)")
    }

    func testFromHookEvent_thinking() {
        let e = EntityInputEvent.from(hookEvent: .thinking, tool: nil, description: nil)
        if case .thinking = e { return }
        XCTFail("expected .thinking, got \(e)")
    }

    func testFromHookEvent_userPromptSubmit() {
        let e = EntityInputEvent.from(hookEvent: .userPromptSubmit, tool: nil, description: nil)
        if case .userPromptSubmit = e { return }
        XCTFail("expected .userPromptSubmit, got \(e)")
    }

    func testFromHookEvent_toolStart_withTool() {
        let e = EntityInputEvent.from(hookEvent: .toolStart, tool: "Read", description: "Reading file")
        if case .toolStart(let name, let desc) = e {
            XCTAssertEqual(name, "Read")
            XCTAssertEqual(desc, "Reading file")
            return
        }
        XCTFail("expected .toolStart, got \(e)")
    }

    func testFromHookEvent_toolEnd_withTool() {
        let e = EntityInputEvent.from(hookEvent: .toolEnd, tool: "Read", description: nil)
        if case .toolEnd(let name) = e {
            XCTAssertEqual(name, "Read")
            return
        }
        XCTFail("expected .toolEnd, got \(e)")
    }

    func testFromHookEvent_permissionRequest_carriesDescription() {
        let e = EntityInputEvent.from(hookEvent: .permissionRequest, tool: "Bash", description: "rm -rf /")
        if case .permissionRequest(let desc) = e {
            XCTAssertEqual(desc, "rm -rf /")
            return
        }
        XCTFail("expected .permissionRequest, got \(e)")
    }

    func testFromHookEvent_taskComplete() {
        let e = EntityInputEvent.from(hookEvent: .taskComplete, tool: nil, description: nil)
        if case .taskComplete = e { return }
        XCTFail("expected .taskComplete, got \(e)")
    }

    func testFromHookEvent_sessionEnd() {
        let e = EntityInputEvent.from(hookEvent: .sessionEnd, tool: nil, description: nil)
        if case .sessionEnd = e { return }
        XCTFail("expected .sessionEnd, got \(e)")
    }
}
