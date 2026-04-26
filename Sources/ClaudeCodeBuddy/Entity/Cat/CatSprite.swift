import SpriteKit
import ImageIO
import GameplayKit

// MARK: - CatState

enum CatState: String, CaseIterable {
    case idle              = "idle"
    case thinking          = "thinking"
    case toolUse           = "tool_use"
    case permissionRequest = "waiting"
    case eating            = "eating"
    case taskComplete      = "task_complete"
}

// MARK: - ExitDirection

enum ExitDirection {
    case left, right
}

// MARK: - CatSprite

class CatSprite {

    // MARK: Properties

    let sessionId: String

    /// Computed current state based on GKStateMachine.
    var currentState: CatState {
        switch stateMachine?.currentState {
        case is CatIdleState:              return .idle
        case is CatThinkingState:          return .thinking
        case is CatToolUseState:           return .toolUse
        case is CatPermissionRequestState: return .permissionRequest
        case is CatEatingState:            return .eating
        case is CatTaskCompleteState:      return .taskComplete
        default:                           return .idle  // before stateMachine init
        }
    }

    /// Container node added to the scene; holds position, physics, and movement.
    let containerNode = SKNode()

    /// The underlying SpriteKit sprite node (child of containerNode at origin).
    let node: SKSpriteNode

    /// Component that owns all texture data and animation playback for this cat's sprite.
    let animationComponent: AnimationComponent

    /// Component that owns all movement and jump behaviour for this cat.
    private(set) var movementComponent: MovementComponent!

    /// Component that owns fright reaction and hover scale behaviours.
    private(set) var interactionComponent: InteractionComponent!

    /// Component that owns drag, drop, and bounce behaviours.
    private(set) var dragComponent: DragComponent!

    /// Component that owns all label and alert overlay nodes.
    private(set) var labelComponent: LabelComponent!

    /// Per-cat personality traits influencing behavior parameters.
    let personality: CatPersonality

    // MARK: - GKStateMachine

    private(set) var stateMachine: GKStateMachine!

    /// Pending tool description passed through to CatPermissionRequestState.
    var pendingToolDescription: String?

    /// Set to true when user clicks the cat during permissionRequest, so willExit skips the persistent badge.
    var permissionAcknowledged = false

    /// State queued during eating — applied after eating animation completes.
    private var pendingStateAfterEating: CatState?
    private var pendingToolDescriptionAfterEating: String?

    /// State queued during drag — applied after landing completes.
    var pendingStateAfterDrag: CatState?
    var pendingToolDescriptionAfterDrag: String?

    /// True during the handoff window (0.15s). Rapid state changes queue here.
    private var isTransitioningOut = false
    /// State queued while isTransitioningOut is true (last-wins).
    private var pendingStateAfterTransition: CatState?
    private var pendingToolDescriptionAfterTransition: String?

    /// Whether this cat is being dragged or landing from a drag drop.
    var isDragging: Bool { dragComponent?.isDragging ?? false }
    var isDragOccupied: Bool { dragComponent?.isOccupied ?? false }

    // MARK: - Session Identity

    static let hitboxSize = CatConstants.Visual.hitboxSize

    // Label node forwarding properties — backed by LabelComponent
    var labelNode: SKLabelNode? { labelComponent?.labelNode }
    var shadowLabelNode: SKLabelNode? { labelComponent?.shadowLabelNode }
    var tabNameNode: SKLabelNode? { labelComponent?.tabNameNode }
    var tabNameShadowNode: SKLabelNode? { labelComponent?.tabNameShadowNode }
    var tabName: String {
        get { labelComponent?.tabName ?? "" }
        set { labelComponent?.updateLabel(newValue) }
    }
    var alertOverlayNode: SKNode? { labelComponent?.alertOverlayNode }
    var persistentBadgeNode: SKNode? { labelComponent?.persistentBadgeNode }
    var updateBadgeNode: SKNode? { labelComponent?.updateBadgeNode }

