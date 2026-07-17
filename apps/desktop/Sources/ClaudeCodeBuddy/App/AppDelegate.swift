import AppKit
import SpriteKit
import Combine

public class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {

    /// 供外部模块访问的弱引用（SystemCatManager 用）。
    static weak var shared: AppDelegate?

    // MARK: - 初始化

    /// 在测试环境（xctest 命令行进程，无 NSApplicationMain）下，
    /// NSApplication.shared 未被初始化，NSApp 为 nil。
    /// 此处提前初始化，确保实例化 AppDelegate 后可安全访问 NSApp。
    /// 生产环境中 NSApplicationMain 已先于此调用，幂等无害。
    public override init() {
        _ = NSApplication.shared
        super.init()
        AppDelegate.shared = self
    }

    var window: BuddyWindow?
    var scene: BuddyScene?
    var sessionManager: SessionManager?
    var statusItem: NSStatusItem?
    var menuBarAnimator: MenuBarAnimator?
    var mouseTracker: MouseTracker?
    private let dockTracker = DockTracker()
    private var dockPollTimer: Timer?
    private var cachedActivityBounds: ClosedRange<CGFloat>?
    private var currentWindowHeight: CGFloat = 80
    private var isMouseInside = false
    private let terminalAdapters: [TerminalAdapter] = [GhosttyAdapter()]
    private let popover = NSPopover()
    /// R2：menubar 路径点设置时，等 popover 完全关闭（popoverDidClose）再 showSettings，
    /// 避免 popover 关闭动画干扰 app activation（日志铁证：popoverShown 时切 .regular 仍不 key）。
    private var pendingSettingsAfterPopoverClose = false
    /// R2：记录最近一个非自己的前台 app。menubar 路径点 status item 会让 app 自己变成 frontmost
    /// （但 isActive 仍 false），需用它做 cooperative activate 的 yield 来源（用户点 menubar 前真正在用的 app）。
    private var lastExternalFrontApp: NSRunningApplication?
    private lazy var popoverController = SessionPopoverController()
    private var cancellables = Set<AnyCancellable>()
    private var settingsWindowController: SettingsWindowController?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // 配置统一日志系统（契约 C2/C3）。
        // 级别解析优先级：BUDDY_LOG_LEVEL > #if DEBUG→debug / release→info > isRunningTests→off。
        // 配置幂等，测试宿主默认 off（resolveMinLevel 返回 nil）。
        BuddyLogger.shared.configure()

        UserDefaults.standard.register(defaults: ["alwaysShowLabel": true])

        BuddyLogger.shared.info("app 启动", subsystem: "app", meta: [
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        ])

        setupWindow()
        setupMenuBar()
        setupEditMenu()
        setupSessionManager()
        setupDockMonitoring()
        setupSkinHotSwap()
        setupLauncher()

