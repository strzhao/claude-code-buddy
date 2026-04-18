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
    private var cats: [String: CatEntity] = [:]
    /// Authoritative mirror of all active entities (CatEntity + RocketEntity).
    /// `cats` remains a typed view for cat-specific code paths.
    private var entities: [String: SessionEntity] = [:]
    private let maxCats = CatConstants.Scene.maxCats

    private lazy var tooltipNode: TooltipNode = {
        let node = TooltipNode()
        addChild(node)
        return node
    }()

    private var cachedSessions: [SessionInfo] = []

    private(set) var foodManager = FoodManager()

    private var hoveredCatSessionId: String?
    /// When non-nil, BuddyScene repositions tooltipNode each frame so it follows
    /// the entity's current position (rocket can drift while cruising).
    private var tooltipFollowSessionId: String?

    /// Tracks which bed slots are in use (sessionId → slot index).
    private var activeBedSlots: [String: Int] = [:]

    /// Activity bounds for cat movement. Updated by AppDelegate when Dock changes.
    var activityBounds: ClosedRange<CGFloat> = 48...752 {
        didSet { propagateActivityBounds() }
    }

    private var leftBoundaryNode: SKSpriteNode?
    private var rightBoundaryNode: SKSpriteNode?

    /// sessionId of the currently-active Starship 3, if any. Used to enforce the
    /// at-most-one rule and to drive the Mechazilla right tower swap.
    private var activeStarshipSessionId: String?

    /// Cached Mechazilla textures (closed / open) — loaded once on first use.
    private var mechazillaClosedTexture: SKTexture?
    private var mechazillaOpenTexture: SKTexture?
    private var mechazillaHalfTexture: SKTexture?

    /// Orbital Launch Mount — trapezoidal concrete slab the Starship sits on.
    /// Shown only while a Starship is on scene.
    private var olmNode: SKNode?

    private let sceneEnvironment = SceneEnvironment()
    private var cancellables = Set<AnyCancellable>()

    func updateSessionsCache(_ sessions: [SessionInfo]) {
        cachedSessions = sessions
    }

    // MARK: Lifecycle

    override func didMove(to view: SKView) {
        backgroundColor = .clear
        // Honour `zPosition` as the sole render-order key across siblings.
        // Required so the Starship liftoff flame (z=-0.3) renders BEHIND the
        // OLM (z=-0.2) regardless of which was added to the scene first.
        view.ignoresSiblingOrder = true
        setupPhysics()
        setupGround()
        setupBoundaryDecorations()
        foodManager.scene = self
        foodManager.start()

        // Wire EntityFactory's starship-uniqueness check to our scene state.
        EntityFactory.hasActiveStarship = { [weak self] in
            self?.hasStarship() ?? false
        }

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

    private static let boundaryRenderSizeCat = CGSize(width: 32, height: 32)
    private static let boundaryRenderSizeRocket = CGSize(width: 32, height: 68)

    private func boundaryRenderSize(for mode: EntityMode) -> CGSize {
        switch mode {
        case .cat:    return Self.boundaryRenderSizeCat
        case .rocket: return Self.boundaryRenderSizeRocket
        }
    }

    /// Loads a boundary-strip texture by name. Tries the active skin pack
    /// first (user-skinnable cat boundary art), falling back to the built-in
    /// bundle so rocket-mode assets (boundary-mechazilla*) — which are not
    /// part of user-uploaded skins — still resolve.
    private func loadBoundaryTexture(named name: String) -> SKTexture? {
        let skin = SkinPackManager.shared.activeSkin
        let url = skin.url(forResource: name,
                           withExtension: "png",
                           subdirectory: skin.manifest.spriteDirectory)
            ?? ResourceBundle.bundle.url(forResource: name,
                                         withExtension: "png",
                                         subdirectory: "Assets/Sprites")
        guard let url,
              let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            return nil
        }
        let tex = SKTexture(cgImage: cgImage)
        tex.filteringMode = .nearest
        return tex
    }

    private func boundaryTextureName(for mode: EntityMode) -> String {
        switch mode {
        case .cat:    return "boundary-bush"
        // Rocket mode always uses Mechazilla towers — both sides, even when
        // no Starship is on scene.
        case .rocket: return "boundary-mechazilla"
        }
    }

    private func setupBoundaryDecorations() {
        let currentMode = EntityModeStore.shared.current
        let tex = loadBoundaryTexture(named: boundaryTextureName(for: currentMode))
        let renderSize = boundaryRenderSize(for: currentMode)

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

        // Keep boundary textures in sync with mode changes (hot-switch).
        EventBus.shared.entityModeChanged
            .receive(on: RunLoop.main)
            .sink { [weak self] change in
                self?.applyBoundaryTexture(for: change.next)
            }
            .store(in: &cancellables)
    }

    private func applyBoundaryTexture(for mode: EntityMode) {
        let tex = loadBoundaryTexture(named: boundaryTextureName(for: mode))
        let renderSize = boundaryRenderSize(for: mode)
        leftBoundaryNode?.texture = tex
        leftBoundaryNode?.size = renderSize
        leftBoundaryNode?.color = tex == nil ? .green : .white
        leftBoundaryNode?.position = CGPoint(
            x: activityBounds.lowerBound - renderSize.width / 2 - 2,
            y: renderSize.height / 2
        )
        rightBoundaryNode?.texture = tex
        rightBoundaryNode?.size = renderSize
        rightBoundaryNode?.color = tex == nil ? .green : .white
        rightBoundaryNode?.position = CGPoint(
            x: activityBounds.upperBound + renderSize.width / 2 + 2,
            y: renderSize.height / 2
        )
        // Re-apply Starship dressing after a mode swap so the left boundary
        // stays hidden / Mechazilla stays on the right while a Starship is still
        // on scene.
        applyStarshipSceneAdjustments()
    }

    private func updateBoundaryPositions() {
        let renderSize = boundaryRenderSize(for: EntityModeStore.shared.current)
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

        let cat = CatEntity(sessionId: sessionId)
        cat.configure(color: info.color, labelText: info.label)

        // Random horizontal spawn position within activity bounds
        let spawnX = findNonOverlappingSpawnX()
        cat.containerNode.position = CGPoint(x: spawnX, y: CatConstants.Visual.groundY) // ground level

        addChild(cat.containerNode)
        cats[sessionId] = cat
        entities[sessionId] = cat
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
        entities.removeValue(forKey: sessionId)
        foodManager.removeCatTracking(sessionId: sessionId)
        releaseBedSlot(for: sessionId)
        // Keep a strong ref to cat until exit animation completes, then remove node
        if sessionId == hoveredCatSessionId {
            hoveredCatSessionId = nil
        }
        // Collect remaining cats as obstacles for the jump animation
        let obstacles: [(cat: CatEntity, x: CGFloat)] = cats.values.map { ($0, $0.containerNode.position.x) }
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

    var activeCatCount: Int { entities.count }

    // MARK: - Entity Management (mode-agnostic)

    func addEntity(info: SessionInfo, mode: EntityMode) {
        switch mode {
        case .cat:
            addCat(info: info)
        case .rocket:
            let sessionId = info.sessionId
            guard entities[sessionId] == nil else { return }
            // Route through EntityFactory so the rocket kind (classic/F9/Starship)
            // is consistent with what the rest of the app expects.
            guard let rocket = EntityFactory.make(mode: .rocket,
                                                  sessionId: sessionId) as? RocketEntity else { return }
            rocket.configure(color: info.color, labelText: info.label)

            // Starship 3 spawns near the right tower, not at a random x.
            let spawnX: CGFloat
            if rocket.kind == .starship3 {
                spawnX = max(activityBounds.lowerBound,
                             activityBounds.upperBound - RocketConstants.Starship.rightTowerPadding)
            } else {
                // Other rockets must not encroach on Starship's OLM area.
                let upper = effectiveUpperBound(for: rocket.kind)
                let lower = min(activityBounds.lowerBound, upper)
                spawnX = CGFloat.random(in: lower...upper)
            }
            // Kind-specific init y (Starship sits higher to keep its booster
            // nozzle on OLM top). Pad uses per-instance padVisibleY.
            rocket.containerNode.position = CGPoint(
                x: spawnX,
                y: rocket.kind.containerInitY
            )
            addChild(rocket.containerNode)
            // Pad sits at scene level so it doesn't follow horizontal drift.
            rocket.padNode.position = CGPoint(x: spawnX, y: rocket.padVisibleY)
            addChild(rocket.padNode)
            entities[sessionId] = rocket
            if rocket.kind == .starship3 {
                activeStarshipSessionId = sessionId
                applyStarshipSceneAdjustments()
            }
            rocket.enterScene(sceneSize: size, activityBounds: activityBounds)
        }
    }

    func removeEntity(sessionId: String) {
        if cats[sessionId] != nil {
            removeCat(sessionId: sessionId)
            return
        }
        guard let entity = entities.removeValue(forKey: sessionId) else { return }
        if sessionId == activeStarshipSessionId {
            activeStarshipSessionId = nil
            applyStarshipSceneAdjustments()
        }
        entity.exitScene(sceneWidth: size.width) {
            entity.containerNode.removeFromParent()
            if let rocket = entity as? RocketEntity {
                rocket.padNode.removeFromParent()
                rocket.setBoosterIgnited(false)  // tear down scene-level plume if still up
            }
        }
    }

    func replaceAllEntities(with mode: EntityMode,
                            infos: [SessionInfo],
                            lastEvents: [String: EntityInputEvent],
                            onOldEntitiesExited: (() -> Void)? = nil,
                            completion: @escaping () -> Void) {
        let group = DispatchGroup()
        let snapshot = entities
        entities.removeAll()
        cats.removeAll()
        activeStarshipSessionId = nil
        // Tear down the OLM now (it belongs to the soon-to-exit Starship)
        // but LEAVE the boundary textures alone — we don't want to swap
        // the right tower to Mechazilla mid cat-exit-animation while the
        // left side is still a tree. The midway hook below drives the
        // coordinated left+right swap via applyBoundaryTexture.
        olmNode?.removeFromParent()
        olmNode = nil
        for (_, entity) in snapshot {
            group.enter()
            entity.exitScene(sceneWidth: size.width) {
                entity.containerNode.removeFromParent()
                if let rocket = entity as? RocketEntity {
                    rocket.padNode.removeFromParent()
                    rocket.setBoosterIgnited(false)  // tear down scene-level plume
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }

            // Clean up lingering scene-level decorations that were owned
            // by the old mode's entities but parented to the scene
            // directly (and therefore survived containerNode removal):
            //   - Cat beds (named "bed_<sessionId>") from CatTaskCompleteState
            for child in self.children where child.name?.hasPrefix("bed_") == true {
                child.removeFromParent()
            }
            self.activeBedSlots.removeAll()

            // Midway hook — after old entities have finished exiting and
            // old-mode decorations are cleaned up, BEFORE new entities spawn.
            // SessionManager uses this to swap boundary artwork so rockets
            // don't briefly stand next to cat-mode trees (or vice versa).
            onOldEntitiesExited?()

            for info in infos {
                self.addEntity(info: info, mode: mode)
                if let e = lastEvents[info.sessionId] {
                    self.entities[info.sessionId]?.handle(event: e)
                }
            }
            completion()
        }
    }

    /// Dispatch an input event to the current entity for a session, whichever form it is.
    func dispatchEntityEvent(sessionId: String, event: EntityInputEvent) {
        entities[sessionId]?.handle(event: event)
    }

    /// Returns an x-position within activity bounds where a pad can land without
    /// overlapping other currently-visible pads. Flying rockets (pad hidden) are ignored.
    func findSafeLandingX(excluding sessionId: String, near preferredX: CGFloat) -> CGFloat {
        let separation = RocketConstants.Visual.spriteSize.width - 4   // ~44pt gap
        let occupied: [CGFloat] = entities.compactMap { sid, ent -> CGFloat? in
            guard sid != sessionId,
                  let rocket = ent as? RocketEntity,
                  !rocket.padNode.isHidden else { return nil }
            return rocket.padNode.position.x
        }

        func overlaps(_ x: CGFloat) -> Bool {
            occupied.contains { abs($0 - x) < separation }
        }
        if !overlaps(preferredX) { return preferredX }

        let halfSprite = RocketConstants.Visual.spriteSize.width / 2
        let leftBound = activityBounds.lowerBound + halfSprite
        let rightBound = min(activityBounds.upperBound - halfSprite,
                             effectiveUpperBound(for: .classic))
        // Note: .classic is a stand-in — effectiveUpperBound returns the same
        // value for all non-starship kinds.

        var delta = separation
        let maxDelta = max(rightBound - leftBound, separation)
        while delta <= maxDelta {
            for candidate in [preferredX + delta, preferredX - delta] {
                if candidate >= leftBound && candidate <= rightBound && !overlaps(candidate) {
                    return candidate
                }
            }
            delta += separation / 2
        }
        return preferredX
    }

    func catAtPoint(_ point: CGPoint) -> String? {
        let hitSize = CatEntity.hitboxSize
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

    /// Mode-agnostic hit test: returns the sessionId of a cat OR rocket under `point`.
    func entityAtPoint(_ point: CGPoint) -> String? {
        if let id = catAtPoint(point) { return id }
        for (sid, entity) in entities {
            guard let rocket = entity as? RocketEntity else { continue }
            let hit = RocketConstants.Visual.hitboxSize
            let pos = rocket.containerNode.position
            let rect = CGRect(
                x: pos.x - hit.width / 2,
                y: pos.y - hit.height / 2,
                width: hit.width,
                height: hit.height
            )
            if rect.contains(point) { return sid }
        }
        return nil
    }

    // MARK: - Private Helpers

    private func propagateActivityBounds() {
        for cat in cats.values {
            cat.updateActivityBounds(activityBounds)
        }
        for case let rocket as RocketEntity in entities.values {
            rocket.updateActivityBounds(activityBounds)
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
        guard let info = cachedSessions.first(where: { $0.sessionId == sessionId }) else { return }
        let shortLabel = Self.truncate(info.label, max: 12)

        if let cat = cats[sessionId] {
            guard cat.currentState != .permissionRequest else { return }
            tooltipFollowSessionId = sessionId
            tooltipNode.show(label: shortLabel, color: info.color,
                             at: cat.containerNode.position, sceneSize: size)
            return
        }
        if let rocket = entities[sessionId] as? RocketEntity {
            tooltipFollowSessionId = sessionId
            tooltipNode.show(label: shortLabel, color: info.color,
                             at: rocket.containerNode.position, sceneSize: size)
        }
    }

    private static func truncate(_ label: String, max: Int) -> String {
        guard label.count > max else { return label }
        return String(label.prefix(max - 1)) + "…"
    }

    func hideTooltip() {
        tooltipFollowSessionId = nil
        tooltipNode.hide()
    }

    /// Per-frame mouse-over detection. NSEvent.mouseMoved only fires on movement,
    /// so a stationary cursor won't re-hit a rocket that drifts underneath it. We
    /// poll each frame to cover both rocket-moves-into-cursor and cursor-moves-off-rocket.
    private func pollMouseHover() {
        guard let view = self.view, let window = view.window else { return }
        let screenPoint = NSEvent.mouseLocation
        let windowFrame = NSRect(origin: screenPoint, size: .zero)
        let windowPoint = window.convertPoint(fromScreen: windowFrame.origin)
        let viewPoint = view.convert(windowPoint, from: nil)
        let scenePoint = convertPoint(fromView: viewPoint)

        let hit = entityAtPoint(scenePoint)
        if let sid = hit {
            if tooltipFollowSessionId != sid {
                showTooltip(for: sid)
                setHovered(sessionId: sid, hovered: true)
            }
        } else if let prev = tooltipFollowSessionId {
            hideTooltip()
            setHovered(sessionId: prev, hovered: false)
        }
    }

    /// Keeps the tooltip pinned above whichever entity it's currently attached to.
    /// Called from `update(_:)` each frame.
    private func updateTooltipFollow() {
        guard let sid = tooltipFollowSessionId else { return }
        let anchor: CGPoint
        if let cat = cats[sid] {
            anchor = cat.containerNode.position
        } else if let rocket = entities[sid] as? RocketEntity {
            anchor = rocket.containerNode.position
        } else {
            tooltipFollowSessionId = nil
            return
        }
        tooltipNode.place(at: anchor, sceneSize: size)
    }

    // MARK: - Hover

    func setHovered(sessionId: String, hovered: Bool) {
        if hovered {
            if let prev = hoveredCatSessionId, prev != sessionId {
                entities[prev]?.removeHoverScale()
            }
            hoveredCatSessionId = sessionId
            entities[sessionId]?.applyHoverScale()
        } else {
            if hoveredCatSessionId == sessionId {
                hoveredCatSessionId = nil
            }
            entities[sessionId]?.removeHoverScale()
        }
    }

    func clearHover() {
        if let sessionId = hoveredCatSessionId {
            entities[sessionId]?.removeHoverScale()
            hoveredCatSessionId = nil
        }
    }

    // MARK: - Per-Frame Update

    override func update(_ currentTime: TimeInterval) {
        super.update(currentTime)

        pollMouseHover()
        updateTooltipFollow()

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

    func idleCats() -> [CatEntity] {
        cats.values.filter { $0.currentState == .idle }
    }

    // MARK: - Skin Hot-Swap

    func reloadSkin(_ skin: SkinPack) {
        // 1. Reload boundary decoration textures — honors current entity mode
        // so skin hot-swap doesn't drop the Mechazilla dressing on rocket side.
        let mode = EntityModeStore.shared.current
        if let tex = loadBoundaryTexture(named: boundaryTextureName(for: mode)) {
            leftBoundaryNode?.texture = tex
            rightBoundaryNode?.texture = tex
        }

        // 2. Reload each cat's textures and restart animations
        for cat in cats.values {
            // Clean up all running actions to prevent stale frame references
            cat.node.removeAllActions()
            cat.containerNode.removeAction(forKey: "randomWalk")
            cat.containerNode.removeAction(forKey: "foodWalk")

            // Reload textures from the new skin
            cat.animationComponent.loadTextures(from: skin)

            // Skip eating cats — CatEatingState has no ResumableState;
            // eating animation completes naturally, next state uses new textures
            if cat.currentState == .eating { continue }

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
        let names = SkinPackManager.shared.activeSkin.manifest.bedNames
        return names[slot % names.count]
    }

    private func bedSlotX(for slot: Int) -> CGFloat {
        activityBounds.upperBound + CatConstants.TaskComplete.firstSlotOffset
            + CGFloat(slot) * CatConstants.TaskComplete.slotSpacing
    }

    // MARK: - Starship 3 scene adjustments

    /// Returns true when a Starship 3 is currently on scene. Exposed to
    /// EntityFactory so it can skip `.starship3` in the kind rotation.
    func hasStarship() -> Bool {
        activeStarshipSessionId != nil
    }

    /// Swings the Mechazilla chopstick arms open or closed. No-op if the
    /// right-boundary node isn't currently in Mechazilla mode (i.e. no
    /// Starship on scene).
    ///
    /// - Parameters:
    ///   - open: `true` = arms retracted (open). `false` = arms extended (closed).
    ///   - animated: when `true`, plays the 3-frame closed↔half↔open animation
    ///     over `RocketConstants.Starship.chopstickAnimationDuration`. Otherwise
    ///     snaps instantly to the target texture.
    func setChopsticks(open: Bool, animated: Bool = false) {
        guard activeStarshipSessionId != nil else { return }
        loadMechazillaTexturesIfNeeded()
        guard let node = rightBoundaryNode else { return }

        // Only the RIGHT (real) Mechazilla animates. The LEFT tower is a
        // static mirrored dressing and must NOT follow liftoff/catch state.
        node.removeAction(forKey: "chopsticks")

        if animated,
           let closed = mechazillaClosedTexture,
           let half = mechazillaHalfTexture,
           let opened = mechazillaOpenTexture {
            let frames: [SKTexture] = open
                ? [closed, half, opened]
                : [opened, half, closed]
            let total = RocketConstants.Starship.chopstickAnimationDuration
            let timePerFrame = total / Double(frames.count)
            let animate = SKAction.animate(with: frames, timePerFrame: timePerFrame)
            node.run(animate, withKey: "chopsticks")
        } else {
            node.texture = open ? mechazillaOpenTexture : mechazillaClosedTexture
        }
    }

    private func loadMechazillaTexturesIfNeeded() {
        if mechazillaClosedTexture == nil {
            mechazillaClosedTexture = loadBoundaryTexture(named: "boundary-mechazilla")
        }
        if mechazillaOpenTexture == nil {
            mechazillaOpenTexture = loadBoundaryTexture(named: "boundary-mechazilla-open")
        }
        if mechazillaHalfTexture == nil {
            mechazillaHalfTexture = loadBoundaryTexture(named: "boundary-mechazilla-half")
        }
    }

    /// Applies (or reverts) the Starship-specific scene dressing: swap the RIGHT
    /// tower to Mechazilla while a Starship is on scene. Left boundary stays
    /// visible as the normal mode-decoration (both launch towers shown).
    private func applyStarshipSceneAdjustments() {
        // Two responsibilities:
        //   1) Manage OLM lifecycle — only while a Starship is active.
        //   2) Reset the right tower to the CLOSED Mechazilla texture when
        //      the Starship leaves AND we're still in rocket mode. In cat
        //      mode the right boundary is a bush, so we must NOT overwrite
        //      it with Mechazilla (bug: previously this fired on every
        //      entity add/remove regardless of mode).
        if activeStarshipSessionId != nil {
            ensureOLM()
        } else {
            olmNode?.removeFromParent()
            olmNode = nil
            guard EntityModeStore.shared.current == .rocket else { return }
            loadMechazillaTexturesIfNeeded()
            if let tex = mechazillaClosedTexture {
                rightBoundaryNode?.texture = tex
            }
        }
    }

    /// Right-edge cap for non-Starship rockets. Starship's spot at the OLM is
    /// reserved permanently — other rockets are capped regardless of whether
    /// a Starship is currently on scene. Returns the OLM's left edge minus
    /// half a sprite so rockets stay fully clear of the mount.
    func effectiveUpperBound(for kind: RocketKind) -> CGFloat {
        let fullUpper = activityBounds.upperBound
        guard kind != .starship3 else { return fullUpper }
        let olmCenter = activityBounds.upperBound - RocketConstants.Starship.rightTowerPadding
        let olmHalfBottomWidth: CGFloat = 11
        let halfSprite = RocketConstants.Visual.spriteSize.width / 2
        return min(fullUpper, olmCenter - olmHalfBottomWidth - halfSprite)
    }

    /// Canonical x for the Starship's OLM / launch-liftoff-land position.
    func starshipAnchorX() -> CGFloat {
        activityBounds.upperBound - RocketConstants.Starship.rightTowerPadding
    }

    /// Builds the Orbital Launch Mount under the Starship spawn x. Open-truss
    /// design: a wide top deck sits on three NARROW pillars with large vent
    /// gaps between them, so the booster's exhaust plume is visible through
    /// the mount at liftoff. A thin mid-height cross-brace hints at
    /// structural framework without obstructing the flame.
    private func ensureOLM() {
        guard olmNode == nil else { return }

        let fill  = NSColor(red: 0.42, green: 0.42, blue: 0.45, alpha: 1.0)
        let outline = NSColor(red: 0.18, green: 0.18, blue: 0.20, alpha: 1.0)
        let accent  = NSColor(red: 0.22, green: 0.22, blue: 0.24, alpha: 1.0)

        let root = SKNode()
        root.zPosition = -0.2

        // Top deck (booster rests on this): 22pt wide, 2pt tall at y=4..6.
        // Wider than before so it spans the outer legs with a slight overhang.
        let plate = SKSpriteNode(color: fill, size: CGSize(width: 22, height: 2))
        plate.position = CGPoint(x: 0, y: 5)
        root.addChild(plate)
        // Dark deflector stripe along the deck's underside
        let plateAccent = SKSpriteNode(color: accent, size: CGSize(width: 22, height: 1))
        plateAccent.position = CGPoint(x: 0, y: 5.5)
        root.addChild(plateAccent)

        // Three SKINNY pillars — narrower than the previous trapezoids, with
        // a gentle flare at the base for stance. Lots of open space between
        // for flame to pass through.
        //   top x-range  →  bottom x-range
        //   left:   -10..-8  →  -11..-8
        //   center: -1..+1   →  -1..+1   (thin central column)
        //   right:  +8..+10  →  +8..+11
        let legs: [(topL: CGFloat, topR: CGFloat, botL: CGFloat, botR: CGFloat)] = [
            (-10, -8, -11, -8),
            ( -1,  1,  -1,  1),
            (  8, 10,   8, 11),
        ]
        for leg in legs {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: leg.botL, y: 0))
            path.addLine(to: CGPoint(x: leg.botR, y: 0))
            path.addLine(to: CGPoint(x: leg.topR, y: 4))
            path.addLine(to: CGPoint(x: leg.topL, y: 4))
            path.closeSubpath()

            let legNode = SKShapeNode(path: path)
            legNode.fillColor = fill
            legNode.strokeColor = outline
            legNode.lineWidth = 1
            legNode.isAntialiased = false
            root.addChild(legNode)
        }

        // Horizontal cross-brace (thin metallic strut) between the outer
        // pillars at y=2 — reads as structural framework without masking
        // the exhaust vents significantly.
        let brace = SKSpriteNode(color: accent, size: CGSize(width: 22, height: 1))
        brace.position = CGPoint(x: 0, y: 2)
        root.addChild(brace)

        // Align under Starship spawn x (see addEntity / Starship.rightTowerPadding).
        let spawnX = activityBounds.upperBound - RocketConstants.Starship.rightTowerPadding
        root.position = CGPoint(x: spawnX, y: 0)
        addChild(root)
        olmNode = root
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
            catsRendered: entities.count,
            boundsMin: activityBounds.lowerBound,
            boundsMax: activityBounds.upperBound
        )
    }
}
