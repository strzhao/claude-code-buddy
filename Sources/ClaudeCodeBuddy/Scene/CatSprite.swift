import SpriteKit
import ImageIO

// MARK: - CatState

enum CatState: String, CaseIterable {
    case idle     = "idle"
    case thinking = "thinking"
    case coding   = "coding"
}

// MARK: - IdleSubState

private enum IdleSubState {
    case breathe, blink, clean, sleep
}

// MARK: - CatSprite

class CatSprite {

    // MARK: Properties

    let sessionId: String
    private(set) var currentState: CatState = .idle

    /// The underlying SpriteKit node added to the scene.
    let node: SKSpriteNode

    /// Animation texture arrays keyed by animation name string.
    /// Known names: "idle-a", "idle-b", "clean", "sleep", "scared", "paw", "walk-a", "walk-b"
    private var animations: [String: [SKTexture]] = [:]

    /// Current idle sub-state.
    private var idleSubState: IdleSubState = .breathe

    // MARK: Init

    init(sessionId: String) {
        self.sessionId = sessionId

        // Start with a placeholder 48x48 colored square if textures are missing
        node = SKSpriteNode(color: .orange, size: CGSize(width: 48, height: 48))
        node.name = "cat_\(sessionId)"

        setupPhysicsBody()
        loadTextures()
    }

    // MARK: - Physics

    private func setupPhysicsBody() {
        let body = SKPhysicsBody(rectangleOf: CGSize(width: 44, height: 44))
        body.allowsRotation = false
        body.categoryBitMask    = PhysicsCategory.cat
        body.collisionBitMask   = PhysicsCategory.cat | PhysicsCategory.ground
        body.contactTestBitMask = PhysicsCategory.ground
        body.restitution = 0.0
        body.friction    = 0.8
        body.linearDamping = 0.5
        node.physicsBody = body
    }

    // MARK: - Textures

