import AppKit

/// Detects the Dock's current position and height so the BuddyWindow can be
/// placed exactly on top of the Dock's upper edge.
class DockTracker {

    private let boundsProvider = DockIconBoundsProvider()

    /// Returns the frame for the BuddyWindow: full-width strip sitting on top of the Dock.
    func buddyWindowFrame(height: CGFloat = 80) -> NSRect {
        guard let screen = NSScreen.main else {
            return NSRect(x: 0, y: 0, width: 800, height: height)
        }

        let screenFrame   = screen.frame
        let visibleFrame  = screen.visibleFrame

        // When the Dock is at the bottom, visibleFrame.origin.y > screenFrame.origin.y
        let dockHeight = visibleFrame.origin.y - screenFrame.origin.y

        // If Dock is hidden or on a side, dockHeight will be 0 or negative.
        let yOffset = max(dockHeight, 0)

        return NSRect(
            x: screenFrame.origin.x,
            y: screenFrame.origin.y + yOffset,
            width: screenFrame.width,
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
