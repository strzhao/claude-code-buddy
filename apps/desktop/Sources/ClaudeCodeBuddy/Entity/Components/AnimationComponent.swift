import SpriteKit
import ImageIO

// MARK: - AnimationComponent

/// Owns all animation texture data for a cat sprite node and provides a
/// unified API for playing frame animations, transitions, and breathing.
class AnimationComponent {

    // MARK: - Properties

    unowned let node: SKSpriteNode
    let personality: CatPersonality

    /// Animation texture arrays keyed by animation name string.
    /// Known names: "idle-a", "idle-b", "clean", "sleep", "scared", "paw", "walk-a", "walk-b", "jump"
    private(set) var animations: [String: [SKTexture]] = [:]

    // MARK: - Init

    init(node: SKSpriteNode, personality: CatPersonality) {
        self.node = node
        self.personality = personality
    }

    // MARK: - Texture Loading

    func loadTextures(from skin: SkinPack) {
        let animNames = skin.manifest.animationNames
        for animName in animNames {
            var textures: [SKTexture] = []
            var frame = 1
            while true {
                let name = "\(skin.effectiveSpritePrefix)-\(animName)-\(frame)"
                guard let url = skin.url(forResource: name,
                                         withExtension: "png",
                                         subdirectory: skin.manifest.spriteDirectory) else { break }
                guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else { break }
                let texture = SKTexture(cgImage: cgImage)
                texture.filteringMode = .nearest
                textures.append(texture)
                frame += 1
            }
            if !textures.isEmpty {
                animations[animName] = textures
            }
        }
    }

    /// Load textures on a background thread, then apply on main thread.
    /// Calls completion on the main thread when done.
    func loadTexturesAsync(from skin: SkinPack, completion: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Read all CGImages from disk on background thread
            let animNames = skin.manifest.animationNames
            var loaded: [String: [CGImage]] = [:]

            for animName in animNames {
                var images: [CGImage] = []
                var frame = 1
                while true {
                    let name = "\(skin.effectiveSpritePrefix)-\(animName)-\(frame)"
                    guard let url = skin.url(forResource: name,
                                             withExtension: "png",
                                             subdirectory: skin.manifest.spriteDirectory) else { break }
                    guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
                          let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else { break }
                    images.append(cgImage)
                    frame += 1
                }
                if !images.isEmpty {
                    loaded[animName] = images
                }
            }

            // Create SKTextures and assign on main thread
            DispatchQueue.main.async {
                guard let self else { return }
                for (animName, images) in loaded {
                    self.animations[animName] = images.map { cgImage in
                        let texture = SKTexture(cgImage: cgImage)
                        texture.filteringMode = .nearest
                        return texture
                    }
                }
                completion()
            }
        }
    }

    // MARK: - Texture Helpers

    func textures(for animName: String) -> [SKTexture]? {
        guard let textures = animations[animName], !textures.isEmpty else { return nil }
        return textures
    }

    func hasAnimation(_ name: String) -> Bool {
        guard let frames = animations[name] else { return false }
        return !frames.isEmpty
    }

    func setTexture(_ name: String) {
        guard let frames = textures(for: name), let first = frames.first else { return }
        node.texture = first
    }

    // MARK: - Animation Playback

    /// Play a named animation on the sprite node.
    ///
    /// - Parameters:
    ///   - name: Animation name key in the animations dictionary.
    ///   - loop: Whether to loop the animation forever.
    ///   - timePerFrame: Duration per frame.
    ///   - key: SKAction key used to identify (and cancel) the action.
    ///   - completion: Optional block run after the animation finishes (only meaningful when loop == false).
    func play(_ name: String, loop: Bool, timePerFrame: TimeInterval, key: String, completion: (() -> Void)? = nil) {
        guard let frames = textures(for: name) else { return }
        let animate = SKAction.animate(with: frames, timePerFrame: timePerFrame)
        let action: SKAction = loop ? SKAction.repeatForever(animate) : animate
        if let completion = completion {
            let done = SKAction.run(completion)
            node.run(SKAction.sequence([action, done]), withKey: key)
        } else {
            node.run(action, withKey: key)
        }
        node.texture = frames[0]
    }

    /// Play a one-shot transition animation and call completion when done.
    /// If the animation is not found, completion is called immediately.
    ///
    /// - Parameters:
    ///   - animName: Animation name key.
    ///   - timePerFrame: Duration per frame.
    ///   - key: SKAction key (default "transition").
    ///   - completion: Block to run after the animation finishes.
    func playTransition(animName: String, timePerFrame: TimeInterval, key: String = "transition", completion: @escaping () -> Void) {
        guard let frames = textures(for: animName) else {
            completion()
            return
        }
        let animate = SKAction.animate(with: frames, timePerFrame: timePerFrame)
        let done = SKAction.run(completion)
        node.run(SKAction.sequence([animate, done]), withKey: key)
    }

    // MARK: - Breathing

    /// Start a subtle Y-scale oscillation (breathing) on the node.
    func startBreathing() {
        let baseAmplitude = CatConstants.Animation.breatheScaleY - 1.0
        let tm = AnimationTransitionManager(node: node, containerNode: SKNode(), personality: personality)
        tm.startEnhancedBreathing(baseAmplitude: baseAmplitude, duration: CatConstants.Animation.breatheDuration)
    }

    // MARK: - Action Management

    func stopAction(forKey key: String) {
        node.removeAction(forKey: key)
    }

    func stopAll() {
        node.removeAllActions()
    }
}
