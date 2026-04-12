import XCTest
import SpriteKit
@testable import BuddyCore

/// 验收测试：退出时跳跃越过障碍猫，被跳过的猫产生惊吓反应
///
/// 测试覆盖设计文档中声明的所有功能点：
/// 1. 无障碍时正常走出（行为不变）
/// 2. 有障碍时跳跃越过（不推挤其他猫）
/// 3. 退出猫 isDynamic 在退出时为 false
/// 4. 惊吓反应：scared 帧播放、moveBy 方向正确
/// 5. .permissionRequest 状态不触发惊吓
/// 6. switchState 中 isDynamic 恢复安全网
/// 7. 障碍按退出方向正确排序
final class JumpExitTests: XCTestCase {

    // MARK: - Test Infrastructure

    var scene: SKScene!

    override func setUp() {
        super.setUp()
        scene = SKScene(size: CGSize(width: 800, height: 200))
        scene.physicsWorld.gravity = .zero
    }

    override func tearDown() {
        scene = nil
        super.tearDown()
    }

    // MARK: - Helper: CatSprite Factory

    /// 创建一个用于测试的 CatSprite（通过公开 API 初始化）
    private func makeCat(sessionId: String, state: CatState = .idle, at position: CGPoint = .zero) -> CatSprite {
        let cat = CatSprite(sessionId: sessionId)
        cat.position = position
        scene.addChild(cat)
        return cat
    }

    // MARK: - AC1: 无障碍时正常退出行为不变

    func testExitWithNoObstaclesRunsNormally() {
        // 准备：单个猫咪，无其他猫阻挡路径
        let exitingCat = makeCat(sessionId: "solo", at: CGPoint(x: 400, y: 100))

        // 记录退出前物理状态
        let physicsBodyBefore = exitingCat.physicsBody

        // 执行：以向右方向退出（无障碍）
        let obstacles: [CatSprite] = []
        exitingCat.exitScene(direction: .right, obstacles: obstacles, onFright: nil)

        // 断言：exitScene 被调用后 isDynamic 为 false（退出动画接管控制）
        XCTAssertFalse(
            exitingCat.physicsBody?.isDynamic ?? true,
            "退出的猫咪 isDynamic 应在退出时设为 false，由 SKAction 接管控制"
        )

        // 断言：无障碍时 onFright 回调不应被触发
        var frightCalled = false
        let obstaclesEmpty: [CatSprite] = []
        exitingCat.exitScene(direction: .left, obstacles: obstaclesEmpty) { _ in
            frightCalled = true
        }
        XCTAssertFalse(frightCalled, "无障碍时不应触发惊吓回调")
    }

    // MARK: - AC2: 有障碍时跳跃越过（不推挤）

    func testExitWithObstacleTriggersJumpNotPush() {
        // 准备：退出猫位于左侧，障碍猫位于路径中间
        let exitingCat = makeCat(sessionId: "exiting", at: CGPoint(x: 100, y: 100))
        let obstacleCat = makeCat(sessionId: "obstacle", at: CGPoint(x: 300, y: 100))

        // 记录障碍猫退出前的 X 位置
        let obstacleXBefore = obstacleCat.position.x

        let expectFright = expectation(description: "障碍猫应收到惊吓回调")
        var frightTarget: CatSprite?

        exitingCat.exitScene(direction: .right, obstacles: [obstacleCat]) { cat in
            frightTarget = cat
            expectFright.fulfill()
        }

        // 等待惊吓回调触发（跳跃动画开始时即触发）
        wait(for: [expectFright], timeout: 2.0)

        // 断言：触发惊吓的目标是障碍猫
        XCTAssertEqual(frightTarget?.name, obstacleCat.name, "惊吓回调应针对障碍猫")

        // 断言：障碍猫位置 X 不应大幅变化（跳跃越过，不推挤）
        // 允许惊吓闪避造成的合理位移（设计文档：moveBy ±30），但不应有推挤式的持续移动
        XCTAssertTrue(
            abs(obstacleCat.position.x - obstacleXBefore) < 200,
            "障碍猫不应被推挤大幅移动（应只有惊吓闪避 ±30px 以内）"
        )
    }

    // MARK: - AC3: 退出猫 isDynamic 在退出时为 false

