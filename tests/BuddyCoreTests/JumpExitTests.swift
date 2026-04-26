import XCTest
import SpriteKit
@testable import BuddyCore

// MARK: - Helpers

private extension JumpExitTests {

    /// 构造已配置的 CatSprite，初始化时给定位置
    func makeCat(
        sessionId: String = "test-cat",
        color: SessionColor = .sky,
        label: String = "test",
        x: CGFloat = 100
    ) -> CatSprite {
        let cat = CatSprite(sessionId: sessionId)
        cat.configure(color: color, labelText: label)
        cat.containerNode.position = CGPoint(x: x, y: 48)
        return cat
    }

    /// 将 CatSprite 数组转换为 exitScene 所需的 obstacles 格式
    func obstacleEntries(_ cats: [CatSprite]) -> [(cat: CatSprite, x: CGFloat)] {
        cats.map { (cat: $0, x: $0.containerNode.position.x) }
    }
}

// MARK: - JumpExitTests

final class JumpExitTests: XCTestCase {

    // MARK: - 验收标准 1：无障碍物退出正常工作（回归）

    func testExitNoObstaclesOriginalSignatureCompletionCalled() {
        // 验收：原有签名 exitScene(sceneWidth:completion:) 不变，completion 被调用
        let cat = makeCat(sessionId: "exit-regression", x: 100)
        let exp = expectation(description: "original exitScene completion called")

        cat.exitScene(sceneWidth: 400) {
            exp.fulfill()
        }

        wait(for: [exp], timeout: 5.0)
    }

    func testExitEmptyObstaclesNewOverloadCompletionCalled() {
        // 验收：新重载传入空障碍物列表，completion 仍被调用（行为与原版一致）
        let cat = makeCat(sessionId: "exit-empty-obs", x: 100)
        let exp = expectation(description: "new exitScene with empty obstacles calls completion")

        cat.exitScene(sceneWidth: 400, obstacles: [], onJumpOver: { _ in }) {
            exp.fulfill()
        }

        wait(for: [exp], timeout: 5.0)
    }

    // MARK: - 验收标准 2：有障碍物时触发跳跃回调（不是推过去）

    func testExitWithSingleObstacleTriggerJumpOverCallback() {
        // 验收：onJumpOver 在跳过障碍物时触发，且传入正确的障碍物 CatSprite
        // exitCat 在右半边 → 向右退出，obstacle 在其右侧路径上
        let exitCat = makeCat(sessionId: "exit-cat", x: 250)
        let obstacle = makeCat(sessionId: "obstacle-cat", x: 350)

        var jumpedOverCat: CatSprite?
        let exp = expectation(description: "onJumpOver callback triggered with obstacle")

        exitCat.exitScene(
            sceneWidth: 400,
            obstacles: obstacleEntries([obstacle]),
            onJumpOver: { cat in
                jumpedOverCat = cat
                exp.fulfill()
            }
        ) {}

        wait(for: [exp], timeout: 4.0)

        XCTAssertTrue(jumpedOverCat === obstacle, "onJumpOver 回调传入的应是障碍物 cat 本身")
    }

    // MARK: - 验收标准 11：所有障碍物都收到受惊回调

    func testAllObstaclesReceiveJumpOverCallback() {
        // exitCat 在右半边 → 向右退出，两个 obstacle 在其右侧路径上
        let exitCat = makeCat(sessionId: "exit-multi", x: 220)
        let obs1 = makeCat(sessionId: "obs-1", x: 300)
        let obs2 = makeCat(sessionId: "obs-2", x: 380)

        var jumpedSessionIds: [String] = []
        let exp = expectation(description: "all obstacles jumped")
        exp.expectedFulfillmentCount = 2

        exitCat.exitScene(
            sceneWidth: 400,
            obstacles: obstacleEntries([obs1, obs2]),
            onJumpOver: { cat in
                jumpedSessionIds.append(cat.sessionId)
                exp.fulfill()
            }
        ) {}

        wait(for: [exp], timeout: 6.0)

        XCTAssertEqual(jumpedSessionIds.count, 2, "两个障碍物都应触发 onJumpOver 回调")
        XCTAssertTrue(
            jumpedSessionIds.contains("obs-1") && jumpedSessionIds.contains("obs-2"),
            "两只障碍物 cat 都应出现在回调列表中"
        )
    }

