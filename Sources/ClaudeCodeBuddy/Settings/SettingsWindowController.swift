import AppKit

class SettingsWindowController: NSWindowController {
    convenience init() {
        let panel = SettingsPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: true
        )
        panel.title = "Skin Market"
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        self.init(window: panel)

        let galleryVC = SkinGalleryViewController()
        panel.contentViewController = galleryVC
        panel.gallery = galleryVC
    }
}

/// Panel that intercepts mouse clicks and forwards them to the gallery.
/// LSUIElement apps can't reliably get key window status, so we bypass
/// NSCollectionView's built-in selection entirely.
class SettingsPanel: NSPanel {
    weak var gallery: SkinGalleryViewController?

    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseUp, let gallery {
            let windowPoint = event.locationInWindow
            gallery.handleClickAt(windowPoint: windowPoint)
        }
        super.sendEvent(event)
    }
}
