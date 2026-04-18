import AppKit
import SpriteKit

class MouseTracker {

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private weak var window: BuddyWindow?
    private weak var scene: BuddyScene?

    var onHover: ((String?) -> Void)?
    var onClick: ((String) -> Void)?

    private var hoveredSessionId: String?
    private var leaveTimer: Timer?
    private var isCursorPushed = false

    init(window: BuddyWindow, scene: BuddyScene) {
        self.window = window
        self.scene = scene
    }

    func start() {
        // Global monitor for mouse movement (works regardless of ignoresMouseEvents)
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            DispatchQueue.main.async {
                self?.handleMouseMoved(event)
            }
        }

        // Local monitor for clicks when window is interactive
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            self?.handleClick(event)
            return event
        }

        // Reset on app activation changes
        NotificationCenter.default.addObserver(self, selector: #selector(appDidResignActive),
                                               name: NSApplication.didResignActiveNotification, object: nil)
    }

    func stop() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        leaveTimer?.invalidate()
        leaveTimer = nil
        if isCursorPushed {
            NSCursor.pop()
            isCursorPushed = false
        }
        NotificationCenter.default.removeObserver(self)
    }

    deinit { stop() }

    // MARK: - Mouse Handling

    private func handleMouseMoved(_ event: NSEvent) {
        guard let window = window, let scene = scene else { return }

        let screenPoint = NSEvent.mouseLocation
        let windowPoint = window.convertPoint(fromScreen: screenPoint)

        guard let view = window.contentView as? SKView else { return }
        let viewPoint = view.convert(windowPoint, from: nil)
        let scenePoint = scene.convertPoint(fromView: viewPoint)

        let hitSessionId = scene.entityAtPoint(scenePoint)

        if let sessionId = hitSessionId {
            // Mouse is over a cat
            leaveTimer?.invalidate()
            leaveTimer = nil

            if hoveredSessionId != sessionId {
                hoveredSessionId = sessionId
                window.setInteractive(true)
                if !isCursorPushed {
                    NSCursor.pointingHand.push()
                    isCursorPushed = true
                }
                onHover?(sessionId)
            }
        } else {
            // Mouse left all cats
            if hoveredSessionId != nil {
                hoveredSessionId = nil
                if isCursorPushed {
                    NSCursor.pop()
                    isCursorPushed = false
                }
                onHover?(nil)

                // Delay before restoring click-through
                leaveTimer?.invalidate()
                leaveTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
                    self?.window?.setInteractive(false)
                }
            }
        }
    }

    private func handleClick(_ event: NSEvent) {
        guard let window = window, let scene = scene else { return }

        guard let view = window.contentView as? SKView else { return }
        let viewPoint = view.convert(event.locationInWindow, from: nil)
        let scenePoint = scene.convertPoint(fromView: viewPoint)

        if let sessionId = scene.entityAtPoint(scenePoint) {
            onClick?(sessionId)
        }
    }

    @objc private func appDidResignActive() {
        window?.setInteractive(false)
        hoveredSessionId = nil
        onHover?(nil)
        leaveTimer?.invalidate()
        leaveTimer = nil
        if isCursorPushed {
            NSCursor.pop()
            isCursorPushed = false
        }
    }
}