    var sessionColor: SessionColor?
    var sessionTintFactor: CGFloat = CatConstants.Visual.tintFactor
    /// The X position when the cat was placed, used as anchor for random movement.
    var originX: CGFloat = 0

    // MARK: - Token Level

    /// Current token-driven scale factor. Drives containerNode.setScale().
    private(set) var tokenScale: CGFloat = 1.0
    /// Current discrete token level (Lv1–Lv8).
    private(set) var currentTokenLevel: TokenLevel = .lv1
    /// The food this cat is currently walking toward or eating.
    var currentTargetFood: FoodSprite?
    /// Callback to release food when cat is interrupted.
    var onFoodAbandoned: ((String) -> Void)?  // passes sessionId
    /// Callback to request a bed slot when entering taskComplete state.
    var onBedRequested: ((String) -> (x: CGFloat, bedName: String)?)?
    /// Callback to release a bed slot when leaving taskComplete state.
    var onBedReleased: ((String) -> Void)?
    /// Single source of truth for horizontal facing direction.
    /// didSet auto-applies xScale so callers never forget to sync visuals.
    var facingRight: Bool = false {
        didSet { applyFacingDirection(animated: facingRight != oldValue) }
    }
    /// Cached scene width for boundary clamping during random walk.
    var sceneWidth: CGFloat = 0

    /// Timestamp (CACurrentMediaTime) when this cat was first detected outside
    /// its activity bounds. Nil when the cat is within bounds.
    var outOfBoundsSince: CFTimeInterval?

    /// Minimum X for cat activity (left boundary).
    var activityMin: CGFloat = CatConstants.Movement.walkBoundaryMargin
    /// Maximum X for cat activity (right boundary). 0 means "use sceneWidth - margin".
    var activityMax: CGFloat = 0

    var effectiveActivityMax: CGFloat {
        activityMax > 0 ? activityMax : sceneWidth - CatConstants.Movement.walkBoundaryMargin
    }

    // MARK: Init

    init(sessionId: String) {
        self.sessionId = sessionId
        self.personality = CatPersonality.random()

        // Start with a placeholder 48x48 colored square if textures are missing
        node = SKSpriteNode(color: .orange, size: CatConstants.Physics.placeholderSize)
        node.name = "catSprite_\(sessionId)"

        containerNode.name = "cat_\(sessionId)"
        containerNode.addChild(node)

        animationComponent = AnimationComponent(node: node, personality: personality)

        setupPhysicsBody()
        animationComponent.loadTextures(from: SkinPackManager.shared.activeSkin)

        // Initialize movement component after animationComponent is ready
        movementComponent = MovementComponent(entity: self)

        // Initialize interaction component
        interactionComponent = InteractionComponent(entity: self)

        // Initialize drag component
        dragComponent = DragComponent(entity: self)

        // Initialize label component
        labelComponent = LabelComponent(spriteNode: node)

        // Initialize GKStateMachine after loadTextures so states can access animations
        let states: [GKState] = [
            CatIdleState(entity: self),
            CatThinkingState(entity: self),
            CatToolUseState(entity: self),
            CatPermissionRequestState(entity: self),
            CatEatingState(entity: self),
            CatTaskCompleteState(entity: self)
        ]
        stateMachine = GKStateMachine(states: states)
    }

    // MARK: - Physics

    private func setupPhysicsBody() {
        let body = SKPhysicsBody(rectangleOf: CatConstants.Physics.bodySize)
        body.allowsRotation = false
        body.categoryBitMask    = PhysicsCategory.cat
        body.collisionBitMask   = PhysicsCategory.ground
        body.contactTestBitMask = PhysicsCategory.ground
        body.restitution = CatConstants.Physics.restitution
        body.friction    = CatConstants.Physics.friction
        body.linearDamping = CatConstants.Physics.linearDamping
        containerNode.physicsBody = body
    }

    // MARK: - Hover Scale

    func applyHoverScale() {
        interactionComponent.applyHoverScale()
    }

    func removeHoverScale() {
        interactionComponent.removeHoverScale()
    }

    // MARK: - Facing Direction

