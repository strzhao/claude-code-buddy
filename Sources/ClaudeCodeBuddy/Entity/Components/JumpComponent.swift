import SpriteKit

// MARK: - JumpComponent

/// Encapsulates the parabolic trajectory jump logic used in two contexts:
///   1. Random-walk jumps (`buildJumpActions`) — no GCD fallbacks, returns [SKAction]
///   2. Exit-scene jumps (`buildExitJumpActionsLoop`) — with GCD fallbacks for XCTest
///
/// Uses projectile motion equations (y = v₀y·t − ½g·t²) for physically accurate
/// parabolic arcs with randomized initial velocities for variation.
class JumpComponent {

    // MARK: - Dependencies

    unowned let containerNode: SKNode
    unowned let spriteNode: SKSpriteNode
    let animationComponent: AnimationComponent
    let personality: CatPersonality

    /// True when running in a real SpriteKit scene with display link (not in XCTest).
    var hasDisplayLink: Bool { containerNode.scene?.view != nil }

    // MARK: - Init

    init(containerNode: SKNode, spriteNode: SKSpriteNode, animationComponent: AnimationComponent, personality: CatPersonality) {
        self.containerNode = containerNode
        self.spriteNode = spriteNode
        self.animationComponent = animationComponent
        self.personality = personality
    }

    // MARK: - Trajectory Model

    /// Encapsulates the physics of a single parabolic jump.
    private struct JumpTrajectory {
        let startX: CGFloat
        let groundY: CGFloat
        let v0x: CGFloat
        let v0y: CGFloat
        let gravity: CGFloat
        let duration: Double

        /// Peak height above groundY in px.
        var peakHeight: CGFloat { v0y * v0y / (2 * gravity) }

        /// Time at which peak occurs (seconds from takeoff).
        var peakTime: Double { Double(v0y / gravity) }

        /// Position at time t (0 <= t <= duration). Clamps y to groundY.
        func position(at t: Double) -> (x: CGFloat, y: CGFloat) {
            let tt = CGFloat(t)
            let x = startX + v0x * tt
            let y = groundY + v0y * tt - 0.5 * gravity * tt * tt
            return (x: x, y: max(y, groundY))
        }
    }

    // MARK: - Trajectory Calculation

    /// Computes a randomized parabolic trajectory for a jump from approachX to landX.
    /// Adjusts horizontal velocity to match the required landing distance.
    private func computeTrajectory(
        from approachX: CGFloat,
        to landX: CGFloat,
        groundY: CGFloat,
        goingRight: Bool
    ) -> JumpTrajectory {
        let v0y = CGFloat.random(in: CatConstants.PhysicsJump.velocityYRange) * personality.jumpVelocityMultiplier
        let horizontalDistance = abs(landX - approachX)
        let directionSign: CGFloat = goingRight ? 1 : -1

        // Flight duration: t_total = 2 * v0y / g
        let rawDuration = Double(2 * v0y / CatConstants.PhysicsJump.gravity)

        // Adjust v0x to land at the target distance, clamped to the allowed range
        let requiredV0x = horizontalDistance / CGFloat(rawDuration)
        let clampedV0x = max(
            CatConstants.PhysicsJump.velocityXRange.lowerBound,
            min(CatConstants.PhysicsJump.velocityXRange.upperBound, requiredV0x)
        )

        return JumpTrajectory(
            startX: approachX,
            groundY: groundY,
            v0x: clampedV0x * directionSign,
            v0y: v0y,
            gravity: CatConstants.PhysicsJump.gravity,
            duration: rawDuration
        )
    }

    // MARK: - Crouch / Launch Actions