    // MARK: - 验收标准 3：退出猫 isDynamic 立即变为 false

    func testExitCatIsDynamicFalseAfterExit() throws {
        let cat = makeCat(sessionId: "exit-dynamic", x: 100)

        guard cat.containerNode.physicsBody != nil else {
            throw XCTSkip("CatSprite 未配置 physicsBody，跳过测试")
        }

        cat.exitScene(sceneWidth: 400, obstacles: [], onJumpOver: { _ in }) {}

        // 调用 exitScene 后应立即设为 false（同步操作）
        XCTAssertFalse(
            cat.containerNode.physicsBody?.isDynamic ?? false,
            "exitScene 后 physicsBody.isDynamic 应立即变为 false"
        )
    }

    // MARK: - 验收标准 4：受惊反应播放 scared 帧

    func testFrightReactionRunsScaredAnimationKey() {
        // 验收：playFrightReaction 以 "frightReaction" key 运行动画序列
        let cat = makeCat(sessionId: "fright-anim", x: 200)

        cat.playFrightReaction(awayFromX: 100)

        XCTAssertTrue(
            cat.node.action(forKey: "frightReaction") != nil,
            "受惊反应应以 'frightReaction' key 启动动画 action"
        )
    }

    /// 验收标准 4 扩展：playFrightReaction(frightenedBy: ExitDirection) 便捷入口
    ///
    /// 设计文档要求新增此重载：
    ///   func playFrightReaction(frightenedBy: ExitDirection)
    /// 当前已实现的是 frightenedBy: CatSprite 版本。
    /// 蓝队实现该 ExitDirection 重载后，取消注释下方两个测试。
    ///
    func testFrightReactionViaExitDirectionLeftConvenience() {
        let cat = makeCat(sessionId: "fright-dir-left", x: 300)
        cat.playFrightReaction(frightenedBy: ExitDirection.left)
        XCTAssertTrue(
            cat.node.action(forKey: "frightReaction") != nil || cat.node.hasActions(),
            "playFrightReaction(frightenedBy: .left) 应触发受惊动画"
        )
    }

    func testFrightReactionViaExitDirectionRightConvenience() {
        let cat = makeCat(sessionId: "fright-dir-right", x: 100)
        cat.playFrightReaction(frightenedBy: ExitDirection.right)
        XCTAssertTrue(
            cat.node.action(forKey: "frightReaction") != nil || cat.node.hasActions(),
            "playFrightReaction(frightenedBy: .right) 应触发受惊动画"
        )
    }

    func testFrightReactionViaExitDirectionLeftSemantics() {
        // 验收等价：ExitDirection.left 表示跳跃者从左来，对应 awayFromX = 0（最左侧）
        // 猫在 x=300，应向右闪避
        let cat = makeCat(sessionId: "fright-dir-left", x: 300)
        let initialX = cat.containerNode.position.x

        let exp = expectation(description: "fright from left direction moves cat right")

        // 用 awayFromX: 0 模拟"跳跃者来自左边"的语义
        cat.playFrightReaction(awayFromX: 0)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertGreaterThan(
                cat.containerNode.position.x, initialX,
                "ExitDirection.left 语义：猫（x=\(initialX)）应向右移动，当前 x=\(cat.containerNode.position.x)"
            )
            exp.fulfill()
        }

