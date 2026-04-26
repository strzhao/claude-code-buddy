import AppKit
import SpriteKit

func clickLog(_ msg: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = "[\(ts)] \(msg)\n"
    let path = "/tmp/claude-buddy-click.log"
    if let fh = FileHandle(forWritingAtPath: path) {
        fh.seekToEndOfFile()
        fh.write(line.data(using: .utf8)!)
        fh.closeFile()
    } else {
        FileManager.default.createFile(atPath: path, contents: line.data(using: .utf8))
    }
}

class MouseTracker {

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private weak var window: BuddyWindow?
    private weak var scene: BuddyScene?

    var onHover: ((String?) -> Void)?
    var onClick: ((String) -> Void)?
    var onDragStart: ((String, CGPoint) -> Void)?
    var onDragUpdate: ((CGPoint) -> Void)?
    var onDragEnd: (() -> Void)?

    private var hoveredSessionId: String?
    private var leaveTimer: Timer?
    private var isCursorPushed = false
    private var isDragCursorPushed = false

    // MARK: - Drag State

    private(set) var isDragging = false
    private var longPressTimer: Timer?
    private var dragCandidateSessionId: String?
    private var mouseDownPoint: CGPoint?

    init(window: BuddyWindow, scene: BuddyScene) {
        self.window = window
        self.scene = scene
    }

    func start() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            DispatchQueue.main.async {
                self?.handleMouseMoved(event)
            }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            self?.handleLocalEvent(event)
            return event
        }

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
        cancelLongPress()
        leaveTimer?.invalidate()
        leaveTimer = nil
        popAllCursors()
        NotificationCenter.default.removeObserver(self)
    }

    deinit { stop() }

    // MARK: - Mouse Handling

    private func handleMouseMoved(_ event: NSEvent) {
        guard !isDragging else { return }
        guard let window = window, let scene = scene else { return }

        // Skip hover detection while a cat is landing from drag
        if let draggedCat = scene.draggedCat, draggedCat.isDragOccupied {
            return
        }

        let screenPoint = NSEvent.mouseLocation
        let windowPoint = window.convertPoint(fromScreen: screenPoint)

        guard let view = window.contentView as? SKView else { return }
        let viewPoint = view.convert(windowPoint, from: nil)
        let scenePoint = scene.convertPoint(fromView: viewPoint)

        let hitSessionId = scene.catAtPoint(scenePoint)

        if let sessionId = hitSessionId {
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
            if hoveredSessionId != nil {
                hoveredSessionId = nil
                if isCursorPushed {
                    NSCursor.pop()
                    isCursorPushed = false
                }
                onHover?(nil)

                leaveTimer?.invalidate()
                leaveTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
                    self?.window?.setInteractive(false)
                }
            }
        }
    }

    // MARK: - Local Event Router

    private func handleLocalEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            handleMouseDown(event)
        case .leftMouseDragged:
            handleMouseDragged(event)
        case .leftMouseUp:
            handleMouseUp(event)
        default:
            break
        }
    }

    // MARK: - Mouse Down

    private func handleMouseDown(_ event: NSEvent) {
        guard let window = window, let scene = scene else { return }
        guard let view = window.contentView as? SKView else { return }

        let viewPoint = view.convert(event.locationInWindow, from: nil)
        let scenePoint = scene.convertPoint(fromView: viewPoint)

        if let sessionId = scene.catAtPoint(scenePoint) {
            dragCandidateSessionId = sessionId
            mouseDownPoint = scenePoint

            // Keep window interactive during potential drag
            leaveTimer?.invalidate()
            leaveTimer = nil

            longPressTimer = Timer.scheduledTimer(withTimeInterval: CatConstants.Drag.longPressThreshold, repeats: false) { [weak self] _ in
                self?.activateDrag()
            }
        }
    }

    // MARK: - Mouse Dragged

    private func handleMouseDragged(_ event: NSEvent) {
        guard isDragging else { return }
        guard let window = window, let scene = scene else { return }
        guard let view = window.contentView as? SKView else { return }

        let viewPoint = view.convert(event.locationInWindow, from: nil)
        let scenePoint = scene.convertPoint(fromView: viewPoint)
        onDragUpdate?(scenePoint)
    }

    // MARK: - Mouse Up

    private func handleMouseUp(_ event: NSEvent) {
        if isDragging {
            isDragging = false
            if isDragCursorPushed {
                NSCursor.pop()
                isDragCursorPushed = false
            }
            onDragEnd?()

            // Restore click-through — landing is SKAction-driven, no mouse events needed
            hoveredSessionId = nil
            onHover?(nil)
            window?.setInteractive(false)
        } else {
            cancelLongPress()
            // Fire regular click if mouse was pressed on a cat
            if let sessionId = dragCandidateSessionId {
                clickLog("MouseTracker.onClick fired for session: \(sessionId)")
                onClick?(sessionId)
            } else {
                clickLog("MouseTracker.mouseUp but no dragCandidateSessionId")
            }
        }
        dragCandidateSessionId = nil
        mouseDownPoint = nil
    }

    // MARK: - Long Press

    private func activateDrag() {
        guard let sessionId = dragCandidateSessionId, let point = mouseDownPoint else { return }
        longPressTimer = nil
        isDragging = true

        // Switch to closed-hand cursor
        if isCursorPushed {
            NSCursor.pop()
            isCursorPushed = false
        }
        NSCursor.closedHand.push()
        isDragCursorPushed = true

        onDragStart?(sessionId, point)
    }

    private func cancelLongPress() {
        longPressTimer?.invalidate()
        longPressTimer = nil
    }

    // MARK: - App State

    @objc private func appDidResignActive() {
        if isDragging {
            isDragging = false
            onDragEnd?()
        }
        cancelLongPress()
        window?.setInteractive(false)
        hoveredSessionId = nil
        onHover?(nil)
        leaveTimer?.invalidate()
        leaveTimer = nil
        popAllCursors()
    }

    private func popAllCursors() {
        if isDragCursorPushed {
            NSCursor.pop()
            isDragCursorPushed = false
        }
        if isCursorPushed {
            NSCursor.pop()
            isCursorPushed = false
        }
    }
}
