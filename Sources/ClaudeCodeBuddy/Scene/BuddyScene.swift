import SpriteKit

// MARK: - Physics Categories

struct PhysicsCategory {
    static let cat:    UInt32 = 0x1
    static let ground: UInt32 = 0x2
    static let food:   UInt32 = 0x4
}

// MARK: - BuddyScene

class BuddyScene: SKScene, SKPhysicsContactDelegate {

    // MARK: Properties

    private var groundNode: SKNode!
    private var cats: [String: CatSprite] = [:]
    private let maxCats = 8

    private lazy var tooltipNode: TooltipNode = {
        let node = TooltipNode()
        addChild(node)
        return node
    }()

    private var cachedSessions: [SessionInfo] = []

    private(set) var foodManager = FoodManager()

    private var hoveredCatSessionId: String?

    func updateSessionsCache(_ sessions: [SessionInfo]) {
        cachedSessions = sessions
    }

    // MARK: Lifecycle

    override func didMove(to view: SKView) {
        backgroundColor = .clear
        setupPhysics()
        setupGround()
        foodManager.scene = self
        foodManager.start()
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
        groundBody.collisionBitMask   = PhysicsCategory.cat | PhysicsCategory.food
        groundBody.contactTestBitMask = PhysicsCategory.cat | PhysicsCategory.food
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
        cat.configure(color: info.color, labelText: info.label)

        // Random horizontal spawn position
        let spawnX = CGFloat.random(in: 48...(size.width - 48))
        cat.containerNode.position = CGPoint(x: spawnX, y: 48) // ground level

        addChild(cat.containerNode)
        cats[sessionId] = cat
        cat.onFoodAbandoned = { [weak self] sessionId in
            self?.foodManager.releaseFoodForCat(sessionId: sessionId)
        }
        cat.enterScene(sceneSize: size)
    }

    func updateCatLabel(sessionId: String, label: String) {
        cats[sessionId]?.updateLabel(label)
    }

    func updateCatColor(sessionId: String, color: SessionColor) {
        // Color is assigned at creation time and doesn't change during session lifetime
    }

    func removeCat(sessionId: String) {
        guard let cat = cats.removeValue(forKey: sessionId) else { return }
        foodManager.removeCatTracking(sessionId: sessionId)
        // Keep a strong ref to cat until exit animation completes, then remove node
        if sessionId == hoveredCatSessionId {
            hoveredCatSessionId = nil
        }
        // Collect remaining cats as obstacles for the jump animation
        let obstacles: [(cat: CatSprite, x: CGFloat)] = cats.values.map { ($0, $0.containerNode.position.x) }
        cat.exitScene(sceneWidth: size.width, obstacles: obstacles, onJumpOver: { [weak cat] jumpedCat in
            guard cat != nil else { return }
            jumpedCat.playFrightReaction(awayFromX: cat?.containerNode.position.x ?? 0)
        }) { [cat] in
            cat.containerNode.removeFromParent()
        }
    }

    func updateCatState(sessionId: String, state: CatState, toolDescription: String? = nil) {
        guard let cat = cats[sessionId] else { return }
        cat.switchState(to: state, toolDescription: toolDescription)
        foodManager.updateCatIdleState(sessionId: sessionId, isIdle: state == .idle)
    }

    var activeCatCount: Int { cats.count }

    func catAtPoint(_ point: CGPoint) -> String? {
        let hitSize = CatSprite.hitboxSize
        for (sessionId, cat) in cats {
            let catPos = cat.containerNode.position
            let rect = CGRect(
                x: catPos.x - hitSize.width / 2,
                y: catPos.y - hitSize.height / 2,
                width: hitSize.width,
                height: hitSize.height
            )
            if rect.contains(point) {
                return sessionId
            }
        }
        return nil
    }

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

    // MARK: - Tooltip

    func showTooltip(for sessionId: String) {
        guard let cat = cats[sessionId],
              let info = cachedSessions.first(where: { $0.sessionId == sessionId }) else { return }
        // Don't show tooltip if cat is already showing label (waiting state)
        guard cat.currentState != .permissionRequest else { return }
        tooltipNode.show(label: info.label, color: info.color, at: cat.containerNode.position, sceneSize: size)
    }

    func hideTooltip() {
        tooltipNode.hide()
    }

    // MARK: - Hover

    func setHovered(sessionId: String, hovered: Bool) {
        if hovered {
            // Unhover previous cat if different
            if let prev = hoveredCatSessionId, prev != sessionId {
                cats[prev]?.removeHoverScale()
            }
            hoveredCatSessionId = sessionId
            cats[sessionId]?.applyHoverScale()
        } else {
            if hoveredCatSessionId == sessionId {
                hoveredCatSessionId = nil
            }
            cats[sessionId]?.removeHoverScale()
        }
    }

    func clearHover() {
        if let sessionId = hoveredCatSessionId {
            cats[sessionId]?.removeHoverScale()
            hoveredCatSessionId = nil
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
            groundNode?.physicsBody?.collisionBitMask   = PhysicsCategory.cat | PhysicsCategory.food
            groundNode?.physicsBody?.contactTestBitMask = PhysicsCategory.cat | PhysicsCategory.food
            groundNode?.physicsBody?.isDynamic = false
            groundNode?.physicsBody?.friction = 0.5
        }
        // Update cached scene width for cat boundary clamping
        for cat in cats.values {
            cat.updateSceneSize(size)
        }
    }

    // MARK: - Physics Contact

    func didBegin(_ contact: SKPhysicsContact) {
        let maskA = contact.bodyA.categoryBitMask
        let maskB = contact.bodyB.categoryBitMask

        // Food hits ground
        if (maskA == PhysicsCategory.food && maskB == PhysicsCategory.ground) ||
           (maskA == PhysicsCategory.ground && maskB == PhysicsCategory.food) {
            let foodNode = maskA == PhysicsCategory.food ? contact.bodyA.node : contact.bodyB.node
            if let foodNode = foodNode as? SKSpriteNode,
               let food = foodManager.food(for: foodNode) {
                foodManager.foodLanded(food)
            }
        }
    }

    // MARK: - Food System

    func spawnFood(near x: CGFloat? = nil) {
        foodManager.trySpawnFood(near: x)
    }

    func catPosition(for sessionId: String) -> CGFloat? {
        cats[sessionId]?.containerNode.position.x
    }

    func idleCats() -> [CatSprite] {
        cats.values.filter { $0.currentState == .idle }
    }
}
