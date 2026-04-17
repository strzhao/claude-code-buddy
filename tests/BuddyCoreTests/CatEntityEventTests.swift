import XCTest
@testable import BuddyCore

final class CatEntityEventTests: XCTestCase {

    func testHandleThinking_entersThinkingState() {
        let cat = CatEntity(sessionId: "test-thinking")
        cat.handle(event: .thinking)
        XCTAssertEqual(cat.currentState, .thinking)
    }

    func testHandleToolStart_entersToolUseState() {
        let cat = CatEntity(sessionId: "test-tool")
        cat.handle(event: .toolStart(name: "Read", description: "x"))
        XCTAssertEqual(cat.currentState, .toolUse)
    }

    func testHandlePermissionRequest_entersPermissionState() {
        let cat = CatEntity(sessionId: "test-perm")
        cat.handle(event: .permissionRequest(description: "risky"))
        XCTAssertEqual(cat.currentState, .permissionRequest)
    }

    func testHandleTaskComplete_entersTaskCompleteState() {
        let cat = CatEntity(sessionId: "test-done")
        cat.handle(event: .taskComplete)
        XCTAssertEqual(cat.currentState, .taskComplete)
    }

    func testHandleHoverEnter_queuesHoverScaleAction() {
        let cat = CatEntity(sessionId: "test-hover")
        // applyHoverScale runs an SKAction on containerNode (not node.yScale directly).
        // In XCTest without a display link, actions don't tick — verify the action was queued.
        cat.handle(event: .hoverEnter)
        XCTAssertNotNil(cat.containerNode.action(forKey: "hoverScale"), "hoverScale action should be queued on containerNode")
    }

    func testHandleHoverExit_queuesRestoreScaleAction() {
        let cat = CatEntity(sessionId: "test-hover2")
        cat.handle(event: .hoverEnter)
        cat.handle(event: .hoverExit)
        // After hoverExit the restore-to-1.0 action replaces the enter action under the same key
        XCTAssertNotNil(cat.containerNode.action(forKey: "hoverScale"), "restore hoverScale action should be queued on containerNode")
    }

    func testIsDebug_trueForDebugPrefix() {
        let cat = CatEntity(sessionId: "debug-A")
        XCTAssertTrue(cat.isDebug)
    }

    func testIsDebug_falseForRegular() {
        let cat = CatEntity(sessionId: "abc-123")
        XCTAssertFalse(cat.isDebug)
    }
}