    /// Set facing direction toward a target X position.
    /// Only changes direction if delta exceeds facingDirectionThreshold.
    func face(towardX targetX: CGFloat) {
        let delta = targetX - containerNode.position.x
        if delta < -CatConstants.Movement.facingDirectionThreshold {
            facingRight = false
        } else if delta > CatConstants.Movement.facingDirectionThreshold {
            facingRight = true
        }
    }

    /// Explicitly set facing direction. Guard avoids redundant didSet triggers.
    func face(right: Bool) {
        guard facingRight != right else { return }
        facingRight = right
    }

    func applyFacingDirection(animated: Bool = false) {
        // Check if the skin's sprites face right by default (true = right, false = left)
        let spriteFacesRight = SkinPackManager.shared.activeSkin.manifest.spriteFacesRight ?? true
        let shouldFaceRight = facingRight == spriteFacesRight

        // Only animate when in a live scene (has display link); tests need instant xScale
        let hasDisplayLink = containerNode.scene?.view != nil
        if animated && hasDisplayLink {
            let tm = AnimationTransitionManager(
                node: node, containerNode: containerNode, personality: personality
            )
            tm.smoothTurn(toRight: shouldFaceRight)
        } else {
            node.xScale = shouldFaceRight ? 1.0 : -1.0
        }
        // Update label scale compensation (handles both facing flip and token scale)
        labelComponent.updateScaleCompensation(tokenScale: tokenScale, facingRight: facingRight)
    }

    func updateSceneSize(_ size: CGSize) {
        sceneWidth = size.width
    }

    func updateActivityBounds(_ bounds: ClosedRange<CGFloat>) {
        activityMin = bounds.lowerBound
        activityMax = bounds.upperBound
    }

    // MARK: - Boundary Recovery

    /// Whether this cat is outside its activity bounds by more than the tolerance.
    func isOutOfBounds() -> Bool {
        let x = containerNode.position.x
        let tolerance = CatConstants.BoundaryRecovery.outOfBoundsTolerance
        return x < activityMin - tolerance || x > effectiveActivityMax + tolerance
    }

    /// Returns the nearest valid X position within activity bounds for an out-of-bounds cat.
    func nearestValidX() -> CGFloat {
        let x = containerNode.position.x
        let margin = CatConstants.Movement.walkBoundaryMargin
        if x < activityMin {
            return activityMin + margin
        } else {
            return effectiveActivityMax - margin
        }
    }

    // MARK: - Token Level

    /// Update token level from total token count. Returns true if level changed.
    @discardableResult
    func applyTokenLevel(totalTokens: Int) -> Bool {
        let newLevel = TokenLevel.from(totalTokens: totalTokens)
        guard newLevel != currentTokenLevel else { return false }

        currentTokenLevel = newLevel
        tokenScale = newLevel.scale

        // Cancel any running hover scale to avoid conflict
        containerNode.removeAction(forKey: "hoverScale")

        // Apply new base scale
        containerNode.setScale(tokenScale)

        // Rebuild physics body to match new size
        rebuildPhysicsBody()

        // Update label scale compensation
        labelComponent.updateScaleCompensation(tokenScale: tokenScale, facingRight: facingRight)

        return true
    }