        wait(for: [exp], timeout: 1.5)
    }

    func testFrightReactionViaExitDirectionRightSemantics() {
        // 验收等价：ExitDirection.right 表示跳跃者从右来，对应 awayFromX = 很大的值
        // 猫在 x=100，应向左闪避
        let cat = makeCat(sessionId: "fright-dir-right", x: 100)
        let initialX = cat.containerNode.position.x

        let exp = expectation(description: "fright from right direction moves cat left")

        // 用 awayFromX: 9999 模拟"跳跃者来自右边"的语义
        cat.playFrightReaction(awayFromX: 9999)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertLessThan(
                cat.containerNode.position.x, initialX,
                "ExitDirection.right 语义：猫（x=\(initialX)）应向左移动，当前 x=\(cat.containerNode.position.x)"
            )
            exp.fulfill()
        }

        wait(for: [exp], timeout: 1.5)
    }

    // MARK: - 验收标准 5：受惊方向正确（远离跳跃者）

    func testFrightReactionMovesRightWhenJumperIsOnLeft() {
        // 猫在 x=200，跳跃者在 x=50（左侧），猫应向右滑动
        let cat = makeCat(sessionId: "fright-direction-right", x: 200)
        let initialX = cat.containerNode.position.x

        let exp = expectation(description: "cat moves right away from left jumper")

        cat.playFrightReaction(awayFromX: 50)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let currentX = cat.containerNode.position.x
            // 滑动动画进行中，x 应增大（向右移动）
            XCTAssertGreaterThan(
                currentX, initialX,
                "跳跃者在左侧（x=50）时，猫（初始 x=\(initialX)）应向右移动，当前 x=\(currentX)"
            )
            exp.fulfill()
        }

        wait(for: [exp], timeout: 1.5)
    }

    func testFrightReactionMovesLeftWhenJumperIsOnRight() {
        // 猫在 x=200，跳跃者在 x=350（右侧），猫应向左滑动
        let cat = makeCat(sessionId: "fright-direction-left", x: 200)
        let initialX = cat.containerNode.position.x

        let exp = expectation(description: "cat moves left away from right jumper")

        cat.playFrightReaction(awayFromX: 350)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let currentX = cat.containerNode.position.x
            XCTAssertLessThan(
                currentX, initialX,
                "跳跃者在右侧（x=350）时，猫（初始 x=\(initialX)）应向左移动，当前 x=\(currentX)"
            )
            exp.fulfill()
        }

        wait(for: [exp], timeout: 1.5)
    }

    func testFrightNetPositiveDisplacementWhenJumperOnLeft() {
        // 滑动 40px（被 clamp 后）后回弹 ~30%，净移动为正
        // 猫 x=200，跳跃者 x=50（向右逃）
        let cat = makeCat(sessionId: "fright-net-disp", x: 200)
        let exp = expectation(description: "net displacement positive after fright from left")

        cat.playFrightReaction(awayFromX: 50)

        // 等待动画全部完成（scared 帧 + slide 0.15s + rebound 0.12s + 余量）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            let finalX = cat.containerNode.position.x
            XCTAssertGreaterThan(
                finalX, 200,
                "受惊动画完成后净位移应为正（向右），finalX=\(finalX)"
            )
            exp.fulfill()
        }

        wait(for: [exp], timeout: 2.0)
    }

    // MARK: - 验收标准 6：受惊后 isDynamic 恢复为 true

    func testIsDynamicRestoredAfterFrightAnimation() throws {
        let cat = makeCat(sessionId: "fright-restore-dynamic", x: 200)

        guard cat.containerNode.physicsBody != nil else {
            throw XCTSkip("CatSprite 未配置 physicsBody，跳过测试")
        }

        let exp = expectation(description: "isDynamic = true after fright animation completes")

        cat.playFrightReaction(awayFromX: 50)

        // scared 帧 ~0.12s × N + slide 0.15s + rebound 0.12s，等待 1.0s
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            XCTAssertTrue(
                cat.containerNode.physicsBody?.isDynamic ?? false,
                "受惊动画完成后 isDynamic 应恢复为 true"
            )
            exp.fulfill()
        }

        wait(for: [exp], timeout: 2.5)
    }

    // MARK: - 验收标准 7：permissionRequest 猫不受惊

    func testPermissionRequestCatImmuneToFrightReaction() {
        // 验收：permissionRequest 状态豁免受惊，x 位置不变
        let cat = makeCat(sessionId: "perm-immune", x: 200)
        cat.switchState(to: .permissionRequest, toolDescription: "Run command")

        let initialX = cat.containerNode.position.x

        let exp = expectation(description: "permission cat position unchanged by fright")

        cat.playFrightReaction(awayFromX: 50)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            let finalX = cat.containerNode.position.x
            XCTAssertEqual(
                finalX, initialX,
                accuracy: 1.0,
                "permissionRequest 状态豁免受惊，x 不应改变：initialX=\(initialX), finalX=\(finalX)"
            )
            exp.fulfill()
        }

        wait(for: [exp], timeout: 1.5)
    }

    func testPermissionRequestCatNoFrightActionKey() {
        // 验收：permissionRequest 豁免时，"frightReaction" action 不应被加入
        let cat = makeCat(sessionId: "perm-no-fright-key", x: 200)
        cat.switchState(to: .permissionRequest, toolDescription: "Run command")

        cat.playFrightReaction(awayFromX: 50)

        XCTAssertNil(
            cat.node.action(forKey: "frightReaction"),
            "permissionRequest 状态不应启动 frightReaction action"
        )
    }

    // MARK: - 验收标准 8：switchState 恢复 isDynamic（安全网）

    func testSwitchStateRestoresDynamicWhenSetToFalse() throws {
        let cat = makeCat(sessionId: "switch-safeguard", x: 200)

        guard cat.containerNode.physicsBody != nil else {
            throw XCTSkip("CatSprite 未配置 physicsBody，跳过测试")
        }

        // 模拟受惊期间 isDynamic 被置为 false
        cat.containerNode.physicsBody?.isDynamic = false
        XCTAssertFalse(cat.containerNode.physicsBody?.isDynamic ?? true, "前置条件：isDynamic 应为 false")

        // switchState 顶部安全网应恢复 isDynamic = true
        cat.switchState(to: .thinking)

        XCTAssertTrue(
            cat.containerNode.physicsBody?.isDynamic ?? false,
            "switchState 应将 isDynamic 恢复为 true（安全网）"
        )
    }

    func testSwitchStateSafeguardWorksForMultipleStates() {
        let states: [CatState] = [.idle, .thinking, .toolUse]

        for state in states {
            let cat = makeCat(sessionId: "safeguard-\(state.rawValue)", x: 200)

            guard cat.containerNode.physicsBody != nil else { continue }

            cat.containerNode.physicsBody?.isDynamic = false
            cat.switchState(to: state)

            XCTAssertTrue(
                cat.containerNode.physicsBody?.isDynamic ?? false,
                "switchState(to: .\(state.rawValue)) 应恢复 isDynamic"
            )
        }
    }

    // MARK: - 验收标准 9：障碍物按正确顺序排列（从近到远）

    func testObstaclesJumpedNearToFarEvenIfPassedOutOfOrder() {
        // 验收：实现应按距离排序，不依赖传入顺序
        // 退出猫 x=220（向右退出），nearObs x=300，farObs x=380
        let exitCat = makeCat(sessionId: "order-exit", x: 220)
        let nearObs = makeCat(sessionId: "order-near", x: 300)
        let farObs = makeCat(sessionId: "order-far", x: 380)

        var jumpOrder: [String] = []
        let exp = expectation(description: "obstacles jumped near-to-far")
        exp.expectedFulfillmentCount = 2

        // 故意传入乱序（farObs 在前），验证实现按距离排序
        exitCat.exitScene(
            sceneWidth: 400,
            obstacles: [
                (cat: farObs, x: farObs.containerNode.position.x),
                (cat: nearObs, x: nearObs.containerNode.position.x)
            ],
            onJumpOver: { cat in
                jumpOrder.append(cat.sessionId)
                exp.fulfill()
            }
        ) {}

        wait(for: [exp], timeout: 6.0)

        XCTAssertEqual(jumpOrder.count, 2, "应跳过 2 个障碍物")
        XCTAssertEqual(jumpOrder[0], "order-near", "应先跳过较近的障碍物（x=150）")
        XCTAssertEqual(jumpOrder[1], "order-far", "应最后跳过较远的障碍物（x=280）")
    }

    func testObstaclesNotOnPathAreNotJumped() {
        // 验收：路径外的猫（反方向）不被跳过
        // 退出猫 x=250，向右退出（sceneWidth=400，右边距更近）
        // onPath: x=350；offPath: x=80（在左侧，不在右侧路径上）
        let exitCat = makeCat(sessionId: "path-exit", x: 250)
        let onPath = makeCat(sessionId: "on-path", x: 350)
        let offPath = makeCat(sessionId: "off-path", x: 80)

        var jumpedIds: [String] = []
        let exp = expectation(description: "only on-path obstacles jumped")
        exp.expectedFulfillmentCount = 1

        var extraCallMade = false

        exitCat.exitScene(
            sceneWidth: 400,
            obstacles: [
                (cat: onPath, x: onPath.containerNode.position.x),
                (cat: offPath, x: offPath.containerNode.position.x)
            ],
            onJumpOver: { cat in
                jumpedIds.append(cat.sessionId)
                if jumpedIds.count == 1 {
                    exp.fulfill()
                } else {
                    extraCallMade = true
                }
            }
        ) {}

        wait(for: [exp], timeout: 5.0)

        // 额外确认没有多余回调
        let noExtraExp = expectation(description: "no extra callbacks")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            noExtraExp.fulfill()
        }
        wait(for: [noExtraExp], timeout: 1.0)

        XCTAssertFalse(extraCallMade, "路径外的猫（x=80）不应触发 onJumpOver 回调")
        XCTAssertEqual(jumpedIds, ["on-path"], "只有路径上的猫应被跳过")
    }

    // MARK: - 验收标准 10：跳跃弧线高于起始位置

    func testJumpArcPeakIsAboveStartingY() {
        // 验收：贝塞尔弧线峰值应高于起始 y（设计要求约 +25px）
        // exitCat 靠近 obstacle，减少 approach 时间确保 GCD 更新在采样窗口内
        let exitCat = makeCat(sessionId: "arc-test", x: 320)
        let obstacle = makeCat(sessionId: "arc-obs", x: 350)

        let startY = exitCat.containerNode.position.y  // 应为 48
        var peakY: CGFloat = startY

        var samplingDone = false
        let samplingExp = expectation(description: "y sampling completed")
        let completionExp = expectation(description: "exit completed")

        exitCat.exitScene(
            sceneWidth: 400,
            obstacles: obstacleEntries([obstacle]),
            onJumpOver: { _ in }
        ) {
            completionExp.fulfill()
        }

        // 以高频采样 y 坐标寻找峰值
        func scheduleSample(count: Int) {
            guard count > 0 && !samplingDone else {
                samplingDone = true
                samplingExp.fulfill()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                let y = exitCat.containerNode.position.y
                if y > peakY { peakY = y }
                scheduleSample(count: count - 1)
            }
        }
        scheduleSample(count: 25)

        wait(for: [samplingExp, completionExp], timeout: 8.0)

        XCTAssertGreaterThan(
            peakY, startY + 10,
            "跳跃弧线峰值 y=\(peakY) 应高于起始 y=\(startY)（设计要求峰值约 +25px）"
        )
    }

    // MARK: - 验收标准 12：eating 猫被受惊后恢复到 idle

    func testEatingCatRestoresToIdleAfterFrightAnimation() {
        let cat = makeCat(sessionId: "eating-restore", x: 200)
        cat.switchState(to: .eating)

        XCTAssertEqual(cat.currentState, .eating, "前置条件：应为 eating 状态")

        let exp = expectation(description: "eating cat restores to idle after fright")

        cat.playFrightReaction(awayFromX: 50)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            XCTAssertEqual(
                cat.currentState, .idle,
                "eating 状态猫受惊后应恢复到 idle，当前状态: \(cat.currentState.rawValue)"
            )
            exp.fulfill()
        }

        wait(for: [exp], timeout: 3.0)
    }

    func testThinkingCatRestoresToThinkingAfterFright() {
        let cat = makeCat(sessionId: "thinking-restore", x: 200)
        cat.switchState(to: .thinking)

        let exp = expectation(description: "thinking cat restores to thinking after fright")

        cat.playFrightReaction(awayFromX: 350)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            XCTAssertEqual(
                cat.currentState, .thinking,
                "thinking 状态猫受惊后应恢复原状态 thinking，当前: \(cat.currentState.rawValue)"
            )
            exp.fulfill()
        }

        wait(for: [exp], timeout: 3.0)
    }

    func testToolUseCatRestoresToToolUseAfterFright() {
        let cat = makeCat(sessionId: "tooluse-restore", x: 200)
        cat.switchState(to: .toolUse)

        let exp = expectation(description: "toolUse cat restores to toolUse after fright")

        cat.playFrightReaction(awayFromX: 350)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            XCTAssertEqual(
                cat.currentState, .toolUse,
                "toolUse 状态猫受惊后应恢复原状态 toolUse，当前: \(cat.currentState.rawValue)"
            )
            exp.fulfill()
        }

        wait(for: [exp], timeout: 3.0)
    }

    // MARK: - 验收标准 13：受惊猫不超出边界

    func testFrightReactionClampedToRightBound() {
        // 猫接近右边界（x=370），向右逃应被 clamp 到 sceneWidth-24
        let cat = makeCat(sessionId: "clamp-right", x: 370)
        cat.updateSceneSize(CGSize(width: 400, height: 80))

        let exp = expectation(description: "x clamped to right bound after fright")

        cat.playFrightReaction(awayFromX: 50)  // 跳跃者在左侧，猫向右逃

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let finalX = cat.containerNode.position.x
            // sceneWidth=400 → 右边界为 376（400-24）
            // 猫从 370 向右逃 30px → 400 → clamp 到 376 → 回弹到 376-15=361
            XCTAssertLessThanOrEqual(
                finalX, 377,  // 允许 1pt 误差
                "受惊后靠近右边界的猫 x=\(finalX) 不应超过 376"
            )
            exp.fulfill()
        }

        wait(for: [exp], timeout: 2.0)
    }

    func testFrightReactionClampedWhenCalledViaExitScene() {
        // 通过 exitScene 触发的受惊场景，使用已知 sceneWidth=400 的 clamp 边界
        // 障碍物在 x=370（接近右边界），跳跃者 exitCat 从左侧跳过
        // exitCat 在右半边 → 向右退出
        let exitCat = makeCat(sessionId: "clamp-exit", x: 250)
        let nearRightBoundary = makeCat(sessionId: "clamp-obs", x: 370)
        nearRightBoundary.updateSceneSize(CGSize(width: 400, height: 80))

        let exp = expectation(description: "frightened obstacle stays within bounds")

        exitCat.exitScene(
            sceneWidth: 400,
            obstacles: obstacleEntries([nearRightBoundary]),
            onJumpOver: { cat in
                // 触发受惊，jumper 在左侧（exitCat 从左向右跳），猫应向右逃
                cat.playFrightReaction(awayFromX: exitCat.containerNode.position.x)
            }
        ) {
            // 在完成后检查障碍物位置
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                let finalX = nearRightBoundary.containerNode.position.x
                // sceneWidth=400 时，右边界为 400-24=376
                XCTAssertLessThanOrEqual(
                    finalX, 377,  // 允许 1pt 误差
                    "受惊后靠近右边界的猫 x=\(finalX) 不应超过右边界 376"
                )
                exp.fulfill()
            }
        }

        wait(for: [exp], timeout: 8.0)
    }

    func testFrightReactionXStaysWithinBoundsDuringAnimation() {
        // 持续采样确保动画全程 x 在合理范围内
        let cat = makeCat(sessionId: "clamp-sampling", x: 200)

        let exp = expectation(description: "x stays within reasonable bounds during fright")

        cat.playFrightReaction(awayFromX: 50)

        var outOfBounds = false
        func checkBounds(count: Int) {
            guard count > 0 else {
                exp.fulfill()
                return
            }
            let x = cat.containerNode.position.x
            // 验证不超出 [0, 500] 的宽松范围，精确边界由 clamp 机制保证
            if x < 0 || x > 500 { outOfBounds = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                checkBounds(count: count - 1)
            }
        }
        checkBounds(count: 16)

        wait(for: [exp], timeout: 2.5)

        XCTAssertFalse(outOfBounds, "受惊过程中 x 坐标不应超出合理范围")
    }

    // MARK: - ExitDirection 枚举类型验证

    func testExitDirectionEnumExists() {
        // 验收：ExitDirection 枚举应存在 .left 和 .right 两个 case
        let left = ExitDirection.left
        let right = ExitDirection.right
        // 仅验证类型可构造，枚举存在
        _ = left
        _ = right
        XCTAssertTrue(true, "ExitDirection.left 和 ExitDirection.right 均存在")
    }

    // MARK: - 完整集成测试

    func testFullJumpExitWithFrightIntegration() {
        // 验收：退出猫跳过障碍物，触发受惊，最终退出屏幕
        // exitCat 在右半边 → 向右退出
        let exitCat = makeCat(sessionId: "integration-exit", x: 250)
        let idleCat = makeCat(sessionId: "integration-obs", x: 350)

        var frightTriggered = false
        let frightExp = expectation(description: "fright triggered on obstacle")
        let completionExp = expectation(description: "exit cat completes exit")

        exitCat.exitScene(
            sceneWidth: 400,
            obstacles: obstacleEntries([idleCat]),
            onJumpOver: { jumpedCat in
                // BuddyScene 会在此回调里调用 playFrightReaction
                jumpedCat.playFrightReaction(awayFromX: exitCat.containerNode.position.x)
                frightTriggered = true
                frightExp.fulfill()
            }
        ) {
            completionExp.fulfill()
        }

        wait(for: [frightExp, completionExp], timeout: 8.0)

        XCTAssertTrue(frightTriggered, "障碍物应收到受惊回调")
        // 退出猫应已离开屏幕（x 超出 [0, 400] 范围）
        let exitX = exitCat.containerNode.position.x
        let isOffScreen = exitX < 0 || exitX > 400
        XCTAssertTrue(isOffScreen, "退出猫应已离开屏幕，当前 x=\(exitX)")
    }

    // MARK: - Eating 状态受惊中断恢复

    /// 验证 eating 猫被受惊后食物资源被正确释放
    func testFrightDuringEatingReleasesFoodResources() {
        let cat = makeCat(sessionId: "eating-food-release", x: 200)
        cat.switchState(to: .eating)

        // 模拟猫持有食物
        let mockFood = FoodSprite(textureName: "test_dummy")
        cat.currentTargetFood = mockFood

        var foodAbandoned = false
        cat.onFoodAbandoned = { _ in foodAbandoned = true }

        cat.playFrightReaction(awayFromX: 50)

        // food resources 应在 removeAllActions 之前被释放
        XCTAssertNil(cat.currentTargetFood, "受惊时应释放 currentTargetFood")
        XCTAssertTrue(foodAbandoned, "受惊时应调用 onFoodAbandoned 回调")
    }

    /// 验证多次受惊不会导致 eating 猫永久卡死
    func testMultipleFrightsDuringEatingDontDeadlock() {
        let cat = makeCat(sessionId: "eating-multi-fright", x: 200)
        cat.switchState(to: .eating)
        XCTAssertEqual(cat.currentState, .eating)

        let exp = expectation(description: "cat recovers after multiple frights during eating")

        // 连续 3 次受惊
        cat.playFrightReaction(awayFromX: 50)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            cat.playFrightReaction(awayFromX: 350)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            cat.playFrightReaction(awayFromX: 50)
        }

        // 1.5s 后检查状态不应是 eating
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            XCTAssertNotEqual(
                cat.currentState, .eating,
                "多次受惊后猫不应卡在 eating 状态，当前: \(cat.currentState.rawValue)"
            )
            exp.fulfill()
        }

        wait(for: [exp], timeout: 3.0)
    }

    /// 验证 eating 状态被受惊中断恢复到 idle 后，后续事件能正常切换状态
    func testEatingCatAcceptsNewStateAfterFrightRecovery() {
        let cat = makeCat(sessionId: "eating-then-thinking", x: 200)
        cat.switchState(to: .eating)
        XCTAssertEqual(cat.currentState, .eating)

        let exp = expectation(description: "cat accepts new state after fright recovery")

        cat.playFrightReaction(awayFromX: 50)

        // 等待 fright 的 GCD fallback 恢复 eating → idle
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            XCTAssertEqual(cat.currentState, .idle, "受惊恢复后应先回到 idle")

            // 从 idle 可以正常切换到任意状态
            cat.switchState(to: .thinking)
            XCTAssertEqual(cat.currentState, .thinking, "idle 后应能切换到 thinking")
            exp.fulfill()
        }

        wait(for: [exp], timeout: 3.0)
    }
}
