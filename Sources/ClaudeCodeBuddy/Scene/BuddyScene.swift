import SpriteKit
import ImageIO
import Combine

// MARK: - Physics Categories

struct PhysicsCategory {
    static let cat: UInt32 = 0x1
    static let ground: UInt32 = 0x2
    static let food: UInt32 = 0x4
}

// MARK: - BuddyScene

class BuddyScene: SKScene, SKPhysicsContactDelegate {

    // MARK: Properties

    private var groundNode: SKNode!
    private var cats: [String: CatSprite] = [:]
    private let maxCats = CatConstants.Scene.maxCats

    private lazy var tooltipNode: TooltipNode = {
        let node = TooltipNode()
        addChild(node)
        return node
    }()

    private var cachedSessions: [SessionInfo] = []

    private(set) var foodManager = FoodManager()

    private var hoveredCatSessionId: String?

    /// Tracks which bed slots are in use (sessionId → slot index).
    private var activeBedSlots: [String: Int] = [:]

    /// Activity bounds for cat movement. Updated by AppDelegate when Dock changes.
    var activityBounds: ClosedRange<CGFloat> = 48...752 {
        didSet { propagateActivityBounds() }
    }

    private var leftBoundaryNode: SKSpriteNode?
    private var rightBoundaryNode: SKSpriteNode?

    private let sceneEnvironment = SceneEnvironment()
    private var cancellables = Set<AnyCancellable>()

    func updateSessionsCache(_ sessions: [SessionInfo]) {
        cachedSessions = sessions
    }

    // MARK: Lifecycle