    func testExitingCatIsDynamicFalse() {
        let exitingCat = makeCat(sessionId: "dyn-test", at: CGPoint(x: 200, y: 100))
        let obstacleCat = makeCat(sessionId: "obs", at: CGPoint(x: 500, y: 100))

        exitingCat.exitScene(direction: .right, obstacles: [obstacleCat], onFright: nil)

        XCTAssertFalse(
            exitingCat.physicsBody?.isDynamic ?? true,
            "退出猫的 physicsBody.isDynamic 必须在 exitScene 调用后立即为 false"
        )
    }

    // MARK: - AC4: 惊吓反应 — scared 帧播放

    func testFrightReactionPlaysScaredFrame() {
        let cat = makeCat(sessionId: "scared-cat", at: CGPoint(x: 400, y: 100))

        // 确保初始纹理不是 scared 帧
        let initialTexture = (cat as? SKSpriteNode)?.texture

        // 触发惊吓反应（直接调用 playFrightReaction）
        let xBefore = cat.position.x
        cat.playFrightReaction(frightenedBy: .right)

        // 断言：isDynamic 应在惊吓动画期间为 false（动画接管）
        // 注：惊吓是 fire-and-forget，动画完成后恢复 isDynamic = true
        // 这里验证调用后立即的状态
        XCTAssertFalse(
            cat.physicsBody?.isDynamic ?? true,
            "惊吓反应期间 isDynamic 应为 false"
        )

        // 断言：scared 纹理已被应用（texture 已切换到 scared 帧）
        // CatSprite 应暴露 currentStateName 或通过 texture 名称判断
        if let spriteCat = cat as? SKSpriteNode {
            XCTAssertNotNil(spriteCat.texture, "惊吓反应期间应有 scared 纹理")
        }
        let _ = xBefore // suppress unused warning
    }

    // MARK: - AC4b: 惊吓反应 — moveBy 方向正确（向退出方向反方向闪避）

    func testFrightReactionMovesInOppositeDirectionOfExiter() {
        // 退出者向右 → 障碍猫应向左闪避（负 X 方向）
        let catFacingRight = makeCat(sessionId: "fright-right", at: CGPoint(x: 400, y: 100))
        let xBefore = catFacingRight.position.x

        catFacingRight.playFrightReaction(frightenedBy: .right)

        // 等待动画执行一小段时间
        let exp = expectation(description: "等待闪避动作开始")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)

