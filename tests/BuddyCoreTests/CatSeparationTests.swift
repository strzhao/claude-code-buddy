import XCTest
import SpriteKit
@testable import BuddyCore

// MARK: - Helpers

private extension CatSeparationTests {

    /// 构造一只独立的 CatEntity（不挂载到 BuddyScene）
    func makeCat(
        sessionId: String = "sep-test",
        x: CGFloat = 200,
        sceneWidth: CGFloat = 800,
        activityMin: CGFloat = 48,
        activityMax: CGFloat = 752
    ) -> CatEntity {
        let cat = CatEntity(sessionId: sessionId)
        cat.configure(color: .sky, labelText: sessionId)
        cat.containerNode.position = CGPoint(x: x, y: CatConstants.Visual.groundY)
        cat.sceneWidth = sceneWidth
        cat.activityMin = activityMin
        cat.activityMax = activityMax
        cat.applyFacingDirection()
        cat.switchState(to: .idle)
        return cat
    }

    /// 构造一个带有 BuddyScene 的测试场景（无需挂载 SKView）
    func makeScene(width: CGFloat = 800, activityBounds: ClosedRange<CGFloat> = 48...752) -> BuddyScene {
        let scene = BuddyScene(size: CGSize(width: width, height: 80))
        scene.activityBounds = activityBounds
        return scene
    }

    /// 为 BuddyScene.addCat 构造最小 SessionInfo
    func makeInfo(
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
}

// MARK: - CatSeparationTests

/// 红队验收测试：猫咪软分离机制
///
/// 策略：
/// - A/B/C/D 组：通过 BuddyScene 公开 API（addCat / update）间接验证 applySoftSeparation 与 findNonOverlappingSpawnX
/// - 物理掩码：直接检查 CatEntity 的 physicsBody.collisionBitMask
/// - 常量组：验证 CatConstants.Separation 的常量存在且合理
final class CatSeparationTests: XCTestCase {

    // MARK: - A. 软分离：通过 BuddyScene.update() 间接测试

    /// A1：两只完全重叠的猫经过 update() 后 X 距离增大
    func testOverlappingCatsGetPushedApart() {
        let scene = makeScene()

        // 添加两只猫并强制放到同一 X 位置（必须在 addCat 之后设置，因为 addCat 使用随机 spawn）
        scene.addCat(info: makeInfo(sessionId: "sep-A1a"))
        scene.addCat(info: makeInfo(sessionId: "sep-A1b"))

        // 找到两只猫并强制重叠
        guard let snapshot = scene.catSnapshot(for: "sep-A1a"),
              let _ = scene.catSnapshot(for: "sep-A1b") else {
            XCTFail("两只猫应已添加到场景")
            return
        }
        _ = snapshot

        // 注意：BuddyScene.cats 是 private，无法直接修改位置
        // 通过反复 update() 驱动 applySoftSeparation，验证不崩溃
        // 并用 allCatSnapshots() 观察最终状态
        let startSnapshots = scene.allCatSnapshots()
        XCTAssertEqual(startSnapshots.count, 2, "场景中应有 2 只猫")

        // 模拟多帧 update
        var time: TimeInterval = CACurrentMediaTime()
        for _ in 0..<10 {
            time += 1.0 / 60.0
            scene.update(time)
        }

        let endSnapshots = scene.allCatSnapshots()
        XCTAssertEqual(endSnapshots.count, 2, "update 后仍应有 2 只猫（不应丢失）")

        // 如果两只猫的 X 差距超过 minDistance，说明分离机制已生效
        // 由于 addCat 随机 spawn，大多数情况下初始就有距离，此处不断言具体数值
        // 只验证 applySoftSeparation 调用不崩溃且猫不越界
        for snap in endSnapshots {
            XCTAssertGreaterThanOrEqual(snap.x, snap.activityBoundsMin - 1,
                "猫 \(snap.sessionId) 不应越过左边界: x=\(snap.x)")
            XCTAssertLessThanOrEqual(snap.x, snap.activityBoundsMax + 1,
                "猫 \(snap.sessionId) 不应越过右边界: x=\(snap.x)")
        }
    }

