import AppKit
import SpriteKit
import SnapshotTesting
@testable import BuddyCore

// MARK: - Mock Manifest Factory

enum SnapshotFixtures {
    static func makeManifest(
        id: String = "test-skin",
        name: String = "Test Skin",
        author: String = "Tester",
        version: String = "1.0.0",
        variants: [SkinVariant]? = nil
    ) -> SkinPackManifest {
        SkinPackManifest(
            id: id,
            name: name,
            author: author,
            version: version,
            previewImage: nil,
            spritePrefix: "cat",
            animationNames: [],
            canvasSize: [48, 48],
            bedNames: [],
            boundarySprite: "",
            foodNames: [],
            foodDirectory: "",
            spriteDirectory: "",
            menuBar: MenuBarConfig(
                walkPrefix: "",
                walkFrameCount: 0,
                runPrefix: "",
                runFrameCount: 0,
                idleFrame: "",
                directory: ""
            ),
            sounds: nil,
            variants: variants,
            spriteFacesRight: nil
        )
    }

    static func makeSkinPack(
        id: String = "test-skin",
        name: String = "Test Skin"
    ) -> SkinPack {
        let manifest = makeManifest(id: id, name: name)
        return SkinPack(manifest: manifest, source: .builtIn(Bundle.module))
    }
}

// MARK: - Offscreen Window Helper

/// Creates a temporary offscreen NSWindow for rendering AppKit views, calls body, then closes the window.
func withOffscreenWindow<T>(size: CGSize, _ body: (NSWindow) -> T) -> T {
    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: size),
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    let result = body(window)
    window.close()
    return result
}

// MARK: - SpriteKit Scene Snapshot Helper

/// Renders a SpriteKit scene off-screen and returns an NSImage.
/// The view is paused before setup and all actions are stripped before capture
/// to ensure fully deterministic output regardless of state animations.
func snapshotSKScene(size: CGSize, setup: (SKScene) -> Void) -> NSImage? {
    let view = SKView(frame: CGRect(origin: .zero, size: size))
    view.isPaused = true
    let scene = SKScene(size: size)
    scene.backgroundColor = .clear
    view.presentScene(scene)
    setup(scene)
    removeAllActionsRecursive(scene)
    guard let texture = view.texture(from: scene) else { return nil }
    let cgImage = texture.cgImage()
    return NSImage(cgImage: cgImage, size: size)
}

private func removeAllActionsRecursive(_ node: SKNode) {
    node.removeAllActions()
    for child in node.children {
        removeAllActionsRecursive(child)
    }
}
