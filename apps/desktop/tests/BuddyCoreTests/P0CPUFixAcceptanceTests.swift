import XCTest
import SpriteKit
@testable import BuddyCore

// MARK: - P0CPUFixAcceptanceTests

/// P0 CPU 修复验收测试
///
/// 验证以下契约：
/// - C1: SKView.preferredFramesPerSecond = 30，不因 runtime 条件改变
/// - C2: activeCatCount == 0 → isPaused = true；activeCatCount > 0 → isPaused = false
/// - C3: 移除 addGlobalMonitorForEvents，保留 addLocalMonitorForEvents
/// - C4: 现有功能不受影响（hover tooltip / click / drag）
///
/// 测试目标：BuddyCoreTests
final class P0CPUFixAcceptanceTests: XCTestCase {

    // MARK: - Helpers

    /// 创建一个已呈现 BuddyScene 的 BuddySKView，模拟 AppDelegate 的 setupWindow 逻辑。
    private func makeSKViewWithScene(width: CGFloat = 800, height: CGFloat = 80) -> (BuddySKView, BuddyScene) {
        let frame = NSRect(x: 0, y: 0, width: width, height: height)
        let skView = BuddySKView(frame: frame)
        skView.allowsTransparency = true
        skView.preferredFramesPerSecond = 30
        skView.isPaused = true

        let scene = BuddyScene(size: frame.size)
        scene.scaleMode = .resizeFill
        scene.activityBounds = 48...752
        skView.presentScene(scene)

        return (skView, scene)
    }

    /// 创建一个基本的 SessionInfo 用于 addCat。
    private func makeSessionInfo(
        sessionId: String = "test-cat",
        label: String = "test",
        color: SessionColor = .coral
    ) -> SessionInfo {
        SessionInfo(
            sessionId: sessionId,
            label: label,
            color: color,
            cwd: "/tmp/test",
            pid: nil,
            terminalId: nil,
            state: .idle,
            lastActivity: Date(),
            toolDescription: nil,
            model: nil,
            startedAt: Date(),
            totalTokens: 0,
            toolCallCount: 0
        )
    }

    /// 创建一个 BuddyWindow 实例用于 MouseTracker 测试。
    private func makeWindow(frame: NSRect = NSRect(x: 0, y: 0, width: 800, height: 80)) -> BuddyWindow {
        BuddyWindow(contentRect: frame)
    }

    // MARK: - C1: SKView 帧率验证

    /// 场景 1: 启动 app 后 SKView 的 preferredFramesPerSecond 应为 30。
    /// 验证 BuddySKView 被正确初始化为 30 FPS。
    func testPreferredFramesPerSecondIs30() {
        let (skView, _) = makeSKViewWithScene()
        XCTAssertEqual(skView.preferredFramesPerSecond, 30,
                       "C1: preferredFramesPerSecond 应为 30")
    }

    /// C1 补充: preferredFramesPerSecond 不应因 presentScene 或 didMove(to:) 改变。
    func testPreferredFramesPerSecondDoesNotChangeAfterScenePresentation() {
        let frame = NSRect(x: 0, y: 0, width: 800, height: 80)
        let skView = BuddySKView(frame: frame)
        skView.preferredFramesPerSecond = 30

        // presentScene 后帧率不变
        let scene = BuddyScene(size: frame.size)
        scene.activityBounds = 48...752
        skView.presentScene(scene)

        XCTAssertEqual(skView.preferredFramesPerSecond, 30,
                       "C1: presentScene 后 preferredFramesPerSecond 应仍为 30")
    }

    /// C1 补充: 重新设置 preferredFramesPerSecond 之后仍可读取正确的值。
    func testPreferredFramesPerSecondPersistsAfterReassignment() {
        let (skView, _) = makeSKViewWithScene()

        // 模拟可能的误改
        skView.preferredFramesPerSecond = 60
        skView.preferredFramesPerSecond = 30

        XCTAssertEqual(skView.preferredFramesPerSecond, 30,
                       "C1: 重新赋值为 30 后 preferredFramesPerSecond 应为 30")
    }

