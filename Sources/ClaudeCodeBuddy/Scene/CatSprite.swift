import SpriteKit

// MARK: - CatState

enum CatState: String, CaseIterable {
    case idle     = "idle"
    case thinking = "thinking"
    case coding   = "coding"
}

// MARK: - CatSprite

class CatSprite {

    // MARK: Properties

    let sessionId: String
    private(set) var currentState: CatState = .idle

    /// The underlying SpriteKit node added to the scene.
    let node: SKSpriteNode

    /// Animation texture arrays keyed by state.
    private var animations: [CatState: [SKTexture]] = [:]

    /// Frame durations per state (seconds per frame).
    private let frameDurations: [CatState: TimeInterval] = [
        .idle:     0.20,
        .thinking: 0.15,
        .coding:   0.10
    ]

    // MARK: Init

    init(sessionId: String) {
        self.sessionId = sessionId

        // Start with a placeholder 32x32 colored square if textures are missing
        node = SKSpriteNode(color: .blue, size: CGSize(width: 32, height: 32))
        node.name = "cat_\(sessionId)"

        setupPhysicsBody()
        loadTextures()
        applyAnimation(for: .idle)
    }

    // MARK: - Physics

    private func setupPhysicsBody() {
        let body = SKPhysicsBody(rectangleOf: CGSize(width: 28, height: 28))
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
        for state in CatState.allCases {
            var textures: [SKTexture] = []
            for frame in 1...4 {
                let name = "cat-\(state.rawValue)-\(frame)"
                if let url = Bundle.module.url(forResource: name,
                                               withExtension: "png",
                                               subdirectory: "Assets/Sprites") {
                    let texture = SKTexture(imageNamed: url.path)
                    texture.filteringMode = .nearest
                    textures.append(texture)
                }
            }
            if !textures.isEmpty {
                animations[state] = textures
            }
        }
    }

    // MARK: - State Machine

    func switchState(to newState: CatState) {
        guard newState != currentState else { return }
        currentState = newState

        // Update sprite color as visual indicator when no textures loaded
        switch newState {
        case .idle:     node.color = .blue
        case .thinking: node.color = .yellow
        case .coding:   node.color = .green
        }

        node.removeAllActions()
        applyAnimation(for: newState)

        // Add horizontal movement for coding state
        if newState == .coding {
            addCodingMovement()
        }
    }

    private func applyAnimation(for state: CatState) {
        guard let textures = animations[state], !textures.isEmpty else { return }
        let duration = frameDurations[state] ?? 0.2
        let animate = SKAction.animate(with: textures, timePerFrame: duration)
        let loop = SKAction.repeatForever(animate)
        node.run(loop, withKey: "animation")

        // Show first texture immediately
        node.texture = textures[0]
        node.color = .white
        node.colorBlendFactor = 0
    }

    private func addCodingMovement() {
        // Scurry back and forth while coding
        let distance: CGFloat = 60
        let duration: TimeInterval = 0.8
        let moveRight = SKAction.moveBy(x:  distance, y: 0, duration: duration)
        let moveLeft  = SKAction.moveBy(x: -distance, y: 0, duration: duration)
        let sequence  = SKAction.sequence([moveRight, moveLeft])
        let loop      = SKAction.repeatForever(sequence)
        node.run(loop, withKey: "movement")
    }

    // MARK: - Enter / Exit

    func enterScene(sceneSize: CGSize) {
        // Start above the visible area
        node.position = CGPoint(x: node.position.x, y: sceneSize.height + 32)

        // Drop down to ground level with a small bounce
        let landY: CGFloat = 32
        let drop = SKAction.moveTo(y: landY, duration: 0.6)
        drop.timingMode = .easeIn

        node.run(drop) { [weak self] in
            self?.switchState(to: .idle)
        }
    }

    func exitScene(sceneWidth: CGFloat, completion: @escaping () -> Void) {
        node.removeAction(forKey: "movement")
        node.removeAction(forKey: "animation")

        // Walk to the nearest edge
        let edgeX: CGFloat = node.position.x < sceneWidth / 2 ? -32 : sceneWidth + 32
        let duration = Double(abs(edgeX - node.position.x)) / 120.0

        let walk = SKAction.moveTo(x: edgeX, duration: max(duration, 0.5))
        walk.timingMode = .easeIn

        node.run(walk) {
            completion()
        }
    }
}
