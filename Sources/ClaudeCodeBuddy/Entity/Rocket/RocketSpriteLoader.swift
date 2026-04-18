import SpriteKit
import AppKit
import ImageIO

/// Loads rocket sprite textures from Assets/Sprites/Rocket/rocket_<state>_<letter>.png.
/// Falls back to a blank white texture if assets are missing.
enum RocketSpriteLoader {

    private static var cache: [String: [SKTexture]] = [:]

    /// Returns (frames, fps) for a named animation on the given rocket kind.
    /// Caches per (kind + animation) so repeated lookups are cheap.
    static func frames(for animation: String,
                       kind: RocketKind = .classic) -> (frames: [SKTexture], fps: Double) {
        let key = "\(kind.spritePrefix)_\(animation)"
        if let cached = cache[key] {
            return (cached, defaultFPS(for: animation))
        }
        let prefix = key + "_"
        let letters = ["a", "b", "c", "d"]
        var loaded: [SKTexture] = []
        for letter in letters {
            guard let url = ResourceBundle.bundle.url(forResource: prefix + letter,
                                                     withExtension: "png",
                                                     subdirectory: "Assets/Sprites/Rocket"),
                  let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateImageAtIndex(src, 0, nil)
            else { continue }
            let tex = SKTexture(cgImage: cg)
            tex.filteringMode = .nearest
            loaded.append(tex)
        }
        guard !loaded.isEmpty else {
            if kind != .classic {
                return frames(for: animation, kind: .classic)
            }
            return ([placeholderTexture()], 1.0)
        }
        cache[key] = loaded
        return (loaded, defaultFPS(for: animation))
    }

    /// White-square fallback for when bundle resources are missing.
    static func placeholderTexture(size: CGSize = RocketConstants.Visual.spriteSize) -> SKTexture {
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        }
        let tex = SKTexture(image: image)
        tex.filteringMode = .nearest
        return tex
    }

    private static func defaultFPS(for anim: String) -> Double {
        switch anim {
        case "systems": return 4.0
        case "cruise":  return 5.0
        case "liftoff": return 8.0
        case "abort":   return 3.0
        case "landing": return 4.0
        default:         return 2.0
        }
    }
}