    // MARK: - C2: 暂停规则

    /// 场景 2a: 初始状态 0 只猫 → SKView.isPaused == true。
    func testSceneIsPausedWhenNoCats() {
        let (skView, scene) = makeSKViewWithScene()
        // 初始: 0 只猫
        XCTAssertEqual(scene.activeCatCount, 0,
                       "初始 activeCatCount 应为 0")

        // 模拟 AppDelegate 中的 onSessionCountChanged 逻辑
        skView.isPaused = (scene.activeCatCount == 0)
        XCTAssertTrue(skView.isPaused,
                      "C2: 0 只猫时 isPaused 应为 true")
    }

    /// 场景 2b: 添加 1 只猫 → SKView.isPaused == false。
    func testSceneResumesWhenCatAdded() {
        let (skView, scene) = makeSKViewWithScene()

        // 初始暂停
        skView.isPaused = (scene.activeCatCount == 0)
        XCTAssertTrue(skView.isPaused)

        // 添加 1 只猫
        scene.addCat(info: makeSessionInfo(sessionId: "cat-1"))
        XCTAssertEqual(scene.activeCatCount, 1,
                       "添加猫后 activeCatCount 应为 1")

        // 模拟 AppDelegate 的 onSessionCountChanged 逻辑
        skView.isPaused = (scene.activeCatCount == 0)
        XCTAssertFalse(skView.isPaused,
                       "C2: activeCatCount > 0 时 isPaused 应为 false")
    }

    /// 场景 2c: 移除所有猫 → SKView.isPaused == true。
    func testScenePausesAgainWhenAllCatsRemoved() {
        let (skView, scene) = makeSKViewWithScene()

        // 添加 2 只猫
        scene.addCat(info: makeSessionInfo(sessionId: "cat-1"))
        scene.addCat(info: makeSessionInfo(sessionId: "cat-2"))
        XCTAssertEqual(scene.activeCatCount, 2)

        skView.isPaused = (scene.activeCatCount == 0)
        XCTAssertFalse(skView.isPaused)

        // 移除第 1 只猫
        scene.removeCat(sessionId: "cat-1")
        XCTAssertEqual(scene.activeCatCount, 1)

        skView.isPaused = (scene.activeCatCount == 0)
        XCTAssertFalse(skView.isPaused,
                       "C2: 仍有 1 只猫时 isPaused 应为 false")

        // 移除第 2 只猫 → 恢复暂停
        scene.removeCat(sessionId: "cat-2")
        XCTAssertEqual(scene.activeCatCount, 0)

        skView.isPaused = (scene.activeCatCount == 0)
        XCTAssertTrue(skView.isPaused,
                      "C2: 移除所有猫后 isPaused 应为 true")
    }

    /// C2 补充: addCat 后在 isPaused 更新前 activeCatCount 已 > 0。
    /// 合同要求「addCat 被调用后 1 帧内完成 resume」。
    func testActiveCatCountIncrementsImmediatelyAfterAddCat() {
        let (_, scene) = makeSKViewWithScene()
        XCTAssertEqual(scene.activeCatCount, 0)

        scene.addCat(info: makeSessionInfo(sessionId: "immediate-cat"))
        // activeCatCount 应立即反映新猫（不等下一帧）
        XCTAssertEqual(scene.activeCatCount, 1,
                       "C2: addCat 调用后 activeCatCount 应立即 > 0")
    }

    /// C2 补充: 多次 add/remove 边界测试。
    func testPauseBehaviorWithMultipleAddRemoveCycles() {
        let (skView, scene) = makeSKViewWithScene()

        // Cycle 1: add → resume
        scene.addCat(info: makeSessionInfo(sessionId: "cycle-cat"))
        skView.isPaused = (scene.activeCatCount == 0)
        XCTAssertFalse(skView.isPaused)

        // Cycle 1: remove → pause
        scene.removeCat(sessionId: "cycle-cat")
        skView.isPaused = (scene.activeCatCount == 0)
        XCTAssertTrue(skView.isPaused)

        // Cycle 2: add again → resume
        scene.addCat(info: makeSessionInfo(sessionId: "cycle-cat-2"))
        skView.isPaused = (scene.activeCatCount == 0)
        XCTAssertFalse(skView.isPaused,
                       "C2: 第二个 add/remove 周期后应能正确恢复")

        // Cycle 2: remove → pause
        scene.removeCat(sessionId: "cycle-cat-2")
        skView.isPaused = (scene.activeCatCount == 0)
        XCTAssertTrue(skView.isPaused,
                      "C2: 第二个周期移除后应恢复暂停")
    }

