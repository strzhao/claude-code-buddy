import AppKit
import ApplicationServices

/// Horizontal bounds of the Dock icon cluster in screen coordinates.
struct DockIconBounds: Equatable {
    let minX: CGFloat
    let maxX: CGFloat

    var width: CGFloat { maxX - minX }
}

/// Provides the Dock icon cluster bounds via Accessibility API with heuristic fallback.
class DockIconBoundsProvider {

    /// Query Dock icon bounds via AX API. Must be called on the main thread.
    /// Returns nil if Dock process not found, AX permission denied, or AX hierarchy changed.
    func queryDockIconBounds() -> DockIconBounds? {
        guard let dockApp = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.dock"
        ).first else { return nil }

        let dockElement = AXUIElementCreateApplication(dockApp.processIdentifier)

        // Get children of the Dock application element
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(dockElement, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return nil }

        // Find the AXList child (the icon list container)
        for child in children {
            var roleRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef) == .success,
                  let role = roleRef as? String, role == "AXList" else { continue }

            // Read position and size
            var posRef: CFTypeRef?
            var sizeRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString, &posRef) == .success,
                  AXUIElementCopyAttributeValue(child, kAXSizeAttribute as CFString, &sizeRef) == .success else { continue }

            var position = CGPoint.zero
            var size = CGSize.zero
            guard AXValueGetValue(posRef as! AXValue, .cgPoint, &position),
                  AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { continue }

            guard size.width > 0 else { continue }
            return DockIconBounds(minX: position.x, maxX: position.x + size.width)
        }

        return nil
    }

    /// Heuristic fallback: centered on screen, ~60% width, capped at 900pt.
    func estimatedDockIconBounds(screenWidth: CGFloat) -> DockIconBounds {
        let estimatedWidth = min(screenWidth * 0.6, 900)
        let center = screenWidth / 2
        return DockIconBounds(
            minX: center - estimatedWidth / 2,
            maxX: center + estimatedWidth / 2
        )
    }

    /// Returns AX bounds if available, otherwise heuristic estimate.
    func currentBounds(screenWidth: CGFloat) -> DockIconBounds {
        if let axBounds = queryDockIconBounds() {
            return axBounds
        }
        NSLog("[Buddy] AX Dock query failed — using heuristic bounds")
        return estimatedDockIconBounds(screenWidth: screenWidth)
    }
}
