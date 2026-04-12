import SpriteKit
import ImageIO

// MARK: - CatState

enum CatState: String, CaseIterable {
    case idle              = "idle"
    case thinking          = "thinking"
    case toolUse           = "tool_use"
    case permissionRequest = "waiting"
}

// MARK: - IdleSubState

private enum IdleSubState {
    case sleep, breathe, blink, clean
}

// MARK: - CatSprite

class CatSprite {

    // MARK: Properties

    let sessionId: String
    private(set) var currentState: CatState = .idle

    /// The underlying SpriteKit node added to the scene.
    let node: SKSpriteNode

    /// Animation texture arrays keyed by animation name string.
    /// Known names: "idle-a", "idle-b", "clean", "sleep", "scared", "paw", "walk-a", "walk-b"
    private var animations: [String: [SKTexture]] = [:]

    /// Current idle sub-state.
    private var idleSubState: IdleSubState = .breathe

    // MARK: - Session Identity

    static let hitboxSize = CGSize(width: 48, height: 64)
    private var labelNode: SKLabelNode?
    private var shadowLabelNode: SKLabelNode?
    var sessionColor: SessionColor?
    private var sessionTintFactor: CGFloat = 0.3
    private var alertOverlayNode: SKNode?
    private var tabNameNode: SKLabelNode?
    private var tabNameShadowNode: SKLabelNode?
    private var tabName: String = ""
    /// The X position when the cat was placed, used as anchor for random movement.
    private var originX: CGFloat = 0
    /// Tracks previous state for transition animations.
    private var previousState: CatState?

    // MARK: Init

    init(sessionId: String) {
        self.sessionId = sessionId

        // Start with a placeholder 48x48 colored square if textures are missing
        node = SKSpriteNode(color: .orange, size: CGSize(width: 48, height: 48))
        node.name = "cat_\(sessionId)"

        setupPhysicsBody()
        loadTextures()
    }

    // MARK: - Physics

    private func setupPhysicsBody() {
        let body = SKPhysicsBody(rectangleOf: CGSize(width: 44, height: 44))
        body.allowsRotation = false
        body.categoryBitMask    = PhysicsCategory.cat
        body.collisionBitMask   = PhysicsCategory.cat | PhysicsCategory.ground
        body.contactTestBitMask = PhysicsCategory.ground
        body.restitution = 0.0
        body.friction    = 0.8
        body.linearDamping = 0.5
        node.physicsBody = body
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

    private func textures(for animName: String) -> [SKTexture]? {
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
        shadow.fontName = NSFont.boldSystemFont(ofSize: 11).fontName
        shadow.fontSize = 11
        shadow.fontColor = color.nsColor.withAlphaComponent(0.4)
        shadow.position = CGPoint(x: 1, y: 1)
        shadow.verticalAlignmentMode = .bottom
        shadow.horizontalAlignmentMode = .center
        shadow.zPosition = 9
        shadow.isHidden = true
        node.addChild(shadow)
        shadowLabelNode = shadow

        // Create main label
        let label = SKLabelNode(text: labelText)
        label.fontName = NSFont.boldSystemFont(ofSize: 11).fontName
        label.fontSize = 11
        label.fontColor = color.nsColor
        label.position = CGPoint(x: 0, y: 2)
        label.verticalAlignmentMode = .bottom
        label.horizontalAlignmentMode = .center
        label.zPosition = 10
        label.isHidden = true
        node.addChild(label)
        labelNode = label

        // 记录 tab name
        tabName = labelText

        // Create tab name shadow (for waiting state)
        let tabShadow = SKLabelNode(text: labelText)
        tabShadow.fontName = NSFont.boldSystemFont(ofSize: 9).fontName
        tabShadow.fontSize = 9
        tabShadow.fontColor = color.nsColor.withAlphaComponent(0.4)
        tabShadow.position = CGPoint(x: 1, y: 16)
        tabShadow.verticalAlignmentMode = .bottom
        tabShadow.horizontalAlignmentMode = .center
        tabShadow.zPosition = 9
        tabShadow.isHidden = true
        node.addChild(tabShadow)
        tabNameShadowNode = tabShadow

        // Create tab name label (for waiting state)
        let tabLabel = SKLabelNode(text: labelText)
        tabLabel.fontName = NSFont.boldSystemFont(ofSize: 9).fontName
        tabLabel.fontSize = 9
        tabLabel.fontColor = color.nsColor
        tabLabel.position = CGPoint(x: 0, y: 17)
        tabLabel.verticalAlignmentMode = .bottom
        tabLabel.horizontalAlignmentMode = .center
        tabLabel.zPosition = 10
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
            // Only update the tool-description label nodes; do not overwrite tabName
            labelNode?.text = text
            shadowLabelNode?.text = text
        }
        labelNode?.isHidden = false
        shadowLabelNode?.isHidden = false
    }