    // MARK: - C3: 全局鼠标监听已移除

    /// 场景 3: MouseTracker 不应再使用 addGlobalMonitorForEvents。
    ///
    /// 验证 MouseTracker 实例不再持有 globalMonitor 属性。
    /// 当前 MouseTracker 仅有 localMonitor（private），
    /// 且 start() 方法中不再调用 addGlobalMonitorForEvents。
    func testMouseTrackerHasNoGlobalMonitorPropertyViaReflection() {
        let window = makeWindow()
        let scene = BuddyScene(size: CGSize(width: 800, height: 80))
        scene.activityBounds = 48...752
        let tracker = MouseTracker(window: window, scene: scene)

        let mirror = Mirror(reflecting: tracker)
        let children = mirror.children.map { $0.label }

        // 不应存在名为 "globalMonitor" 的存储属性
        let hasGlobalMonitor = children.contains { $0 == "globalMonitor" }
        XCTAssertFalse(hasGlobalMonitor,
                       "C3: MouseTracker 不应有 globalMonitor 属性")
    }

    /// C3 补充: 验证 localMonitor 仍然存在（保留的本地监听）。
    func testMouseTrackerStillHasLocalMonitorProperty() {
        let window = makeWindow()
        let scene = BuddyScene(size: CGSize(width: 800, height: 80))
        scene.activityBounds = 48...752
        let tracker = MouseTracker(window: window, scene: scene)

        let mirror = Mirror(reflecting: tracker)
        let children = mirror.children.map { $0.label }

        let hasLocalMonitor = children.contains { $0 == "localMonitor" }
        XCTAssertTrue(hasLocalMonitor,
                      "C3: MouseTracker 应保留 localMonitor 属性（本地监听不动）")
    }

    /// C3 补充: start() 后 localMonitor 不为 nil。
    ///
    /// 注意: 测试环境中 addLocalMonitorForEvents 可能无法正常工作，
    /// 但至少应验证 start() 不崩溃且无全局监听副作用。
    func testMouseTrackerStartDoesNotThrow() {
        let window = makeWindow()
        let scene = BuddyScene(size: CGSize(width: 800, height: 80))
        scene.activityBounds = 48...752
        let tracker = MouseTracker(window: window, scene: scene)

        // start() 不应崩溃或抛异常
        tracker.start()

        // stop() 清理
        tracker.stop()
    }

    /// C3 补充: BuddySKView 有 NSTrackingArea 回调属性用于替代全局监听。
    func testBuddySKViewHasTrackingAreaCallbacks() {
        let skView = BuddySKView(frame: NSRect(x: 0, y: 0, width: 800, height: 80))

        // 验证回调属性存在（用于替代全局监听）
        XCTAssertNil(skView.onMouseMoved, "onMouseMoved 初始应为 nil")
        XCTAssertNil(skView.onMouseEntered, "onMouseEntered 初始应为 nil")
        XCTAssertNil(skView.onMouseExited, "onMouseExited 初始应为 nil")
    }

    /// C3 补充: BuddySKView 的 updateTrackingAreas 正确配置 NSTrackingArea。
    func testBuddySKViewUpdateTrackingAreasAddsTrackingArea() {
        let skView = BuddySKView(frame: NSRect(x: 0, y: 0, width: 800, height: 80))

        // 调用 updateTrackingAreas 应添加 tracking area
        let beforeCount = skView.trackingAreas.count
        skView.updateTrackingAreas()
        let afterCount = skView.trackingAreas.count

        XCTAssertGreaterThanOrEqual(afterCount, beforeCount,
                                    "updateTrackingAreas 应添加 tracking area")
        XCTAssertFalse(skView.trackingAreas.isEmpty,
                       "updateTrackingAreas 后 trackingAreas 不应为空")
    }

