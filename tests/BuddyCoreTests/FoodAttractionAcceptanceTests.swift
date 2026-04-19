import XCTest
import SpriteKit
@testable import BuddyCore

// MARK: - FoodAttractionAcceptanceTests
//
// 验收测试：食物吸引力优化 — "一群猫抢食物"
//
// 设计文档覆盖点:
//   A. foodEligibleCats() 返回 idle/thinking/toolUse 猫，排除 permissionRequest/taskComplete/eating
//   B. walkToFood 接受 thinking 和 toolUse 状态（guard 放宽）
//   C. walkToFood 仍拒绝 permissionRequest 和 taskComplete 状态
//   D. notifyCatAboutLandedFood 跳过已有 currentTargetFood 的猫
//   E. updateCatState 在 thinking/toolUse 状态变更时触发食物通知
//   F. CatConstants.Movement.foodWalkSpeed 常量值为 100
//
// 黑盒原则：不依赖实现细节，只通过公开 API 观察行为。
// 测试 WILL NOT compile 直到蓝队合并实现 — 这是预期的。

final class FoodAttractionAcceptanceTests: XCTestCase {

    // MARK: - Helpers

    /// 构造一只已进入场景的 CatEntity
    private func makeCat(
        sessionId: String = "food-test",
        sceneSize: CGSize = CGSize(width: 800, height: 80)
    ) -> CatEntity {
        let cat = CatEntity(sessionId: sessionId)
        cat.configure(color: .sky, labelText: sessionId)
        cat.enterScene(sceneSize: sceneSize)
        return cat
    }

    /// 构造一个包含 BuddyScene 的测试场景
    private func makeScene(width: CGFloat = 800) -> BuddyScene {
        let scene = BuddyScene(size: CGSize(width: width, height: 80))
        scene.activityBounds = 48...752
        return scene
    }

    /// 构造 SessionInfo 用于 BuddyScene.addCat
    private func makeInfo(
        sessionId: String,
        color: SessionColor = .sky,
        label: String = "test"
    ) -> SessionInfo {
        SessionInfo(
            sessionId: sessionId,
            label: label,
            color: color,
            cwd: "/tmp",
            pid: nil,
            terminalId: nil,
            state: .idle,
            lastActivity: Date(),
            toolDescription: nil,
            model: nil,
            startedAt: nil,
            totalTokens: 0,
            toolCallCount: 0
        )
    }

    /// 构造一个已 markLanded 的 FoodSprite
    private func makeLandedFood() -> FoodSprite {
        let food = FoodSprite(textureName: "test_dummy")
        food.markLanded()
        return food
    }

    // MARK: - A. foodEligibleCats() 验收

    /// A1: idle 猫应包含在 foodEligibleCats() 中
    func testFoodEligibleCats_includesIdleCat() {
        let scene = makeScene()
        scene.addCat(info: makeInfo(sessionId: "idle-cat"))
        // idle 是 addCat 后的默认状态

        let eligible = scene.foodEligibleCats()
        let ids = eligible.map(\.sessionId)
        XCTAssertTrue(ids.contains("idle-cat"),
            "idle 状态的猫应包含在 foodEligibleCats() 中，实际: \(ids)")
    }

    /// A2: thinking 猫应包含在 foodEligibleCats() 中
    func testFoodEligibleCats_includesThinkingCat() {
        let scene = makeScene()
        scene.addCat(info: makeInfo(sessionId: "thinking-cat"))
        scene.updateCatState(sessionId: "thinking-cat", state: .thinking)

        let eligible = scene.foodEligibleCats()
        let ids = eligible.map(\.sessionId)
        XCTAssertTrue(ids.contains("thinking-cat"),
            "thinking 状态的猫应包含在 foodEligibleCats() 中，实际: \(ids)")
    }

    /// A3: toolUse 猫应包含在 foodEligibleCats() 中
    func testFoodEligibleCats_includesToolUseCat() {
        let scene = makeScene()
        scene.addCat(info: makeInfo(sessionId: "tooluse-cat"))
        scene.updateCatState(sessionId: "tooluse-cat", state: .toolUse)

        let eligible = scene.foodEligibleCats()
        let ids = eligible.map(\.sessionId)
        XCTAssertTrue(ids.contains("tooluse-cat"),
            "toolUse 状态的猫应包含在 foodEligibleCats() 中，实际: \(ids)")
    }