    func hideLabel() {
        labelNode?.isHidden = true
        shadowLabelNode?.isHidden = true
        tabNameNode?.isHidden = true
        tabNameShadowNode?.isHidden = true
    }

    // MARK: - State Machine

    func switchState(to newState: CatState, toolDescription: String? = nil) {
        guard newState != currentState else { return }
        let oldState = currentState
        previousState = oldState
        currentState = newState

        node.removeAllActions()
        removeAlertOverlay()
        hideLabel()
        // Reset transform from previous state effects
        node.xScale = 1.0
        node.yScale = 1.0
        node.zRotation = 0
        labelNode?.xScale = 1.0
        shadowLabelNode?.xScale = 1.0
        // Snap back to origin X (random walk may have drifted)
        if oldState == .toolUse && originX != 0 {
            node.position.x = originX
        }

        // Determine transition animation before entering new state
        let transition = transitionAnimation(from: oldState, to: newState)

        if let transition = transition {
            let enter = SKAction.run { [weak self] in
                guard let self = self, self.currentState == newState else { return }
                self.applyState(newState, toolDescription: toolDescription)
            }
            node.run(SKAction.sequence([transition, enter]), withKey: "transition")
        } else {
            applyState(newState, toolDescription: toolDescription)
        }
    }

    // MARK: - Transition Animations

    private func transitionAnimation(from: CatState, to: CatState) -> SKAction? {
        switch (from, to) {
        case (.idle, .thinking):
            // Wake up: blink then stretch
            guard let blinkFrames = textures(for: "idle-b") else { return nil }
            let blink = SKAction.animate(with: blinkFrames, timePerFrame: 0.12)
            return blink

        case (.permissionRequest, .idle), (.permissionRequest, .thinking):
            // Relief: jump
            guard let jumpFrames = textures(for: "jump") else { return nil }
            let jump = SKAction.animate(with: jumpFrames, timePerFrame: 0.12)
            return jump

        case (.toolUse, .idle), (.thinking, .idle):
            // Settle down: clean once (grooming = wind-down)
            guard let cleanFrames = textures(for: "clean") else { return nil }
            let clean = SKAction.animate(with: cleanFrames, timePerFrame: 0.15)
            return clean

        default:
            return nil
        }
    }

    // MARK: - State Application

    private func applyState(_ state: CatState, toolDescription: String? = nil) {
        switch state {
        case .idle:
            node.color = sessionColor?.nsColor ?? .orange
            node.colorBlendFactor = sessionTintFactor
            startIdleLoop()

        case .thinking:
            // Paw animation + gentle sway + breathing
            if let frames = textures(for: "paw"), !frames.isEmpty {
                let animate = SKAction.animate(with: frames, timePerFrame: 0.18)
                let loop = SKAction.repeatForever(animate)
                node.run(loop, withKey: "animation")
                node.texture = frames[0]
                node.color = sessionColor?.nsColor ?? .white
                node.colorBlendFactor = sessionTintFactor
            }
            // Gentle sway ±3°
            let swayRight = SKAction.rotate(toAngle: .pi / 60, duration: 0.6)
            swayRight.timingMode = .easeInEaseOut
            let swayLeft = SKAction.rotate(toAngle: -.pi / 60, duration: 0.6)
            swayLeft.timingMode = .easeInEaseOut
            let sway = SKAction.repeatForever(SKAction.sequence([swayRight, swayLeft]))
            node.run(sway, withKey: "stateEffect")
            startBreathing()

        case .toolUse:
            // Start with standing pose, random walk handles walk animation
            if let frames = textures(for: "idle-a"), !frames.isEmpty {
                node.texture = frames[0]
                node.color = sessionColor?.nsColor ?? .white
                node.colorBlendFactor = sessionTintFactor
            }
            originX = node.position.x
            startRandomWalk()
            startBreathing()

        case .permissionRequest:
            // Scared animation (fast) + bounce + shake + red override + "!" badge
            if let frames = textures(for: "scared"), !frames.isEmpty {
                let animate = SKAction.animate(with: frames, timePerFrame: 0.12)
                let loop = SKAction.repeatForever(animate)
                node.run(loop, withKey: "animation")
                node.texture = frames[0]
            }
            // Red color override
            node.color = NSColor(red: 1, green: 0.3, blue: 0, alpha: 1)
            node.colorBlendFactor = 0.55

            // Bounce scale pulse
            let scaleUp = SKAction.scale(to: 1.15, duration: 0.175)
            scaleUp.timingMode = .easeIn
            let scaleDown = SKAction.scale(to: 1.0, duration: 0.175)
            scaleDown.timingMode = .easeOut
            let bounce = SKAction.repeatForever(SKAction.sequence([scaleUp, scaleDown]))
            node.run(bounce, withKey: "stateEffect")

            // Horizontal shake
            let shakeRight = SKAction.moveBy(x: 3, y: 0, duration: 0.04)
            let shakeLeft = SKAction.moveBy(x: -6, y: 0, duration: 0.04)
            let shakeBack = SKAction.moveBy(x: 3, y: 0, duration: 0.04)
            let shake = SKAction.repeatForever(SKAction.sequence([shakeRight, shakeLeft, shakeBack]))
            node.run(shake, withKey: "shakeEffect")

            // Show tool description label
            let displayText = toolDescription ?? "Permission?"
            showLabel(text: displayText)
            // Override label color to white for visibility on red cat
            labelNode?.fontColor = .white
            shadowLabelNode?.fontColor = NSColor(white: 0, alpha: 0.6)

            // "!" badge positioned to the right of the label text
            addAlertOverlay(afterLabel: displayText)

            // Show tab name above the tool description
            tabNameNode?.isHidden = false
            tabNameShadowNode?.isHidden = false
        }
    }

