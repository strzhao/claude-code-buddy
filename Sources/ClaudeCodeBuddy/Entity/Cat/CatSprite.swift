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

    /// Component that owns all label and alert overlay nodes.
    private(set) var labelComponent: LabelComponent!

    // MARK: - GKStateMachine

    private(set) var stateMachine: GKStateMachine!

    /// Pending tool description passed through to CatPermissionRequestState.
    var pendingToolDescription: String?

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

    var sessionColor: SessionColor?
    var sessionTintFactor: CGFloat = CatConstants.Visual.tintFactor
    /// The X position when the cat was placed, used as anchor for random movement.
    var originX: CGFloat = 0
    /// The food this cat is currently walking toward or eating.
    var currentTargetFood: FoodSprite?
    /// Callback to release food when cat is interrupted.
    var onFoodAbandoned: ((String) -> Void)?  // passes sessionId
    /// Single source of truth for horizontal facing direction.
    /// didSet auto-applies xScale so callers never forget to sync visuals.
    var facingRight: Bool = false {
        didSet { applyFacingDirection() }
    }
    /// Cached scene width for boundary clamping during random walk.
    var sceneWidth: CGFloat = 0

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

        // Start with a placeholder 48x48 colored square if textures are missing
        node = SKSpriteNode(color: .orange, size: CatConstants.Physics.placeholderSize)
        node.name = "catSprite_\(sessionId)"

        containerNode.name = "cat_\(sessionId)"
        containerNode.addChild(node)

        animationComponent = AnimationComponent(node: node)

        setupPhysicsBody()
        animationComponent.loadTextures(prefix: "cat", bundle: .module)

        // Initialize movement component after animationComponent is ready
        movementComponent = MovementComponent(entity: self)

        // Initialize interaction component
        interactionComponent = InteractionComponent(entity: self)

        // Initialize label component
        labelComponent = LabelComponent(spriteNode: node)

        // Initialize GKStateMachine after loadTextures so states can access animations
        let states: [GKState] = [
            CatIdleState(entity: self),
            CatThinkingState(entity: self),
            CatToolUseState(entity: self),
            CatPermissionRequestState(entity: self),
            CatEatingState(entity: self)
        ]
        stateMachine = GKStateMachine(states: states)
    }

    // MARK: - Physics

    private func setupPhysicsBody() {
        let body = SKPhysicsBody(rectangleOf: CatConstants.Physics.bodySize)
        body.allowsRotation = false
        body.categoryBitMask    = PhysicsCategory.cat
        body.collisionBitMask   = PhysicsCategory.cat | PhysicsCategory.ground
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

    func applyFacingDirection() {
        // Sprites face RIGHT by default (xScale=1.0), flip to face LEFT (xScale=-1.0)
        let xScale: CGFloat = facingRight ? 1.0 : -1.0
        node.xScale = xScale
        // Child labels inherit parent xScale; applying the same value cancels the flip,
        // keeping text readable regardless of facing direction.
        labelNode?.xScale = xScale
        shadowLabelNode?.xScale = xScale
        tabNameNode?.xScale = xScale
        tabNameShadowNode?.xScale = xScale
    }

    func updateSceneSize(_ size: CGSize) {
        sceneWidth = size.width
    }

    func updateActivityBounds(_ bounds: ClosedRange<CGFloat>) {
        activityMin = bounds.lowerBound
        activityMax = bounds.upperBound
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
        // Safety net: always restore physics dynamics regardless of whether state actually changes
        containerNode.physicsBody?.isDynamic = true

        // Release any claimed food when switching to a different state
        if currentTargetFood != nil {
            currentTargetFood = nil
            onFoodAbandoned?(sessionId)
        }

        // Store tool description for CatPermissionRequestState to access
        pendingToolDescription = toolDescription

        // Clean up common animation keys before entering new state
        node.removeAllActions()
        containerNode.removeAction(forKey: "randomWalk")
        containerNode.removeAction(forKey: "foodWalk")
        removeAlertOverlay()
        hideLabel()
        // Reset transform but preserve facing direction
        node.yScale = 1.0
        node.zRotation = 0
        applyFacingDirection()

        let stateClass: AnyClass
        switch newState {
        case .idle:              stateClass = CatIdleState.self
        case .thinking:          stateClass = CatThinkingState.self
        case .toolUse:           stateClass = CatToolUseState.self
        case .permissionRequest: stateClass = CatPermissionRequestState.self
        case .eating:            stateClass = CatEatingState.self
        }
        stateMachine.enter(stateClass)
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

    // MARK: - Food Interaction

    func walkToFood(_ food: FoodSprite, onArrival: @escaping (CatSprite, FoodSprite) -> Void) {
        movementComponent.walkToFood(food, onArrival: onArrival)
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
            }
            node.run(SKAction.sequence([eatCycle, done]), withKey: "animation")
            node.texture = frames[0]
            node.color = sessionColor?.nsColor ?? .white
            node.colorBlendFactor = sessionTintFactor
        } else {
            currentTargetFood = nil
            switchState(to: .idle)
            completion()
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
        containerNode.setScale(1.0)
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
    }

    func onTimeOfDayChanged(_ time: TimeOfDay) {
        // Placeholder for future time-based behavior changes
    }
}
