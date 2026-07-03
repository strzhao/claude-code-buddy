import AppKit
import Foundation

/// 全屏透明 overlay 截屏选区控制器（C-OVERLAY-* 契约）。
///
/// 设计（对标微信截屏选区阶段）：
/// - **C-MULTI-DISPLAY**：为每个 `NSScreen` 创建一个全屏透明 `NSPanel`，盖所有显示器；
///   主屏的 panel 接管鼠标拖框；副屏 panel 仅遮罩（背景半透黑），不抢鼠标。
/// - **C-RETINA-COORDS**：选区几何全程 points（逻辑坐标），捕获时由 `ScreenCapturing`
///   实现按目标屏 `backingScaleFactor` 转 physical pixels。
/// - **C-MIN-SELECTION**：选区 < 8×8 pt 时 `Enter` 不确认（视为误触），提示重选。
/// - **C-OVERLAY-DEFOCUS-ABORT**：overlay 失焦（点其他窗口 / 切 Space）→ 自动中止，
///   不捕获、不写剪贴板。
/// - **C-ESC-CANCEL**：`ESC` → 取消（不捕获、不写剪贴板）。
/// - **C-ENTER-CONFIRM**：`Enter` → 确认，回调 `onConfirm(globalRect)`。
/// - **C-OVERLAY-TEST-HOOK**：暴露 `_simulateDrag/_simulateConfirm/_simulateCancel`
///   test-only hook，供 XCTest 确定性驱动选区逻辑（禁 osascript / XCUITest 鼠标）。
///
/// @MainActor：overlay 全程主线程编排（NSPanel / NSEvent / 鼠标），规避跨 actor Sendable 风险。
@MainActor
final class ScreenshotOverlayController {

    /// 最小有效选区边长（pt）。小于此尺寸视为误触，不确认（C-MIN-SELECTION）。
    static let minSelectionSize: CGFloat = 8.0

    // MARK: - 回调注入（生产/测试可换）

    /// 确认选区时回调（参数 = 全局坐标系 points 矩形）。生产路径触发捕获+复制；测试断言调用。
    /// **async**（红队 hook 契约 CONTRACT_AMBIGUOUS #1）：生产 `confirm()`（键盘事件，同步）用
    /// `Task { @MainActor in await callback?(rect) }` 触发（cooperative，不死锁）；
    /// 测试 `_simulateConfirm()`（async）`await callback?(rect)` 内联执行（确定性：返回时回调已完成）。
    var onConfirm: ((CGRect) async -> Void)?
    /// 取消（ESC / 失焦）时回调。生产路径仅清理；测试断言调用。
    var onCancel: (() -> Void)?

    // MARK: - 状态

    /// 当前选区（全局坐标系 points），nil = 尚未拖框。
    private(set) var currentSelection: CGRect?
    /// overlay 是否已 present（防重入）。
    private(set) var isPresented: Bool = false

    /// 创建的所有 overlay panels（每个显示器一个）。
    private var overlayPanels: [NSPanel] = []
    /// 接管鼠标拖框的主屏 overlay view。
    private var primaryOverlayView: ScreenshotOverlayView?
    /// 全局本地事件监视器（overlay 期间捕获 ESC/Enter）。
    private var localKeyMonitor: Any?
    /// 失焦监视器（C-OVERLAY-DEFOCUS-ABORT）：overlay 期间 app 失活 → 中止。
    private var deactivationObserver: NSObjectProtocol?

    // MARK: - Present / Dismiss

    /// 盖住所有显示器，进入选区模式。
    func present() {
        guard !isPresented else { return }
        isPresented = true

        // 测试环境：跳过真实 NSPanel 创建（避免 GUI 副作用 + 无 TCC 时仍可断言 isPresented）。
        // 真实 overlay 视觉呈现由真机 XCUITest 终验（设计 Tier 1.5 真机层）。
        if RuntimeEnvironment.isRunningTests {
            BuddyLogger.shared.info(
                "screenshot overlay present (test mode, skip GUI panels)",
                subsystem: "builtin"
            )
            return
        }

        let screens = NSScreen.screens
        guard let mainScreen = screens.first else {
            // 无显示器（极端情况）：直接 cancel
            cancel()
            return
        }

        BuddyLogger.shared.info(
            "screenshot overlay present",
            subsystem: "builtin",
            meta: ["displays": screens.count]
        )

        // 为每个屏创建全屏透明 panel
        for screen in screens {
            let isMain = (screen == mainScreen)
            let panel = ScreenshotOverlayPanel(
                contentRect: screen.frame,
                screen: screen,
                isPrimary: isMain
            )

            let overlayView = ScreenshotOverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
            overlayView.isPrimary = isMain
            // 主屏 overlay 接管拖框 + 绘制选区框；副屏只画半透遮罩
            overlayView.onSelectionChange = { [weak self] rect in
                Task { @MainActor in self?.handleSelectionChange(rect) }
            }
            panel.contentView = overlayView
            if isMain {
                primaryOverlayView = overlayView
            }

            panel.orderFrontRegardless()
            overlayPanels.append(panel)
        }

        // 让主屏 panel 成为 key window（接收键盘）
        if let primary = overlayPanels.first {
            primary.makeKeyAndOrderFront(nil)
        }

        installKeyMonitor()
        installDeactivationObserver()
    }