    /// Play level-up animation on the sprite (flash + scale overshoot).
    /// Call after applyTokenLevel returns true.
    func playLevelUpAnimation() {
        let targetScale = tokenScale

        // Flash animation on node (white flash)
        let originalBlend = node.colorBlendFactor
        let flashIn = SKAction.customAction(withDuration: CatConstants.LevelUp.flashInDuration) { node, elapsed in
            guard let sprite = node as? SKSpriteNode else { return }
            let progress = elapsed / CGFloat(CatConstants.LevelUp.flashInDuration)
            sprite.color = .white
            sprite.colorBlendFactor = CatConstants.LevelUp.flashBlendFactor * progress
        }
        let flashOut = SKAction.customAction(withDuration: CatConstants.LevelUp.flashOutDuration) { [weak self] node, elapsed in
            guard let sprite = node as? SKSpriteNode, let self = self else { return }
            let progress = elapsed / CGFloat(CatConstants.LevelUp.flashOutDuration)
            sprite.color = self.sessionColor?.nsColor ?? .white
            sprite.colorBlendFactor = CatConstants.LevelUp.flashBlendFactor * (1.0 - progress) + originalBlend * progress
        }
        node.run(SKAction.sequence([flashIn, flashOut]), withKey: CatConstants.LevelUp.flashActionKey)

        // Scale overshoot animation on containerNode
        let overshoot = SKAction.scale(to: targetScale * CatConstants.LevelUp.scaleOvershoot,
                                        duration: CatConstants.LevelUp.scaleOvershootDuration)
        overshoot.timingMode = .easeOut
        let settle = SKAction.scale(to: targetScale,
                                     duration: CatConstants.LevelUp.scaleSettleDuration)
        settle.timingMode = .easeInEaseOut
        containerNode.run(SKAction.sequence([overshoot, settle]), withKey: CatConstants.LevelUp.actionKey)
    }

    /// Rebuild physics body scaled to current tokenScale, preserving velocity and dynamic state.
    private func rebuildPhysicsBody() {
        let oldVelocity = containerNode.physicsBody?.velocity ?? .zero
        let wasDynamic = containerNode.physicsBody?.isDynamic ?? true

        let scaledSize = CGSize(
            width: CatConstants.Physics.bodySize.width * tokenScale,
            height: CatConstants.Physics.bodySize.height * tokenScale
        )
        let body = SKPhysicsBody(rectangleOf: scaledSize)
        body.allowsRotation = false
        body.categoryBitMask    = PhysicsCategory.cat
        body.collisionBitMask   = PhysicsCategory.ground
        body.contactTestBitMask = PhysicsCategory.ground
        body.restitution = CatConstants.Physics.restitution
        body.friction    = CatConstants.Physics.friction
        body.linearDamping = CatConstants.Physics.linearDamping
        body.velocity = oldVelocity
        body.isDynamic = wasDynamic
        containerNode.physicsBody = body
    }

    // MARK: - Session Identity

    func configure(color: SessionColor, labelText: String) {
        sessionColor = color

        // Apply tint to sprite
        node.color = color.nsColor
        node.colorBlendFactor = sessionTintFactor

        // Delegate label creation to LabelComponent
        labelComponent.configure(color: color, labelText: labelText)
    }

    func updateLabel(_ newLabel: String) {
        labelComponent.updateLabel(newLabel)
    }

    func showLabel(text: String? = nil) {
        labelComponent.showLabel(text: text)
    }

    /// Debug cats (session ID starts with "debug-") always show their name label.
    var isDebugCat: Bool { sessionId.hasPrefix("debug-") }

    /// True when running in a real SpriteKit scene with display link (not in XCTest).
    private var hasDisplayLink: Bool { containerNode.scene?.view != nil }

    /// Closure to query other cats' positions for jump-over detection.
    var nearbyObstacles: (() -> [(cat: CatSprite, x: CGFloat)])?

    func hideLabel() {
        labelComponent.hideLabel(isDebugCat: isDebugCat)
    }

    // MARK: - State Machine

