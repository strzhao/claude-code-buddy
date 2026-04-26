import AppKit
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
    private var currentWindowHeight: CGFloat = 80
    private let terminalAdapters: [TerminalAdapter] = [GhosttyAdapter()]
    private let popover = NSPopover()
    private lazy var popoverController = SessionPopoverController()
    private var cancellables = Set<AnyCancellable>()
    private var settingsWindowController: SettingsWindowController?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        setupWindow()
        setupMenuBar()
        setupSessionManager()
        setupDockMonitoring()
        setupSkinHotSwap()

        // Initialize sound manager (subscribes to EventBus for audio playback)
        _ = SoundManager.shared

        setupUpdateChecker()

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

        let skView = SKView(frame: NSRect(origin: .zero, size: windowFrame.size))
        skView.allowsTransparency = true
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
                guard let self = self,
                      let info = self.sessionManager?.sessionInfo(for: sessionId) else {
                    clickLog("AppDelegate.onClick BAIL — self or sessionInfo is nil for: \(sessionId)")
                    return
                }
                clickLog("SessionInfo — label: \(info.label), terminalId: \(info.terminalId ?? "NIL"), cwd: \(info.cwd ?? "NIL")")
                self.scene?.acknowledgePermission(for: sessionId)
                self.scene?.removePersistentBadge(for: sessionId)
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

    private func showSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.center()
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
        // LSUIElement apps need explicit activation for windows to become key.
        // .accessory policy allows key windows without showing a Dock icon.
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
        let bundleURL = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true

        NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { _, error in
            if let error = error {
                NSLog("[AppDelegate] Restart failed: \(error)")
            }
        }
        NSApplication.shared.terminate(nil)
    }
}