    /// 关闭 overlay，清理所有资源（取消/确认后统一调用）。
    func dismiss() {
        guard isPresented else { return }
        isPresented = false

        for panel in overlayPanels {
            panel.orderOut(nil)
        }
        overlayPanels.removeAll()

        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyMonitor = nil
        }
        if let observer = deactivationObserver {
            NotificationCenter.default.removeObserver(observer)
            deactivationObserver = nil
        }
        primaryOverlayView = nil
        currentSelection = nil
    }

    // MARK: - 选区变更

    private func handleSelectionChange(_ rect: CGRect?) {
        currentSelection = rect
        // 副屏 overlay 不画选区框（选区在主屏坐标系，副屏画会错位）；仅主屏 overlay 绘制。
    }

    // MARK: - 确认 / 取消

    /// 确认选区（C-ENTER-CONFIRM + C-MIN-SELECTION）。
    /// - Returns: 确认的选区（全局 points）；nil = 无选区 / 选区过小 / 未 present。
    @discardableResult
    func confirm() -> CGRect? {
        guard isPresented else { return nil }

        guard let selection = currentSelection else {
            BuddyLogger.shared.info(
                "screenshot confirm 跳过：无选区",
                subsystem: "builtin"
            )
            return nil
        }

        // C-MIN-SELECTION：选区过小视为误触
        guard selection.width >= Self.minSelectionSize,
              selection.height >= Self.minSelectionSize else {
            BuddyLogger.shared.info(
                "screenshot confirm 跳过：选区过小（< \(Self.minSelectionSize)pt）",
                subsystem: "builtin",
                meta: ["w": selection.width, "h": selection.height]
            )
            // 提示重选：让主屏 overlay 闪一下边框（视觉反馈），不关闭 overlay
            primaryOverlayView?.flashMinSelectionWarning()
            return nil
        }

        // 把选区从主屏 panel 坐标转回全局屏幕坐标（panel.frame.origin == screen.frame.origin）
        let globalRect = primaryOverlayView.map { overlayView in
            var r = selection
            // overlay view 坐标系是 panel content（origin 在 panel 左下）；
            // panel.frame.origin == screen.frame.origin（全局）。叠加得到全局坐标。
            if let panel = overlayView.window {
                r.origin.x += panel.frame.origin.x
                r.origin.y += panel.frame.origin.y
            }
            return r
        } ?? selection

        BuddyLogger.shared.info(
            "screenshot confirm",
            subsystem: "builtin",
            meta: ["rect": "\(globalRect)"]
        )

        // 先记录回调引用，再 dismiss（dismiss 会清状态），再异步触发回调。
        // onConfirm 是 async（生产路径触发捕获+复制）；confirm() 同步（键盘事件），
        // 用 Task 在主 actor 上 await 执行——不阻塞、不死锁（main actor 在 await 期间释放，
        // 不再踩旧 performCaptureSync 的 semaphore.wait 阻塞 main actor hop 死锁坑）。
        let callback = onConfirm
        dismiss()
        Task { @MainActor in
            await callback?(globalRect)
        }
        return globalRect
    }

    /// 取消（C-ESC-CANCEL）。
    func cancel() {
        guard isPresented else { return }
        BuddyLogger.shared.info(
            "screenshot cancel（不捕获、不写剪贴板）",
            subsystem: "builtin"
        )
        let callback = onCancel
        dismiss()
        callback?()
    }

    // MARK: - 键盘监听（ESC / Enter）

    private func installKeyMonitor() {
        // 监听 keyDown：ESC = cancel，Enter = confirm
        let mask: NSEvent.EventTypeMask = [.keyDown]
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self = self else { return event }
            guard self.isPresented else { return event }

            switch event.keyCode {
            case 53:  // ESC
                self.cancel()
                return nil  // 吞掉事件
            case 36:  // Return / Enter
                _ = self.confirm()
                return nil
            default:
                return event
            }
        }
    }

    // MARK: - 失焦中止（C-OVERLAY-DEFOCUS-ABORT）

    private func installDeactivationObserver() {
        // NSApplication.willResignActiveNotification：app 失活（切到其他 app / 切 Space）
        // → 自动中止 overlay。LSUIElement app 此通知在 deactivate 时触发。
        deactivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // 失焦中止走主线程（observer queue 已指定 .main，但显式 Task 隔离更稳）
            Task { @MainActor in
                guard let self = self, self.isPresented else { return }
                BuddyLogger.shared.info(
                    "screenshot overlay 失焦中止",
                    subsystem: "builtin"
                )
                self.cancel()
            }
        }
    }

    // MARK: - C-OVERLAY-TEST-HOOK（test-only 程序化驱动）

    /// 程序化模拟拖框选区（test-only，禁 osascript / XCUITest 鼠标）。
    /// `from` / `to` 是主屏 overlay view 坐标系（左下原点）。
    ///
    /// **测试兼容**：不要求 present（headless 测试可直接驱动选区，present 在无显示器环境可能 no-op）。
    /// 见红队 `ScreenshotOverlayHookTests` CONTRACT_AMBIGUOUS #2：present 在测试环境可能 no-op，
    /// 不视为副作用。本 hook 直接设置 `currentSelection`（若已 present，同步刷 overlay view 视觉）。
    func _simulateDrag(from start: CGPoint, to end: CGPoint) {
        // 归一化（min origin / abs size），保证反向拖框也产出正向 rect
        let rect = CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
        currentSelection = rect
        // 若已 present，同步刷主屏 overlay view 视觉；未 present 时仅记 selection
        primaryOverlayView?._simulateSelection(rect)
    }

    /// 程序化模拟确认（test-only）。返回确认的全局 rect（成功）或抛 `LauncherError`（失败）。
    ///
    /// **async throws** 签名对齐红队契约：`XCTAssertNoThrow(await controller._simulateConfirm())`。
    /// - Throws: `LauncherError.systemCommandFailed` 当无选区 / 选区过小。
    @discardableResult
    func _simulateConfirm() async throws -> CGRect {
        // 走确认逻辑（present 与否都允许 hook 驱动；hook 路径直接用 currentSelection）
        guard let selection = currentSelection else {
            throw LauncherError.systemCommandFailed("screenshot 确认失败：无选区")
        }

        // C-MIN-SELECTION：选区过小视为误触
        guard selection.width >= Self.minSelectionSize,
              selection.height >= Self.minSelectionSize else {
            throw LauncherError.systemCommandFailed(
                "screenshot 确认失败：选区过小（< \(Self.minSelectionSize)pt）")
        }

        // hook 路径：未 present 时直接以 currentSelection 为全局 rect（测试坐标即屏幕坐标）；
        // 已 present 时叠加 panel origin 转全局（与生产 confirm() 一致）。
        let globalRect: CGRect
        if isPresented, let overlayView = primaryOverlayView, let panel = overlayView.window {
            globalRect = CGRect(
                origin: CGPoint(
                    x: selection.origin.x + panel.frame.origin.x,
                    y: selection.origin.y + panel.frame.origin.y
                ),
                size: selection.size
            )
        } else {
            globalRect = selection
        }

        BuddyLogger.shared.info(
            "screenshot _simulateConfirm",
            subsystem: "builtin",
            meta: ["rect": "\(globalRect)", "presented": isPresented]
        )

        // 先记录回调，再清状态，再 await 触发回调。
        // **inline await** → 测试确定性：_simulateConfirm 返回时 onConfirm（含捕获+复制）已完成，
        // 测试可立即断言 capture/copy seam 调用，无 Task race。
        let callback = onConfirm
        currentSelection = nil
        if isPresented { dismiss() }
        await callback?(globalRect)
        return globalRect
    }

    /// 程序化模拟取消（test-only）。
    func _simulateCancel() {
        BuddyLogger.shared.info(
            "screenshot _simulateCancel（不捕获、不写剪贴板）",
            subsystem: "builtin"
        )
        let callback = onCancel
        currentSelection = nil
        if isPresented { dismiss() }
        callback?()
    }
}