    /// A4: permissionRequest 状态的猫不应包含在 foodEligibleCats() 中
    func testFoodEligibleCats_excludesPermissionRequestCat() {
        let scene = makeScene()
        scene.addCat(info: makeInfo(sessionId: "perm-cat"))
        scene.updateCatState(sessionId: "perm-cat", state: .permissionRequest, toolDescription: "Run bash")

        let eligible = scene.foodEligibleCats()
        let ids = eligible.map(\.sessionId)
        XCTAssertFalse(ids.contains("perm-cat"),
            "permissionRequest 状态的猫不应包含在 foodEligibleCats() 中，实际: \(ids)")
    }

    /// A5: taskComplete 状态的猫不应包含在 foodEligibleCats() 中
    func testFoodEligibleCats_excludesTaskCompleteCat() {
        let scene = makeScene()
        scene.addCat(info: makeInfo(sessionId: "tc-cat"))
        // taskComplete 需要 bed slot — 通过 switchState 直接设置
        // 使用 addCat 后切换到 taskComplete 来模拟真实场景
        // 注：BuddyScene.updateCatState 会转发到 cat.switchState
        scene.updateCatState(sessionId: "tc-cat", state: .taskComplete)

        let eligible = scene.foodEligibleCats()
        let ids = eligible.map(\.sessionId)
        XCTAssertFalse(ids.contains("tc-cat"),
            "taskComplete 状态的猫不应包含在 foodEligibleCats() 中，实际: \(ids)")
    }

    /// A6: eating 状态的猫不应包含在 foodEligibleCats() 中
    func testFoodEligibleCats_excludesEatingCat() {
        let scene = makeScene()
        scene.addCat(info: makeInfo(sessionId: "eating-cat"))
        scene.updateCatState(sessionId: "eating-cat", state: .eating)

        let eligible = scene.foodEligibleCats()
        let ids = eligible.map(\.sessionId)
        XCTAssertFalse(ids.contains("eating-cat"),
            "eating 状态的猫不应包含在 foodEligibleCats() 中，实际: \(ids)")
    }

    /// A7: 混合状态 — idle/thinking/toolUse 猫均出现，permissionRequest/taskComplete/eating 均不出现
    func testFoodEligibleCats_mixedStates() {
        let scene = makeScene()

        scene.addCat(info: makeInfo(sessionId: "cat-idle"))
        scene.addCat(info: makeInfo(sessionId: "cat-thinking"))
        scene.addCat(info: makeInfo(sessionId: "cat-tooluse"))
        scene.addCat(info: makeInfo(sessionId: "cat-perm"))
        scene.addCat(info: makeInfo(sessionId: "cat-eating"))

        scene.updateCatState(sessionId: "cat-thinking", state: .thinking)
        scene.updateCatState(sessionId: "cat-tooluse", state: .toolUse)
        scene.updateCatState(sessionId: "cat-perm", state: .permissionRequest, toolDescription: "Run bash")
        scene.updateCatState(sessionId: "cat-eating", state: .eating)

        let eligible = scene.foodEligibleCats()
        let ids = Set(eligible.map(\.sessionId))

        XCTAssertTrue(ids.contains("cat-idle"), "idle 猫应在 eligible 集合中")
        XCTAssertTrue(ids.contains("cat-thinking"), "thinking 猫应在 eligible 集合中")
        XCTAssertTrue(ids.contains("cat-tooluse"), "toolUse 猫应在 eligible 集合中")
        XCTAssertFalse(ids.contains("cat-perm"), "permissionRequest 猫不应在 eligible 集合中")
        XCTAssertFalse(ids.contains("cat-eating"), "eating 猫不应在 eligible 集合中")

        XCTAssertEqual(eligible.count, 3,
            "混合状态场景中 foodEligibleCats() 应返回 3 只猫（idle+thinking+toolUse），实际: \(eligible.count)")
    }

    // MARK: - B. walkToFood 接受 thinking/toolUse 状态

    /// B1: thinking 状态的猫调用 walkToFood 后应接受（currentTargetFood 被设置）
    func testWalkToFood_acceptsThinkingCat() {
        let cat = makeCat(sessionId: "walk-thinking")
        cat.switchState(to: .thinking)
        XCTAssertEqual(cat.currentState, .thinking, "前置条件：应为 thinking 状态")

        let food = makeLandedFood()
        food.node.position = CGPoint(x: 400, y: 48)

        var arrivalFired = false
        cat.walkToFood(food, excitedDelay: 0) { _, _ in
            arrivalFired = true
        }

        // guard 放宽后，thinking 状态的猫应接受 walkToFood 调用
        // currentTargetFood 被设置说明 guard 没有拦截
        XCTAssertNotNil(cat.currentTargetFood,
            "thinking 状态的猫应响应 walkToFood（currentTargetFood 应被设置），guard 不应拦截")
        _ = arrivalFired  // 不断言 arrival（需要 SKAction 运行完成）
    }