    func switchState(to newState: CatState, toolDescription: String? = nil) {
        if isDragOccupied {
            pendingStateAfterDrag = newState
            pendingToolDescriptionAfterDrag = toolDescription
            return
        }

        if currentState == .eating && newState != .idle {
            pendingStateAfterEating = newState
            pendingToolDescriptionAfterEating = toolDescription
            return
        }

        if isTransitioningOut {
            pendingStateAfterTransition = newState
            pendingToolDescriptionAfterTransition = toolDescription
            return
        }

        containerNode.physicsBody?.isDynamic = true
        pendingToolDescription = toolDescription

        if currentState == newState {
            if newState == .permissionRequest {
                removeAlertOverlay()
                (stateMachine.currentState as? CatPermissionRequestState)?.resume()
            }
            return
        }

        if currentTargetFood != nil {
            currentTargetFood = nil
            onFoodAbandoned?(sessionId)
        }

        // Stop positional actions immediately
        containerNode.removeAction(forKey: "randomWalk")
        containerNode.removeAction(forKey: "foodWalk")
        containerNode.removeAction(forKey: CatConstants.BoundaryRecovery.actionKey)
        containerNode.removeAction(forKey: "bedWalk")
        removeAlertOverlay()
        hideLabel()

        let hasDisplayLink = containerNode.scene?.view != nil
        if !hasDisplayLink {
            node.removeAllActions()
            node.position.y = 0
            node.yScale = 1.0
            node.zRotation = 0
            applyFacingDirection()
            stateMachine.enter(stateClass(for: newState))
            return
        }

        // Collect state-specific exit overlay actions
        let exitActions = currentExitActions()

        isTransitioningOut = true

        // Speed up the primary looping animation
        let primaryKey = primaryAnimationKey(for: currentState)
        if let current = node.action(forKey: primaryKey) {
            current.speed = CatConstants.Transition.exitAnimationSpeed
        }

        for (key, action) in exitActions {
            node.run(action, withKey: key)
        }

        // Animate transform reset
        if node.yScale != 1.0 {
            let resetY = SKAction.scaleY(to: 1.0, duration: CatConstants.Transition.transformResetDuration)
            resetY.timingMode = .easeOut
            node.run(resetY, withKey: "transformResetY")
        }
        if node.zRotation != 0 {
            let resetRot = SKAction.rotate(toAngle: 0, duration: CatConstants.Transition.transformResetDuration)
            resetRot.timingMode = .easeOut
            node.run(resetRot, withKey: "transformResetRot")
        }
        node.position.y = 0

        let targetStateClass: AnyClass = stateClass(for: newState)

        let dispatch = SKAction.sequence([
            SKAction.wait(forDuration: CatConstants.Transition.handoffDuration),
            SKAction.run { [weak self] in
                guard let self = self else { return }
                self.isTransitioningOut = false

                self.node.removeAllActions()
                self.node.yScale = 1.0
                self.node.zRotation = 0
                self.applyFacingDirection()

                self.stateMachine.enter(targetStateClass)

                if let pending = self.pendingStateAfterTransition {
                    self.pendingStateAfterTransition = nil
                    let desc = self.pendingToolDescriptionAfterTransition
                    self.pendingToolDescriptionAfterTransition = nil
                    self.switchState(to: pending, toolDescription: desc)
                }
            }
        ])
        node.run(dispatch, withKey: CatConstants.Transition.pendingDispatchKey)
    }

    private func primaryAnimationKey(for state: CatState) -> String {
        switch state {
        case .idle:              return "idleLoop"
        case .thinking:          return "animation"
        case .toolUse:           return "animation"
        case .permissionRequest: return "animation"
        case .eating:            return "animation"
        case .taskComplete:      return "animation"
        }
    }

    private func currentExitActions() -> [String: SKAction] {
        switch stateMachine.currentState {
        case let s as CatIdleState:              return s.prepareExitActions()
        case let s as CatThinkingState:          return s.prepareExitActions()
        case let s as CatToolUseState:           return s.prepareExitActions()
        case let s as CatPermissionRequestState: return s.prepareExitActions()
        case let s as CatTaskCompleteState:      return s.prepareExitActions()
        case let s as CatEatingState:            return s.prepareExitActions()
        default:                                 return [:]
        }
    }

    private func stateClass(for state: CatState) -> AnyClass {
        switch state {
        case .idle:              return CatIdleState.self
        case .thinking:          return CatThinkingState.self
        case .toolUse:           return CatToolUseState.self
        case .permissionRequest: return CatPermissionRequestState.self
        case .eating:            return CatEatingState.self
        case .taskComplete:      return CatTaskCompleteState.self
        }
    }

    // MARK: - Organic Random Walk (toolUse)

