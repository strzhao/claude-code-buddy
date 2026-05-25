import AppKit

final class LauncherWindow: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: LauncherConstants.windowWidth, height: LauncherConstants.windowMinHeight),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .transient]
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = true   // 失焦自动隐藏（macOS 默认行为）
        // standardWindowButton 全隐藏
        for btn in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(btn)?.isHidden = true
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }   // 不抢应用主窗口

    func centerOnScreen() {
        guard let screen = NSScreen.main else { return }
        let rect = screen.visibleFrame
        let x = rect.midX - frame.width / 2
        let y = rect.minY + rect.height * (1 - LauncherConstants.windowYRatio)
        setFrameOrigin(NSPoint(x: x, y: y))
    }
}