        // task 006: HUD "查看" 按钮 → openBuddyStore() → post 通知 → 本订阅者打开 Settings
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleBuddyStoreShouldOpen),
            name: .buddyStoreShouldOpen,
            object: nil
        )

        // R2：持续追踪非自己的前台 app（didActivate 时更新），供 menubar 路径 cooperative yield 用。
        // menubar 点 status item 后 frontmost 会变成 app 自己，须用点击前记录的用户 app。
        if let front = NSWorkspace.shared.frontmostApplication,
           front != NSRunningApplication.current {
            lastExternalFrontApp = front
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(trackExternalFrontApp(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        // Initialize sound manager (subscribes to EventBus for audio playback)
        _ = SoundManager.shared

        setupUpdateChecker()

        // Initialize system cat manager (update notification cat)
        if let buddyScene = self.scene {
            SystemCatManager.shared.start(in: buddyScene)
        }

        // Initialize notification manager (subscribes to EventBus for push notifications)
        NotificationManager.shared.setup()
        NotificationManager.shared.onNotificationClicked = { [weak self] sessionId in
            guard let self = self,
                  let info = self.sessionManager?.sessionInfo(for: sessionId) else { return }
            self.scene?.acknowledgePermission(for: sessionId)
            self.scene?.removePersistentBadge(for: sessionId)
            for adapter in self.terminalAdapters where adapter.activateTab(for: info) { break }
        }

        // Ensure socket cleanup on any exit
        atexit {
            unlink(SocketServer.socketPath)
        }

        // Fast exit on SIGTERM (kill) — use _exit for async-signal-safety
        signal(SIGTERM) { _ in
            unlink(SocketServer.socketPath)
            _exit(0)
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        sessionManager?.stop()
        mouseTracker?.stop()
        dockPollTimer?.invalidate()
        dockPollTimer = nil
    }

    // MARK: - Window

    private func setupWindow() {
        let windowFrame = dockTracker.buddyWindowFrame(height: currentWindowHeight)

        let win = BuddyWindow(contentRect: windowFrame)
        window = win

        let skView = BuddySKView(frame: NSRect(origin: .zero, size: windowFrame.size))
        skView.allowsTransparency = true
        skView.preferredFramesPerSecond = 30
        skView.isPaused = true
        win.contentView = skView

        let buddyScene = BuddyScene(size: windowFrame.size)
        buddyScene.scaleMode = .resizeFill
        scene = buddyScene
        skView.presentScene(buddyScene)

        // Apply initial activity bounds
        let bounds = dockTracker.activityBounds(windowOriginX: windowFrame.origin.x)
        buddyScene.activityBounds = bounds
        buddyScene.foodManager.activityBounds = bounds
        cachedActivityBounds = bounds

        win.makeKeyAndOrderFront(nil)

        // Setup mouse tracker
        if let buddyWindow = window, let buddyScene = scene {
            let tracker = MouseTracker(window: buddyWindow, scene: buddyScene)
            tracker.start()
            tracker.onHover = { [weak self] sessionId in
                if let sessionId = sessionId {
                    self?.scene?.showTooltip(for: sessionId)
                    self?.scene?.setHovered(sessionId: sessionId, hovered: true)
                } else {
                    self?.scene?.hideTooltip()
                    self?.scene?.clearHover()
                }
            }
            tracker.onClick = { [weak self] sessionId in
                clickLog("AppDelegate.onClick received for session: \(sessionId)")
                guard let self = self else {
                    clickLog("AppDelegate.onClick BAIL — self is nil for: \(sessionId)")
                    return
                }
                // 系统猫点击由 simulateClick 内部转发到 SystemCatManager
                let handled = self.scene?.simulateClick(sessionId: sessionId) ?? false
                if !handled {
                    clickLog("simulateClick returned false for session: \(sessionId)")
                    return
                }
                // 非系统猫：simulateClick 内部已处理 ack + removePersistentBadge
                // 此处只需要处理终端激活
                if sessionId != SystemCatManager.systemCatSessionId,
                   let info = self.sessionManager?.sessionInfo(for: sessionId) {
                    clickLog("SessionInfo — label: \(info.label), terminalId: \(info.terminalId ?? "NIL"), cwd: \(info.cwd ?? "NIL")")
                    var activated = false
                    for adapter in self.terminalAdapters {
                        clickLog("Trying adapter: \(type(of: adapter))")
                        if adapter.activateTab(for: info) {
                            clickLog("Adapter \(type(of: adapter)) returned TRUE")
                            activated = true
                            break
                        }
                        clickLog("Adapter \(type(of: adapter)) returned FALSE")
                    }
                    if !activated {
                        clickLog("No adapter activated tab for session: \(sessionId)")
                    }
                }
            }
            tracker.onDragStart = { [weak self] sessionId, point in
                self?.scene?.startDrag(sessionId: sessionId, at: point)
            }
            tracker.onDragUpdate = { [weak self] point in
                self?.scene?.updateDrag(to: point)
            }
            tracker.onDragEnd = { [weak self] in
                self?.scene?.endDrag()
            }
            mouseTracker = tracker

            // 将 BuddySKView 的 NSTrackingArea 回调连接到 MouseTracker
            skView.onMouseMoved = { [weak tracker] event in
                tracker?.handleMouseMoved(event)
            }
            skView.onMouseEntered = { [weak tracker] in
                tracker?.onMouseEntered?()
            }
            skView.onMouseExited = { [weak tracker] in
                tracker?.onMouseExited?()
            }

            // P0 CPU 优化：鼠标进入/离开窗口时控制 SKView 暂停状态
            tracker.onMouseEntered = { [weak self, weak skView] in
                self?.isMouseInside = true
                skView?.isPaused = false
            }
            tracker.onMouseExited = { [weak self, weak skView] in
                self?.isMouseInside = false
                let hasCats = (self?.scene?.activeCatCount ?? 0) > 0
                skView?.isPaused = !hasCats
            }
        }

        // Re-position when Dock or display changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func screenParametersChanged() {
        guard let win = window else { return }
        let newFrame = dockTracker.buddyWindowFrame(height: currentWindowHeight)
        win.setFrame(newFrame, display: true)
        scene?.size = newFrame.size
        refreshActivityBounds(windowOriginX: newFrame.origin.x)
    }

    private func updateWindowHeight(_ height: CGFloat) {
        guard height != currentWindowHeight else { return }
        currentWindowHeight = height
        guard let win = window else { return }
        let newFrame = dockTracker.buddyWindowFrame(height: height)
        win.setFrame(newFrame, display: true)
        scene?.size = newFrame.size
        refreshActivityBounds(windowOriginX: newFrame.origin.x)
    }

    private func handleDragWindowExpand(_ expand: Bool) {
        guard let win = window, let screen = NSScreen.main else { return }
        if expand {
            let screenFrame = screen.frame
            let dockHeight = max(screen.visibleFrame.origin.y - screenFrame.origin.y, 0)
            let expandedHeight = screenFrame.height - dockHeight
            let newFrame = NSRect(
                x: screenFrame.origin.x,
                y: screenFrame.origin.y + dockHeight,
                width: screenFrame.width,
                height: expandedHeight
            )
            win.setFrame(newFrame, display: true)
            scene?.size = newFrame.size
        } else {
            updateWindowHeight(currentWindowHeight)
        }
    }

    // MARK: - Menu Bar

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.action = #selector(togglePopover)
            button.target = self
            menuBarAnimator = MenuBarAnimator(button: button)
        }

        popover.contentViewController = popoverController
        popover.behavior = .transient
        popover.animates = false  // R2：去掉消失动画，popoverDidClose 更快触发（用户确认动画不重要）
        popover.delegate = self  // R2：监听 popoverDidClose，menubar 路径等 popover 关闭后再开设置
        // Force loadView + set initial content size
        _ = popoverController.view
        popover.contentSize = popoverController.preferredContentSize

        popoverController.onQuit = {
            NSApplication.shared.terminate(nil)
        }

        popoverController.onSettings = { [weak self] in
            // R2 menubar 根因：popover.performClose 是异步动画关闭，紧接 showSettings 时 popover
            // 仍 shown，其关闭动画干扰 app activation 致窗口不 key。故只标记，等 popoverDidClose
            // （动画完成）回调里再 showSettings，此时 popover 已彻底关闭、不再干扰 activation。
            self?.pendingSettingsAfterPopoverClose = true
            self?.popover.performClose(nil)
        }

        popoverController.onSessionClicked = { [weak self] session in
            self?.popover.performClose(nil)
            guard let adapters = self?.terminalAdapters else { return }
            for adapter in adapters where adapter.activateTab(for: session) { break }
        }
    }

    // MARK: - NSPopoverDelegate

    public func popoverDidClose(_ notification: Notification) {
        // R2：menubar 路径点设置时，popover 完全关闭（动画结束）后才开设置窗口，
        // 避免 popover 关闭动画干扰 activation（pendingSettingsAfterPopoverClose 仅在点设置时置位）。
        guard pendingSettingsAfterPopoverClose else { return }
        pendingSettingsAfterPopoverClose = false
        showSettings(source: "menubar")
    }

    // MARK: - Edit Menu

    func setupEditMenu() {
        NSApp.mainMenu = makeEditMenu()
    }

    @objc func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.contentSize = popoverController.preferredContentSize
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func updateSessionCount(_ count: Int) {
        // No-op: session count is now shown in the popover via updateSessions
    }

    // MARK: - Session Manager

    private func setupSessionManager() {
        guard let scene = scene else { return }
        let manager = SessionManager(scene: scene)
        manager.onSessionCountChanged = { [weak self] count in
            self?.updateSessionCount(count)
            // P0 CPU 优化：无猫且鼠标不在窗口内时暂停 SKView 渲染
            if let skView = self?.window?.contentView as? SKView {
                let isMouseInside = self?.isMouseInside ?? false
                skView.isPaused = (count == 0 && !isMouseInside)
            }
        }
        manager.onSessionsChanged = { [weak self] sessions in
            self?.scene?.updateSessionsCache(sessions)
            let activeSessions = sessions.filter { $0.state != .idle && $0.state != .eating }
            self?.menuBarAnimator?.updateActiveCatCount(activeSessions.count)
            DispatchQueue.main.async {
                self?.popoverController.updateSessions(sessions)
                self?.popover.contentSize = self?.popoverController.preferredContentSize ?? NSSize(width: 320, height: 130)
            }
        }
        manager.onSessionNeedsTabTitle = { [weak self] session in
            guard let adapters = self?.terminalAdapters else { return }
            DispatchQueue.global(qos: .utility).async {
                for adapter in adapters where adapter.setTabTitle(for: session) { break }
            }
        }
        sessionManager = manager
        manager.start()

        // Window height callback for token level changes
        scene.onWindowHeightNeeded = { [weak self] height in
            self?.updateWindowHeight(height)
        }
        scene.onDragWindowExpand = { [weak self] expand in
            self?.handleDragWindowExpand(expand)
        }
    }

    private func setupSkinHotSwap() {
        SkinPackManager.shared.skinChanged
            .receive(on: RunLoop.main)
            .sink { [weak self] skin in
                self?.scene?.reloadSkin(skin)
                self?.menuBarAnimator?.reloadSprites()
            }
            .store(in: &cancellables)
    }

    // MARK: - Settings

    /// source 标识打开来源（menubar/notify/about/launcher），用于排查日志。
    /// internal（非 private）：launcher ⌘, 快捷键跨文件调用。
    /// @MainActor：建 NSWindow 必须主线程；可被 socket 后台 Task 经
    /// handleBuddyStoreShouldOpen 间接调用（B3 加固），编译期保证不 SIGABRT。
    @MainActor
    func showSettings(source: String = "unknown") {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }

        // LSUIElement key window 治本（详见 .autopilot/knowledge 沉淀）：
        // ① 切 .regular——.accessory 窗口无成为 key 的资格（steipete 发现，无 Dock 图标 app 窗口无法 key）
        // ② cooperative activate（见 activateApp，从用户点 menubar 前在用的 app yield）
        // ③ makeKey；policy 切换异步，delay 后二次激活兜底（首次 policy 转换可能慢）
        NSApp.setActivationPolicy(.regular)
        activateApp()
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.center()
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, let w = self.settingsWindowController?.window else { return }
            activateApp()
            w.makeKeyAndOrderFront(nil)
            w.orderFrontRegardless()
            BuddyLogger.shared.info("设置窗口二次激活", subsystem: "settings",
                                    meta: ["source": source, "isKeyWindow": "\(w.isKeyWindow)"])
        }
    }

    /// R2 治本：设置窗口关闭后切回 .accessory（恢复无 Dock 图标的 menubar app 形态）。
    /// 与 showSettings 的 setActivationPolicy(.regular) 配对；由 SettingsWindowController 监听 willClose 触发。
    func restoreActivationPolicy() {
        guard NSApp.activationPolicy() == .regular else { return }
        NSApp.setActivationPolicy(.accessory)
        BuddyLogger.shared.info("恢复 .accessory policy", subsystem: "settings")
    }

    /// R2 治本：cooperative activation（macOS 14+）。NSApp.activate() 只是请求、不保证成功
    /// （日志证实 menubar 路径 frontmost 为外部 app 时也常失败）；activate(from:) 要求当前前台 app
    /// yield，是官方保证成功的激活路径（Ice 同款）。frontmost 为外部 regular app（终端/编辑器）时从其
    /// yield；为自己/无前台时降级 NSApp.activate()（此时无 yield 来源，可靠性下降）。
    private func activateApp() {
        if #available(macOS 14.0, *) {
            // menubar 路径点 status item 后 frontmost 会变成 app 自己（isActive 仍 false），
            // 故优先用记录到的 lastExternalFrontApp（用户点 menubar 前真正在用的 app）做 cooperative yield。
            let tracked = (lastExternalFrontApp?.isTerminated == false) ? lastExternalFrontApp : nil
            let frontApp = tracked ?? NSWorkspace.shared.frontmostApplication
            if let frontApp, frontApp != NSRunningApplication.current {
                NSRunningApplication.current.activate(from: frontApp)
                BuddyLogger.shared.info("cooperative activate(from:)", subsystem: "settings",
                                        meta: ["frontApp": frontApp.bundleIdentifier ?? "?",
                                               "yieldSource": tracked != nil ? "tracked" : "frontmost"])
            } else {
                NSApp.activate()
                BuddyLogger.shared.info("降级 NSApp.activate()（无外部 yield 来源）", subsystem: "settings")
            }
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// 打开设置窗口并切换到「关于」分类（系统猫点击触发）。
    /// @MainActor：内部调 showSettings（@MainActor），整链主线程。
    @MainActor
    func openSettingsToAbout() {
        showSettings(source: "about")
        settingsWindowController?.splitViewController.selectSection(.about)
    }

    // MARK: - Settings Debug（CLI 驱动，绕过 LSUIElement osascript click 不路由 patterns/2026-06-23）
    //
    // `buddy launcher debug open-settings / select-section / select-plugin / get-state` 经 socket
    // 调这些方法。LSUIElement accessory app 下 osascript click/AXPress/keystroke 对非 key 窗口不路由，
    // CLI 直驱 in-process API 是唯一可靠的自动化打开/切换路径。

    /// CLI debug: 打开设置窗口，可选预选分类（general/about/hotkey/ai/skins/plugins）。
    /// @MainActor：内部调 showSettings（@MainActor），整链主线程。
    @MainActor
    func debugShowSettings(sectionRaw: String?) {
        showSettings(source: "cli-debug")
        if let raw = sectionRaw, let section = SettingsSection(rawValue: raw) {
            settingsWindowController?.splitViewController.selectSection(section)
        }
    }

    /// CLI debug: 选中主分类。非法分类 → false；窗口未开则先开。
    /// @MainActor：内部可能调 showSettings（@MainActor），整链主线程。
    @discardableResult
    @MainActor
    func debugSelectSection(_ raw: String) -> Bool {
        guard let section = SettingsSection(rawValue: raw) else { return false }
        if settingsWindowController == nil {
            showSettings(source: "cli-debug")
        }
        settingsWindowController?.splitViewController.selectSection(section)
        return true
    }

    /// CLI debug: 在「插件」分类内选中具名插件（如 snip）。强制刷新 gallery 数据后选中。
    /// - Returns: 是否命中（gallery 未加载 / 名字不在列表 → false）。
    @MainActor
    func debugSelectPlugin(_ name: String) async -> Bool {
        if settingsWindowController == nil {
            showSettings(source: "cli-debug")
        }
        let splitVC = settingsWindowController?.splitViewController
        splitVC?.selectSection(.plugins)
        guard let gallery = splitVC?.detailChildViewController as? PluginGalleryViewController else {
            return false
        }
        // gallery 初始 .loading，viewDidAppear 异步 refresh；显式 await 确保数据就绪再选中。
        await gallery.refresh()
        let ok = gallery.selectPlugin(named: name)
        // autopilot 2026-07-13：窗口已开时上面分支不调 showSettings → 不激活，CLI select-plugin 后
        // 设置窗易失焦被终端/其他 app 遮挡（screencapture 拍到背后 app）。强制激活保证前台可见。
        let win = settingsWindowController?.window
        win?.makeKeyAndOrderFront(nil)
        win?.orderFrontRegardless()
        return ok
    }

    /// CLI debug: 展开 snip 面板编辑态（autopilot 2026-07-13：验证 content 编辑器布局）。
    /// mode="create" → 新建表单；"edit" → 展开第一个片段。窗口前台 + layout 后返回 frame 诊断。
    @MainActor
    func debugSnipExpand(mode: String, row: Int = 0) -> [String: Any] {
        let splitVC = settingsWindowController?.splitViewController
        guard let gallery = splitVC?.detailChildViewController as? PluginGalleryViewController,
              let snipPanel = gallery.currentPanelChild as? SnipPanelVC else {
            return ["ok": false]
        }
        snipPanel.view.layoutSubtreeIfNeeded()
        if mode == "edit" {
            snipPanel.testHook_selectRow(row)
        } else {
            snipPanel.testHook_startCreate()
        }
        snipPanel.view.layoutSubtreeIfNeeded()
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
        settingsWindowController?.window?.orderFrontRegardless()
        // det-machine：dump content editor scrollView frame + cell bounds，
        // 客观验证 content editor 占满 cell 宽度（非窄 control 区"跑到 keyword 那边"）。
        let svFrame = snipPanel.debug_contentScrollViewFrame
        let cellBounds = snipPanel.debug_expandedCellBounds
        return [
            "ok": true,
            "mode": mode,
            "content_scrollview_x": svFrame?.minX ?? -1,
            "content_scrollview_width": svFrame?.width ?? -1,
            "expanded_cell_width": cellBounds?.width ?? -1,
        ]
    }

    /// CLI debug: dump 设置窗口几何 + 选中态（供 verifier 帧谓词求值）。
    /// 返回 window_open=false 表示窗口未开。
    @MainActor
    func debugSettingsState() -> [String: Any] {
        guard let wc = settingsWindowController, let window = wc.window else {
            return ["window_open": false]
        }
        // 强制 layout 跑完再读 bounds（socket 读可能在 layout 周期之间，bounds 未更新）
        window.contentView?.layoutSubtreeIfNeeded()
        let frame = window.frame
        var state: [String: Any] = [
            "window_open": true,
            "window": [
                "x": frame.minX,
                "y": frame.minY,
                "width": frame.width,
                "height": frame.height,
                "isKeyWindow": window.isKeyWindow,
                "title": window.title,
            ] as [String: Any],
        ]
        let splitVC = wc.splitViewController
        state["selectedSection"] = splitVC?.selectedSection.rawValue ?? ""
        // sidebar 宽（NSSplitViewController splitViewItems[0]）：契约 sidebarWidth 200
        let sidebarWidth = splitVC?.splitViewItems.first?.viewController.view.bounds.width ?? -1
        state["sidebarWidth"] = sidebarWidth
        if let child = splitVC?.detailChildViewController {
            state["detailVC"] = String(describing: type(of: child))
            state["detailAX"] = child.view.accessibilityIdentifier() ?? ""
            // 通用：detail content 高（C-CONTENTCOLUMN-NO-REGRESS 防白屏回归，场景 4.P1）
            state["detail_content_height"] = child.view.bounds.height
        }
        // 插件分类额外几何：pluginListWidth 240 / contentColumnWidth ≤780
        if let gallery = splitVC?.detailChildViewController as? PluginGalleryViewController {
            gallery.view.layoutSubtreeIfNeeded()
            state["pluginListWidth"] = gallery.pluginListColumnWidth
            state["contentColumnWidth"] = gallery.contentColumnWidth
            state["selectedPlugin"] = gallery.currentSelectedPluginName ?? ""
            // snip 展开字段（场景 1.P3）：向下探测 gallery.currentPanelChild as? SnipPanelVC
            // （currentPanelChild 是 NSViewController?，两跳向下转换）
            if let snipPanel = gallery.currentPanelChild as? SnipPanelVC {
                let expandedVisible = snipPanel.expandedRowIndex != nil
                state["snip_expanded_visible"] = expandedVisible
                state["snip_expanded_height"] = snipPanel.expandedRowHeight
                state["snip_expanded_row"] = snipPanel.expandedRowIndex
                state["snip_panel_width"] = snipPanel.view.bounds.width
                state["snip_panel_height"] = snipPanel.view.bounds.height
                state["snip_widths"] = snipPanel.debug_widths
            }
        }
        return state
    }

    @MainActor @objc private func handleBuddyStoreShouldOpen() {
        // 经 socket / buddy CLI open_settings 通知进来。
        showSettings(source: "notify")
    }

    /// 记录非自己的前台 app 激活（menubar 路径 cooperative yield 的来源：点 status item 后
    /// frontmost 变 app 自己，须用点击前记录的用户 app 做 activate(from:)）。
    @objc private func trackExternalFrontApp(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app != NSRunningApplication.current else { return }
        lastExternalFrontApp = app
    }

    // MARK: - Dock Monitoring

    private func setupDockMonitoring() {
        // Poll AX bounds every 3 seconds (catches icon size changes, Dock show/hide)
        dockPollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self = self, let win = self.window else { return }
            self.refreshActivityBounds(windowOriginX: win.frame.origin.x)
        }

        // App launch/terminate may change Dock icon count
        let ws = NSWorkspace.shared
        ws.notificationCenter.addObserver(self, selector: #selector(dockMayHaveChanged),
                                          name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        ws.notificationCenter.addObserver(self, selector: #selector(dockMayHaveChanged),
                                          name: NSWorkspace.didTerminateApplicationNotification, object: nil)
    }

    @objc private func dockMayHaveChanged() {
        // Dock animates icon changes — delay before querying
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self = self, let win = self.window else { return }
            self.refreshActivityBounds(windowOriginX: win.frame.origin.x)
        }
    }

    private func refreshActivityBounds(windowOriginX: CGFloat) {
        let newBounds = dockTracker.activityBounds(windowOriginX: windowOriginX)

        // Only propagate if changed
        if let cached = cachedActivityBounds,
           cached.lowerBound == newBounds.lowerBound,
           cached.upperBound == newBounds.upperBound {
            return
        }

        cachedActivityBounds = newBounds
        scene?.activityBounds = newBounds
        scene?.foodManager.activityBounds = newBounds
    }

    // MARK: - Update Checker

    private func setupUpdateChecker() {
        EventBus.shared.upgradeCompleted
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                self?.restartApp()
            }
            .store(in: &cancellables)

        UpdateChecker.shared.scheduleInitialCheck()
    }

    private func restartApp() {
        let bundlePath = Bundle.main.bundleURL.path
        // detached /bin/sh 子进程：父 terminate→exit 后由 launchd 收养继续执行。
        // trap '' HUP 兜底 controlling-terminal 场景；pgrep 轮询等旧实例真正退出；
        // open -n 强制 LaunchServices 新建实例（-n 等价 createsNewApplicationInstance=true，
        // 杜绝 bundle id 残存登记时复用旧实例 → launch 0 items）。
        // 根因：旧实现用 NSWorkspace.openApplication（createsNewApplicationInstance 默认 false）
        // 启动"还在运行的自己"→ LaunchServices launch 0 items → terminate 杀唯一实例 → app 消失。
        let script = RestartHelper.buildScript(bundlePath: bundlePath)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script]
        do {
            try task.run()
        } catch {
            BuddyLogger.shared.error("restart spawn helper failed", subsystem: "app", meta: ["error": "\(error)"])
        }
        BuddyLogger.shared.info("restart: spawned detached helper", subsystem: "app", meta: ["bundle": bundlePath])
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Launcher

    private func setupLauncher() {
        // applicationDidFinishLaunching 保证在主线程调用；LauncherManager 是 @MainActor 类型
        MainActor.assumeIsolated {
            LauncherManager.shared.setup()
        }
    }
}
