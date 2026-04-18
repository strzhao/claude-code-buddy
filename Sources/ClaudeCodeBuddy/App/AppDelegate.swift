import AppKit
import Combine
import SpriteKit
import Combine

public class AppDelegate: NSObject, NSApplicationDelegate {
    var window: BuddyWindow?
    var scene: BuddyScene?
    var sessionManager: SessionManager?
    var statusItem: NSStatusItem?
    var menuBarAnimator: MenuBarAnimator?
    var mouseTracker: MouseTracker?
    private let dockTracker = DockTracker()
    private var dockPollTimer: Timer?
    private var cachedActivityBounds: ClosedRange<CGFloat>?
    private let terminalAdapters: [TerminalAdapter] = [GhosttyAdapter()]
    private let popover = NSPopover()
    private lazy var popoverController = SessionPopoverController()
    private var cancellables = Set<AnyCancellable>()
    private var settingsWindowController: SettingsWindowController?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        _ = EntityModeStore.shared
        NSLog("[AppDelegate] EntityMode at launch: \(EntityModeStore.shared.current.rawValue)")

        setupWindow()
        setupMenuBar()
        setupSessionManager()
        setupDockMonitoring()
        setupSceneExpansion()
        setupStatusBarIconMode()
        setupSkinHotSwap()

        // Initialize sound manager (subscribes to EventBus for audio playback)
        _ = SoundManager.shared

        // Request Accessibility permission (non-blocking prompt)
        DispatchQueue.main.async {
            let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
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
        let windowFrame = dockTracker.buddyWindowFrame()

        let win = BuddyWindow(contentRect: windowFrame)
        window = win

        let skView = SKView(frame: NSRect(origin: .zero, size: windowFrame.size))
        skView.allowsTransparency = true
        win.contentView = skView

        let buddyScene = BuddyScene(size: windowFrame.size)
        buddyScene.scaleMode = .resizeFill
        scene = buddyScene
        skView.presentScene(buddyScene)

        // Apply initial activity bounds (clamped so boundary decorations stay visible).
        var bounds = dockTracker.activityBounds(windowOriginX: windowFrame.origin.x)
        let decorationMargin: CGFloat = 36
        let minX = max(bounds.lowerBound, decorationMargin)
        let maxX = min(bounds.upperBound, windowFrame.size.width - decorationMargin)
        if minX < maxX { bounds = minX...maxX }
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
                guard let self = self,
                      let info = self.sessionManager?.sessionInfo(for: sessionId) else { return }
                for adapter in self.terminalAdapters where adapter.activateTab(for: info) { break }
            }
            mouseTracker = tracker
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
        guard !dockTracker.isSuspended else { return }
        let newFrame = dockTracker.buddyWindowFrame()
        win.setFrame(newFrame, display: true)
        scene?.size = newFrame.size
        refreshActivityBounds(windowOriginX: newFrame.origin.x)
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
        // Force loadView + set initial content size
        _ = popoverController.view
        popover.contentSize = popoverController.preferredContentSize

        popoverController.onQuit = {
            NSApplication.shared.terminate(nil)
        }

        popoverController.onSettings = { [weak self] in
            self?.popover.performClose(nil)
            self?.showSettings()
        }

        popoverController.onSessionClicked = { [weak self] session in
            self?.popover.performClose(nil)
            guard let adapters = self?.terminalAdapters else { return }
            for adapter in adapters where adapter.activateTab(for: session) { break }
        }
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
        manager.bind(modeStore: EntityModeStore.shared)
        manager.start()
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

    private func showSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.center()
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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

    private func setupStatusBarIconMode() {
        updateStatusBarIcon(for: EntityModeStore.shared.current)
        EntityModeStore.shared.publisher
            .receive(on: RunLoop.main)
            .sink { [weak self] mode in
                self?.updateStatusBarIcon(for: mode)
            }
            .store(in: &cancellables)
    }

    private func updateStatusBarIcon(for mode: EntityMode) {
        menuBarAnimator?.mode = mode
        guard mode == .rocket else { return }
        // In cat mode the animator owns the image; in rocket mode we set a static symbol.
        statusItem?.button?.image = NSImage(
            systemSymbolName: "airplane",
            accessibilityDescription: mode.rawValue
        )
    }

    private func setupSceneExpansion() {
        EventBus.shared.sceneExpansionRequested
            .receive(on: RunLoop.main)
            .sink { [weak self] req in
                guard let self = self, let win = self.window else { return }
                self.dockTracker.suspendRepositioning()
                win.expandHeightTemporarily(by: req.height, duration: req.duration)
                DispatchQueue.main.asyncAfter(deadline: .now() + req.duration + 0.1) { [weak self] in
                    self?.dockTracker.resumeRepositioning()
                }
            }
            .store(in: &cancellables)
    }

    private func refreshActivityBounds(windowOriginX: CGFloat) {
        var newBounds = dockTracker.activityBounds(windowOriginX: windowOriginX)

        // Clamp to scene width minus a margin for boundary decorations (~36 per side).
        if let sceneWidth = scene?.size.width {
            let decorationMargin: CGFloat = 36
            let minX = max(newBounds.lowerBound, decorationMargin)
            let maxX = min(newBounds.upperBound, sceneWidth - decorationMargin)
            if minX < maxX { newBounds = minX...maxX }
        }

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
}
