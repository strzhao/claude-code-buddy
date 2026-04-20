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

    /// Called when the required window height changes due to token level changes.
    var onWindowHeightNeeded: ((CGFloat) -> Void)?

    /// Tracks the last known token level per session for change detection.
    private var lastKnownTokenLevels: [String: TokenLevel] = [:]

    private var leftBoundaryNode: SKSpriteNode?
    private var rightBoundaryNode: SKSpriteNode?

    private let sceneEnvironment = SceneEnvironment()
    private var cancellables = Set<AnyCancellable>()

    func updateSessionsCache(_ sessions: [SessionInfo]) {
        cachedSessions = sessions

        // Check for token level changes and apply scaling
        var windowHeightChanged = false
        for session in sessions {
            guard let cat = cats[session.sessionId] else { continue }
            let newLevel = TokenLevel.from(totalTokens: session.totalTokens)
            let oldLevel = lastKnownTokenLevels[session.sessionId] ?? .lv1

            if newLevel != oldLevel {
                lastKnownTokenLevels[session.sessionId] = newLevel
                cat.applyTokenLevel(totalTokens: session.totalTokens)

                // Play level-up animation when level increases
                if newLevel > oldLevel {
                    cat.playLevelUpAnimation()
                    showLevelUpPopup(
                        at: cat.containerNode.position,
                        level: newLevel,
                        tokens: session.totalTokens,
                        color: session.color
                    )
                }
                windowHeightChanged = true
            }
        }

        if windowHeightChanged {
            recalculateWindowHeight()
        }
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
        let skin = SkinPackManager.shared.activeSkin
        guard let url = skin.url(forResource: skin.manifest.boundarySprite,
                                 withExtension: "png",
                                 subdirectory: skin.manifest.spriteDirectory),
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
        lastKnownTokenLevels.removeValue(forKey: sessionId)
        // Keep a strong ref to cat until exit animation completes, then remove node
        if sessionId == hoveredCatSessionId {
            hoveredCatSessionId = nil
        }
        // Collect remaining cats as obstacles for the jump animation
        let obstacles: [(cat: CatSprite, x: CGFloat)] = cats.values.map { ($0, $0.containerNode.position.x) }
        cat.exitScene(sceneWidth: size.width, obstacles: obstacles, onJumpOver: { [weak cat] jumpedCat in
            guard cat != nil else { return }
            jumpedCat.playFrightReaction(awayFromX: cat?.containerNode.position.x ?? 0)
        }, completion: { [cat, weak self] in
            cat.containerNode.removeFromParent()
            self?.recalculateWindowHeight()
        })
    }

    func updateCatState(sessionId: String, state: CatState, toolDescription: String? = nil) {
        guard let cat = cats[sessionId] else { return }
        cat.switchState(to: state, toolDescription: toolDescription)
        foodManager.updateCatIdleState(sessionId: sessionId, isIdle: state == .idle)
        // When a cat becomes idle/thinking/toolUse, check for existing landed food
        if state == .idle || state == .thinking || state == .toolUse {
            foodManager.notifyCatAboutLandedFood(cat)
        }
    }

    var activeCatCount: Int { cats.count }

    func removePersistentBadge(for sessionId: String) {
        cats[sessionId]?.removePersistentBadge()
    }

    func acknowledgePermission(for sessionId: String) {
        guard let cat = cats[sessionId], cat.currentState == .permissionRequest else { return }
        cat.permissionAcknowledged = true
    }

    func catAtPoint(_ point: CGPoint) -> String? {
        let baseSize = CatSprite.hitboxSize
        for (sessionId, cat) in cats {
            let catPos = cat.containerNode.position
            let scale = cat.tokenScale
            let scaledWidth = baseSize.width * scale
            let scaledHeight = baseSize.height * scale
            let rect = CGRect(
                x: catPos.x - scaledWidth / 2,
                y: catPos.y - scaledHeight / 2,
                width: scaledWidth,
                height: scaledHeight
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

        // Include token level info in tooltip if above Lv1
        var label = info.label
        if cat.currentTokenLevel.rawValue > 1 {
            label += " | " + cat.currentTokenLevel.tooltipText(tokens: info.totalTokens)
        }

        tooltipNode.show(label: label, color: info.color, at: cat.containerNode.position, sceneSize: size)
    }

    func hideTooltip() {
        tooltipNode.hide()
    }

    // MARK: - Level-Up Popup

    /// Show a temporary popup label above a cat when it levels up.
    func showLevelUpPopup(at catPosition: CGPoint, level: TokenLevel, tokens: Int, color: SessionColor) {
        let text = level.levelUpText(tokens: tokens)

        let shadow = SKLabelNode(text: text)
        shadow.fontName = NSFont.boldSystemFont(ofSize: CatConstants.LevelUp.popupFontSize).fontName
        shadow.fontSize = CatConstants.LevelUp.popupFontSize
        shadow.fontColor = color.nsColor.withAlphaComponent(0.5)
        shadow.horizontalAlignmentMode = .center
        shadow.verticalAlignmentMode = .bottom
        shadow.position = CGPoint(x: 1, y: -1)
        shadow.zPosition = 0

        let label = SKLabelNode(text: text)
        label.fontName = NSFont.boldSystemFont(ofSize: CatConstants.LevelUp.popupFontSize).fontName
        label.fontSize = CatConstants.LevelUp.popupFontSize
        label.fontColor = color.nsColor
        label.horizontalAlignmentMode = .center
        label.verticalAlignmentMode = .bottom
        label.zPosition = 1

        let popup = SKNode()
        popup.addChild(shadow)
        popup.addChild(label)

        // Position above cat, clamped to scene bounds
        let x = max(40, min(catPosition.x, size.width - 40))
        let y = catPosition.y + CatConstants.LevelUp.popupYOffset
        popup.position = CGPoint(x: x, y: y)
        popup.zPosition = 100
        popup.alpha = 0

        addChild(popup)

        let fadeIn = SKAction.fadeIn(withDuration: 0.15)
        let wait = SKAction.wait(forDuration: CatConstants.LevelUp.popupDisplayDuration)
        let fadeOut = SKAction.fadeOut(withDuration: CatConstants.LevelUp.popupFadeOutDuration)
        let remove = SKAction.removeFromParent()
        popup.run(SKAction.sequence([fadeIn, wait, fadeOut, remove]))
    }

    // MARK: - Window Height Management

    /// Recalculate the required window height based on the max token level of all cats.
    private func recalculateWindowHeight() {
        let maxLevel = cats.values.map(\.currentTokenLevel).max() ?? .lv1
        onWindowHeightNeeded?(maxLevel.windowHeight)
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

        let baseMinDist = CatConstants.Separation.minDistance
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

                // Scale-aware minimum distance
                let minDist = max(catA.tokenScale, catB.tokenScale) * baseMinDist

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

    func foodEligibleCats() -> [CatSprite] {
        cats.values.filter { [.idle, .thinking, .toolUse].contains($0.currentState) }
    }

    // MARK: - Skin Hot-Swap

    func reloadSkin(_ skin: SkinPack) {
        // 1. Reload boundary decoration textures
        if let tex = loadBoundaryTexture() {
            leftBoundaryNode?.texture = tex
            rightBoundaryNode?.texture = tex
        }

        // 2. Reload each cat's textures asynchronously and restart animations when done
        for cat in cats.values {
            // Clean up all running actions to prevent stale frame references
            cat.node.removeAllActions()
            cat.containerNode.removeAction(forKey: "randomWalk")
            cat.containerNode.removeAction(forKey: "foodWalk")

            // Skip eating cats — CatEatingState has no ResumableState;
            // eating animation completes naturally, next state uses new textures
            if cat.currentState == .eating { continue }

            // Load textures in background, then resume animation on main thread
            cat.animationComponent.loadTexturesAsync(from: skin) { [weak cat] in
                guard let cat else { return }

                // Reload bed texture for sleeping cats
                if cat.currentState == .taskComplete {
                    (cat.stateMachine?.currentState as? CatTaskCompleteState)?
                        .reloadBedTexture(from: skin)
                }

                // Restart current state animation via ResumableState
                (cat.stateMachine?.currentState as? ResumableState)?.resume()

                // Reapply session color tint
                cat.node.color = cat.sessionColor?.nsColor ?? .white
                cat.node.colorBlendFactor = cat.sessionTintFactor
            }

            // Restore token scale (skin reload may reset containerNode scale)
            cat.containerNode.setScale(cat.tokenScale)
        }
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
        let names = SkinPackManager.shared.activeSkin.effectiveBedNames
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
        let labelHidden = cat.labelNode?.isHidden ?? true
        let tabHidden = cat.tabNameNode?.isHidden ?? true
        return CatSnapshot(
            sessionId: cat.sessionId,
            x: cat.containerNode.position.x,
            y: cat.containerNode.position.y,
            state: cat.currentState.rawValue,
            facingRight: cat.facingRight,
            isDebug: cat.isDebugCat,
            activityBoundsMin: cat.activityMin,
            activityBoundsMax: cat.activityMax,
            labelText: labelHidden ? nil : cat.labelNode?.text,
            tabName: tabHidden ? nil : cat.tabNameNode?.text,
            hasAlertOverlay: cat.alertOverlayNode != nil,
            hasPersistentBadge: cat.persistentBadgeNode != nil,
            permissionAcknowledged: cat.permissionAcknowledged
        )
    }

    func allCatSnapshots() -> [CatSnapshot] {
        cats.values.map { cat in
            let labelHidden = cat.labelNode?.isHidden ?? true
            let tabHidden = cat.tabNameNode?.isHidden ?? true
            return CatSnapshot(
                sessionId: cat.sessionId,
                x: cat.containerNode.position.x,
                y: cat.containerNode.position.y,
                state: cat.currentState.rawValue,
                facingRight: cat.facingRight,
                isDebug: cat.isDebugCat,
                activityBoundsMin: cat.activityMin,
                activityBoundsMax: cat.activityMax,
                labelText: labelHidden ? nil : cat.labelNode?.text,
                tabName: tabHidden ? nil : cat.tabNameNode?.text,
                hasAlertOverlay: cat.alertOverlayNode != nil,
                hasPersistentBadge: cat.persistentBadgeNode != nil,
                permissionAcknowledged: cat.permissionAcknowledged
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

    func simulateClick(sessionId: String) -> Bool {
        guard cats[sessionId] != nil else { return false }
        acknowledgePermission(for: sessionId)
        removePersistentBadge(for: sessionId)
        return true
    }
}
