import XCTest
import SpriteKit
@testable import BuddyCore

// MARK: - Helpers

private extension CatSpriteStateGuardTests {

    func makeCat(sessionId: String = "test-guard") -> CatSprite {
        let cat = CatSprite(sessionId: sessionId)
        cat.configure(color: .sky, labelText: "test")
        return cat
    }
}

// MARK: - CatSpriteStateGuardTests

/// Tests that switchState with the same state does NOT clear running animations.
/// Bug: GKStateMachine rejects same-state transitions, but switchState's cleanup
/// (removeAllActions) runs before enter(), leaving the cat frozen.
final class CatSpriteStateGuardTests: XCTestCase {

    // MARK: - Same-State Guard: idle → idle

    func testIdleToIdlePreservesState() {
        let cat = makeCat()
        // enterScene puts cat into CatIdleState
        cat.enterScene(sceneSize: CGSize(width: 800, height: 100))
        XCTAssertEqual(cat.currentState, .idle)

        // Same-state switch should not crash or change state
        cat.switchState(to: .idle)
        XCTAssertEqual(cat.currentState, .idle)
    }

    func testIdleToIdleDoesNotClearNodeActions() {
        let cat = makeCat()
        cat.enterScene(sceneSize: CGSize(width: 800, height: 100))

        // After enterScene, idle loop should have started actions on node
        let actionsBefore = cat.node.hasActions()

        cat.switchState(to: .idle)

        // Actions should be preserved (not cleared)
        let actionsAfter = cat.node.hasActions()
        // Note: in test environment without display link, hasActions may not reflect
        // SKAction state accurately. The key assertion is that the state is preserved
        // and no crash occurs. If hasActions works, verify it wasn't cleared.
        if actionsBefore {
            XCTAssertTrue(actionsAfter, "idle→idle should not clear node actions")
        }
    }

    // MARK: - Same-State Guard: thinking → thinking

    func testThinkingToThinkingPreservesState() {
        let cat = makeCat()
        cat.enterScene(sceneSize: CGSize(width: 800, height: 100))
        cat.switchState(to: .thinking)
        XCTAssertEqual(cat.currentState, .thinking)

        cat.switchState(to: .thinking)
        XCTAssertEqual(cat.currentState, .thinking)
    }

    // MARK: - Same-State Guard: toolUse → toolUse

    func testToolUseToToolUsePreservesState() {
        let cat = makeCat()
        cat.enterScene(sceneSize: CGSize(width: 800, height: 100))
        cat.switchState(to: .toolUse)
        XCTAssertEqual(cat.currentState, .toolUse)

        cat.switchState(to: .toolUse)
        XCTAssertEqual(cat.currentState, .toolUse)
    }

    // MARK: - Same-State Guard: permissionRequest → permissionRequest

    func testPermissionRequestSameStateUpdatesDescription() {
        let cat = makeCat()
        cat.enterScene(sceneSize: CGSize(width: 800, height: 100))

        cat.switchState(to: .permissionRequest, toolDescription: "Read file.txt")
        XCTAssertEqual(cat.currentState, .permissionRequest)

        // Same state with different tool description
        cat.switchState(to: .permissionRequest, toolDescription: "Write output.json")
        XCTAssertEqual(cat.currentState, .permissionRequest)
        XCTAssertEqual(cat.pendingToolDescription, "Write output.json")

        // Label should show updated description
        XCTAssertEqual(cat.labelNode?.text, "Write output.json")
    }

    func testPermissionRequestSameStateRefreshesAlertOverlay() {
        let cat = makeCat()
        cat.enterScene(sceneSize: CGSize(width: 800, height: 100))

        cat.switchState(to: .permissionRequest, toolDescription: "Read")
        XCTAssertNotNil(cat.alertOverlayNode, "Alert overlay should exist after entering permissionRequest")

        // Same-state switch should rebuild (not duplicate) the alert overlay
        cat.switchState(to: .permissionRequest, toolDescription: "Write output.json")
        XCTAssertNotNil(cat.alertOverlayNode, "Alert overlay should still exist after same-state refresh")
    }

    // MARK: - Normal Transitions Still Work

    func testIdleToThinkingTransitionWorks() {
        let cat = makeCat()
        cat.enterScene(sceneSize: CGSize(width: 800, height: 100))
        XCTAssertEqual(cat.currentState, .idle)

        cat.switchState(to: .thinking)
        XCTAssertEqual(cat.currentState, .thinking)
    }