    /// Returns actions for crouch (compress) + launch stretch on spriteNode.
    private func buildCrouchActions() -> [SKAction] {
        let crouchDuration = Double.random(in: CatConstants.PhysicsJump.crouchDurationRange)
        let crouch = SKAction.scaleY(to: CatConstants.PhysicsJump.crouchScaleY, duration: crouchDuration)
        crouch.timingMode = EasingCurves.catJump.timingMode

        let stretch = SKAction.scaleY(
            to: CatConstants.PhysicsJump.launchStretchScaleY,
            duration: CatConstants.PhysicsJump.launchStretchDuration
        )
        stretch.timingMode = EasingCurves.catJump.timingMode

        return [crouch, stretch]
    }

    // MARK: - Arc Actions

    /// Returns the parabolic arc action that moves containerNode and applies air stretch to spriteNode.
    private func buildArcAction(
        trajectory: JumpTrajectory,
        onJumpOver: ((CatSprite) -> Void)?,
        obstacleCat: CatSprite?
    ) -> SKAction {
        var jumpOverFired = false

        return SKAction.customAction(withDuration: trajectory.duration) { [weak self] _, elapsed in
            guard let self = self else { return }
            let pos = trajectory.position(at: Double(elapsed))
            self.containerNode.position = CGPoint(x: pos.x, y: pos.y)

            // Velocity-based air stretch
            let t = CGFloat(elapsed)
            let vy = trajectory.v0y - trajectory.gravity * t
            let velocityFraction = abs(vy) / trajectory.v0y
            let stretchY = 1.0 + (CatConstants.PhysicsJump.airStretchMaxScaleY - 1.0) * min(velocityFraction, 1.0)
            let squeezeX = 1.0 - (1.0 - CatConstants.PhysicsJump.airStretchSqueezeScaleX) * min(velocityFraction, 1.0)
            self.spriteNode.yScale = stretchY
            let facingSign: CGFloat = self.spriteNode.xScale > 0 ? 1 : -1
            self.spriteNode.xScale = squeezeX * facingSign

            // Fire onJumpOver near apex
            let apexTime = trajectory.duration * CatConstants.PhysicsJump.apexCallbackFraction
            if !jumpOverFired && elapsed >= apexTime {
                jumpOverFired = true
                if let cat = obstacleCat {
                    onJumpOver?(cat)
                    cat.playFrightReaction(awayFromX: self.containerNode.position.x)
                }
            }
        }
    }

    // MARK: - Landing Actions

    /// Returns actions for landing squash + dust particles + recovery.
    private func buildLandingActions() -> [SKAction] {
        // Landing squash (instant)
        let squash = SKAction.run { [weak self] in
            guard let self = self else { return }
            let facingSign: CGFloat = self.spriteNode.xScale > 0 ? 1 : -1
            self.spriteNode.xScale = CatConstants.PhysicsJump.landingSquashScaleX * facingSign
            self.spriteNode.yScale = CatConstants.PhysicsJump.landingSquashScaleY
        }

        // Spawn dust particles
        let spawnDust = SKAction.run { [weak self] in
            self?.spawnDustParticles()
        }

        // Hold squash briefly, modified by personality
        let holdDuration = CatConstants.PhysicsJump.landingSquashDuration * (1.0 + Double(personality.playfulness) * 0.3)
        let hold = SKAction.wait(forDuration: holdDuration)

        // Recover to normal scale with easing curve
        let recover = SKAction.run { [weak self] in
            guard let self = self else { return }
            let facingSign: CGFloat = self.spriteNode.xScale > 0 ? 1 : -1
            let recoverX = SKAction.scaleX(to: 1.0 * facingSign, duration: CatConstants.PhysicsJump.landingRecoveryDuration)
            let recoverY = SKAction.scaleY(to: 1.0, duration: CatConstants.PhysicsJump.landingRecoveryDuration)
            recoverX.timingMode = EasingCurves.catLand.timingMode
            recoverY.timingMode = EasingCurves.catLand.timingMode
            self.spriteNode.run(SKAction.group([recoverX, recoverY]), withKey: "landingRecovery")
        }

        // Reset node.position.y to prevent residue
        let resetNodeY = SKAction.run { [weak self] in
            self?.spriteNode.position.y = 0
        }

        // Ensure cat is at ground level
        let snapGround = SKAction.run { [weak self] in
            self?.containerNode.position.y = CatConstants.Visual.groundY
        }

        return [squash, spawnDust, hold, recover, snapGround, resetNodeY]
    }