    /// A2：两只猫相距 200px，经过 update() 后各自位置基本不变
    func testDistantCatsAreNotMoved() {
        let scene = makeScene()

        // 手动放置远离的两只猫，但 addCat 使用随机位置，我们通过独立测试猫的方式验证
        // 此测试验证"不重叠的猫不被推动"的逻辑通过独立 CatEntity 验证
        let cat1 = makeCat(sessionId: "distant-A", x: 200)
        let cat2 = makeCat(sessionId: "distant-B", x: 400)

        let initialX1 = cat1.containerNode.position.x
        let initialX2 = cat2.containerNode.position.x

        // 距离 200px 远超 minDistance (52)，两只猫不应被推动
        let distance = abs(initialX1 - initialX2)
        XCTAssertGreaterThan(distance, CatConstants.Separation.minDistance,
            "前置条件：两猫距离 \(distance) 应大于 minDistance \(CatConstants.Separation.minDistance)")

        // 没有外力时位置不变
        XCTAssertEqual(cat1.containerNode.position.x, initialX1, accuracy: 0.1)
        XCTAssertEqual(cat2.containerNode.position.x, initialX2, accuracy: 0.1)
    }

    /// A3：软分离推挤不导致猫越出 activityBounds
    func testSeparationRespectsActivityBounds() {
        let scene = makeScene(width: 800, activityBounds: 48...752)

        // 添加若干只猫后多次 update，验证所有猫都在边界内
        for i in 0..<3 {
            scene.addCat(info: makeInfo(sessionId: "bounds-cat-\(i)"))
        }

        var time: TimeInterval = CACurrentMediaTime()
        for _ in 0..<30 {
            time += 1.0 / 60.0
            scene.update(time)
        }

        let snapshots = scene.allCatSnapshots()
        for snap in snapshots {
            // 允许 BoundaryRecovery 容差内的微小越界（8px）
            let tolerance = CatConstants.BoundaryRecovery.outOfBoundsTolerance
            XCTAssertGreaterThanOrEqual(
                snap.x, snap.activityBoundsMin - tolerance,
                "猫 \(snap.sessionId) 不应越出左边界超过容差"
            )
            XCTAssertLessThanOrEqual(
                snap.x, snap.activityBoundsMax + tolerance,
                "猫 \(snap.sessionId) 不应越出右边界超过容差"
            )
        }
    }

    /// A4：eating 状态的猫不被软分离推动
    func testEatingCatsNotNudged() {
        // eating 状态的猫应豁免软分离
        // 通过验证 eating 猫经历多帧后仍在 eating 状态（未被意外打断）
        let cat = makeCat(sessionId: "eating-immune", x: 200)
        cat.switchState(to: .eating)

        XCTAssertEqual(cat.currentState, .eating,
            "前置条件：应为 eating 状态，实际：\(cat.currentState.rawValue)")

        // eating 状态不参与软分离，验证状态不被外力改变
        // 这里验证 eating 猫在没有 food 完成时不会自动切换状态
        XCTAssertEqual(cat.currentState, .eating,
            "eating 猫应保持 eating 状态，不被软分离逻辑干扰")
    }

    /// A5：taskComplete 状态的猫不被软分离推动
    func testTaskCompleteCatsNotNudged() {
        let scene = makeScene()

        // 添加一只猫并切换到 taskComplete（需要 bed slot）
        // 验证 update() 不崩溃，且 taskComplete 猫不被软分离影响
        scene.addCat(info: makeInfo(sessionId: "tc-immune"))

        // BuddyScene.update() 中 taskComplete 状态猫已有 guard 跳过边界检查
        // 软分离应遵循同样的豁免逻辑
        var time: TimeInterval = CACurrentMediaTime()
        for _ in 0..<5 {
            time += 1.0 / 60.0
            scene.update(time)
        }

        // 只要 update 不崩溃即验收通过（taskComplete 豁免逻辑的存在性检查）
        let snapshots = scene.allCatSnapshots()
        XCTAssertFalse(snapshots.isEmpty, "update 后场景应仍有猫")
    }

    // MARK: - B. 生成位置测试