    // MARK: - Breathing (subtle scale oscillation for all active states)

    private func startBreathing() {
        let breatheIn = SKAction.scaleY(to: 1.02, duration: 1.0)
        breatheIn.timingMode = .easeInEaseOut
        let breatheOut = SKAction.scaleY(to: 1.0, duration: 1.0)
        breatheOut.timingMode = .easeInEaseOut
        let breathe = SKAction.repeatForever(SKAction.sequence([breatheIn, breatheOut]))
        node.run(breathe, withKey: "breathing")
    }

    // MARK: - Organic Random Walk (toolUse)

    /// Recursive random walk: pick a random target within range, move there
    /// with variable speed, pause randomly, then pick next target.
    private func startRandomWalk() {
        doRandomWalkStep()
    }

    private func doRandomWalkStep() {
        guard currentState == .toolUse else { return }

        // Random target: ±60px from origin (wide range)
        let maxRange: CGFloat = 60
        let target = originX + CGFloat.random(in: -maxRange...maxRange)

        // Flip sprite to face movement direction
        // Default sprite faces LEFT, so xScale=1.0 → left, xScale=-1.0 → right
        let delta = target - node.position.x
        if delta < -0.5 {
            node.xScale = 1.0
            labelNode?.xScale = 1.0
            shadowLabelNode?.xScale = 1.0
        } else if delta > 0.5 {
            node.xScale = -1.0
            labelNode?.xScale = -1.0
            shadowLabelNode?.xScale = -1.0
        }

        let distance = abs(delta)

        // Skip move if barely any distance, just pause
        if distance < 2.0 {
            let pause = SKAction.wait(forDuration: Double.random(in: 1.0...2.5))
            let next = SKAction.run { [weak self] in self?.doRandomWalkStep() }
            node.run(SKAction.sequence([pause, next]), withKey: "randomWalk")
            return
        }

        // --- Walk phase: play walk-b while moving ---
        let speed: Double = Double.random(in: 25...40) // px/s, leisurely
        let duration = max(0.3, Double(distance) / speed)

        // Start walk animation
        if let walkFrames = textures(for: "walk-b"), !walkFrames.isEmpty {
            let animate = SKAction.animate(with: walkFrames, timePerFrame: 0.10)
            node.run(SKAction.repeatForever(animate), withKey: "animation")
            node.color = sessionColor?.nsColor ?? .white
            node.colorBlendFactor = sessionTintFactor
        }

        let move = SKAction.moveTo(x: target, duration: duration)
        move.timingMode = .easeInEaseOut

        // --- Pause phase: stop walk, show standing pose ---
        let stopWalkAndPause = SKAction.run { [weak self] in
            guard let self = self, self.currentState == .toolUse else { return }
            self.node.removeAction(forKey: "animation")
            // Standing pose: use paw or idle-a
            let standAnim = Float.random(in: 0..<1) < 0.3 ? "paw" : "idle-a"
            if let frames = self.textures(for: standAnim), !frames.isEmpty {
                let animate = SKAction.animate(with: frames, timePerFrame: 0.25)
                self.node.run(SKAction.repeatForever(animate), withKey: "animation")
                self.node.color = self.sessionColor?.nsColor ?? .white
                self.node.colorBlendFactor = self.sessionTintFactor
            }
        }

        // Longer walks: mostly keep moving, occasional brief stop
        let pauseDuration: Double
        let roll = Float.random(in: 0..<1)
        if roll < 0.15 {
            pauseDuration = Double.random(in: 0.8...1.5)   // brief rest (15%)
        } else {
            pauseDuration = 0                                // keep moving (85%)
        }
        let pause = SKAction.wait(forDuration: pauseDuration)

        let next = SKAction.run { [weak self] in self?.doRandomWalkStep() }

        if pauseDuration > 0 {
            let pause = SKAction.wait(forDuration: pauseDuration)
            node.run(SKAction.sequence([move, stopWalkAndPause, pause, next]), withKey: "randomWalk")
        } else {
            // No pause — walk continuously to next target
            node.run(SKAction.sequence([move, next]), withKey: "randomWalk")
        }
    }