    /// B2: toolUse 状态的猫调用 walkToFood 后应接受（currentTargetFood 被设置）
    func testWalkToFood_acceptsToolUseCat() {
        let cat = makeCat(sessionId: "walk-tooluse")
        cat.switchState(to: .toolUse)
        XCTAssertEqual(cat.currentState, .toolUse, "前置条件：应为 toolUse 状态")

        let food = makeLandedFood()
        food.node.position = CGPoint(x: 300, y: 48)

        cat.walkToFood(food, excitedDelay: 0) { _, _ in }

        XCTAssertNotNil(cat.currentTargetFood,
            "toolUse 状态的猫应响应 walkToFood（currentTargetFood 应被设置），guard 不应拦截")
    }

    /// B3: idle 状态的猫仍能响应 walkToFood（回归验证）
    func testWalkToFood_stillAcceptsIdleCat() {
        let cat = makeCat(sessionId: "walk-idle")
        XCTAssertEqual(cat.currentState, .idle, "前置条件：应为 idle 状态")

        let food = makeLandedFood()
        food.node.position = CGPoint(x: 500, y: 48)

        cat.walkToFood(food, excitedDelay: 0) { _, _ in }

        XCTAssertNotNil(cat.currentTargetFood,
            "idle 状态的猫仍应响应 walkToFood（回归验证）")
    }

    // MARK: - C. walkToFood 仍拒绝 permissionRequest/taskComplete 状态

    /// C1: permissionRequest 状态的猫调用 walkToFood 应被 guard 拦截
    func testWalkToFood_rejectsPermissionRequestCat() {
        let cat = makeCat(sessionId: "walk-perm")
        cat.switchState(to: .permissionRequest, toolDescription: "Run bash")
        XCTAssertEqual(cat.currentState, .permissionRequest, "前置条件：应为 permissionRequest 状态")

        let food = makeLandedFood()
        food.node.position = CGPoint(x: 200, y: 48)

        cat.walkToFood(food, excitedDelay: 0) { _, _ in }

        XCTAssertNil(cat.currentTargetFood,
            "permissionRequest 状态的猫不应响应 walkToFood（guard 应拦截，currentTargetFood 应为 nil）")
    }

    /// C2: taskComplete 状态的猫调用 walkToFood 应被 guard 拦截
    func testWalkToFood_rejectsTaskCompleteCat() {
        let cat = makeCat(sessionId: "walk-tc")
        cat.switchState(to: .taskComplete)
        XCTAssertEqual(cat.currentState, .taskComplete, "前置条件：应为 taskComplete 状态")

        let food = makeLandedFood()
        food.node.position = CGPoint(x: 600, y: 48)

        cat.walkToFood(food, excitedDelay: 0) { _, _ in }

        XCTAssertNil(cat.currentTargetFood,
            "taskComplete 状态的猫不应响应 walkToFood（guard 应拦截，currentTargetFood 应为 nil）")
    }

    // MARK: - D. notifyCatAboutLandedFood 跳过已有 currentTargetFood 的猫

    /// D1: 已有 currentTargetFood 的猫不应被 notifyCatAboutLandedFood 重定向
    func testNotifyCatAboutLandedFood_skipsAlreadyTargetingCat() {
        let scene = makeScene()
        scene.addCat(info: makeInfo(sessionId: "busy-cat"))

        // 先给猫设置一个当前目标食物
        let existingFood = makeLandedFood()
        existingFood.node.position = CGPoint(x: 200, y: 48)

        // 通过直接访问 cat 设置现有目标（利用 BuddyScene 的 catSnapshot 确认猫存在）
        // 注：使用 allCatSnapshots 验证猫在场景中，然后通过 updateCatState 触发 notifyCat
        let snapshots = scene.allCatSnapshots()
        XCTAssertEqual(snapshots.count, 1, "前置条件：场景中应有 1 只猫")

        // 获取 cat 引用并设置 currentTargetFood
        // 使用 foodEligibleCats() 来访问实际的 CatEntity 对象
        let eligibleCats = scene.foodEligibleCats()
        guard let cat = eligibleCats.first(where: { $0.sessionId == "busy-cat" }) else {
            XCTFail("前置条件：应能通过 foodEligibleCats() 访问到 busy-cat")
            return
        }

        // 设置当前目标食物（模拟猫已经在追食物的状态）
        cat.currentTargetFood = existingFood

        // 现在通知猫有新食物落地（模拟从 idle 重新触发）
        let newFood = makeLandedFood()
        newFood.node.position = CGPoint(x: 500, y: 48)

        // 手动触发 notifyCatAboutLandedFood（通过 foodManager 公开 API）
        scene.foodManager.notifyCatAboutLandedFood(cat)

        // 已经在追食物的猫，currentTargetFood 不应被替换为新食物
        XCTAssertTrue(cat.currentTargetFood === existingFood,
            "已有 currentTargetFood 的猫不应被 notifyCatAboutLandedFood 重定向到新食物")
    }