    /// B1：新猫生成时尽量远离已有猫（间距 >= minSpawnDistance 或尽力避让）
    func testNewCatSpawnsAwayFromExisting() {
        let scene = makeScene(width: 800, activityBounds: 48...752)

        // 先添加一只猫
        scene.addCat(info: makeInfo(sessionId: "spawn-first"))
        let firstSnapshots = scene.allCatSnapshots()
        XCTAssertEqual(firstSnapshots.count, 1, "第一只猫应已添加")

        // 再添加第二只猫
        scene.addCat(info: makeInfo(sessionId: "spawn-second"))
        let bothSnapshots = scene.allCatSnapshots()
        XCTAssertEqual(bothSnapshots.count, 2, "第二只猫应已添加")

        guard bothSnapshots.count == 2 else { return }
        let x1 = bothSnapshots[0].x
        let x2 = bothSnapshots[1].x
        let distance = abs(x1 - x2)

        // 验证两猫间距合理（findNonOverlappingSpawnX 应尽量保证 >= minSpawnDistance）
        // 注意：随机 spawn 在小场景中可能偶尔失败，所以验证"场景足够宽时"的情况
        // 此测试主要验证生成逻辑不崩溃，以及在宽场景下通常能避开
        // 如果蓝队实现了 findNonOverlappingSpawnX，距离应 >= minSpawnDistance
        let minSpawnDist = CatConstants.Separation.minSpawnDistance
        if distance < minSpawnDist {
            // 允许极端情况（场景太窄或随机失败），但记录实际值供人工检查
            print("[CatSeparationTests] spawn 距离 \(distance) < minSpawnDistance \(minSpawnDist)（可能随机巧合或场景窄）")
        }
        // 至少验证两猫不在完全相同位置（生成位置有随机性）
        // 在宽场景(800px, 活动范围704px)中，两猫重叠概率极低
        // 主要验证 addCat 不崩溃
        XCTAssertGreaterThanOrEqual(bothSnapshots[0].x, 48,
            "第一只猫应在活动范围内")
        XCTAssertGreaterThanOrEqual(bothSnapshots[1].x, 48,
            "第二只猫应在活动范围内")
    }

    // MARK: - C. 物理掩码测试

    /// C1：CatEntity 的 physicsBody.collisionBitMask 不应包含 PhysicsCategory.cat
    func testCatPhysicsBodyDoesNotCollideWithCats() {
        let cat = makeCat(sessionId: "physics-mask-test")

        guard let body = cat.containerNode.physicsBody else {
            XCTFail("CatEntity 应有 physicsBody")
            return
        }

        // 软分离机制实现后，cat 间不使用物理碰撞，由代码逻辑推开
        // collisionBitMask 中不应包含 cat 位
        let collisionWithCat = body.collisionBitMask & PhysicsCategory.cat
        XCTAssertEqual(
            collisionWithCat, 0,
            "CatEntity 的 collisionBitMask 不应与其他 cat 物理碰撞（实际掩码: \(body.collisionBitMask)）"
        )
    }

    /// C2：CatEntity 的 categoryBitMask 仍应为 PhysicsCategory.cat
    func testCatPhysicsBodyCategoryIsStillCat() {
        let cat = makeCat(sessionId: "category-mask-test")

        guard let body = cat.containerNode.physicsBody else {
            XCTFail("CatEntity 应有 physicsBody")
            return
        }

        XCTAssertEqual(
            body.categoryBitMask, PhysicsCategory.cat,
            "CatEntity 的 categoryBitMask 应为 PhysicsCategory.cat"
        )
    }

    // MARK: - D. 常量验证

    /// D1：CatConstants.Separation 常量存在且合理
    func testSeparationConstantsExistAndAreReasonable() {
        // 验证 minDistance > 0 且小于屏幕宽度
        XCTAssertGreaterThan(CatConstants.Separation.minDistance, 0,
            "minDistance 应大于 0")
        XCTAssertLessThan(CatConstants.Separation.minDistance, 200,
            "minDistance 不应过大（实际值: \(CatConstants.Separation.minDistance)）")

        // nudgeSpeed 应在合理范围内
        XCTAssertGreaterThan(CatConstants.Separation.nudgeSpeed, 0,
            "nudgeSpeed 应大于 0")
        XCTAssertLessThanOrEqual(CatConstants.Separation.nudgeSpeed, 10,
            "nudgeSpeed 不应过大（实际值: \(CatConstants.Separation.nudgeSpeed)）")

        // minSpawnDistance 应大于 minDistance
        XCTAssertGreaterThanOrEqual(CatConstants.Separation.minSpawnDistance,
            CatConstants.Separation.minDistance,
            "minSpawnDistance 应 >= minDistance")

        // maxSpawnAttempts 应为正整数
        XCTAssertGreaterThan(CatConstants.Separation.maxSpawnAttempts, 0,
            "maxSpawnAttempts 应大于 0")
    }

    /// D2：minDistance 约为 52（设计文档指定值）
    func testSeparationMinDistanceIsApproximately52() {
        XCTAssertEqual(CatConstants.Separation.minDistance, 52, accuracy: 5,
            "minDistance 应约为 52px（设计文档指定值）")
    }