    // MARK: - Alert Overlay

    private func addAlertOverlay(afterLabel text: String) {
        let overlay = SKNode()
        overlay.zPosition = 15

        // Estimate label width: ~7pt per character at font size 11
        let labelHalfWidth = CGFloat(text.count) * 3.5
        let badgeX = labelHalfWidth + 12

        let circle = SKShapeNode(circleOfRadius: 8)
        circle.fillColor = NSColor(red: 0.95, green: 0.2, blue: 0.1, alpha: 1)
        circle.strokeColor = .white
        circle.lineWidth = 1.0
        circle.position = CGPoint(x: badgeX, y: 8)
        overlay.addChild(circle)

        let label = SKLabelNode(text: "!")
        label.fontName = NSFont.boldSystemFont(ofSize: 12).fontName
        label.fontSize = 12
        label.fontColor = .white
        label.verticalAlignmentMode = .center
        label.horizontalAlignmentMode = .center
        label.position = CGPoint(x: badgeX, y: 8)
        overlay.addChild(label)

        // Pulse the badge
        let fadeOut = SKAction.fadeAlpha(to: 0.3, duration: 0.25)
        let fadeIn = SKAction.fadeAlpha(to: 1.0, duration: 0.25)
        let pulse = SKAction.repeatForever(SKAction.sequence([fadeOut, fadeIn]))
        overlay.run(pulse)

        node.addChild(overlay)
        alertOverlayNode = overlay
    }

    private func removeAlertOverlay() {
        alertOverlayNode?.removeFromParent()
        alertOverlayNode = nil
    }

    // MARK: - Idle State Machine

    private func startIdleLoop() {
        idleSubState = pickNextIdleSubState()
        runIdleSubState()
    }

    private func pickNextIdleSubState() -> IdleSubState {
        // Weighted random: sleep 70%, breathe 10%, blink 10%, clean 10%
        let roll = Float.random(in: 0..<1)
        switch roll {
        case ..<0.70: return .sleep
        case ..<0.80: return .breathe
        case ..<0.90: return .blink
        default:      return .clean
        }
    }

