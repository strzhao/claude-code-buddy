import AppKit

/// Detects the Dock's current position and height so the BuddyWindow can be
/// placed exactly on top of the Dock's upper edge.
class DockTracker {

    private let boundsProvider = DockIconBoundsProvider()

    /// When true, callers should skip repositioning the window.
    /// Used during SceneExpansion animations to avoid jitter.
    private(set) var isSuspended = false

    func suspendRepositioning() { isSuspended = true }
    func resumeRepositioning() { isSuspended = false }

    /// Returns the frame for the BuddyWindow: a strip sitting on top of the Dock.
    /// Width defaults to full screen but can be scaled via `BUDDY_WIDTH_SCALE` env var
    /// (e.g. "0.5" = 50% width). Horizontal position shifts with `BUDDY_OFFSET_X` (points).
    func buddyWindowFrame(height: CGFloat = 80) -> NSRect {
        guard let screen = NSScreen.main else {
            return NSRect(x: 0, y: 0, width: 800, height: height)
        }

        let screenFrame   = screen.frame
        let visibleFrame  = screen.visibleFrame

        // When the Dock is at the bottom, visibleFrame.origin.y > screenFrame.origin.y
        let dockHeight = visibleFrame.origin.y - screenFrame.origin.y
        let yOffset = max(dockHeight, 0)

        // Horizontal scale + offset via env vars
        let env = ProcessInfo.processInfo.environment
        let rawScale = env["BUDDY_WIDTH_SCALE"].flatMap(Double.init) ?? 1.0
        let scale = CGFloat(min(max(rawScale, 0.2), 1.0))   // clamp to [0.2, 1.0]
        let offsetX = CGFloat(env["BUDDY_OFFSET_X"].flatMap(Double.init) ?? 0)

        let width = screenFrame.width * scale
        let centeredX = screenFrame.origin.x + (screenFrame.width - width) / 2
        return NSRect(
            x: centeredX + offsetX,
            y: screenFrame.origin.y + yOffset,
            width: width,
            height: height
        )
    }

    /// The height of the Dock on the main screen. Returns 0 if not on the bottom.
    var dockHeight: CGFloat {
        guard let screen = NSScreen.main else { return 0 }
        let dh = screen.visibleFrame.origin.y - screen.frame.origin.y
        return max(dh, 0)
    }

    /// Returns the cat activity bounds in scene-local coordinates.
    /// When Dock is not at bottom (dockHeight == 0), uses full screen with margins.
    func activityBounds(windowOriginX: CGFloat, screenMargin: CGFloat = 48) -> ClosedRange<CGFloat> {
        guard let screen = NSScreen.main else {
            return screenMargin...(800 - screenMargin)
        }

        let screenWidth = screen.frame.width

        if dockHeight == 0 {
            // Dock hidden or on side — full screen with margins
            return screenMargin...(screenWidth - screenMargin)
        }

        // Get Dock icon bounds in screen coordinates and convert to scene-local
        let dockBounds = boundsProvider.currentBounds(screenWidth: screenWidth)
        let localMin = dockBounds.minX - windowOriginX
        let localMax = dockBounds.maxX - windowOriginX

        // Ensure minimum 100pt width
        let width = localMax - localMin
        if width < 100 {
            let center = (localMin + localMax) / 2
            return (center - 50)...(center + 50)
        }

        return localMin...localMax
    }
}
