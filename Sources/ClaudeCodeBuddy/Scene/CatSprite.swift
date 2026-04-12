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

    /// Animation texture arrays keyed by animation name string.
    /// Known names: "idle-a", "idle-b", "clean", "sleep", "scared", "paw", "walk-a", "walk-b"
    var animations: [String: [SKTexture]] = [:]

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
    private var sceneWidth: CGFloat = 0

    // MARK: Init

    init(sessionId: String) {
        self.sessionId = sessionId

        // Start with a placeholder 48x48 colored square if textures are missing
        node = SKSpriteNode(color: .orange, size: CatConstants.Physics.placeholderSize)
        node.name = "catSprite_\(sessionId)"

        containerNode.name = "cat_\(sessionId)"
        containerNode.addChild(node)

        setupPhysicsBody()
        loadTextures()

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

    // MARK: - Textures

    private func loadTextures() {
        let animNames = ["idle-a", "idle-b", "clean", "sleep", "scared", "paw", "walk-a", "walk-b", "jump"]

        for animName in animNames {
            var textures: [SKTexture] = []
            var frame = 1
            while true {
                let name = "cat-\(animName)-\(frame)"
                guard let url = Bundle.module.url(forResource: name,
                                                  withExtension: "png",
                                                  subdirectory: "Assets/Sprites") else {
                    break
                }
                guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
                    break
                }
                let texture = SKTexture(cgImage: cgImage)
                texture.filteringMode = .nearest
                textures.append(texture)
                frame += 1
            }
            if !textures.isEmpty {
                animations[animName] = textures
            }
        }
    }

    // MARK: - Helpers

    func textures(for animName: String) -> [SKTexture]? {
        guard let textures = animations[animName], !textures.isEmpty else { return nil }
        return textures
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

    // MARK: - Breathing (subtle scale oscillation for all active states)

    func startBreathing() {
        let breatheIn = SKAction.scaleY(to: CatConstants.Animation.breatheScaleY, duration: CatConstants.Animation.breatheDuration)
        breatheIn.timingMode = .easeInEaseOut
        let breatheOut = SKAction.scaleY(to: 1.0, duration: CatConstants.Animation.breatheDuration)
        breatheOut.timingMode = .easeInEaseOut
        let breathe = SKAction.repeatForever(SKAction.sequence([breatheIn, breatheOut]))
        node.run(breathe, withKey: "breathing")
    }

    // MARK: - Organic Random Walk (toolUse)

    /// Recursive random walk: pick a random target within range, move there
    /// with variable speed, pause randomly, then pick next target.
    func startRandomWalk() {
        doRandomWalkStep()
    }

    func doRandomWalkStep() {
        guard currentState == .toolUse else { return }

        // Random target: ±120px from origin (wide range)
        let maxRange: CGFloat = CatConstants.Movement.walkMaxRange
        let margin: CGFloat = CatConstants.Movement.walkBoundaryMargin
        let rawTarget = originX + CGFloat.random(in: -maxRange...maxRange)
        let target = sceneWidth > 0
            ? max(margin, min(sceneWidth - margin, rawTarget))
            : rawTarget

        // Update facing direction based on movement
        let delta = target - containerNode.position.x
        if delta < -CatConstants.Movement.facingDirectionThreshold {
            facingRight = false
        } else if delta > CatConstants.Movement.facingDirectionThreshold {
            facingRight = true
        }
        applyFacingDirection()

        let distance = abs(delta)

        // Skip move if barely any distance, just pause
        if distance < CatConstants.Movement.walkMinDistance {
            let pause = SKAction.wait(forDuration: Double.random(in: CatConstants.Movement.walkPauseRange))
            let next = SKAction.run { [weak self] in self?.doRandomWalkStep() }
            containerNode.run(SKAction.sequence([pause, next]), withKey: "randomWalk")
            return
        }

        // --- Walk phase: play walk-b while moving ---
        let speed: Double = Double.random(in: CatConstants.Movement.walkSpeedRange) // px/s
        let duration = max(CatConstants.Movement.walkMinDuration, Double(distance) / speed)

        // Start walk animation
        if let walkFrames = textures(for: "walk-b"), !walkFrames.isEmpty {
            let animate = SKAction.animate(with: walkFrames, timePerFrame: CatConstants.Animation.frameTimeWalk)
            node.run(SKAction.repeatForever(animate), withKey: "animation")
            node.color = sessionColor?.nsColor ?? .white
            node.colorBlendFactor = sessionTintFactor
        }

        let move = SKAction.moveTo(x: target, duration: duration)
        move.timingMode = .easeInEaseOut

        // --- Check for obstacles in the walk path and build jump actions ---
        let jumpActions = buildJumpActions(from: containerNode.position.x, to: target, goingRight: delta > 0)

        // --- Pause phase: stop walk, show standing pose ---
        let stopWalkAndPause = SKAction.run { [weak self] in
            guard let self = self, self.currentState == .toolUse else { return }
            self.node.removeAction(forKey: "animation")
            // Standing pose: use paw or idle-a
            let standAnim = Float.random(in: 0..<1) < CatConstants.Movement.walkPawProbability ? "paw" : "idle-a"
            if let frames = self.textures(for: standAnim), !frames.isEmpty {
                let animate = SKAction.animate(with: frames, timePerFrame: CatConstants.Animation.frameTimeStand)
                self.node.run(SKAction.repeatForever(animate), withKey: "animation")
                self.node.color = self.sessionColor?.nsColor ?? .white
                self.node.colorBlendFactor = self.sessionTintFactor
            }
        }

        // Longer walks: mostly keep moving, occasional brief stop
        let pauseDuration: Double
        let roll = Float.random(in: 0..<1)
        if roll < CatConstants.Movement.walkRestProbability {
            pauseDuration = Double.random(in: CatConstants.Movement.walkRestDurationRange)   // brief rest (15%)
        } else {
            pauseDuration = 0                                // keep moving (85%)
        }

        let next = SKAction.run { [weak self] in self?.doRandomWalkStep() }

        // Build the walk sequence, inserting jumps if there are obstacles
        var walkSequence: [SKAction] = []
        if jumpActions.isEmpty {
            // No obstacles — simple walk
            walkSequence.append(move)
        } else {
            // Has obstacles — replace simple move with jump-walk sequence
            walkSequence.append(contentsOf: jumpActions)
            // Walk remaining distance to target after last jump
            let remainDist = abs(target - containerNode.position.x)
            if remainDist > CatConstants.Movement.walkPostJumpMinDistance {
                let remainWalk = SKAction.moveTo(x: target, duration: max(CatConstants.Movement.walkPostJumpMinDuration, Double(remainDist) / speed))
                remainWalk.timingMode = .easeOut
                walkSequence.append(remainWalk)
            }
        }

        if pauseDuration > 0 {
            let pause = SKAction.wait(forDuration: pauseDuration)
            containerNode.run(SKAction.sequence(walkSequence + [stopWalkAndPause, pause, next]), withKey: "randomWalk")
        } else {
            containerNode.run(SKAction.sequence(walkSequence + [next]), withKey: "randomWalk")
        }
    }

    // MARK: - Jump Over Obstacles (general purpose)

    /// Builds SKAction sequence to jump over obstacles between `fromX` and `toX`.
    /// Returns empty array if no obstacles in the path.
    private func buildJumpActions(
        from fromX: CGFloat,
        to toX: CGFloat,
        goingRight: Bool,
        onJumpOver: ((CatSprite) -> Void)? = nil
    ) -> [SKAction] {
        guard let obstacles = nearbyObstacles?() else { return [] }

        let onPath: [(cat: CatSprite, x: CGFloat)]
        if goingRight {
            onPath = obstacles.filter { $0.x > fromX - CatConstants.Jump.obstaclePathTolerance && $0.x < toX + CatConstants.Jump.obstaclePathTolerance }
                              .sorted { $0.x < $1.x }
        } else {
            onPath = obstacles.filter { $0.x < fromX + CatConstants.Jump.obstaclePathTolerance && $0.x > toX - CatConstants.Jump.obstaclePathTolerance }
                              .sorted { $0.x > $1.x }
        }

        guard !onPath.isEmpty else { return [] }

        let groundY = containerNode.position.y  // actual resting Y
        var actions: [SKAction] = []
        var lastX = fromX

        for obstacle in onPath {
            let obstX = obstacle.x
            let approachX = goingRight ? obstX - CatConstants.Jump.approachOffset : obstX + CatConstants.Jump.approachOffset
            let landX = goingRight ? obstX + CatConstants.Jump.approachOffset : obstX - CatConstants.Jump.approachOffset
            let capturedObstacleCat = obstacle.cat

            // Walk to approach point
            let approachDist = abs(approachX - lastX)
            if approachDist > 1 {
                let approachWalk = SKAction.moveTo(x: approachX, duration: max(Double(approachDist) / CatConstants.Jump.approachWalkSpeed, CatConstants.Jump.approachMinDuration))
                approachWalk.timingMode = .easeOut
                actions.append(approachWalk)
            }

            // Jump animation (visual on node)
            if let jumpFrames = textures(for: "jump"), !jumpFrames.isEmpty {
                let jumpAnimDuration = Double(jumpFrames.count) * CatConstants.Animation.frameTimeJumpOver
                let jumpAnim = SKAction.animate(with: jumpFrames, timePerFrame: CatConstants.Animation.frameTimeJumpOver)
                let playJump = SKAction.run { [weak self] in
                    self?.node.removeAction(forKey: "animation")
                    self?.node.removeAction(forKey: "walkAnimation")
                    self?.node.run(jumpAnim)
                }
                actions.append(playJump)
                actions.append(SKAction.wait(forDuration: jumpAnimDuration))
            }

            // Bezier arc
            let capturedStartX = approachX
            let capturedObstX = obstX
            var jumpOverFired = false

            let bezierAction = SKAction.customAction(withDuration: CatConstants.Jump.arcDuration) { [weak self] _, elapsed in
                guard let self = self else { return }
                let t = CGFloat(elapsed) / CatConstants.Jump.arcDuration
                let p0x = capturedStartX, p0y = groundY
                let p1x = capturedObstX,  p1y = groundY + CatConstants.Jump.arcHeight
                let p2x = landX,          p2y = groundY
                let oneMinusT = 1 - t
                let bx = oneMinusT * oneMinusT * p0x + 2 * oneMinusT * t * p1x + t * t * p2x
                let by = oneMinusT * oneMinusT * p0y + 2 * oneMinusT * t * p1y + t * t * p2y
                self.containerNode.position = CGPoint(x: bx, y: by)

                if !jumpOverFired && elapsed >= CatConstants.Jump.apexThreshold {
                    jumpOverFired = true
                    onJumpOver?(capturedObstacleCat)
                    capturedObstacleCat.playFrightReaction(awayFromX: self.containerNode.position.x)
                }
            }
            actions.append(bezierAction)

            // Ensure cat lands at ground level (bezier may not hit groundY exactly)
            let land = SKAction.run { [weak self] in
                self?.containerNode.position.y = groundY
            }
            actions.append(land)

            // Resume walk animation after landing
            let resumeWalk = SKAction.run { [weak self] in
                guard let self = self else { return }
                let walkAnim = self.currentState == .toolUse ? "walk-b" : "walk-a"
                if let frames = self.textures(for: walkAnim), !frames.isEmpty {
                    let animate = SKAction.animate(with: frames, timePerFrame: CatConstants.Animation.frameTimeWalk)
                    self.node.run(SKAction.repeatForever(animate), withKey: self.currentState == .toolUse ? "animation" : "walkAnimation")
                    self.node.color = self.sessionColor?.nsColor ?? .white
                    self.node.colorBlendFactor = self.sessionTintFactor
                }
            }
            actions.append(resumeWalk)

            lastX = landX
        }

        return actions
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
        guard currentState == .idle else { return }
        currentTargetFood = food

        let targetX = food.node.position.x
        let delta = targetX - containerNode.position.x
        let distance = abs(delta)

        // Update facing direction via unified path
        if delta < -CatConstants.Movement.facingDirectionThreshold {
            facingRight = false
        } else if delta > CatConstants.Movement.facingDirectionThreshold {
            facingRight = true
        }
        applyFacingDirection()

        // Stop idle animations
        node.removeAllActions()

        // Walk animation (reuse walk-b, same as toolUse)
        if let frames = textures(for: "walk-b"), !frames.isEmpty {
            let animate = SKAction.animate(with: frames, timePerFrame: CatConstants.Animation.frameTimeWalk)
            node.run(SKAction.repeatForever(animate), withKey: "animation")
            node.color = sessionColor?.nsColor ?? .white
            node.colorBlendFactor = sessionTintFactor
        }

        let speed: CGFloat = CatConstants.Movement.foodWalkSpeed
        let duration = max(CatConstants.Movement.foodWalkMinDuration, Double(distance) / Double(speed))
        let move = SKAction.moveTo(x: targetX, duration: duration)
        move.timingMode = .easeInEaseOut

        let arrive = SKAction.run { [weak self] in
            guard let self = self, self.currentTargetFood === food else { return }
            onArrival(self, food)
        }
        containerNode.run(SKAction.sequence([move, arrive]), withKey: "foodWalk")
    }

    func startEating(_ food: FoodSprite, completion: @escaping () -> Void) {
        pendingToolDescription = nil
        stateMachine.enter(CatEatingState.self)
        currentTargetFood = food
        node.removeAllActions()
        containerNode.removeAction(forKey: "foodWalk")

        if let frames = textures(for: "paw"), !frames.isEmpty {
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

        guard let scaredFrames = textures(for: "scared"), !scaredFrames.isEmpty else {
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
        node.removeAllActions()
        containerNode.removeAllActions()
        containerNode.setScale(1.0)

        // Walk to the nearest edge
        let edgeX: CGFloat = containerNode.position.x < sceneWidth / 2 ? -CatConstants.Movement.exitOffscreenOffset : sceneWidth + CatConstants.Movement.exitOffscreenOffset
        let duration = Double(abs(edgeX - containerNode.position.x)) / CatConstants.Movement.exitWalkSpeed

        // Face the exit direction
        if edgeX < containerNode.position.x {
            facingRight = false
        } else {
            facingRight = true
        }
        applyFacingDirection()

        // Play walk animation during exit
        if let frames = textures(for: "walk-a"), !frames.isEmpty {
            let animate = SKAction.animate(with: frames, timePerFrame: CatConstants.Animation.frameTimeExitWalk)
            let loop = SKAction.repeatForever(animate)
            node.run(loop, withKey: "walkAnimation")
            node.texture = frames[0]
            node.color = sessionColor?.nsColor ?? .white
            node.colorBlendFactor = sessionTintFactor
        }

        var completionFired = false
        let safeCompletion: () -> Void = {
            guard !completionFired else { return }
            completionFired = true
            completion()
        }

        let walk = SKAction.moveTo(x: edgeX, duration: max(duration, CatConstants.Movement.exitMinDuration))
        walk.timingMode = .easeIn

        containerNode.run(walk) {
            safeCompletion()
        }

        // GCD fallback for tests without a display link
        let walkDuration = max(duration, CatConstants.Movement.exitMinDuration)
        DispatchQueue.main.asyncAfter(deadline: .now() + walkDuration + 0.05) { [weak self] in
            guard let self = self, !self.hasDisplayLink else { return }
            self.containerNode.position.x = edgeX
            safeCompletion()
        }
    }

    /// Exit variant that jumps over any cats on the path, triggering fright reactions.
    func exitScene(
        sceneWidth: CGFloat,
        obstacles: [(cat: CatSprite, x: CGFloat)],
        onJumpOver: @escaping (CatSprite) -> Void,
        completion: @escaping () -> Void
    ) {
        node.removeAllActions()
        containerNode.removeAllActions()
        containerNode.setScale(1.0)
        containerNode.physicsBody?.isDynamic = false

        let myX = containerNode.position.x
        let groundY = containerNode.position.y  // actual resting Y (gravity-settled)
        let goingRight = myX >= sceneWidth / 2
        let edgeX: CGFloat = goingRight ? sceneWidth + CatConstants.Movement.exitOffscreenOffset : -CatConstants.Movement.exitOffscreenOffset

        // Face exit direction
        facingRight = goingRight
        applyFacingDirection()

        var completionFired = false
        let safeCompletion: () -> Void = {
            guard !completionFired else { return }
            completionFired = true
            completion()
        }

        // Helper: start looping walk-a animation
        func startWalkAnim() {
            if let frames = self.textures(for: "walk-a"), !frames.isEmpty {
                let animate = SKAction.animate(with: frames, timePerFrame: CatConstants.Animation.frameTimeExitWalk)
                self.node.run(SKAction.repeatForever(animate), withKey: "walkAnimation")
                self.node.texture = frames[0]
                self.node.color = self.sessionColor?.nsColor ?? .white
                self.node.colorBlendFactor = self.sessionTintFactor
            }
        }

        // Filter obstacles on the path — include overlapping cats (within 24px behind)
        let onPath: [(cat: CatSprite, x: CGFloat)]
        if goingRight {
            onPath = obstacles.filter { $0.x > myX - CatConstants.Jump.obstaclePathTolerance && $0.x < edgeX }
                              .sorted { $0.x < $1.x }
        } else {
            onPath = obstacles.filter { $0.x < myX + CatConstants.Jump.obstaclePathTolerance && $0.x > edgeX }
                              .sorted { $0.x > $1.x }
        }

        guard !onPath.isEmpty else {
            // No obstacles — original walk-to-edge behaviour
            let duration = Double(abs(edgeX - myX)) / CatConstants.Movement.exitWalkSpeed
            startWalkAnim()
            let walkAction = SKAction.moveTo(x: edgeX, duration: max(duration, CatConstants.Movement.exitMinDuration))
            walkAction.timingMode = .easeIn
            containerNode.run(walkAction) { safeCompletion() }
            // GCD fallback: fire completion if SKAction doesn't run (no display link)
            let walkDuration = max(duration, CatConstants.Movement.exitMinDuration)
            DispatchQueue.main.asyncAfter(deadline: .now() + walkDuration + 0.05) { [weak self] in
                guard let self = self, !self.hasDisplayLink else { return }
                self.containerNode.position.x = edgeX
                safeCompletion()
            }
            return
        }

        // Build action sequence: for each obstacle, walk-near → jump-over → continue
        var actions: [SKAction] = []
        var lastX = myX
        var gcdDelay: Double = 0  // cumulative delay for GCD fallback scheduling

        startWalkAnim()

        for obstacle in onPath {
            let obstX = obstacle.x
            let approachX = goingRight ? obstX - CatConstants.Jump.approachOffset : obstX + CatConstants.Jump.approachOffset
            let landX = goingRight ? obstX + CatConstants.Jump.approachOffset : obstX - CatConstants.Jump.approachOffset

            // Walk to approach point
            let approachDist = abs(approachX - lastX)
            let approachDuration: Double
            if approachDist > 1 {
                approachDuration = max(Double(approachDist) / CatConstants.Jump.approachWalkSpeed, CatConstants.Jump.approachMinDurationExit)
                let approachWalk = SKAction.moveTo(x: approachX, duration: approachDuration)
                approachWalk.timingMode = .easeOut
                actions.append(approachWalk)
            } else {
                approachDuration = 0
            }
            gcdDelay += approachDuration

            // Jump animation frames (visual — run on node via SKAction.run block)
            var jumpAnimDuration: Double = 0
            if let jumpFrames = textures(for: "jump"), !jumpFrames.isEmpty {
                jumpAnimDuration = Double(jumpFrames.count) * CatConstants.Animation.frameTimeJumpOver
                let jumpAnim = SKAction.animate(with: jumpFrames, timePerFrame: CatConstants.Animation.frameTimeJumpOver)
                let playJump = SKAction.run { [weak self] in
                    self?.node.removeAction(forKey: "walkAnimation")
                    self?.node.run(jumpAnim)
                }
                actions.append(playJump)
                actions.append(SKAction.wait(forDuration: jumpAnimDuration))
            }
            gcdDelay += jumpAnimDuration

            // Bezier arc over the obstacle
            let capturedStartX = approachX
            let capturedObstX = obstX
            let capturedObstacleCat = obstacle.cat
            var jumpOverFired = false

            let bezierAction = SKAction.customAction(withDuration: CatConstants.Jump.arcDuration) { [weak self] _, elapsed in
                guard let self = self else { return }
                let t = CGFloat(elapsed) / CatConstants.Jump.arcDuration
                let p0x = capturedStartX, p0y = groundY
                let p1x = capturedObstX,  p1y = groundY + CatConstants.Jump.arcHeight  // control point 50px up
                let p2x = landX,          p2y = groundY
                let oneMinusT = 1 - t
                let bx = oneMinusT * oneMinusT * p0x + 2 * oneMinusT * t * p1x + t * t * p2x
                let by = oneMinusT * oneMinusT * p0y + 2 * oneMinusT * t * p1y + t * t * p2y
                self.containerNode.position = CGPoint(x: bx, y: by)

                // Fire onJumpOver at apex (t ≈ 0.5)
                if !jumpOverFired && elapsed >= CatConstants.Jump.apexThreshold {
                    jumpOverFired = true
                    onJumpOver(capturedObstacleCat)
                }
            }
            actions.append(bezierAction)

            // Ensure cat lands at ground level (bezier may not hit y=48 exactly)
            let landAction = SKAction.run { [weak self] in
                self?.containerNode.position.y = groundY
            }
            actions.append(landAction)

            // GCD fallback: only for test environments (no display link)
            let capturedGcdDelay = gcdDelay + CatConstants.Jump.gcdFallbackOffset
            DispatchQueue.main.asyncAfter(deadline: .now() + capturedGcdDelay) { [weak self] in
                guard let self = self, !self.hasDisplayLink else { return }
                self.containerNode.position = CGPoint(x: capturedObstX, y: groundY + CatConstants.Jump.gcdMidArcYOffset)
                if !jumpOverFired {
                    jumpOverFired = true
                    onJumpOver(capturedObstacleCat)
                }
            }

            gcdDelay += CatConstants.Jump.arcDuration

            // Resume walk after landing (visual — on node)
            let resumeWalk = SKAction.run { [weak self] in
                guard let self = self else { return }
                if let frames = self.textures(for: "walk-a"), !frames.isEmpty {
                    let animate = SKAction.animate(with: frames, timePerFrame: CatConstants.Animation.frameTimeExitWalk)
                    self.node.run(SKAction.repeatForever(animate), withKey: "walkAnimation")
                    self.node.color = self.sessionColor?.nsColor ?? .white
                    self.node.colorBlendFactor = self.sessionTintFactor
                }
            }
            actions.append(resumeWalk)

            // GCD fallback: land position (test only)
            let capturedLandDelay = gcdDelay
            DispatchQueue.main.asyncAfter(deadline: .now() + capturedLandDelay) { [weak self] in
                guard let self = self, !self.hasDisplayLink else { return }
                self.containerNode.position = CGPoint(x: landX, y: groundY)
            }

            lastX = landX
        }

        // Final walk to edge
        let finalDist = abs(edgeX - lastX)
        let finalDuration: Double
        if finalDist > 1 {
            finalDuration = max(Double(finalDist) / CatConstants.Movement.exitWalkSpeed, CatConstants.Movement.walkPostJumpMinDuration)
            let finalWalk = SKAction.moveTo(x: edgeX, duration: finalDuration)
            finalWalk.timingMode = .easeIn
            actions.append(finalWalk)
        } else {
            finalDuration = 0
        }
        gcdDelay += finalDuration

        actions.append(SKAction.run { safeCompletion() })
        containerNode.run(SKAction.sequence(actions), withKey: "exitSequence")

        // GCD fallback: completion (test only)
        DispatchQueue.main.asyncAfter(deadline: .now() + gcdDelay + 0.1) { [weak self] in
            guard let self = self, !self.hasDisplayLink else { return }
            self.containerNode.position.x = edgeX
            safeCompletion()
        }
    }
}