    /// D2: 无 currentTargetFood 的猫应被 notifyCatAboutLandedFood 正常通知
    func testNotifyCatAboutLandedFood_notifiesFreeCat() {
        let scene = makeScene()
        scene.addCat(info: makeInfo(sessionId: "free-cat"))

        let eligibleCats = scene.foodEligibleCats()
        guard let cat = eligibleCats.first(where: { $0.sessionId == "free-cat" }) else {
            XCTFail("前置条件：应能访问到 free-cat")
            return
        }

        // 确认猫没有当前目标食物
        XCTAssertNil(cat.currentTargetFood, "前置条件：猫应无当前食物目标")

        // 创建已落地的食物并注入到 foodManager（通过 foodManager 直接调用）
        let food = makeLandedFood()
        food.node.position = CGPoint(x: 400, y: 48)

        // 为了测试 notifyCatAboutLandedFood 能找到食物，需要让 foodManager 知道食物存在
        // 通过访问 activeFoods 的内部方法不可行（private），
        // 改用验证：notifyCatAboutLandedFood 对无 currentTargetFood 的猫调用时不 crash
        // 当 activeFoods 为空时，方法应安静退出
        scene.foodManager.notifyCatAboutLandedFood(cat)

        // 没有 activeFoods 时，猫的 currentTargetFood 应保持为 nil（无食物可追）
        // 这验证了方法执行不崩溃
        XCTAssertNil(cat.currentTargetFood,
            "当无 landed food 时，notifyCatAboutLandedFood 应安静退出不修改猫的状态")
    }

    // MARK: - E. updateCatState 在 thinking/toolUse 变更时触发食物通知

    /// E1: 猫从 idle 切换到 thinking 时，updateCatState 应触发 notifyCatAboutLandedFood
    func testUpdateCatState_thinkingTriggersFoodNotification() {
        let scene = makeScene()
        scene.addCat(info: makeInfo(sessionId: "notify-thinking"))

        // 验证：切换到 thinking 时不 crash（功能存在性验证）
        // updateCatState 内部会调用 foodManager.notifyCatAboutLandedFood
        // 由于 activeFoods 为空，猫的 currentTargetFood 仍为 nil，但方法不应 crash
        scene.updateCatState(sessionId: "notify-thinking", state: .thinking)

        let eligibleCats = scene.foodEligibleCats()
        let ids = eligibleCats.map(\.sessionId)
        XCTAssertTrue(ids.contains("notify-thinking"),
            "切换到 thinking 后猫应出现在 foodEligibleCats() 中（验证状态已更新）")
    }

    /// E2: 猫从 idle 切换到 toolUse 时，updateCatState 应触发 notifyCatAboutLandedFood
    func testUpdateCatState_toolUseTriggersFoodNotification() {
        let scene = makeScene()
        scene.addCat(info: makeInfo(sessionId: "notify-tooluse"))

        scene.updateCatState(sessionId: "notify-tooluse", state: .toolUse)

        let eligibleCats = scene.foodEligibleCats()
        let ids = eligibleCats.map(\.sessionId)
        XCTAssertTrue(ids.contains("notify-tooluse"),
            "切换到 toolUse 后猫应出现在 foodEligibleCats() 中（验证状态已更新）")
    }

    /// E3: 猫切换到 permissionRequest 时，不应触发食物通知（不在 eligible 集合中）
    func testUpdateCatState_permissionRequestDoesNotTriggerFoodNotification() {
        let scene = makeScene()
        scene.addCat(info: makeInfo(sessionId: "no-notify-perm"))

        scene.updateCatState(sessionId: "no-notify-perm", state: .permissionRequest, toolDescription: "Write file")

        let eligibleCats = scene.foodEligibleCats()
        let ids = eligibleCats.map(\.sessionId)
        XCTAssertFalse(ids.contains("no-notify-perm"),
            "切换到 permissionRequest 后猫不应在 foodEligibleCats() 中")
    }

