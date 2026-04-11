import AppKit

/// Detects the Dock's current position and height so the BuddyWindow can be
/// placed exactly on top of the Dock's upper edge.
class DockTracker {

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
}
