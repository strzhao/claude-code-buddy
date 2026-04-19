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

    /// Temporarily grow the window upward by `delta` pts for `duration` seconds,
    /// then animate back to the original frame. Anchored to the bottom (Dock top).
    /// Caller is responsible for suspending DockTracker during the animation.
    func expandHeightTemporarily(by delta: CGFloat, duration: TimeInterval) {
        let original = self.frame
        let expanded = NSRect(
            x: original.origin.x,
            y: original.origin.y,
            width: original.size.width,
            height: original.size.height + delta
        )
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration / 2
            ctx.allowsImplicitAnimation = true
            self.setFrame(expanded, display: true, animate: true)
        }, completionHandler: { [weak self] in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = duration / 2
                ctx.allowsImplicitAnimation = true
                self?.setFrame(original, display: true, animate: true)
            })
        })
    }
}