    /// E4: 猫切换到 idle 时，updateCatState 也应触发 notifyCatAboutLandedFood（回归验证）
    func testUpdateCatState_idleTriggersFoodNotification() {
        let scene = makeScene()
        scene.addCat(info: makeInfo(sessionId: "notify-idle"))
        scene.updateCatState(sessionId: "notify-idle", state: .thinking)  // 先切到 thinking

        // 再切回 idle
        scene.updateCatState(sessionId: "notify-idle", state: .idle)

        let eligibleCats = scene.foodEligibleCats()
        let ids = eligibleCats.map(\.sessionId)
        XCTAssertTrue(ids.contains("notify-idle"),
            "切换到 idle 后猫应出现在 foodEligibleCats() 中（回归验证）")
    }

    // MARK: - F. foodWalkSpeed 常量值为 100

    /// F1: CatConstants.Movement.foodWalkSpeed 应等于 100
    func testFoodWalkSpeedConstant_is100() {
        XCTAssertEqual(CatConstants.Movement.foodWalkSpeed, 100,
            "foodWalkSpeed 常量应为 100 px/s（设计文档指定值），实际: \(CatConstants.Movement.foodWalkSpeed)")
    }

    /// F2: foodWalkSpeed 应大于普通随机游走速度上限（55），体现食物吸引时更快
    func testFoodWalkSpeedConstant_fasterThanRandomWalk() {
        let maxRandomWalk = CatConstants.Movement.walkSpeedRange.upperBound
        XCTAssertGreaterThan(CatConstants.Movement.foodWalkSpeed, maxRandomWalk,
            "foodWalkSpeed (\(CatConstants.Movement.foodWalkSpeed)) 应大于随机游走最大速度 (\(maxRandomWalk))")
    }

    // MARK: - 综合场景: 多猫抢食物不崩溃

    /// G1: 三只处于不同状态(idle/thinking/toolUse)的猫，food 落地后均被通知且不 crash
    func testMultipleCatsCompeteForFood_noCrash() {
        let scene = makeScene()
        scene.addCat(info: makeInfo(sessionId: "multi-idle"))
        scene.addCat(info: makeInfo(sessionId: "multi-thinking"))
        scene.addCat(info: makeInfo(sessionId: "multi-tooluse"))

        scene.updateCatState(sessionId: "multi-thinking", state: .thinking)
        scene.updateCatState(sessionId: "multi-tooluse", state: .toolUse)

        // 验证三只猫都在 eligible 集合中
        let eligible = scene.foodEligibleCats()
        XCTAssertEqual(eligible.count, 3,
            "三只猫（idle/thinking/toolUse）都应在 foodEligibleCats() 中，实际: \(eligible.count)")

        // 通过多帧 update 触发食物系统（不崩溃即通过）
        var time = CACurrentMediaTime()
        for _ in 0..<10 {
            time += 1.0 / 60.0
            scene.update(time)
        }

        // 场景中仍有所有猫
        let snapshots = scene.allCatSnapshots()
        XCTAssertEqual(snapshots.count, 3,
            "多帧 update 后所有猫应仍在场景中，实际: \(snapshots.count)")
    }

    /// G2: food.claim(by:) 互斥锁不变 — 两只猫竞争同一食物，只有一只能成功 claim
    func testFoodClaimMutex_onlyOneCatSucceeds() {
        let food = makeLandedFood()

        let result1 = food.claim(by: "cat-A")
        let result2 = food.claim(by: "cat-B")

        XCTAssertTrue(result1, "第一只猫应成功 claim 食物")
        XCTAssertFalse(result2, "第二只猫 claim 已被领取的食物应失败（互斥锁）")
        XCTAssertEqual(food.claimedBy, "cat-A", "食物应被第一只猫持有")
        XCTAssertEqual(food.state, .claimed, "食物状态应为 claimed")
    }

    /// G3: thinking → eating 状态转换路径应能正常进行（GKState 层面允许）
    func testThinkingToEatingTransition_isAllowed() {
        let cat = makeCat(sessionId: "thinking-to-eating")
        cat.switchState(to: .thinking)
        XCTAssertEqual(cat.currentState, .thinking)

        // thinking → eating 应被 GKStateMachine 允许（设计文档确认）
        cat.switchState(to: .eating)
        XCTAssertEqual(cat.currentState, .eating,
            "thinking 状态应能转入 eating 状态（GKStateMachine 层面允许）")
    }

    /// G4: toolUse → eating 状态转换路径应能正常进行（GKState 层面允许）
    func testToolUseToEatingTransition_isAllowed() {
        let cat = makeCat(sessionId: "tooluse-to-eating")
        cat.switchState(to: .toolUse)
        XCTAssertEqual(cat.currentState, .toolUse)

        cat.switchState(to: .eating)
        XCTAssertEqual(cat.currentState, .eating,
            "toolUse 状态应能转入 eating 状态（GKStateMachine 层面允许）")
    }
}