    override func didMove(to view: SKView) {
        backgroundColor = .clear
        setupPhysics()
        setupGround()
        setupBoundaryDecorations()
        foodManager.scene = self
        foodManager.start()

        sceneEnvironment.start()

        EventBus.shared.weatherChanged
            .receive(on: RunLoop.main)
            .sink { [weak self] weather in
                guard let self = self else { return }
                for cat in self.cats.values {
                    cat.onWeatherChanged(weather)
                }
            }
            .store(in: &cancellables)

        EventBus.shared.timeOfDayChanged
            .receive(on: RunLoop.main)
            .sink { [weak self] time in
                guard let self = self else { return }
                for cat in self.cats.values {
                    cat.onTimeOfDayChanged(time)
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Setup

    private func setupPhysics() {
        physicsWorld.gravity = CGVector(dx: 0, dy: CatConstants.Scene.gravity)
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
        groundBody.friction = CatConstants.Scene.groundFriction
        groundNode.physicsBody = groundBody

        addChild(groundNode)
    }

    private static let boundaryRenderSize = CGSize(width: 32, height: 32)

    private func loadBoundaryTexture() -> SKTexture? {
        guard let url = ResourceBundle.bundle.url(forResource: "boundary-bush",
                                          withExtension: "png",
                                          subdirectory: "Assets/Sprites"),
              let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            return nil
        }
        let tex = SKTexture(cgImage: cgImage)
        tex.filteringMode = .nearest
        return tex
    }

    private func setupBoundaryDecorations() {
        let tex = loadBoundaryTexture()
        let renderSize = Self.boundaryRenderSize

        let left = SKSpriteNode(texture: tex, size: renderSize)
        left.color = tex == nil ? .green : .white
        left.position = CGPoint(x: activityBounds.lowerBound - renderSize.width / 2 - 2,
                                y: renderSize.height / 2)
        left.zPosition = -1
        addChild(left)
        leftBoundaryNode = left

        let right = SKSpriteNode(texture: tex, size: renderSize)
        right.color = tex == nil ? .green : .white
        right.xScale = -1  // Mirror horizontally
        right.position = CGPoint(x: activityBounds.upperBound + renderSize.width / 2 + 2,
                                 y: renderSize.height / 2)
        right.zPosition = -1
        addChild(right)
        rightBoundaryNode = right
    }

    private func updateBoundaryPositions() {
        let renderSize = Self.boundaryRenderSize
        leftBoundaryNode?.position.x = activityBounds.lowerBound - renderSize.width / 2 - 2
        rightBoundaryNode?.position.x = activityBounds.upperBound + renderSize.width / 2 + 2
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

        // Random horizontal spawn position within activity bounds
        let spawnX = findNonOverlappingSpawnX()
        cat.containerNode.position = CGPoint(x: spawnX, y: CatConstants.Visual.groundY) // ground level

        addChild(cat.containerNode)
        cats[sessionId] = cat
        cat.onFoodAbandoned = { [weak self] sessionId in
            self?.foodManager.releaseFoodForCat(sessionId: sessionId)
        }
        cat.onBedRequested = { [weak self] sessionId in
            guard let self = self,
                  let x = self.assignBedSlot(for: sessionId),
                  let name = self.bedColorName(for: sessionId) else { return nil }
            return (x: x, bedName: name)
        }
        cat.onBedReleased = { [weak self] sessionId in
            self?.releaseBedSlot(for: sessionId)
        }
        cat.nearbyObstacles = { [weak self, weak cat] in
            guard let self = self, let cat = cat else { return [] }
            return self.cats.values
                .filter { $0.sessionId != cat.sessionId }
                .map { ($0, $0.containerNode.position.x) }
        }
        cat.enterScene(sceneSize: size, activityBounds: activityBounds)
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
        releaseBedSlot(for: sessionId)
        // Keep a strong ref to cat until exit animation completes, then remove node
        if sessionId == hoveredCatSessionId {
            hoveredCatSessionId = nil
        }
        // Collect remaining cats as obstacles for the jump animation
        let obstacles: [(cat: CatSprite, x: CGFloat)] = cats.values.map { ($0, $0.containerNode.position.x) }
        cat.exitScene(sceneWidth: size.width, obstacles: obstacles, onJumpOver: { [weak cat] jumpedCat in
            guard cat != nil else { return }
            jumpedCat.playFrightReaction(awayFromX: cat?.containerNode.position.x ?? 0)
        }, completion: { [cat] in
            cat.containerNode.removeFromParent()
        })
    }

    func updateCatState(sessionId: String, state: CatState, toolDescription: String? = nil) {
        guard let cat = cats[sessionId] else { return }
        cat.switchState(to: state, toolDescription: toolDescription)
        foodManager.updateCatIdleState(sessionId: sessionId, isIdle: state == .idle)
        // When a cat becomes idle, check for existing landed food
        if state == .idle {
            foodManager.notifyCatAboutLandedFood(cat)
        }
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

    private func propagateActivityBounds() {
        for cat in cats.values {
            cat.updateActivityBounds(activityBounds)
        }
        foodManager.activityBounds = activityBounds
        updateBoundaryPositions()
    }

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

    // MARK: - Per-Frame Update

    override func update(_ currentTime: TimeInterval) {
        super.update(currentTime)

        for cat in cats.values {
            // Skip cats in taskComplete state (beds are outside activityBounds)
            guard cat.currentState != .taskComplete else { continue }

            // Skip cats already running a boundary recovery
            guard cat.containerNode.action(forKey: CatConstants.BoundaryRecovery.actionKey) == nil else {
                continue
            }

            // Skip cats in the middle of a fright reaction
            guard cat.node.action(forKey: "frightReaction") == nil,
                  cat.containerNode.action(forKey: "frightMove") == nil else {
                cat.outOfBoundsSince = nil
                continue
            }

            if cat.isOutOfBounds() {
                if cat.outOfBoundsSince == nil {
                    cat.outOfBoundsSince = CACurrentMediaTime()
                }
                guard let since = cat.outOfBoundsSince else { continue }
                let elapsed = CACurrentMediaTime() - since
                if elapsed >= CatConstants.BoundaryRecovery.gracePeriod {
                    let targetX = cat.nearestValidX()
                    cat.movementComponent.walkBackIntoBounds(targetX: targetX)
                }
            } else {
                cat.outOfBoundsSince = nil
            }
        }
        applySoftSeparation()
    }

    /// Gently push overlapping cats apart each frame (spring-damper model).
    private func applySoftSeparation() {
        let catArray = Array(cats.values)
        let count = catArray.count
        guard count >= 2 else { return }

        let minDist = CatConstants.Separation.minDistance
        let nudgeSpeed = CatConstants.Separation.nudgeSpeed

        // Accumulate nudge deltas to avoid order bias
        var nudges = [ObjectIdentifier: CGFloat]()

        for i in 0..<count {
            let catA = catArray[i]
            guard catA.currentState != .taskComplete,
                  catA.currentState != .eating,
                  catA.containerNode.action(forKey: "frightMove") == nil,
                  catA.containerNode.action(forKey: CatConstants.BoundaryRecovery.actionKey) == nil
            else { continue }

            for j in (i + 1)..<count {
                let catB = catArray[j]
                guard catB.currentState != .taskComplete,
                      catB.currentState != .eating,
                      catB.containerNode.action(forKey: "frightMove") == nil,
                      catB.containerNode.action(forKey: CatConstants.BoundaryRecovery.actionKey) == nil
                else { continue }

                let xA = catA.containerNode.position.x
                let xB = catB.containerNode.position.x
                let dist = abs(xA - xB)

                guard dist < minDist else { continue }

                let overlap = minDist - dist
                let nudgeMag = min(overlap * 0.1, nudgeSpeed)

                let direction: CGFloat
                if xA < xB {
                    direction = -1
                } else if xA > xB {
                    direction = 1
                } else {
                    direction = Bool.random() ? 1 : -1
                }

                let idA = ObjectIdentifier(catA)
                let idB = ObjectIdentifier(catB)
                nudges[idA, default: 0] += nudgeMag * direction
                nudges[idB, default: 0] -= nudgeMag * direction
            }
        }

        // Apply accumulated nudges, clamped to activity bounds
        for cat in catArray {
            let id = ObjectIdentifier(cat)
            guard let nudge = nudges[id], abs(nudge) > 0.01 else { continue }

            let currentX = cat.containerNode.position.x
            let newX = max(cat.activityMin, min(cat.effectiveActivityMax, currentX + nudge))
            cat.containerNode.position.x = newX
        }
    }

    /// Find a spawn X that is at least minSpawnDistance from any existing cat.
    private func findNonOverlappingSpawnX() -> CGFloat {
        let minDist = CatConstants.Separation.minSpawnDistance
        let existingPositions = cats.values.map { $0.containerNode.position.x }

        guard !existingPositions.isEmpty else {
            return CGFloat.random(in: activityBounds)
        }

        var bestX = CGFloat.random(in: activityBounds)
        var bestMinDist: CGFloat = existingPositions.map { abs($0 - bestX) }.min() ?? .infinity

        for _ in 0..<CatConstants.Separation.maxSpawnAttempts {
            let candidateX = CGFloat.random(in: activityBounds)
            let nearestDist = existingPositions.map { abs($0 - candidateX) }.min() ?? .infinity

            if nearestDist >= minDist {
                return candidateX
            }
            if nearestDist > bestMinDist {
                bestMinDist = nearestDist
                bestX = candidateX
            }
        }

        return bestX
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
            groundNode?.physicsBody?.friction = CatConstants.Scene.groundFriction
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

    // MARK: - Bed Slot Management

    func assignBedSlot(for sessionId: String) -> CGFloat? {
        // Already assigned?
        if let slot = activeBedSlots[sessionId] {
            return bedSlotX(for: slot)
        }
        // Find first available slot
        let usedSlots = Set(activeBedSlots.values)
        for slot in 0..<CatConstants.TaskComplete.maxSlots where !usedSlots.contains(slot) {
            activeBedSlots[sessionId] = slot
            return bedSlotX(for: slot)
        }
        return nil // All slots full
    }

    func releaseBedSlot(for sessionId: String) {
        activeBedSlots.removeValue(forKey: sessionId)
    }

    func bedColorName(for sessionId: String) -> String? {
        guard let slot = activeBedSlots[sessionId] else { return nil }
        let names = CatConstants.TaskComplete.bedNames
        return names[slot % names.count]
    }

    private func bedSlotX(for slot: Int) -> CGFloat {
        activityBounds.upperBound + CatConstants.TaskComplete.firstSlotOffset
            + CGFloat(slot) * CatConstants.TaskComplete.slotSpacing
    }
}

// MARK: - SceneControlling

extension BuddyScene: SceneControlling {
    func catSnapshot(for sessionId: String) -> CatSnapshot? {
        guard let cat = cats[sessionId] else { return nil }
        return CatSnapshot(
            sessionId: cat.sessionId,
            x: cat.containerNode.position.x,
            y: cat.containerNode.position.y,
            state: cat.currentState.rawValue,
            facingRight: cat.facingRight,
            isDebug: cat.isDebugCat,
            activityBoundsMin: cat.activityMin,
            activityBoundsMax: cat.activityMax
        )
    }

    func allCatSnapshots() -> [CatSnapshot] {
        cats.values.map { cat in
            CatSnapshot(
                sessionId: cat.sessionId,
                x: cat.containerNode.position.x,
                y: cat.containerNode.position.y,
                state: cat.currentState.rawValue,
                facingRight: cat.facingRight,
                isDebug: cat.isDebugCat,
                activityBoundsMin: cat.activityMin,
                activityBoundsMax: cat.activityMax
            )
        }
    }

    func sceneSnapshot() -> SceneSnapshot {
        SceneSnapshot(
            visible: view != nil,
            catsRendered: cats.count,
            boundsMin: activityBounds.lowerBound,
            boundsMax: activityBounds.upperBound
        )
    }
}
