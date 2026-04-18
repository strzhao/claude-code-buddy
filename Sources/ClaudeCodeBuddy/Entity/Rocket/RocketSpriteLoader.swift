import SpriteKit
import AppKit
import ImageIO

/// Loads rocket sprite textures from Assets/Sprites/Rocket/rocket_<state>_<letter>.png.
/// Falls back to a transparent texture if assets are missing — a missing
/// asset should render as *nothing* rather than a big white rectangle that
/// silently masquerades as a valid sprite (which is what the old white
/// placeholder caused: any pre-animation window, or any sprite whose frames
/// failed to load, painted a full 72×72 white block over the Starship body).
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
            NSLog("[RocketSpriteLoader] no frames for \(key) — using transparent placeholder")
            return ([placeholderTexture()], 1.0)
        }
        cache[key] = loaded
        return (loaded, defaultFPS(for: animation))
    }

    /// Transparent fallback for when bundle resources are missing OR when a
    /// sprite is created before its first animation tick assigns a real
    /// texture. Clear (not white) so the "missing asset" state fails silently
    /// invisibly — never a white block over a real ship.
    static func placeholderTexture(size: CGSize = RocketConstants.Visual.spriteSize) -> SKTexture {
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.clear.setFill()
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