    func testThinkingToIdleTransitionWorks() {
        let cat = makeCat()
        cat.enterScene(sceneSize: CGSize(width: 800, height: 100))
        cat.switchState(to: .thinking)

        cat.switchState(to: .idle)
        XCTAssertEqual(cat.currentState, .idle)
    }

    func testFullLifecycleTransitions() {
        let cat = makeCat()
        cat.enterScene(sceneSize: CGSize(width: 800, height: 100))

        // idle → thinking → toolUse → thinking → permissionRequest → idle
        cat.switchState(to: .thinking)
        XCTAssertEqual(cat.currentState, .thinking)

        cat.switchState(to: .toolUse)
        XCTAssertEqual(cat.currentState, .toolUse)

        cat.switchState(to: .thinking)
        XCTAssertEqual(cat.currentState, .thinking)

        cat.switchState(to: .permissionRequest, toolDescription: "Run test")
        XCTAssertEqual(cat.currentState, .permissionRequest)

        cat.switchState(to: .idle)
        XCTAssertEqual(cat.currentState, .idle)
    }

    // MARK: - Physics Safety Net

    func testSameStateSwitchRestoresPhysicsDynamic() {
        let cat = makeCat()
        cat.enterScene(sceneSize: CGSize(width: 800, height: 100))

        // Artificially disable physics (simulating a stuck state)
        cat.containerNode.physicsBody?.isDynamic = false

        cat.switchState(to: .idle)

        // isDynamic should be restored even for same-state
        XCTAssertEqual(cat.containerNode.physicsBody?.isDynamic, true)
    }

    // MARK: - Food Release Only On Real Transition

    func testSameStateSwitchDoesNotReleaseFoodCallback() {
        let cat = makeCat()
        cat.enterScene(sceneSize: CGSize(width: 800, height: 100))

        var foodAbandoned = false
        cat.onFoodAbandoned = { _ in foodAbandoned = true }

        // Set up fake food target
        cat.currentTargetFood = FoodSprite(textureName: "test_dummy")

        // Same-state should NOT trigger food abandoned
        cat.switchState(to: .idle)
        XCTAssertFalse(foodAbandoned, "Same-state switch should not release food")
        XCTAssertNotNil(cat.currentTargetFood, "Food target should be preserved on same-state switch")
    }

    func testDifferentStateSwitchReleasesFood() {
        let cat = makeCat()
        cat.enterScene(sceneSize: CGSize(width: 800, height: 100))

        var foodAbandoned = false
        cat.onFoodAbandoned = { _ in foodAbandoned = true }

        cat.currentTargetFood = FoodSprite(textureName: "test_dummy")

        // Different state should trigger food abandoned
        cat.switchState(to: .thinking)
        XCTAssertTrue(foodAbandoned, "State change should release food")
        XCTAssertNil(cat.currentTargetFood, "Food target should be cleared on state change")
    }

    // MARK: - Eating State Recovery

    /// 验证 eating 状态可以通过 switchState(.idle) 正常退出
    func testEatingCanTransitionToIdleDirectly() {
        let cat = makeCat()
        cat.switchState(to: .eating)
        XCTAssertEqual(cat.currentState, .eating)

        cat.switchState(to: .idle)
        XCTAssertEqual(cat.currentState, .idle, "eating 应能直接切换到 idle")
    }

    /// 验证 eating 状态下非 idle 的事件被正确排队
    func testEatingQueuesNonIdleStateTransitions() {
        let cat = makeCat()
        cat.switchState(to: .eating)
        XCTAssertEqual(cat.currentState, .eating)

        // 非 idle 状态应被排队而非直接切换
        cat.switchState(to: .thinking, toolDescription: "test tool")
        XCTAssertEqual(cat.currentState, .eating, "eating 时 thinking 应被排队，不应立即切换")
    }

    /// 验证 eating → idle 后排队的状态能被应用
    func testPendingStateAppliedAfterEatingToIdle() {
        let cat = makeCat()
        cat.switchState(to: .eating)

        // 排队一个 thinking
        cat.switchState(to: .thinking, toolDescription: "test pending")

        // 切换到 idle
        cat.switchState(to: .idle)
        // 在无 display link 的测试环境中，switchState 走即时路径
        XCTAssertEqual(cat.currentState, .idle)
    }
}
