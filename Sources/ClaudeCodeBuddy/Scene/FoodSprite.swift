import SpriteKit
import ImageIO

// MARK: - FoodState

enum FoodState {
    case falling, landed, claimed, eaten
}

// MARK: - FoodSprite

class FoodSprite {

    let node: SKSpriteNode
    private(set) var state: FoodState = .falling
    private(set) var claimedBy: String?
    private var landedTime: Date?

    static let renderSize = CGSize(width: 24, height: 24)
    static let expirationInterval: TimeInterval = 60  // auto-remove after 60s on ground

    // Food texture names from the active skin manifest
    static var allFoodNames: [String] {
        SkinPackManager.shared.activeSkin.manifest.foodNames
    }

    init(textureName: String) {
        let skin = SkinPackManager.shared.activeSkin
        if let url = skin.url(forResource: textureName, withExtension: "png", subdirectory: skin.manifest.foodDirectory),
           let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
           let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) {
            let texture = SKTexture(cgImage: cgImage)
            texture.filteringMode = .nearest
            node = SKSpriteNode(texture: texture, size: Self.renderSize)
        } else {
            // Fallback: colored square (same pattern as CatEntity)
            node = SKSpriteNode(color: .brown, size: Self.renderSize)
        }
        node.name = "food_\(textureName)"
        node.zPosition = -1  // behind cats
        setupPhysicsBody()
    }

    private func setupPhysicsBody() {
        let body = SKPhysicsBody(rectangleOf: CGSize(width: 20, height: 20))
        body.categoryBitMask = PhysicsCategory.food
        body.collisionBitMask = PhysicsCategory.ground
        body.contactTestBitMask = PhysicsCategory.ground
        body.restitution = 0.1
        body.friction = 0.9
        body.allowsRotation = false
        body.linearDamping = 0.3
        node.physicsBody = body
    }

    func markLanded() {
        guard state == .falling else { return }
        state = .landed
        landedTime = Date()
        // Stop physics movement
        node.physicsBody?.isDynamic = false
    }

    func claim(by sessionId: String) -> Bool {
        guard state == .landed else { return false }
        state = .claimed
        claimedBy = sessionId
        return true
    }

    func release() {
        guard state == .claimed else { return }
        state = .landed
        claimedBy = nil
    }

    var isExpired: Bool {
        guard let landedTime = landedTime, state == .landed else { return false }
        return Date().timeIntervalSince(landedTime) >= Self.expirationInterval
    }

    func eat(completion: @escaping () -> Void) {
        state = .eaten
        node.physicsBody = nil
        let pop = SKAction.scale(to: 1.3, duration: 0.1)
        let fadeOut = SKAction.fadeOut(withDuration: 0.25)
        let group = SKAction.group([pop, fadeOut])
        node.run(group) {
            self.node.removeFromParent()
            completion()
        }
    }

    func expire(completion: @escaping () -> Void) {
        state = .eaten
        node.physicsBody = nil
        let fadeOut = SKAction.fadeOut(withDuration: 0.5)
        node.run(fadeOut) {
            self.node.removeFromParent()
            completion()
        }
    }

    static func randomFoodName() -> String {
        allFoodNames.randomElement() ?? "81_pizza"
    }
}
