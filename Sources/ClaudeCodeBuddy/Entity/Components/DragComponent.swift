import SpriteKit

// MARK: - DragComponent

class DragComponent {

    // MARK: - Dependencies

    unowned let entity: CatSprite

    // MARK: - State

    private(set) var isDragging = false
    private(set) var isLanding = false
    var isOccupied: Bool { isDragging || isLanding }

    private var preState: CatState?
    private var dragOffset = CGPoint.zero

    var onWindowExpand: ((Bool) -> Void)?
    var onLandingComplete: (() -> Void)?

    // MARK: - Init

    init(entity: CatSprite) {
        self.entity = entity
    }

    // MARK: - Drag Lifecycle

    func startDrag(at scenePoint: CGPoint) {
        guard !isOccupied else { return }

        isDragging = true
        preState = entity.currentState

        let catPos = entity.containerNode.position
        dragOffset = CGPoint(x: scenePoint.x - catPos.x, y: scenePoint.y - catPos.y)

        entity.containerNode.physicsBody?.isDynamic = false
        entity.node.removeAllActions()
        entity.containerNode.removeAllActions()

        // Reset transform
        entity.node.position.y = 0
        entity.node.yScale = 1.0
        entity.node.zRotation = 0

        playGrabbedAnimation()
        onWindowExpand?(true)
    }

    func updatePosition(to scenePoint: CGPoint) {
        guard isDragging else { return }
        let targetX = scenePoint.x - dragOffset.x
        let targetY = max(scenePoint.y - dragOffset.y, CatConstants.Visual.groundY)
        // Weight feel: lerp toward target instead of instant snap
        let weightFactor: CGFloat = 1.0 - entity.personality.playfulness * 0.15
        let currentPos = entity.containerNode.position
        let newX = currentPos.x + (targetX - currentPos.x) * weightFactor
        let newY = currentPos.y + (targetY - currentPos.y) * weightFactor
        entity.containerNode.position = CGPoint(x: newX, y: newY)
    }

    func endDrag() {
        guard isDragging else { return }
        isDragging = false
        isLanding = true
        entity.node.removeAllActions()
        playFallAndBounce()
    }

    func cancelDrag() {
        guard isOccupied else { return }
        entity.containerNode.removeAction(forKey: "dragFall")
        entity.containerNode.removeAction(forKey: "dragRestore")
        entity.containerNode.removeAction(forKey: "dragDust")
        entity.containerNode.removeAction(forKey: "dragBounceDust")
        isDragging = false
        isLanding = false
        entity.containerNode.physicsBody?.isDynamic = true
        entity.containerNode.position.y = CatConstants.Visual.groundY
        onWindowExpand?(false)
        restoreState()
    }

    // MARK: - Grabbed Animation

    private func playGrabbedAnimation() {
        let textures = entity.animationComponent.textures(for: "grabbed")
            ?? entity.animationComponent.textures(for: "scared")
        guard let frames = textures, !frames.isEmpty else { return }

        let animate = SKAction.animate(with: frames, timePerFrame: CatConstants.Drag.frameTimeGrabbed)
        entity.node.texture = frames[0]
        entity.node.run(SKAction.repeatForever(animate), withKey: "animation")
        if let color = entity.sessionColor?.nsColor {
            entity.node.color = color
            entity.node.colorBlendFactor = entity.sessionTintFactor
        }
    }

    // MARK: - Bounce Model

    private struct Bounce {
        let velocity: CGFloat
        let duration: Double
        let peak: CGFloat
    }

    // MARK: - Fall & Bounce Physics

    private func playFallAndBounce() {
        let startY = entity.containerNode.position.y
        let groundY = CatConstants.Visual.groundY
        let gravity = CatConstants.Drag.dropGravity
        let restitution = CatConstants.Drag.bounceRestitution
        let minV = CatConstants.Drag.minBounceVelocity

        let fallHeight = startY - groundY

        if fallHeight < 1 {
            finishLanding()
            return
        }

        // Phase 1: Free fall
        let tImpact = sqrt(2 * fallHeight / gravity)
        let vImpact = gravity * tImpact

        // Phase 2-3: Bounces
        var bounces: [Bounce] = []
        var v = restitution * vImpact
        while v >= minV && bounces.count < 2 {
            let dur = Double(2 * v / gravity)
            let peak = v * v / (2 * gravity)
            bounces.append(Bounce(velocity: v, duration: dur, peak: peak))
            v *= restitution
        }

        let totalDuration = Double(tImpact) + bounces.reduce(0) { $0 + $1.duration }

        let fallAction = SKAction.customAction(withDuration: totalDuration) { [weak self] _, elapsed in
            guard let self = self else { return }
            let t = CGFloat(elapsed)
            var y: CGFloat

            if t <= tImpact {
                // Free fall
                y = startY - 0.5 * gravity * t * t
            } else {
                var phaseStart = tImpact
                y = groundY
                for bounce in bounces {
                    let phaseEnd = phaseStart + CGFloat(bounce.duration)
                    if t <= phaseEnd {
                        let bt = t - phaseStart
                        y = groundY + bounce.velocity * bt - 0.5 * gravity * bt * bt
                        break
                    }
                    phaseStart = phaseEnd
                }
            }

            self.entity.containerNode.position.y = max(y, groundY)
        }

        let snapGround = SKAction.run { [weak self] in
            self?.entity.containerNode.position.y = groundY
        }

        // Landing squash at first impact
        let squashActions = buildLandingSquash()

        let finish = SKAction.run { [weak self] in
            self?.finishLanding()
        }

        let sequence = SKAction.sequence([fallAction, snapGround] + squashActions + [finish])
        entity.containerNode.run(sequence, withKey: "dragFall")

        // Spawn dust at first impact time
        let dustDelay = SKAction.wait(forDuration: Double(tImpact))
        let spawnDust = SKAction.run { [weak self] in
            self?.spawnDustParticles()
        }
        entity.containerNode.run(SKAction.sequence([dustDelay, spawnDust]), withKey: "dragDust")

        // Spawn dust at each bounce landing (combined into single keyed action)
        if !bounces.isEmpty {
            var dustActions: [SKAction] = []
            var cumulativeTime = Double(tImpact)
            for bounce in bounces {
                cumulativeTime += bounce.duration
                dustActions.append(SKAction.wait(forDuration: cumulativeTime))
                dustActions.append(SKAction.run { [weak self] in
                    self?.spawnDustParticles()
                })
            }
            entity.containerNode.run(SKAction.sequence(dustActions), withKey: "dragBounceDust")
        }
    }