    private func loadTextures() {
        let animNames = ["idle-a", "idle-b", "clean", "sleep", "scared", "paw", "walk-a", "walk-b"]

        for animName in animNames {
            var textures: [SKTexture] = []
            var frame = 1
            while true {
                let name = "cat-\(animName)-\(frame)"
                guard let url = Bundle.module.url(forResource: name,
                                                  withExtension: "png",
                                                  subdirectory: "Assets/Sprites") else {
                    break
                }
                guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
                    break
                }
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

    // MARK: - Helpers

    private func textures(for animName: String) -> [SKTexture]? {
        guard let textures = animations[animName], !textures.isEmpty else { return nil }
        return textures
    }

    // MARK: - State Machine

    func switchState(to newState: CatState) {
        guard newState != currentState else { return }
        currentState = newState

        node.removeAllActions()

        switch newState {
        case .idle:
            node.color = .orange
            startIdleLoop()

        case .thinking:
            node.color = .yellow
            if let frames = textures(for: "scared"), !frames.isEmpty {
                let animate = SKAction.animate(with: frames, timePerFrame: 0.15)
                let loop = SKAction.repeatForever(animate)
                node.run(loop, withKey: "animation")
                node.texture = frames[0]
                node.color = .white
                node.colorBlendFactor = 0
            }

        case .coding:
            node.color = .green
            if let frames = textures(for: "clean"), !frames.isEmpty {
                let animate = SKAction.animate(with: frames, timePerFrame: 0.12)
                let loop = SKAction.repeatForever(animate)
                node.run(loop, withKey: "animation")
                node.texture = frames[0]
                node.color = .white
                node.colorBlendFactor = 0
            }
        }
    }

    // MARK: - Idle State Machine

    private func startIdleLoop() {
        idleSubState = pickNextIdleSubState()
        runIdleSubState()
    }

    private func pickNextIdleSubState() -> IdleSubState {
        // Weighted random: breathe 70%, blink 15%, clean 10%, sleep 5%
        let roll = Float.random(in: 0..<1)
        switch roll {
        case ..<0.70: return .breathe
        case ..<0.85: return .blink
        case ..<0.95: return .clean
        default:      return .sleep
        }
    }

    private func runIdleSubState() {
        // Guard: only run if still in idle state
        guard currentState == .idle else { return }

        switch idleSubState {
        case .breathe:
            playIdleAnimation(animName: "idle-a", looping: true)
            scheduleNextIdleTransition(after: SKAction.wait(forDuration: 4, withRange: 2))

        case .blink:
            // Play idle-b once (~2s), then return to breathe
            if let frames = textures(for: "idle-b"), !frames.isEmpty {
                let duration = 2.0 / Double(frames.count)
                let animate = SKAction.animate(with: frames, timePerFrame: duration)
                let returnToBreathe = SKAction.run { [weak self] in
                    guard let self = self, self.currentState == .idle else { return }
                    self.idleSubState = .breathe
                    self.runIdleSubState()
                }
                node.run(SKAction.sequence([animate, returnToBreathe]), withKey: "idleLoop")
                node.texture = frames[0]
                node.color = .white
                node.colorBlendFactor = 0
            } else {
                // Fallback: treat like breathe
                idleSubState = .breathe
                runIdleSubState()
            }

        case .clean:
            // Play clean textures once (~3s), then return to breathe
            if let frames = textures(for: "clean"), !frames.isEmpty {
                let duration = 3.0 / Double(frames.count)
                let animate = SKAction.animate(with: frames, timePerFrame: duration)
                let returnToBreathe = SKAction.run { [weak self] in
                    guard let self = self, self.currentState == .idle else { return }
                    self.idleSubState = .breathe
                    self.runIdleSubState()
                }
                node.run(SKAction.sequence([animate, returnToBreathe]), withKey: "idleLoop")
                node.texture = frames[0]
                node.color = .white
                node.colorBlendFactor = 0
            } else {
                idleSubState = .breathe
                runIdleSubState()
            }

        case .sleep:
            // Play sleep textures, wait ~5s, then return to breathe
            if let frames = textures(for: "sleep"), !frames.isEmpty {
                let animDuration = 1.0 / Double(frames.count)
                let animate = SKAction.animate(with: frames, timePerFrame: animDuration)
                let loopSleep = SKAction.repeat(animate, count: 3)
                let wait = SKAction.wait(forDuration: 5, withRange: 2)
                let returnToBreathe = SKAction.run { [weak self] in
                    guard let self = self, self.currentState == .idle else { return }
                    self.idleSubState = .breathe
                    self.runIdleSubState()
                }
                node.run(SKAction.sequence([loopSleep, wait, returnToBreathe]), withKey: "idleLoop")
                node.texture = frames[0]
                node.color = .white
                node.colorBlendFactor = 0
            } else {
                idleSubState = .breathe
                runIdleSubState()
            }
        }
    }

    private func playIdleAnimation(animName: String, looping: Bool) {
        guard let frames = textures(for: animName), !frames.isEmpty else { return }
        let animate = SKAction.animate(with: frames, timePerFrame: 0.20)
        let action = looping ? SKAction.repeatForever(animate) : animate
        node.run(action, withKey: "idleLoop")
        node.texture = frames[0]
        node.color = .white
        node.colorBlendFactor = 0
    }

    private func scheduleNextIdleTransition(after waitAction: SKAction) {
        let pickAndRun = SKAction.run { [weak self] in
            guard let self = self, self.currentState == .idle else { return }
            self.idleSubState = self.pickNextIdleSubState()
            self.node.removeAction(forKey: "idleLoop")
            self.runIdleSubState()
        }
        node.run(SKAction.sequence([waitAction, pickAndRun]), withKey: "idleTransition")
    }

    // MARK: - Enter / Exit

    func enterScene(sceneSize: CGSize) {
        // Start above the visible area
        node.position = CGPoint(x: node.position.x, y: sceneSize.height + 48)

        // Play walk animation during drop
        if let frames = textures(for: "walk-a"), !frames.isEmpty {
            let animate = SKAction.animate(with: frames, timePerFrame: 0.12)
            let loop = SKAction.repeatForever(animate)
            node.run(loop, withKey: "walkAnimation")
            node.texture = frames[0]
            node.color = .white
            node.colorBlendFactor = 0
        }

        // Drop down to ground level
        let landY: CGFloat = 48
        let drop = SKAction.moveTo(y: landY, duration: 0.6)
        drop.timingMode = .easeIn

        node.run(drop) { [weak self] in
            self?.node.removeAction(forKey: "walkAnimation")
            self?.switchState(to: .idle)
        }
    }

    func exitScene(sceneWidth: CGFloat, completion: @escaping () -> Void) {
        node.removeAllActions()

        // Walk to the nearest edge
        let edgeX: CGFloat = node.position.x < sceneWidth / 2 ? -48 : sceneWidth + 48
        let duration = Double(abs(edgeX - node.position.x)) / 120.0

        // Play walk animation during exit
        if let frames = textures(for: "walk-a"), !frames.isEmpty {
            let animate = SKAction.animate(with: frames, timePerFrame: 0.12)
            let loop = SKAction.repeatForever(animate)
            node.run(loop, withKey: "walkAnimation")
            node.texture = frames[0]
            node.color = .white
            node.colorBlendFactor = 0
        }

        let walk = SKAction.moveTo(x: edgeX, duration: max(duration, 0.5))
        walk.timingMode = .easeIn

        node.run(walk) {
            completion()
        }
    }
}