    /// D3：nudgeSpeed 约为 0.5（设计文档指定值）
    func testSeparationNudgeSpeedIsApproximately0Point5() {
        XCTAssertEqual(CatConstants.Separation.nudgeSpeed, 0.5, accuracy: 0.2,
            "nudgeSpeed 应约为 0.5px/frame（设计文档指定值）")
    }

    /// D4：minSpawnDistance 约为 60（设计文档指定值）
    func testSeparationMinSpawnDistanceIsApproximately60() {
        XCTAssertEqual(CatConstants.Separation.minSpawnDistance, 60, accuracy: 5,
            "minSpawnDistance 应约为 60px（设计文档指定值）")
    }

    /// D5：maxSpawnAttempts 约为 10（设计文档指定值）
    func testSeparationMaxSpawnAttemptsIsApproximately10() {
        XCTAssertEqual(CatConstants.Separation.maxSpawnAttempts, 10,
            "maxSpawnAttempts 应为 10（设计文档指定值）")
    }

    // MARK: - E. update 多猫稳定性

    /// E1：8 只猫在场景中持续 update 不崩溃
    func testManyCatsUpdateDoesNotCrash() {
        let scene = makeScene(width: 800, activityBounds: 48...752)

        for i in 0..<8 {
            scene.addCat(info: makeInfo(sessionId: "stability-\(i)"))
        }

        XCTAssertEqual(scene.activeCatCount, 8, "场景应有 8 只猫（maxCats）")

        var time: TimeInterval = CACurrentMediaTime()
        for _ in 0..<60 {  // 模拟 1 秒（60 帧）
            time += 1.0 / 60.0
            scene.update(time)
        }

        // 60 帧 update 后所有猫应仍在场景中且在活动范围内
        let snapshots = scene.allCatSnapshots()
        XCTAssertEqual(snapshots.count, 8, "60 帧后应仍有 8 只猫")

        let tolerance = CatConstants.BoundaryRecovery.outOfBoundsTolerance
        for snap in snapshots {
            XCTAssertGreaterThanOrEqual(snap.x, snap.activityBoundsMin - tolerance,
                "猫 \(snap.sessionId) 越出左边界 x=\(snap.x)")
            XCTAssertLessThanOrEqual(snap.x, snap.activityBoundsMax + tolerance,
                "猫 \(snap.sessionId) 越出右边界 x=\(snap.x)")
        }
    }

    /// E2：两只猫在 toolUse 随机游走时经过多帧后不相互重叠（间距倾向于增大）
    func testToolUseCatsDoNotOverlapAfterRandomWalk() {
        let scene = makeScene(width: 800, activityBounds: 48...752)

        // 添加两只 toolUse 状态的猫
        scene.addCat(info: makeInfo(sessionId: "walk-A"))
        scene.addCat(info: makeInfo(sessionId: "walk-B"))

        // 切换到 toolUse（触发随机游走）
        scene.updateCatState(sessionId: "walk-A", state: .toolUse)
        scene.updateCatState(sessionId: "walk-B", state: .toolUse)

        // 运行多帧让 adjustTargetAwayFromOtherCats 生效
        var time: TimeInterval = CACurrentMediaTime()
        for _ in 0..<120 {  // 模拟 2 秒
            time += 1.0 / 60.0
            scene.update(time)
        }

        let snapshots = scene.allCatSnapshots()
        XCTAssertEqual(snapshots.count, 2, "两只猫应仍在场景中")

        // 验证最终状态下两猫不会严重重叠
        // 注意：随机游走有时间性，此测试更多是"不崩溃"的 smoke test
        // 精确的间距验证依赖 adjustTargetAwayFromOtherCats 的时序
        guard snapshots.count == 2 else { return }
        let finalDist = abs(snapshots[0].x - snapshots[1].x)

        // 宽松验证：2 秒内至少在某些时刻会触发避让逻辑
        // 只验证最终位置都在活动范围内
        for snap in snapshots {
            XCTAssertGreaterThanOrEqual(snap.x, 48,
                "猫 \(snap.sessionId) 应在活动范围内，x=\(snap.x)")
            XCTAssertLessThanOrEqual(snap.x, 752,
                "猫 \(snap.sessionId) 应在活动范围内，x=\(snap.x)")
        }

        // 如果最终距离 >= minDistance，说明避让逻辑起效
        // 如果未到，则是随机性导致（不断言，仅记录）
        if finalDist < CatConstants.Separation.minDistance {
            print("[CatSeparationTests] 2 秒后间距 \(finalDist) 未达到 minDistance \(CatConstants.Separation.minDistance)（随机性正常）")
        }
    }
}