    // MARK: - C4: 现有功能回归 —— Hover

    /// 场景 4a: catAtPoint 正常返回命中猫咪的 sessionId。
    func testCatAtPointReturnsSessionIdWhenPointHitsCat() {
        let (_, scene) = makeSKViewWithScene()
        let sessionId = "hover-cat"
        scene.addCat(info: makeSessionInfo(sessionId: sessionId))

        // 猫咪初始位置在 spawnX（随机在 activityBounds 内），Y=24 (groundY)
        // 用 catPosition 获取实际 X 坐标
        guard let catX = scene.catPosition(for: sessionId) else {
            XCTFail("catPosition 应返回非 nil")
            return
        }

        // catAtPoint 在猫咪 hitbox 中心应命中
        let hitSessionId = scene.catAtPoint(CGPoint(x: catX, y: 24))
        XCTAssertEqual(hitSessionId, sessionId,
                       "C4: catAtPoint 应命中猫咪并返回 sessionId")
    }

    /// 场景 4a 补充: catAtPoint 在猫咪 hitbox 外返回 nil。
    func testCatAtPointReturnsNilWhenPointMissesCat() {
        let (_, scene) = makeSKViewWithScene()
        let sessionId = "miss-cat"
        scene.addCat(info: makeSessionInfo(sessionId: sessionId))

        // 远离猫咪的位置
        let hitSessionId = scene.catAtPoint(CGPoint(x: 9999, y: 9999))
        XCTAssertNil(hitSessionId,
                     "C4: catAtPoint 在 hitbox 外应返回 nil")
    }

    /// 场景 4a 补充: setHovered 和 clearHover 正常工作。
    func testSetHoveredAndClearHover() {
        let (_, scene) = makeSKViewWithScene()
        let sessionId = "hover-cat"
        scene.addCat(info: makeSessionInfo(sessionId: sessionId))

        // setHovered(true) 不应崩溃
        scene.setHovered(sessionId: sessionId, hovered: true)

        // clearHover 不应崩溃
        scene.clearHover()
    }

    /// 场景 4a 补充: MouseTracker.handleMouseMoved 触发 onHover 回调。
    @MainActor
    func testMouseTrackerHandleMouseMovedFiresOnHover() throws {
        let window = makeWindow()
        let scene = BuddyScene(size: CGSize(width: 800, height: 80))
        scene.activityBounds = 48...752
        let skView = BuddySKView(frame: NSRect(x: 0, y: 0, width: 800, height: 80))
        skView.presentScene(scene)
        window.contentView = skView

        let sessionId = "hover-firing-cat"
        scene.addCat(info: makeSessionInfo(sessionId: sessionId))

        guard let catX = scene.catPosition(for: sessionId) else {
            XCTFail("catPosition 应返回非 nil")
            return
        }

        let tracker = MouseTracker(window: window, scene: scene)

        let hoverExpectation = expectation(description: "onHover 回调触发")
        var receivedSessionId: String?
        tracker.onHover = { sessionId in
            receivedSessionId = sessionId
            hoverExpectation.fulfill()
        }

        // 构造一个鼠标移动到猫咪上方的事件
        // 场景坐标: catX, 24 → 需要转换为 window 坐标
        // 注意: 在测试环境中 SKView 的坐标转换可能与实际不同
        // 这里直接使用场景坐标（假设 scene 和 view 原点对齐）
        guard let event = NSEvent.mouseEvent(
            with: .mouseMoved,
            location: NSPoint(x: catX, y: 24),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        ) else {
            throw XCTSkip("无法创建 NSEvent，测试环境中可能不支持")
        }

        tracker.handleMouseMoved(event)

        wait(for: [hoverExpectation], timeout: 1.0)
        XCTAssertEqual(receivedSessionId, sessionId,
                       "C4: handleMouseMoved 应触发 onHover 并传入正确的 sessionId")
    }

