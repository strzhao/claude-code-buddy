import SpriteKit
import AppKit

/// Loads rocket sprite textures. Step 6 will populate Assets/Sprites/Rocket/*.png.
/// Phase 1 returns SF Symbol "airplane" rendered to texture as a placeholder.
enum RocketSpriteLoader {

    static func placeholderTexture(size: CGSize = RocketConstants.Visual.spriteSize) -> SKTexture {
        let symbol = NSImage(systemSymbolName: "airplane",
                             accessibilityDescription: nil)
            ?? NSImage(size: size)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            symbol.draw(in: rect.insetBy(dx: 6, dy: 6))
            return true
        }
        let tex = SKTexture(image: image)
        tex.filteringMode = .nearest
        return tex
    }

    /// Returns (frames, fps) for a named animation. Phase 1 always returns the placeholder once.
    static func frames(for animation: String) -> (frames: [SKTexture], fps: Double) {
        return ([placeholderTexture()], 1.0)
    }
}