    /// Starts the recursive random walk used in toolUse state.
    /// Delegates to MovementComponent.
    func startRandomWalk() {
        movementComponent.startRandomWalk()
    }

    // MARK: - Alert Overlay

    func addAlertOverlay(afterLabel text: String) {
        labelComponent.addAlertOverlay(afterLabel: text)
    }

    func removeAlertOverlay() {
        labelComponent.removeAlertOverlay()
    }

    // MARK: - Persistent Badge

    func addPersistentBadge() {
        labelComponent.addPersistentBadge()
    }

    func removePersistentBadge() {
        labelComponent.removePersistentBadge()
    }

    // MARK: - Update Badge

    func addUpdateBadge() {
        labelComponent.addUpdateBadge()
    }

    func removeUpdateBadge() {
        labelComponent.removeUpdateBadge()
    }

    // MARK: - Upgrade Animation

    func startUpgradeAnimation() {
        guard let frames = animationComponent.textures(for: "paw"), !frames.isEmpty else { return }
        node.removeAllActions()
        let animate = SKAction.animate(with: frames, timePerFrame: CatConstants.Animation.frameTimePaw)
        node.run(SKAction.repeatForever(animate), withKey: "upgradeAnimation")
        node.texture = frames[0]
        node.color = sessionColor?.nsColor ?? .white
        node.colorBlendFactor = sessionTintFactor
    }

    func stopUpgradeAnimation() {
        node.removeAction(forKey: "upgradeAnimation")
    }

    // MARK: - Tab Name

    func showTabName() {
        labelComponent.showTabName()
    }

    // MARK: - Food Interaction

    func playExcitedReaction(delay: TimeInterval, completion: @escaping () -> Void) {
        let wait = SKAction.wait(forDuration: delay)
        // Personality-based hop height
        let hopHeight = personality.excitedHopHeight
        let hopUp = SKAction.moveBy(x: 0, y: hopHeight, duration: 0.1)
        hopUp.timingMode = EasingCurves.catExcited.timingMode
        let hopDown = SKAction.moveBy(x: 0, y: -hopHeight, duration: 0.1)
        hopDown.timingMode = .easeIn
        let hop = SKAction.sequence([hopUp, hopDown])
        // Flash paw frame briefly
        var pawAction = SKAction.wait(forDuration: 0.15)
        if let frames = animationComponent.textures(for: "paw"), !frames.isEmpty {
            let pawAnimate = SKAction.animate(with: [frames[0]], timePerFrame: 0.15)
            pawAction = pawAnimate
        }
        let done = SKAction.run { completion() }
        let reaction = SKAction.sequence([hop, pawAction, done])
        node.run(SKAction.sequence([wait, reaction]), withKey: "excitedReaction")
    }

    func playDisappointedReaction() {
        let droop = SKAction.scaleY(to: 0.92, duration: 0.15)
        let pause = SKAction.wait(forDuration: 0.3)
        let recover = SKAction.scaleY(to: 1.0, duration: 0.15)
        let toIdle = SKAction.run { [weak self] in
            self?.switchState(to: .idle)
        }
        node.run(SKAction.sequence([droop, pause, recover, toIdle]), withKey: "disappointedReaction")
    }

    func walkToFood(_ food: FoodSprite, excitedDelay: TimeInterval = 0, onArrival: @escaping (CatSprite, FoodSprite) -> Void) {
        movementComponent.walkToFood(food, excitedDelay: excitedDelay, onArrival: onArrival)
    }

