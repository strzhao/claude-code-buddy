import SpriteKit

// MARK: - Physics Categories

struct PhysicsCategory {
    static let cat:    UInt32 = 0x1
    static let ground: UInt32 = 0x2
}

// MARK: - BuddyScene

class BuddyScene: SKScene, SKPhysicsContactDelegate {

    // MARK: Properties

    private var groundNode: SKNode!
    private var cats: [String: CatSprite] = [:]
    private let maxCats = 8

    // MARK: Lifecycle

    override func didMove(to view: SKView) {
        backgroundColor = .clear
        setupPhysics()
        setupGround()
    }

    // MARK: - Setup

    private func setupPhysics() {
        physicsWorld.gravity = CGVector(dx: 0, dy: -9.8)
        physicsWorld.contactDelegate = self
    }

    private func setupGround() {
        groundNode = SKNode()
        groundNode.position = CGPoint(x: size.width / 2, y: 0)

        let groundBody = SKPhysicsBody(edgeFrom: CGPoint(x: -size.width / 2, y: 0),
                                       to: CGPoint(x: size.width / 2, y: 0))
        groundBody.categoryBitMask    = PhysicsCategory.ground
        groundBody.collisionBitMask   = PhysicsCategory.cat
        groundBody.contactTestBitMask = PhysicsCategory.cat
        groundBody.isDynamic = false
        groundBody.friction = 0.5
        groundNode.physicsBody = groundBody

        addChild(groundNode)
    }

    // MARK: - Cat Management

    func addCat(info: SessionInfo) {
        let sessionId = info.sessionId
        guard cats[sessionId] == nil else { return }

        // Enforce max-cat rule: evict earliest idle cat
        if cats.count >= maxCats {
            evictIdleCat()
        }

        let cat = CatSprite(sessionId: sessionId)

        // Random horizontal spawn position
        let spawnX = CGFloat.random(in: 48...(size.width - 48))
        cat.node.position = CGPoint(x: spawnX, y: size.height) // start above frame

        addChild(cat.node)
        cats[sessionId] = cat
        cat.enterScene(sceneSize: size)
    }

    func updateCatLabel(sessionId: String, label: String) {
        // Stub: will be implemented in 003-visual-layer
    }

    func updateCatColor(sessionId: String, color: SessionColor) {
        // Stub: will be implemented in 003-visual-layer
    }

    func removeCat(sessionId: String) {
        guard let cat = cats.removeValue(forKey: sessionId) else { return }
        // Keep a strong ref to cat until exit animation completes, then remove node
        cat.exitScene(sceneWidth: size.width) { [cat] in
            cat.node.removeFromParent()
        }
    }

    func updateCatState(sessionId: String, state: CatState) {
        guard let cat = cats[sessionId] else { return }
        cat.switchState(to: state)
    }

    var activeCatCount: Int { cats.count }

    // MARK: - Private Helpers

    private func evictIdleCat() {
        // Find first idle cat and evict it
        if let (id, _) = cats.first(where: { $0.value.currentState == .idle }) {
            removeCat(sessionId: id)
        } else if let (id, _) = cats.first {
            // No idle cat — remove oldest (first in dict)
            removeCat(sessionId: id)
        }
    }

    // MARK: - Scene Resize

    override func didChangeSize(_ oldSize: CGSize) {
        // Reposition ground when window resizes
        groundNode?.position = CGPoint(x: size.width / 2, y: 0)
        if groundNode?.physicsBody != nil {
            groundNode?.physicsBody = SKPhysicsBody(
                edgeFrom: CGPoint(x: -size.width / 2, y: 0),
                to: CGPoint(x: size.width / 2, y: 0)
            )
            groundNode?.physicsBody?.categoryBitMask    = PhysicsCategory.ground
            groundNode?.physicsBody?.collisionBitMask   = PhysicsCategory.cat
            groundNode?.physicsBody?.contactTestBitMask = PhysicsCategory.cat
            groundNode?.physicsBody?.isDynamic = false
            groundNode?.physicsBody?.friction = 0.5
        }
    }
}
