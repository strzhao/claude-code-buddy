import AppKit

/// A transparent, borderless, floating window that sits above the Dock.
/// It passes mouse clicks through to windows underneath.
class BuddyWindow: NSWindow {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        // Visual appearance
        isOpaque = false
        backgroundColor = NSColor.clear
        hasShadow = false

        // Always float above normal windows
        level = .floating

        // Clicks pass through the transparent window
        ignoresMouseEvents = true

        // Appear on all Spaces and don't participate in Exposé cycling
        collectionBehavior = [.canJoinAllSpaces, .stationary]
    }

    // Allow the window to become key so we can receive events if needed later
    override var canBecomeKey: Bool { true }

    func setInteractive(_ interactive: Bool) {
        ignoresMouseEvents = !interactive
    }
}
