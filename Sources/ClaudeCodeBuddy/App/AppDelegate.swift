import AppKit
import SpriteKit

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: BuddyWindow?
    var scene: BuddyScene?
    var sessionManager: SessionManager?
    var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
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

    func applicationWillTerminate(_ notification: Notification) {
        sessionManager?.stop()
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
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Claude Code Buddy", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())

        let sessionItem = NSMenuItem(title: "Active Sessions: 0", action: nil, keyEquivalent: "")
        sessionItem.isEnabled = false
        sessionItem.tag = 100
        menu.addItem(sessionItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem?.menu = menu
    }

    func updateSessionCount(_ count: Int) {
        DispatchQueue.main.async { [weak self] in
            if let item = self?.statusItem?.menu?.item(withTag: 100) {
                item.title = "Active Sessions: \(count)"
            }
        }
    }

    // MARK: - Session Manager

    private func setupSessionManager() {
        guard let scene = scene else { return }
        let manager = SessionManager(scene: scene)
        manager.onSessionCountChanged = { [weak self] count in
            self?.updateSessionCount(count)
        }
        sessionManager = manager
        manager.start()
    }
}
