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

    // MARK: - GKStateMachine

    private(set) var stateMachine: GKStateMachine!

    /// Pending tool description passed through to CatPermissionRequestState.
    var pendingToolDescription: String?

    // MARK: - Session Identity

    static let hitboxSize = CatConstants.Visual.hitboxSize
    var labelNode: SKLabelNode?
    var shadowLabelNode: SKLabelNode?
    var sessionColor: SessionColor?
    var sessionTintFactor: CGFloat = CatConstants.Visual.tintFactor
    var alertOverlayNode: SKNode?
    var tabNameNode: SKLabelNode?
    var tabNameShadowNode: SKLabelNode?
    var tabName: String = ""
    /// The X position when the cat was placed, used as anchor for random movement.
    var originX: CGFloat = 0
    /// The food this cat is currently walking toward or eating.
    var currentTargetFood: FoodSprite?
    /// Callback to release food when cat is interrupted.
    var onFoodAbandoned: ((String) -> Void)?  // passes sessionId
    /// Single source of truth for horizontal facing direction.
    var facingRight: Bool = false
    /// Cached scene width for boundary clamping during random walk.
    var sceneWidth: CGFloat = 0

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

    private static let hoverScale: CGFloat = CatConstants.Visual.hoverScale
    private static let hoverDuration: TimeInterval = CatConstants.Visual.hoverDuration

    func applyHoverScale() {
        containerNode.removeAction(forKey: "hoverScale")
        let scale = SKAction.scale(to: CatSprite.hoverScale, duration: CatSprite.hoverDuration)
        scale.timingMode = .easeOut
        containerNode.run(scale, withKey: "hoverScale")
    }

    func removeHoverScale() {
        containerNode.removeAction(forKey: "hoverScale")
        let scale = SKAction.scale(to: 1.0, duration: CatSprite.hoverDuration)
        scale.timingMode = .easeOut
        containerNode.run(scale, withKey: "hoverScale")
    }

    // MARK: - Facing Direction

    func applyFacingDirection() {
        let xScale: CGFloat = facingRight ? -1.0 : 1.0
        node.xScale = xScale
        // Child labels inherit parent xScale; applying the same value cancels the flip,
        // keeping text readable regardless of facing direction.
        labelNode?.xScale = xScale
        shadowLabelNode?.xScale = xScale
    }

    func updateSceneSize(_ size: CGSize) {
        sceneWidth = size.width
    }

    // MARK: - Session Identity

    func configure(color: SessionColor, labelText: String) {
        sessionColor = color

        // Apply tint to sprite
        node.color = color.nsColor
        node.colorBlendFactor = sessionTintFactor

        // Create shadow label (behind, for glow effect)
        let shadow = SKLabelNode(text: labelText)
        shadow.fontName = NSFont.boldSystemFont(ofSize: CatConstants.Visual.labelFontSize).fontName
        shadow.fontSize = CatConstants.Visual.labelFontSize
        shadow.fontColor = color.nsColor.withAlphaComponent(CatConstants.Visual.labelShadowAlpha)
        shadow.position = CatConstants.Visual.labelShadowOffset
        shadow.verticalAlignmentMode = .bottom
        shadow.horizontalAlignmentMode = .center
        shadow.zPosition = CatConstants.Visual.labelShadowZPosition
        shadow.isHidden = true
        node.addChild(shadow)
        shadowLabelNode = shadow

        // Create main label
        let label = SKLabelNode(text: labelText)
        label.fontName = NSFont.boldSystemFont(ofSize: CatConstants.Visual.labelFontSize).fontName
        label.fontSize = CatConstants.Visual.labelFontSize
        label.fontColor = color.nsColor
        label.position = CGPoint(x: 0, y: CatConstants.Visual.labelYOffset)
        label.verticalAlignmentMode = .bottom
        label.horizontalAlignmentMode = .center
        label.zPosition = CatConstants.Visual.labelZPosition
        label.isHidden = true
        node.addChild(label)
        labelNode = label

        // 记录 tab name
        tabName = labelText

        // Create tab name shadow (for waiting state)
        let tabShadow = SKLabelNode(text: labelText)
        tabShadow.fontName = NSFont.boldSystemFont(ofSize: CatConstants.Visual.tabLabelFontSize).fontName
        tabShadow.fontSize = CatConstants.Visual.tabLabelFontSize
        tabShadow.fontColor = color.nsColor.withAlphaComponent(CatConstants.Visual.labelShadowAlpha)
        tabShadow.position = CGPoint(x: CatConstants.Visual.labelShadowOffset.x, y: CatConstants.Visual.tabLabelShadowYOffset)
        tabShadow.verticalAlignmentMode = .bottom
        tabShadow.horizontalAlignmentMode = .center
        tabShadow.zPosition = CatConstants.Visual.labelShadowZPosition
        tabShadow.isHidden = true
        node.addChild(tabShadow)
        tabNameShadowNode = tabShadow

        // Create tab name label (for waiting state)
        let tabLabel = SKLabelNode(text: labelText)
        tabLabel.fontName = NSFont.boldSystemFont(ofSize: CatConstants.Visual.tabLabelFontSize).fontName
        tabLabel.fontSize = CatConstants.Visual.tabLabelFontSize
        tabLabel.fontColor = color.nsColor
        tabLabel.position = CGPoint(x: 0, y: CatConstants.Visual.tabLabelYOffset)
        tabLabel.verticalAlignmentMode = .bottom
        tabLabel.horizontalAlignmentMode = .center
        tabLabel.zPosition = CatConstants.Visual.labelZPosition
        tabLabel.isHidden = true
        node.addChild(tabLabel)
        tabNameNode = tabLabel
    }

    func updateLabel(_ newLabel: String) {
        labelNode?.text = newLabel
        shadowLabelNode?.text = newLabel
        tabName = newLabel
        tabNameNode?.text = newLabel
        tabNameShadowNode?.text = newLabel
    }

    func showLabel(text: String? = nil) {
        if let text = text {
            // Truncate to avoid Metal texture overflow (max 16384px width)
            let truncated = text.count > CatConstants.Visual.labelMaxLength ? String(text.prefix(CatConstants.Visual.labelMaxLength)) + "…" : text
            // Only update the tool-description label nodes; do not overwrite tabName
            labelNode?.text = truncated
            shadowLabelNode?.text = truncated
        }
        labelNode?.isHidden = false
        shadowLabelNode?.isHidden = false
    }

    /// Debug cats (session ID starts with "test-") always show their name label.
    var isDebugCat: Bool { sessionId.hasPrefix("debug-") }

    /// True when running in a real SpriteKit scene with display link (not in XCTest).
    private var hasDisplayLink: Bool { containerNode.scene?.view != nil }

    /// Closure to query other cats' positions for jump-over detection.
    var nearbyObstacles: (() -> [(cat: CatSprite, x: CGFloat)])?

    func hideLabel() {
        labelNode?.isHidden = true
        shadowLabelNode?.isHidden = true
        if isDebugCat {
            // Debug cats keep tab name visible for identification
            tabNameNode?.isHidden = false
            tabNameShadowNode?.isHidden = false
        } else {
            tabNameNode?.isHidden = true
            tabNameShadowNode?.isHidden = true
        }
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
        let overlay = SKNode()
        overlay.zPosition = CatConstants.Visual.alertOverlayZPosition

        // Estimate label width: ~7pt per character at font size 11
        let labelHalfWidth = CGFloat(text.count) * CatConstants.Visual.alertBadgeCharWidth
        let badgeX = labelHalfWidth + CatConstants.Visual.alertBadgeHPadding

        let circle = SKShapeNode(circleOfRadius: CatConstants.Visual.alertBadgeRadius)
        circle.fillColor = CatConstants.Visual.alertBadgeColor
        circle.strokeColor = .white
        circle.lineWidth = CatConstants.Visual.alertBadgeLineWidth
        circle.position = CGPoint(x: badgeX, y: CatConstants.Visual.alertBadgeYOffset)
        overlay.addChild(circle)

        let label = SKLabelNode(text: "!")
        label.fontName = NSFont.boldSystemFont(ofSize: CatConstants.Visual.alertBadgeFontSize).fontName
        label.fontSize = CatConstants.Visual.alertBadgeFontSize
        label.fontColor = .white
        label.verticalAlignmentMode = .center
        label.horizontalAlignmentMode = .center
        label.position = CGPoint(x: badgeX, y: CatConstants.Visual.alertBadgeYOffset)
        overlay.addChild(label)

        // Pulse the badge
        let fadeOut = SKAction.fadeAlpha(to: CatConstants.Animation.badgePulseMinAlpha, duration: CatConstants.Animation.badgeFadeDuration)
        let fadeIn = SKAction.fadeAlpha(to: 1.0, duration: CatConstants.Animation.badgeFadeDuration)
        let pulse = SKAction.repeatForever(SKAction.sequence([fadeOut, fadeIn]))
        overlay.run(pulse)

        node.addChild(overlay)
        alertOverlayNode = overlay
    }

    func removeAlertOverlay() {
        alertOverlayNode?.removeFromParent()
        alertOverlayNode = nil
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

    func enterScene(sceneSize: CGSize) {
        sceneWidth = sceneSize.width

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
        // Don't interrupt permission-request state (it's already alert)
        guard currentState != .permissionRequest else { return }

        containerNode.physicsBody?.isDynamic = false
        node.removeAllActions()

        // Decide escape direction: flee away from jumper
        let myX = containerNode.position.x
        let fleeRight = myX > jumperX   // flee to the same side we're on relative to jumper
        let rawTarget = fleeRight ? myX + CatConstants.Fright.fleeDistance : myX - CatConstants.Fright.fleeDistance
        let clampedTarget: CGFloat
        if sceneWidth > 0 {
            clampedTarget = max(CatConstants.Fright.boundaryMargin, min(sceneWidth - CatConstants.Fright.boundaryMargin, rawTarget))
        } else {
            clampedTarget = rawTarget
        }
        let slideDelta = clampedTarget - myX
        let reboundDelta = -slideDelta * CatConstants.Fright.reboundFactor

        // Face the flee direction
        facingRight = fleeRight
        applyFacingDirection()

        guard let scaredFrames = animationComponent.textures(for: "scared"), !scaredFrames.isEmpty else {
            // Fallback: just re-enable physics and resume
            containerNode.physicsBody?.isDynamic = true
            return
        }

        let scaredAnim = SKAction.animate(with: scaredFrames, timePerFrame: CatConstants.Animation.frameTimeScared)
        let slide      = SKAction.moveBy(x: slideDelta, y: 0, duration: CatConstants.Fright.slideDuration)
        slide.timingMode = .easeOut
        let rebound    = SKAction.moveBy(x: reboundDelta, y: 0, duration: CatConstants.Fright.reboundDuration)
        rebound.timingMode = .easeInEaseOut

        let recover = SKAction.run { [weak self] in
            guard let self = self else { return }
            self.containerNode.physicsBody?.isDynamic = true
            if self.currentState == .eating {
                // Use switchState so food is properly released
                self.switchState(to: .idle)
            } else {
                // Re-apply steady state animation via ResumableState protocol
                (self.stateMachine.currentState as? ResumableState)?.resume()
            }
        }

        node.run(scaredAnim, withKey: "frightReaction")

        // Movement runs on containerNode (holds world position)
        let moveSequence = SKAction.sequence([
            SKAction.wait(forDuration: Double(scaredFrames.count) * CatConstants.Animation.frameTimeScared),
            slide,
            rebound,
            recover
        ])
        containerNode.run(moveSequence, withKey: "frightMove")

        // GCD fallback for tests without a display link
        let scaredDuration = Double(scaredFrames.count) * CatConstants.Animation.frameTimeScared
        DispatchQueue.main.asyncAfter(deadline: .now() + CatConstants.Fright.gcdInitialOffset) { [weak self] in
            guard let self = self, !self.hasDisplayLink,
                  self.containerNode.physicsBody?.isDynamic == false else { return }
            self.containerNode.position.x += slideDelta
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + scaredDuration + CatConstants.Fright.slideDuration) { [weak self] in
            guard let self = self, !self.hasDisplayLink,
                  self.containerNode.physicsBody?.isDynamic == false else { return }
            self.containerNode.position.x += reboundDelta
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + scaredDuration + CatConstants.Fright.slideDuration + CatConstants.Fright.reboundDuration + CatConstants.Fright.gcdSettleOffset) { [weak self] in
            guard let self = self, !self.hasDisplayLink,
                  self.containerNode.physicsBody?.isDynamic == false else { return }
            self.containerNode.physicsBody?.isDynamic = true
            if self.currentState == .eating {
                self.switchState(to: .idle)
            } else {
                (self.stateMachine.currentState as? ResumableState)?.resume()
            }
        }
    }

    /// Convenience overload: react based on exit direction enum.
    func playFrightReaction(frightenedBy direction: ExitDirection) {
        let jumperX: CGFloat
        switch direction {
        case .left:
            jumperX = containerNode.position.x - 1
        case .right:
            jumperX = containerNode.position.x + 1
        }
        playFrightReaction(awayFromX: jumperX)
    }

    /// Convenience overload: pass the jumper CatSprite directly.
    func playFrightReaction(frightenedBy jumper: CatSprite) {
        playFrightReaction(awayFromX: jumper.containerNode.position.x)
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
