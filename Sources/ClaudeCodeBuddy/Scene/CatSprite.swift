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
    case sleep, breathe, blink
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
        shadow.position = CGPoint(x: 1, y: 27)
        shadow.verticalAlignmentMode = .bottom
        shadow.horizontalAlignmentMode = .center
        shadow.zPosition = 9
        node.addChild(shadow)
        shadowLabelNode = shadow

        // Create main label
        let label = SKLabelNode(text: labelText)
        label.fontName = NSFont.boldSystemFont(ofSize: 11).fontName
        label.fontSize = 11
        label.fontColor = color.nsColor
        label.position = CGPoint(x: 0, y: 28)
        label.verticalAlignmentMode = .bottom
        label.horizontalAlignmentMode = .center
        label.zPosition = 10
        node.addChild(label)
        labelNode = label
    }

    func updateLabel(_ newLabel: String) {
        labelNode?.text = newLabel
        shadowLabelNode?.text = newLabel
    }

    // MARK: - State Machine

    func switchState(to newState: CatState) {
        guard newState != currentState else { return }
        currentState = newState

        node.removeAllActions()
        removeAlertOverlay()
        // Reset transform from previous state effects
        node.xScale = 1.0
        node.yScale = 1.0
        node.zRotation = 0

        switch newState {
        case .idle:
            node.color = sessionColor?.nsColor ?? .orange
            node.colorBlendFactor = sessionTintFactor
            // Play jump transition then enter idle loop
            if let jumpFrames = textures(for: "jump"), !jumpFrames.isEmpty {
                let jumpAnim = SKAction.animate(with: jumpFrames, timePerFrame: 0.12)
                let enterIdle = SKAction.run { [weak self] in
                    guard let self = self, self.currentState == .idle else { return }
                    self.startIdleLoop()
                }
                node.run(SKAction.sequence([jumpAnim, enterIdle]), withKey: "animation")
                node.texture = jumpFrames[0]
                node.color = sessionColor?.nsColor ?? .white
                node.colorBlendFactor = sessionTintFactor
            } else {
                startIdleLoop()
            }

        case .thinking:
            // Paw animation + gentle sway
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

        case .toolUse:
            // Walk-b animation (fast) + left-right micro-pace
            if let frames = textures(for: "walk-b"), !frames.isEmpty {
                let animate = SKAction.animate(with: frames, timePerFrame: 0.08)
                let loop = SKAction.repeatForever(animate)
                node.run(loop, withKey: "animation")
                node.texture = frames[0]
                node.color = sessionColor?.nsColor ?? .white
                node.colorBlendFactor = sessionTintFactor
            }
            // Micro-pace ±4px
            let paceRight = SKAction.moveBy(x: 4, y: 0, duration: 0.2)
            let paceLeft = SKAction.moveBy(x: -4, y: 0, duration: 0.2)
            let pace = SKAction.repeatForever(SKAction.sequence([paceRight, paceLeft]))
            node.run(pace, withKey: "stateEffect")

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

            // "!" alert badge
            addAlertOverlay()
        }
    }

    // MARK: - Alert Overlay

    private func addAlertOverlay() {
        let overlay = SKNode()
        overlay.zPosition = 15

        let circle = SKShapeNode(circleOfRadius: 8)
        circle.fillColor = NSColor(red: 0.95, green: 0.2, blue: 0.1, alpha: 1)
        circle.strokeColor = .white
        circle.lineWidth = 1.0
        circle.position = CGPoint(x: 18, y: 22)
        overlay.addChild(circle)

        let label = SKLabelNode(text: "!")
        label.fontName = NSFont.boldSystemFont(ofSize: 12).fontName
        label.fontSize = 12
        label.fontColor = .white
        label.verticalAlignmentMode = .center
        label.horizontalAlignmentMode = .center
        label.position = CGPoint(x: 18, y: 22)
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
        // Weighted random: sleep 80%, breathe 10%, blink 10%
        let roll = Float.random(in: 0..<1)
        switch roll {
        case ..<0.80: return .sleep
        case ..<0.90: return .breathe
        default:      return .blink
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