// MARK: - ScreenshotOverlayPanel（每个显示器一个全屏透明 NSPanel）

/// 全屏透明 panel：盖住整个显示器，接收鼠标事件绘制选区。
/// `.nonactivatingPanel` 避免抢 app 焦点（虽然我们要 key 接收键盘，但用 makeKey 而非 activate）。
private final class ScreenshotOverlayPanel: NSPanel {

    let isPrimary: Bool

    init(contentRect: NSRect, screen: NSScreen, isPrimary: Bool) {
        self.isPrimary = isPrimary
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        level = .screenSaver  // 盖住一切（含菜单栏 / Dock）
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        titleVisibility = .hidden
        hidesOnDeactivate = false  // 我们手动管理失焦中止（C-OVERLAY-DEFOCUS-ABORT）
        // 标准按钮隐藏
        for btn in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(btn)?.isHidden = true
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - ScreenshotOverlayView（鼠标拖框 + 选区绘制）

/// 主屏 overlay 的内容视图：背景半透黑遮罩 + 鼠标拖框绘制选区矩形 + 选区外暗化。
/// 副屏 overlay 只画背景遮罩（`isPrimary == false` 时不接管鼠标）。
private final class ScreenshotOverlayView: NSView {

    var isPrimary: Bool = false

    /// 选区变更回调（rect=nil = 清除选区）。主屏专用。
    var onSelectionChange: ((CGRect?) -> Void)?

    /// 当前选区（本视图坐标系，左下原点）。nil = 尚未拖框。
    private var selection: CGRect?
    /// 拖动起点（mouseDown 位置）。
    private var dragStart: NSPoint?
    /// 是否正在拖动。
    private var isDragging: Bool = false
    /// 最小选区警告闪烁状态（C-MIN-SELECTION 视觉反馈）。
    private var warningFlash: Bool = false

    override var isFlipped: Bool { false }  // 左下原点（与 NSWindow 全局坐标系一致）

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 鼠标（仅主屏接管）

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { isPrimary }

    override func mouseDown(with event: NSEvent) {
        guard isPrimary else { return }
        let location = convert(event.locationInWindow, from: nil)
        dragStart = location
        isDragging = true
        selection = nil
        warningFlash = false
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isPrimary, isDragging, let start = dragStart else { return }
        let current = convert(event.locationInWindow, from: nil)
        let rect = CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
        selection = rect
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isPrimary, isDragging else { return }
        isDragging = false
        // 通知 controller 选区变更（即使 mouseUp 也会保留最后选区，等 Enter 确认）
        onSelectionChange?(selection)
        needsDisplay = true
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds

        if let selection = selection, isPrimary {
            // 选区外：半透黑遮罩（强调选区）；选区内：透明（清晰可见）
            let path = NSBezierPath(rect: bounds)
            // 用 even-odd 规则挖空选区（外框 - 选区 → 镂空）。reversed 返回反转路径（属性）。
            let selectionPath = NSBezierPath(rect: selection).reversed
            path.append(selectionPath)
            path.windingRule = .evenOdd

            let maskColor = NSColor.black.withAlphaComponent(0.35)
            maskColor.setFill()
            path.fill()

            // 选区边框（白色细线 + 外阴影，对标微信）
            NSColor.white.setStroke()
            let borderPath = NSBezierPath(rect: selection)
            borderPath.lineWidth = 1.0
            borderPath.stroke()

            // 警告闪烁（C-MIN-SELECTION）：红色边框
            if warningFlash {
                NSColor.systemRed.withAlphaComponent(0.8).setStroke()
                let warnPath = NSBezierPath(rect: selection.insetBy(dx: -1, dy: -1))
                warnPath.lineWidth = 2.0
                warnPath.stroke()
            }
        } else {
            // 无选区（或副屏）：整块半透黑
            NSColor.black.withAlphaComponent(0.35).setFill()
            bounds.fill()
        }
    }

    // MARK: - 最小选区警告闪烁

    /// 触发一次红色边框闪烁（confirm 选区过小时调用，视觉反馈「选区太小」）。
    func flashMinSelectionWarning() {
        warningFlash = true
        needsDisplay = true
        // 测试环境下不启逐帧动画（避免 RunLoop 空转，见测试坑 2）
        if RuntimeEnvironment.isRunningTests {
            return
        }
        // 0.6s 后清除闪烁
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.warningFlash = false
            self?.needsDisplay = true
        }
    }

    // MARK: - C-OVERLAY-TEST-HOOK（程序化模拟选区）

    /// test-only：直接设置选区矩形（绕过鼠标事件）。
    func _simulateSelection(_ rect: CGRect) {
        selection = rect
        warningFlash = false
        needsDisplay = true
        onSelectionChange?(rect)
    }
}