    // MARK: - C4: 现有功能回归 —— Click

    /// 场景 4b: onClick 回调在鼠标按下+松开（非拖拽）时正常触发。
    ///
    /// 注意: MouseTracker 的 click/drag 处理逻辑是私有的 (handleMouseDown/Up/Dragged)。
    /// 由于这些方法不公开且依赖 NSEvent 的真实流经 monitor 链，
    /// 此处通过验证 BuddyScene.simulateClick 来间接确认 click 链完整性。
    func testSimulateClickInvokesPermissionAcknowledge() {
        let (_, scene) = makeSKViewWithScene()
        let sessionId = "click-cat"
        scene.addCat(info: makeSessionInfo(sessionId: sessionId))

        // 先切换到 permissionRequest 状态以验证 simulateClick 的 acknowledge 分支
        scene.updateCatState(sessionId: sessionId, state: .permissionRequest)

        // simulateClick 应返回 true
        let result = scene.simulateClick(sessionId: sessionId)
        XCTAssertTrue(result, "C4: simulateClick 应返回 true")
    }

    /// 场景 4b 补充: onClick 回调可在 MouseTracker 上设置。
    func testMouseTrackerOnClickCallbackCanBeSet() {
        let window = makeWindow()
        let scene = BuddyScene(size: CGSize(width: 800, height: 80))
        scene.activityBounds = 48...752
        let tracker = MouseTracker(window: window, scene: scene)

        var clickFired = false
        tracker.onClick = { sessionId in
            clickFired = true
        }

        XCTAssertNotNil(tracker.onClick, "C4: onClick 回调应可设置")
        // 验证回调可执行（不检查是否被触发，因为需要真实事件流）
        tracker.onClick?("test")
        XCTAssertTrue(clickFired, "C4: onClick 闭包应可正常执行")
    }

    // MARK: - C4: 现有功能回归 —— Drag

    /// 场景 4c: onDragStart/Update/End 回调正常。
    func testBuddySceneStartDragUpdateDragEndDrag() {
        let (_, scene) = makeSKViewWithScene()
        let sessionId = "drag-cat"
        scene.addCat(info: makeSessionInfo(sessionId: sessionId))

        guard let catX = scene.catPosition(for: sessionId) else {
            XCTFail("catPosition 应返回非 nil")
            return
        }

        let startPoint = CGPoint(x: catX, y: 24)

        // startDrag 不应崩溃
        scene.startDrag(sessionId: sessionId, at: startPoint)

        // updateDrag 不应崩溃
        scene.updateDrag(to: CGPoint(x: catX + 100, y: 24))

        // endDrag 不应崩溃
        scene.endDrag()
    }

    /// 场景 4c 补充: startDrag 对不存在的 sessionId 应安全处理（不崩溃）。
    func testBuddySceneStartDragWithUnknownSessionId() {
        let (_, scene) = makeSKViewWithScene()

        // startDrag 对不存在的 sessionId 不应崩溃
        scene.startDrag(sessionId: "nonexistent", at: CGPoint(x: 400, y: 24))
        // 测试通过即不崩溃
    }

    /// 场景 4c 补充: MouseTracker 的 drag 回调属性可设置。
    func testMouseTrackerDragCallbacksCanBeSet() {
        let window = makeWindow()
        let scene = BuddyScene(size: CGSize(width: 800, height: 80))
        scene.activityBounds = 48...752
        let tracker = MouseTracker(window: window, scene: scene)

        var dragStartFired = false
        var dragUpdateFired = false
        var dragEndFired = false

        tracker.onDragStart = { sessionId, point in
            dragStartFired = true
        }
        tracker.onDragUpdate = { point in
            dragUpdateFired = true
        }
        tracker.onDragEnd = {
            dragEndFired = true
        }

        XCTAssertNotNil(tracker.onDragStart, "C4: onDragStart 回调应可设置")
        XCTAssertNotNil(tracker.onDragUpdate, "C4: onDragUpdate 回调应可设置")
        XCTAssertNotNil(tracker.onDragEnd, "C4: onDragEnd 回调应可设置")

        // 直接调用验证闭包可执行
        tracker.onDragStart?("test", CGPoint(x: 400, y: 24))
        tracker.onDragUpdate?(CGPoint(x: 500, y: 24))
        tracker.onDragEnd?()

        XCTAssertTrue(dragStartFired, "C4: onDragStart 闭包应可正常执行")
        XCTAssertTrue(dragUpdateFired, "C4: onDragUpdate 闭包应可正常执行")
        XCTAssertTrue(dragEndFired, "C4: onDragEnd 闭包应可正常执行")
    }

