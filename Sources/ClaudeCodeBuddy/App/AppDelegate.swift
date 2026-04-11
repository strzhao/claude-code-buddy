import AppKit
import SpriteKit

public class AppDelegate: NSObject, NSApplicationDelegate {
    var window: BuddyWindow?
    var scene: BuddyScene?
    var sessionManager: SessionManager?
    var statusItem: NSStatusItem?
    var mouseTracker: MouseTracker?
    private let terminalAdapters: [TerminalAdapter] = [GhosttyAdapter()]
    private let popover = NSPopover()
    private lazy var popoverController = SessionPopoverController()

    public func applicationDidFinishLaunching(_ notification: Notification) {
        setupWindow()
        setupMenuBar()
        setupSessionManager()

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
    }

    // MARK: - Window

    private func setupWindow() {
        let dockTracker = DockTracker()
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

        win.makeKeyAndOrderFront(nil)

        // Setup mouse tracker
        if let buddyWindow = window, let buddyScene = scene {
            let tracker = MouseTracker(window: buddyWindow, scene: buddyScene)
            tracker.start()
            tracker.onHover = { [weak self] sessionId in
                if let sessionId = sessionId {
                    self?.scene?.showTooltip(for: sessionId)
                } else {
                    self?.scene?.hideTooltip()
                }
            }
            tracker.onClick = { [weak self] sessionId in
                guard let self = self,
                      let info = self.sessionManager?.sessionInfo(for: sessionId) else { return }
                for adapter in self.terminalAdapters {
                    if adapter.activateTab(for: info) { break }
                }
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
        let dockTracker = DockTracker()
        let newFrame = dockTracker.buddyWindowFrame()
        win.setFrame(newFrame, display: true)
        scene?.size = newFrame.size
    }

    // MARK: - Menu Bar

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            if let catImage = NSImage(systemSymbolName: "cat.fill", accessibilityDescription: "Claude Code Buddy") {
                button.image = catImage
            } else {
                button.title = "🐱"
            }
            button.action = #selector(togglePopover)
            button.target = self
        }

        popover.contentViewController = popoverController
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 320, height: 450)

        popoverController.onQuit = {
            NSApplication.shared.terminate(nil)
        }

        popoverController.onSessionClicked = { [weak self] session in
            self?.popover.performClose(nil)
            guard let adapters = self?.terminalAdapters else { return }
            for adapter in adapters {
                if adapter.activateTab(for: session) { break }
            }
        }
    }

    @objc func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
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
            DispatchQueue.main.async {
                self?.popoverController.updateSessions(sessions)
            }
        }
        manager.onSessionNeedsTabTitle = { [weak self] session in
            guard let adapters = self?.terminalAdapters else { return }
            DispatchQueue.global(qos: .utility).async {
                for adapter in adapters {
                    if adapter.setTabTitle(for: session) { break }
                }
            }
        }
        sessionManager = manager
        manager.start()
    }
}