    // MARK: - Landing Effects

    private func facingSign() -> CGFloat {
        let spriteFacesRight = SkinPackManager.shared.activeSkin.manifest.spriteFacesRight ?? true
        return (entity.facingRight == spriteFacesRight) ? 1.0 : -1.0
    }

    private func buildLandingSquash() -> [SKAction] {
        let squash = SKAction.run { [weak self] in
            guard let self = self else { return }
            let sign = self.facingSign()
            self.entity.node.xScale = CatConstants.Drag.landingSquashScaleX * sign
            self.entity.node.yScale = CatConstants.Drag.landingSquashScaleY
        }

        let hold = SKAction.wait(forDuration: CatConstants.Drag.landingSquashDuration)

        let recover = SKAction.run { [weak self] in
            guard let self = self else { return }
            let sign = self.facingSign()
            let recoverX = SKAction.scaleX(to: 1.0 * sign, duration: CatConstants.Drag.landingRecoveryDuration)
            let recoverY = SKAction.scaleY(to: 1.0, duration: CatConstants.Drag.landingRecoveryDuration)
            recoverX.timingMode = EasingCurves.catLand.timingMode
            recoverY.timingMode = EasingCurves.catLand.timingMode
            self.entity.node.run(SKAction.group([recoverX, recoverY]), withKey: "landingRecovery")
        }

        let resetNodeY = SKAction.run { [weak self] in
            self?.entity.node.position.y = 0
        }

        return [squash, hold, recover, resetNodeY]
    }

    private func spawnDustParticles() {
        guard let scene = entity.containerNode.scene else { return }
        let landX = entity.containerNode.position.x
        let landY = entity.containerNode.position.y

        for _ in 0..<CatConstants.Drag.dustParticleCount {
            let size = CGFloat.random(in: CatConstants.PhysicsJump.dustParticleSizeRange)
            let dust = SKSpriteNode(
                color: NSColor(white: 0.7, alpha: CatConstants.PhysicsJump.dustAlpha),
                size: CGSize(width: size, height: size)
            )
            dust.position = CGPoint(x: landX, y: landY)
            scene.addChild(dust)

            let dustV = CatConstants.PhysicsJump.dustVelocityRange
            let vx = CGFloat.random(in: -dustV.upperBound...dustV.upperBound)
            let vy = CGFloat.random(in: 0...dustV.upperBound * 0.5)
            let fadeDur = CatConstants.PhysicsJump.dustFadeDuration
            let move = SKAction.moveBy(
                x: vx * CGFloat(fadeDur),
                y: vy * CGFloat(fadeDur),
                duration: fadeDur
            )
            let fade = SKAction.fadeOut(withDuration: fadeDur)
            let clean = SKAction.run { dust.removeFromParent() }
            dust.run(SKAction.sequence([SKAction.group([move, fade]), clean]))
        }
    }

    // MARK: - Finish

    private func finishLanding() {
        isLanding = false
        entity.containerNode.physicsBody?.isDynamic = true
        onWindowExpand?(false)

        let wait = SKAction.wait(forDuration: CatConstants.Drag.restoreDelay)
        let restore = SKAction.run { [weak self] in
            self?.restoreState()
        }
        entity.containerNode.run(SKAction.sequence([wait, restore]), withKey: "dragRestore")
    }

    private func restoreState() {
        let targetState = entity.pendingStateAfterDrag ?? preState ?? .idle
        let targetDesc = entity.pendingToolDescriptionAfterDrag
        entity.pendingStateAfterDrag = nil
        entity.pendingToolDescriptionAfterDrag = nil
        preState = nil

        if targetState == entity.currentState {
            // Same state: animations were cleared by drag, need full re-enter.
            // switchState has a same-state guard, so force through idle first
            // to trigger proper willExit → didEnter lifecycle (e.g., taskComplete
            // needs to re-request bed slot and walk back).
            entity.switchState(to: .idle)
        }
        entity.switchState(to: targetState, toolDescription: targetDesc)
        onLandingComplete?()
    }
}