    private func runIdleSubState() {
        // Guard: only run if still in idle state
        guard currentState == .idle else { return }

        switch idleSubState {
        case .sleep:
            if let frames = textures(for: "sleep"), !frames.isEmpty {
                let animDuration = 1.0 / Double(frames.count)
                let animate = SKAction.animate(with: frames, timePerFrame: animDuration)
                let loopSleep = SKAction.repeat(animate, count: 3)
                let wait = SKAction.wait(forDuration: 5, withRange: 2)
                let next = SKAction.run { [weak self] in
                    guard let self = self, self.currentState == .idle else { return }
                    self.idleSubState = self.pickNextIdleSubState()
                    self.runIdleSubState()
                }
                node.run(SKAction.sequence([loopSleep, wait, next]), withKey: "idleLoop")
                node.texture = frames[0]
                node.color = sessionColor?.nsColor ?? .white
                node.colorBlendFactor = sessionTintFactor
            } else {
                idleSubState = .breathe
                runIdleSubState()
            }

        case .breathe:
            playIdleAnimation(animName: "idle-a", looping: true)
            scheduleNextIdleTransition(after: SKAction.wait(forDuration: 4, withRange: 2))

        case .blink:
            if let frames = textures(for: "idle-b"), !frames.isEmpty {
                let duration = 2.0 / Double(frames.count)
                let animate = SKAction.animate(with: frames, timePerFrame: duration)
                let next = SKAction.run { [weak self] in
                    guard let self = self, self.currentState == .idle else { return }
                    self.idleSubState = self.pickNextIdleSubState()
                    self.runIdleSubState()
                }
                node.run(SKAction.sequence([animate, next]), withKey: "idleLoop")
                node.texture = frames[0]
                node.color = sessionColor?.nsColor ?? .white
                node.colorBlendFactor = sessionTintFactor
            } else {
                idleSubState = .sleep
                runIdleSubState()
            }

        case .clean:
            if let frames = textures(for: "clean"), !frames.isEmpty {
                let duration = 3.0 / Double(frames.count)
                let animate = SKAction.animate(with: frames, timePerFrame: duration)
                let next = SKAction.run { [weak self] in
                    guard let self = self, self.currentState == .idle else { return }
                    self.idleSubState = self.pickNextIdleSubState()
                    self.runIdleSubState()
                }
                node.run(SKAction.sequence([animate, next]), withKey: "idleLoop")
                node.texture = frames[0]
                node.color = sessionColor?.nsColor ?? .white
                node.colorBlendFactor = sessionTintFactor
            } else {
                idleSubState = .sleep
                runIdleSubState()
            }
        }
    }

    private func playIdleAnimation(animName: String, looping: Bool) {
        guard let frames = textures(for: animName), !frames.isEmpty else { return }
        let animate = SKAction.animate(with: frames, timePerFrame: 0.20)
        let action = looping ? SKAction.repeatForever(animate) : animate
        node.run(action, withKey: "idleLoop")
        node.texture = frames[0]
        node.color = sessionColor?.nsColor ?? .white
        node.colorBlendFactor = sessionTintFactor
    }

    private func scheduleNextIdleTransition(after waitAction: SKAction) {
        let pickAndRun = SKAction.run { [weak self] in
            guard let self = self, self.currentState == .idle else { return }
            self.idleSubState = self.pickNextIdleSubState()
            self.node.removeAction(forKey: "idleLoop")
            self.runIdleSubState()
        }
        node.run(SKAction.sequence([waitAction, pickAndRun]), withKey: "idleTransition")
    }

    // MARK: - Enter / Exit

    func enterScene(sceneSize: CGSize) {
        // Start above the visible area
        node.position = CGPoint(x: node.position.x, y: sceneSize.height + 48)

        // Play walk animation during drop
        if let frames = textures(for: "walk-a"), !frames.isEmpty {
            let animate = SKAction.animate(with: frames, timePerFrame: 0.12)
            let loop = SKAction.repeatForever(animate)
            node.run(loop, withKey: "walkAnimation")
            node.texture = frames[0]
            node.color = sessionColor?.nsColor ?? .white
            node.colorBlendFactor = sessionTintFactor
        }

        // Drop down to ground level
        let landY: CGFloat = 48
        let drop = SKAction.moveTo(y: landY, duration: 0.6)
        drop.timingMode = .easeIn

        node.run(drop) { [weak self] in
            self?.node.removeAction(forKey: "walkAnimation")
            self?.switchState(to: .idle)
        }
    }

    func exitScene(sceneWidth: CGFloat, completion: @escaping () -> Void) {
        node.removeAllActions()

        // Walk to the nearest edge
        let edgeX: CGFloat = node.position.x < sceneWidth / 2 ? -48 : sceneWidth + 48
        let duration = Double(abs(edgeX - node.position.x)) / 120.0

        // Flip sprite to face exit direction (default sprite faces LEFT)
        if edgeX < node.position.x {
            node.xScale = 1.0   // exiting left → face left
        } else {
            node.xScale = -1.0  // exiting right → face right
        }

        // Play walk animation during exit
        if let frames = textures(for: "walk-a"), !frames.isEmpty {
            let animate = SKAction.animate(with: frames, timePerFrame: 0.12)
            let loop = SKAction.repeatForever(animate)
            node.run(loop, withKey: "walkAnimation")
            node.texture = frames[0]
            node.color = sessionColor?.nsColor ?? .white
            node.colorBlendFactor = sessionTintFactor
        }

        let walk = SKAction.moveTo(x: edgeX, duration: max(duration, 0.5))
        walk.timingMode = .easeIn

        node.run(walk) {
            completion()
        }
    }
}