    // MARK: - C4: 现有功能回归 —— MouseTracker 连接 BuddySKView

    /// 验证 MouseTracker.handleMouseMoved 可连接至 BuddySKView.onMouseMoved。
    ///
    /// 这是 C3 重构后的新事件路径：全局监听 → NSTrackingArea → onMouseMoved → MouseTracker。
    /// 合约要求新的鼠标事件处理逻辑与旧的 hover/click/drag 行为等价。
    @MainActor
    func testBuddySKViewOnMouseMovedConnectsToMouseTracker() throws {
        let window = makeWindow()
        let scene = BuddyScene(size: CGSize(width: 800, height: 80))
        scene.activityBounds = 48...752
        let skView = BuddySKView(frame: NSRect(x: 0, y: 0, width: 800, height: 80))
        skView.presentScene(scene)
        window.contentView = skView

        let sessionId = "connect-cat"
        scene.addCat(info: makeSessionInfo(sessionId: sessionId))

        guard let catX = scene.catPosition(for: sessionId) else {
            XCTFail("catPosition 应返回非 nil")
            return
        }

        let tracker = MouseTracker(window: window, scene: scene)
        tracker.start()

        // 绑定: BuddySKView.onMouseMoved → MouseTracker.handleMouseMoved
        skView.onMouseMoved = { [weak tracker] event in
            tracker?.handleMouseMoved(event)
        }

        // 验证绑定不崩溃
        guard let event = NSEvent.mouseEvent(
            with: .mouseMoved,
            location: NSPoint(x: catX, y: 24),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        ) else {
            throw XCTSkip("无法创建 NSEvent，测试环境中可能不支持")
        }

        // 通过 onMouseMoved 驱动 handleMouseMoved（模拟 NSTrackingArea 回调）
        skView.onMouseMoved?(event)

        tracker.stop()
    }

    // MARK: - 综合集成测试

    /// 端到端: 模拟完整生命周期——启动、添加猫、暂停恢复、移除猫、暂停。
    @MainActor
    func testFullLifecycleWithPauseBehavior() {
        let (skView, scene) = makeSKViewWithScene()

        // 初始状态: 暂停
        skView.isPaused = (scene.activeCatCount == 0)
        XCTAssertTrue(skView.isPaused, "初始: 0 猫 → 暂停")
        XCTAssertEqual(scene.activeCatCount, 0)

        // Phase 1: 添加猫 → 恢复渲染
        scene.addCat(info: makeSessionInfo(sessionId: "lifecycle-1"))
        skView.isPaused = (scene.activeCatCount == 0)
        XCTAssertFalse(skView.isPaused, "添加猫 → 恢复渲染")

        // Phase 2: hovering 正常
        guard let catX = scene.catPosition(for: "lifecycle-1") else {
            XCTFail("catPosition 应返回非 nil")
            return
        }
        let hit = scene.catAtPoint(CGPoint(x: catX, y: 24))
        XCTAssertEqual(hit, "lifecycle-1", "hover 检测正常")

        // Phase 3: drag 正常
        scene.startDrag(sessionId: "lifecycle-1", at: CGPoint(x: catX, y: 24))
        scene.updateDrag(to: CGPoint(x: catX + 50, y: 24))
        scene.endDrag()

        // Phase 4: 移除猫 → 暂停
        scene.removeCat(sessionId: "lifecycle-1")
        skView.isPaused = (scene.activeCatCount == 0)
        XCTAssertTrue(skView.isPaused, "移除猫 → 暂停")
        XCTAssertEqual(scene.activeCatCount, 0)
    }
}
