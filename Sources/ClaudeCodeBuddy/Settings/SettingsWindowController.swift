import AppKit

class SettingsWindowController: NSWindowController {
    convenience init() {
        let panel = NSPanel(
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
    }
}