    func startEating(_ food: FoodSprite, completion: @escaping () -> Void) {
        pendingToolDescription = nil
        stateMachine.enter(CatEatingState.self)
        currentTargetFood = food
        node.removeAllActions()
        containerNode.removeAction(forKey: "foodWalk")

        if let frames = animationComponent.textures(for: "paw"), !frames.isEmpty {
            let animate = SKAction.animate(with: frames, timePerFrame: CatConstants.Animation.frameTimePaw)
            let eatCycle = SKAction.repeat(animate, count: 2)
            let done = SKAction.run { [weak self] in
                guard let self = self else { return }
                self.currentTargetFood = nil
                // Don't set currentState directly — let switchState handle the transition
                self.switchState(to: .idle)
                completion()
                // Apply any state that was queued during eating
                if let pending = self.pendingStateAfterEating {
                    self.pendingStateAfterEating = nil
                    let desc = self.pendingToolDescriptionAfterEating
                    self.pendingToolDescriptionAfterEating = nil
                    self.switchState(to: pending, toolDescription: desc)
                }
            }
            node.run(SKAction.sequence([eatCycle, done]), withKey: "animation")
            node.texture = frames[0]
            node.color = sessionColor?.nsColor ?? .white
            node.colorBlendFactor = sessionTintFactor
        } else {
            currentTargetFood = nil
            switchState(to: .idle)
            completion()
            if let pending = pendingStateAfterEating {
                pendingStateAfterEating = nil
                let desc = pendingToolDescriptionAfterEating
                pendingToolDescriptionAfterEating = nil
                switchState(to: pending, toolDescription: desc)
            }
        }
    }

    // MARK: - Enter / Exit

    func enterScene(sceneSize: CGSize, activityBounds: ClosedRange<CGFloat>? = nil) {
        sceneWidth = sceneSize.width
        if let bounds = activityBounds {
            activityMin = bounds.lowerBound
            activityMax = bounds.upperBound
        }

        // Place directly at ground level — no drop animation
        containerNode.position = CGPoint(x: containerNode.position.x, y: CatConstants.Visual.groundY)
        containerNode.setScale(tokenScale)
        node.yScale = 1.0
        node.zRotation = 0
        removeAlertOverlay()
        hideLabel()

        // Enter idle state via state machine
        applyFacingDirection()
        stateMachine.enter(CatIdleState.self)

        // Debug cats: ensure name label is visible immediately
        if isDebugCat {
            tabNameNode?.isHidden = false
            tabNameShadowNode?.isHidden = false
        }
    }

    // MARK: - Fright Reaction

    /// Primary entry: called on the cat that was jumped over, passing the jumper's x position.
    func playFrightReaction(awayFromX jumperX: CGFloat) {
        interactionComponent.playFrightReaction(awayFromX: jumperX)
    }

    /// Convenience overload: react based on exit direction enum.
    func playFrightReaction(frightenedBy direction: ExitDirection) {
        interactionComponent.playFrightReaction(frightenedBy: direction)
    }

    /// Convenience overload: pass the jumper CatSprite directly.
    func playFrightReaction(frightenedBy jumper: CatSprite) {
        interactionComponent.playFrightReaction(frightenedBy: jumper)
    }

    func exitScene(sceneWidth: CGFloat, completion: @escaping () -> Void) {
        movementComponent.exitScene(sceneWidth: sceneWidth, completion: completion)
    }

    /// Exit variant that jumps over any cats on the path, triggering fright reactions.
    func exitScene(
        sceneWidth: CGFloat,
        obstacles: [(cat: CatSprite, x: CGFloat)],
        onJumpOver: @escaping (CatSprite) -> Void,
        completion: @escaping () -> Void
    ) {
        movementComponent.exitScene(sceneWidth: sceneWidth, obstacles: obstacles, onJumpOver: onJumpOver, completion: completion)
    }
}

// MARK: - EntityProtocol Conformance

extension CatSprite: EntityProtocol {}

// MARK: - EnvironmentResponder Conformance

extension CatSprite: EnvironmentResponder {
    func onWeatherChanged(_ weather: WeatherState) {
        // Apply behavior modifier to movement speed
        let modifier = weather.behaviorModifier
        movementComponent.speedMultiplier = modifier.walkSpeedMultiplier

        // Visual weather reaction
        let tm = AnimationTransitionManager(
            node: node, containerNode: containerNode, personality: personality
        )
        tm.playWeatherReaction(for: weather)
    }

    func onTimeOfDayChanged(_ time: TimeOfDay) {
        // Placeholder for future time-based behavior changes
    }
}