    // MARK: - Dust Particles

    /// Spawns small dust particles at the current containerNode position.
    private func spawnDustParticles() {
        guard let scene = containerNode.scene else { return }
        let landX = containerNode.position.x
        let landY = containerNode.position.y

        for _ in 0..<CatConstants.PhysicsJump.dustParticleCount {
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

    // MARK: - Bounds Clamping

    /// Clamps a prospective landing X to stay within activity bounds.
    private func clampLandX(_ landX: CGFloat, activityMin: CGFloat, activityMax: CGFloat) -> CGFloat {
        let minBound = activityMin + CatConstants.PhysicsJump.boundsClearance
        let maxBound = activityMax - CatConstants.PhysicsJump.boundsClearance
        return max(minBound, min(maxBound, landX))
    }

    // MARK: - Random Walk Jump Actions

    /// Builds SKAction sequence to jump over obstacles between `fromX` and `toX`.
    /// Used during random walk (toolUse state). Returns empty array if no obstacles are on path.
    ///
    /// - Important: Callers must disable physics (`isDynamic = false`) before running the returned
    ///   actions and re-enable after. The approach walk and parabolic arc set `containerNode.position`
    ///   directly, which conflicts with an active physics body.
    func buildJumpActions(
        from fromX: CGFloat,
        to toX: CGFloat,
        goingRight: Bool,
        nearbyObstacles: (() -> [(cat: CatSprite, x: CGFloat)])?,
        currentState: CatState,
        sessionColor: SessionColor?,
        sessionTintFactor: CGFloat,
        activityMin: CGFloat = 0,
        activityMax: CGFloat = .infinity,
        onJumpOver: ((CatSprite) -> Void)? = nil
    ) -> [SKAction] {
        guard let obstacles = nearbyObstacles?() else { return [] }

        let tolerance = CatConstants.Jump.obstaclePathTolerance
        let onPath: [(cat: CatSprite, x: CGFloat)]
        if goingRight {
            onPath = obstacles
                .filter { $0.x >= fromX && $0.x < toX + tolerance }
                .sorted { $0.x < $1.x }
        } else {
            onPath = obstacles
                .filter { $0.x <= fromX && $0.x > toX - tolerance }
                .sorted { $0.x > $1.x }
        }

        guard !onPath.isEmpty else { return [] }

        let groundY = containerNode.position.y
        var actions: [SKAction] = []
        var lastX = fromX

        for obstacle in onPath {
            let obstX = obstacle.x
            let approachOffset = CGFloat.random(in: CatConstants.PhysicsJump.approachOffsetRange)
            let approachX = goingRight ? obstX - approachOffset : obstX + approachOffset
            let rawLandX = goingRight ? obstX + approachOffset : obstX - approachOffset
            let landX = clampLandX(rawLandX, activityMin: activityMin, activityMax: activityMax)
            let capturedObstacleCat = obstacle.cat

            // Walk to approach point
            let approachDist = abs(approachX - lastX)
            if approachDist > 1 {
                let approachWalk = SKAction.moveTo(
                    x: approachX,
                    duration: max(Double(approachDist) / CatConstants.Jump.approachWalkSpeed,
                                  CatConstants.Jump.approachMinDuration)
                )
                approachWalk.timingMode = .easeOut
                actions.append(approachWalk)
            }

            // Crouch + launch
            actions.append(contentsOf: buildCrouchActions())

            // Jump animation frames (visual — on node)
            if let jumpFrames = animationComponent.textures(for: "jump"), !jumpFrames.isEmpty {
                let jumpAnim = SKAction.animate(with: jumpFrames, timePerFrame: CatConstants.Animation.frameTimeJumpOver)
                let playJump = SKAction.run { [weak self] in
                    self?.spriteNode.removeAction(forKey: "animation")
                    self?.spriteNode.removeAction(forKey: "walkAnimation")
                    self?.spriteNode.run(jumpAnim)
                }
                actions.append(playJump)
            }

            // Compute trajectory and build arc
            let trajectory = computeTrajectory(from: approachX, to: landX, groundY: groundY, goingRight: goingRight)
            actions.append(buildArcAction(trajectory: trajectory, onJumpOver: onJumpOver, obstacleCat: capturedObstacleCat))

            // Snap to ground level
            let snapY = SKAction.run { [weak self] in
                self?.containerNode.position.y = groundY
            }
            actions.append(snapY)

            // Landing squash + dust + recovery
            actions.append(contentsOf: buildLandingActions())

            // Resume walk animation after landing
            let capturedCurrentState = currentState
            let capturedSessionColor = sessionColor
            let capturedSessionTintFactor = sessionTintFactor
            let resumeWalk = SKAction.run { [weak self] in
                guard let self = self else { return }
                let walkAnim = capturedCurrentState == .toolUse ? "walk-b" : "walk-a"
                if let frames = self.animationComponent.textures(for: walkAnim), !frames.isEmpty {
                    let animate = SKAction.animate(with: frames, timePerFrame: CatConstants.Animation.frameTimeWalk)
                    self.spriteNode.run(SKAction.repeatForever(animate),
                                        withKey: capturedCurrentState == .toolUse ? "animation" : "walkAnimation")
                    self.spriteNode.color = capturedSessionColor?.nsColor ?? .white
                    self.spriteNode.colorBlendFactor = capturedSessionTintFactor
                }
            }
            actions.append(resumeWalk)

            lastX = landX
        }

        return actions
    }

    // MARK: - Exit Scene Jump Loop

    /// Appends SKActions for jumping over each obstacle during an exit sequence,
    /// and schedules GCD fallback blocks (for test environments without a display link).
    func buildExitJumpActionsLoop(
        onPath: [(cat: CatSprite, x: CGFloat)],
        startX: CGFloat,
        groundY: CGFloat,
        goingRight: Bool,
        sessionColor: SessionColor?,
        sessionTintFactor: CGFloat,
        activityMin: CGFloat = 0,
        activityMax: CGFloat = .infinity,
        onJumpOver: @escaping (CatSprite) -> Void,
        actions: inout [SKAction],
        gcdDelay: inout Double,
        lastLandX: inout CGFloat
    ) {
        var lastX = startX

        for obstacle in onPath {
            let obstX = obstacle.x
            let approachOffset = CGFloat.random(in: CatConstants.PhysicsJump.approachOffsetRange)
            let approachX = goingRight ? obstX - approachOffset : obstX + approachOffset
            let rawLandX = goingRight ? obstX + approachOffset : obstX - approachOffset
            let landX = clampLandX(rawLandX, activityMin: activityMin, activityMax: activityMax)

            // Walk to approach point
            let approachDist = abs(approachX - lastX)
            let approachDuration: Double
            if approachDist > 1 {
                approachDuration = max(Double(approachDist) / CatConstants.Jump.approachWalkSpeed,
                                       CatConstants.Jump.approachMinDurationExit)
                let approachWalk = SKAction.moveTo(x: approachX, duration: approachDuration)
                approachWalk.timingMode = .easeOut
                actions.append(approachWalk)
            } else {
                approachDuration = 0
            }
            gcdDelay += approachDuration

            // Crouch + launch (visual only — don't add to gcdDelay, SKActions don't run in test mode)
            let crouchDuration = Double.random(in: CatConstants.PhysicsJump.crouchDurationRange)
            let crouch = SKAction.scaleY(to: CatConstants.PhysicsJump.crouchScaleY, duration: crouchDuration)
            crouch.timingMode = .easeIn
            let stretch = SKAction.scaleY(to: CatConstants.PhysicsJump.launchStretchScaleY,
                                           duration: CatConstants.PhysicsJump.launchStretchDuration)
            stretch.timingMode = .easeOut
            actions.append(crouch)
            actions.append(stretch)

            // Jump animation frames (visual only — don't add to gcdDelay)
            if let jumpFrames = animationComponent.textures(for: "jump"), !jumpFrames.isEmpty {
                let jumpAnim = SKAction.animate(with: jumpFrames, timePerFrame: CatConstants.Animation.frameTimeJumpOver)
                let playJump = SKAction.run { [weak self] in
                    self?.spriteNode.removeAction(forKey: "walkAnimation")
                    self?.spriteNode.run(jumpAnim)
                }
                actions.append(playJump)
                actions.append(SKAction.wait(forDuration: Double(jumpFrames.count) * CatConstants.Animation.frameTimeJumpOver))
            }

            // Compute trajectory and build arc
            let trajectory = computeTrajectory(from: approachX, to: landX, groundY: groundY, goingRight: goingRight)
            let capturedObstacleCat = obstacle.cat
            var jumpOverFired = false

            let arcAction = SKAction.customAction(withDuration: trajectory.duration) { [weak self] _, elapsed in
                guard let self = self else { return }
                let pos = trajectory.position(at: Double(elapsed))
                self.containerNode.position = CGPoint(x: pos.x, y: pos.y)

                // Velocity-based air stretch
                let t = CGFloat(elapsed)
                let vy = trajectory.v0y - trajectory.gravity * t
                let velocityFraction = abs(vy) / trajectory.v0y
                let stretchY = 1.0 + (CatConstants.PhysicsJump.airStretchMaxScaleY - 1.0) * min(velocityFraction, 1.0)
                let squeezeX = 1.0 - (1.0 - CatConstants.PhysicsJump.airStretchSqueezeScaleX) * min(velocityFraction, 1.0)
                self.spriteNode.yScale = stretchY
                let facingSign: CGFloat = self.spriteNode.xScale > 0 ? 1 : -1
                self.spriteNode.xScale = squeezeX * facingSign

                if !jumpOverFired && elapsed >= trajectory.duration * CatConstants.PhysicsJump.apexCallbackFraction {
                    jumpOverFired = true
                    onJumpOver(capturedObstacleCat)
                }
            }
            actions.append(arcAction)

            // Snap to ground
            let landAction = SKAction.run { [weak self] in
                self?.containerNode.position.y = groundY
            }
            actions.append(landAction)

            // Landing squash + dust + recovery
            actions.append(contentsOf: buildLandingActions())

            // GCD fallback: mid-arc position (test only)
            // Schedule at approachDuration + half the arc duration (visual delays excluded)
            let gcdFallbackDelay = gcdDelay + trajectory.duration * 0.5
            DispatchQueue.main.asyncAfter(deadline: .now() + gcdFallbackDelay) { [weak self] in
                guard let self = self, !self.hasDisplayLink else { return }
                let midPos = trajectory.position(at: trajectory.duration * 0.5)
                self.containerNode.position = CGPoint(x: midPos.x, y: midPos.y)
                if !jumpOverFired {
                    jumpOverFired = true
                    onJumpOver(capturedObstacleCat)
                }
            }

            gcdDelay += trajectory.duration

            // Resume walk after landing
            let capturedSessionColor = sessionColor
            let capturedSessionTintFactor = sessionTintFactor
            let resumeWalk = SKAction.run { [weak self] in
                guard let self = self else { return }
                if let frames = self.animationComponent.textures(for: "walk-a"), !frames.isEmpty {
                    let animate = SKAction.animate(with: frames, timePerFrame: CatConstants.Animation.frameTimeExitWalk)
                    self.spriteNode.run(SKAction.repeatForever(animate), withKey: "walkAnimation")
                    self.spriteNode.color = capturedSessionColor?.nsColor ?? .white
                    self.spriteNode.colorBlendFactor = capturedSessionTintFactor
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

        lastLandX = lastX
    }
}