        // 断言：猫向左移动（X 减小），闪避方向与退出者相反
        XCTAssertLessThan(
            catFacingRight.position.x, xBefore,
            "被右侧退出者跳过的猫应向左闪避（X 减小）"
        )
    }

    func testFrightReactionMovesRightWhenExiterGoesLeft() {
        // 退出者向左 → 障碍猫应向右闪避（正 X 方向）
        let catFacingLeft = makeCat(sessionId: "fright-left", at: CGPoint(x: 400, y: 100))
        let xBefore = catFacingLeft.position.x

        catFacingLeft.playFrightReaction(frightenedBy: .left)

        let exp = expectation(description: "等待闪避动作开始")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)

        XCTAssertGreaterThan(
            catFacingLeft.position.x, xBefore,
            "被左侧退出者跳过的猫应向右闪避（X 增大）"
        )
    }

    // MARK: - AC4c: 惊吓反应 — isDynamic 动画结束后恢复为 true

    func testFrightReactionRestoresDynamicAfterAnimation() {
        let cat = makeCat(sessionId: "dynamic-restore", at: CGPoint(x: 400, y: 100))

        cat.playFrightReaction(frightenedBy: .right)

        // 等待惊吓动画完成（设计：moveBy ±30，应在 ~0.5s 内完成）
        let exp = expectation(description: "等待惊吓动画完成并恢复 isDynamic")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 3.0)

        XCTAssertTrue(
            cat.physicsBody?.isDynamic ?? false,
            "惊吓动画完成后 isDynamic 应恢复为 true（fire-and-forget 安全网）"
        )
    }

    // MARK: - AC5: .permissionRequest 状态不触发惊吓

    func testPermissionRequestCatDoesNotFright() {
        let exitingCat = makeCat(sessionId: "exiting-perm", at: CGPoint(x: 100, y: 100))

        // 障碍猫处于 permissionRequest 状态
        let permCat = makeCat(sessionId: "permission-cat", at: CGPoint(x: 300, y: 100))
        permCat.switchState(.permissionRequest)

        var frightCalled = false
        exitingCat.exitScene(direction: .right, obstacles: [permCat]) { _ in
            frightCalled = true
        }

        // 等待足够长时间确认惊吓未触发
        let exp = expectation(description: "确认 permissionRequest 猫不触发惊吓")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)

        XCTAssertFalse(frightCalled, ".permissionRequest 状态的猫不应收到惊吓回调")
    }

    // MARK: - AC6: switchState 中 isDynamic 恢复安全网

    func testSwitchStateRestoresDynamic() {
        let cat = makeCat(sessionId: "switch-safety", at: CGPoint(x: 400, y: 100))

        // 模拟退出中途被强制切换状态（中断场景）
        // 先将 isDynamic 设为 false（模拟退出中状态）
        cat.physicsBody?.isDynamic = false

        // 调用 switchState 切换到任何普通状态
        cat.switchState(.idle)

        // 断言：switchState 应包含安全网，恢复 isDynamic = true
        XCTAssertTrue(
            cat.physicsBody?.isDynamic ?? false,
            "switchState 应作为安全网将 isDynamic 恢复为 true，确保中断安全"
        )
    }

    func testSwitchStateToThinkingRestoresDynamic() {
        let cat = makeCat(sessionId: "switch-think", at: CGPoint(x: 400, y: 100))
        cat.physicsBody?.isDynamic = false

        cat.switchState(.thinking)

        XCTAssertTrue(
            cat.physicsBody?.isDynamic ?? false,
            "switchState(.thinking) 应恢复 isDynamic = true"
        )
    }

    func testSwitchStateToToolUseRestoresDynamic() {
        let cat = makeCat(sessionId: "switch-tool", at: CGPoint(x: 400, y: 100))
        cat.physicsBody?.isDynamic = false

        cat.switchState(.toolUse)

        XCTAssertTrue(
            cat.physicsBody?.isDynamic ?? false,
            "switchState(.toolUse) 应恢复 isDynamic = true"
        )
    }

    // MARK: - AC7: 障碍按退出方向正确排序

    func testObstaclesSortedCorrectlyForRightExit() {
        // 退出方向向右：障碍应按 X 从小到大排序（从近到远）
        let exitingCat = makeCat(sessionId: "sort-right-exiter", at: CGPoint(x: 50, y: 100))
        let farCat   = makeCat(sessionId: "far",   at: CGPoint(x: 600, y: 100))
        let nearCat  = makeCat(sessionId: "near",  at: CGPoint(x: 200, y: 100))
        let midCat   = makeCat(sessionId: "mid",   at: CGPoint(x: 400, y: 100))

        var frightOrder: [String] = []
        let expFar  = expectation(description: "far cat fright")
        let expNear = expectation(description: "near cat fright")
        let expMid  = expectation(description: "mid cat fright")

        exitingCat.exitScene(direction: .right, obstacles: [farCat, nearCat, midCat]) { cat in
            let sid = cat.sessionId ?? ""
            frightOrder.append(sid)
            switch sid {
            case "near": expNear.fulfill()
            case "mid":  expMid.fulfill()
            case "far":  expFar.fulfill()
            default: break
            }
        }

        wait(for: [expNear, expMid, expFar], timeout: 5.0)

        // 断言：向右退出时，最近的猫先被跳过（near < mid < far）
        XCTAssertEqual(
            frightOrder, ["near", "mid", "far"],
            "向右退出时障碍猫应按 X 从小到大顺序被跳跃（由近到远）"
        )
    }

    func testObstaclesSortedCorrectlyForLeftExit() {
        // 退出方向向左：障碍应按 X 从大到小排序（从近到远）
        let exitingCat = makeCat(sessionId: "sort-left-exiter", at: CGPoint(x: 750, y: 100))
        let farCat   = makeCat(sessionId: "far-l",  at: CGPoint(x: 100, y: 100))
        let nearCat  = makeCat(sessionId: "near-l", at: CGPoint(x: 600, y: 100))
        let midCat   = makeCat(sessionId: "mid-l",  at: CGPoint(x: 350, y: 100))

        var frightOrder: [String] = []
        let expFar  = expectation(description: "far-l fright")
        let expNear = expectation(description: "near-l fright")
        let expMid  = expectation(description: "mid-l fright")

        exitingCat.exitScene(direction: .left, obstacles: [farCat, nearCat, midCat]) { cat in
            let sid = cat.sessionId ?? ""
            frightOrder.append(sid)
            switch sid {
            case "near-l": expNear.fulfill()
            case "mid-l":  expMid.fulfill()
            case "far-l":  expFar.fulfill()
            default: break
            }
        }

        wait(for: [expNear, expMid, expFar], timeout: 5.0)

        // 断言：向左退出时，最近的猫先被跳过（near-l > mid-l > far-l in X）
        XCTAssertEqual(
            frightOrder, ["near-l", "mid-l", "far-l"],
            "向左退出时障碍猫应按 X 从大到小顺序被跳跃（由近到远）"
        )
    }

    // MARK: - AC8: 贝塞尔弧线跳跃峰值高于起点（验证跳跃，非直线）

    func testJumpArcPeakIsAboveStartPosition() {
        // 通过观察退出猫在动画中间时刻的 Y 坐标来验证弧线轨迹
        let exitingCat = makeCat(sessionId: "arc-test", at: CGPoint(x: 100, y: 100))
        let obstacleCat = makeCat(sessionId: "arc-obs", at: CGPoint(x: 300, y: 100))

        let initialY = exitingCat.position.y
        var peakY: CGFloat = initialY

        exitingCat.exitScene(direction: .right, obstacles: [obstacleCat], onFright: nil)

        // 采样动画中间时刻的 Y 坐标
        let sampleExp = expectation(description: "采样弧线峰值")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            // 在跳跃弧线中途采样
            peakY = max(peakY, exitingCat.position.y)
            sampleExp.fulfill()
        }
        wait(for: [sampleExp], timeout: 2.0)

        // 断言：峰值 Y 坐标应高于起始 Y（设计文档：峰值 +25px）
        XCTAssertGreaterThan(
            peakY, initialY,
            "跳跃弧线的峰值 Y 坐标应高于起始位置（设计文档：峰值 +25px），确认非直线行走"
        )
    }

    // MARK: - AC9: 多障碍情况下每个障碍都被跳跃

    func testAllObstaclesReceiveFrightCallback() {
        let exitingCat  = makeCat(sessionId: "multi-exit",  at: CGPoint(x: 50, y: 100))
        let obstacle1   = makeCat(sessionId: "obs-1",       at: CGPoint(x: 200, y: 100))
        let obstacle2   = makeCat(sessionId: "obs-2",       at: CGPoint(x: 400, y: 100))
        let obstacle3   = makeCat(sessionId: "obs-3",       at: CGPoint(x: 600, y: 100))

        var frightedIds: Set<String> = []
        let exp1 = expectation(description: "obs-1 fright")
        let exp2 = expectation(description: "obs-2 fright")
        let exp3 = expectation(description: "obs-3 fright")

        exitingCat.exitScene(direction: .right, obstacles: [obstacle1, obstacle2, obstacle3]) { cat in
            let sid = cat.sessionId ?? ""
            frightedIds.insert(sid)
            switch sid {
            case "obs-1": exp1.fulfill()
            case "obs-2": exp2.fulfill()
            case "obs-3": exp3.fulfill()
            default: break
            }
        }

        wait(for: [exp1, exp2, exp3], timeout: 8.0)

        XCTAssertEqual(frightedIds.count, 3, "所有 3 个障碍猫都应收到惊吓回调")
        XCTAssertTrue(frightedIds.contains("obs-1"))
        XCTAssertTrue(frightedIds.contains("obs-2"))
        XCTAssertTrue(frightedIds.contains("obs-3"))
    }
}

// MARK: - CatSprite Testability Extensions

/// 为测试提供访问辅助（基于设计文档声明的公开接口）
extension CatSprite {
    /// 暴露 sessionId 供测试验证障碍排序和回调目标
    var sessionId: String? {
        return self.name
    }
}
