import SpriteKit

// MARK: - JumpComponent

/// Encapsulates the Bezier arc jump logic used in two contexts:
///   1. Random-walk jumps (`buildJumpActions`) — no GCD fallbacks, returns [SKAction]
///   2. Exit-scene jumps (`buildExitJumpActionsLoop`) — with GCD fallbacks for XCTest
class JumpComponent {

    // MARK: - Dependencies

    unowned let containerNode: SKNode
    unowned let spriteNode: SKSpriteNode
    let animationComponent: AnimationComponent

    /// True when running in a real SpriteKit scene with display link (not in XCTest).
    var hasDisplayLink: Bool { containerNode.scene?.view != nil }

    // MARK: - Init

    init(containerNode: SKNode, spriteNode: SKSpriteNode, animationComponent: AnimationComponent) {
        self.containerNode = containerNode
        self.spriteNode = spriteNode
        self.animationComponent = animationComponent
    }

    // MARK: - Random Walk Jump Actions

    /// Builds SKAction sequence to jump over obstacles between `fromX` and `toX`.
    /// Used during random walk (toolUse state). Returns empty array if no obstacles are on path.
    ///
    /// - Parameters:
    ///   - fromX: Current X position of the jumping cat.
    ///   - toX: Target X position.
    ///   - goingRight: Direction of travel.
    ///   - nearbyObstacles: Closure to query other cats' positions.
    ///   - currentState: The cat's current state (used to pick walk animation key).
    ///   - sessionColor: Session tint color.
    ///   - sessionTintFactor: Session tint blend factor.
    ///   - onJumpOver: Optional callback fired at apex for each jumped-over cat.
    func buildJumpActions(
        from fromX: CGFloat,
        to toX: CGFloat,
        goingRight: Bool,
        nearbyObstacles: (() -> [(cat: CatSprite, x: CGFloat)])?,
        currentState: CatState,
        sessionColor: SessionColor?,
        sessionTintFactor: CGFloat,
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

            // Jump animation frames (visual — on node)
            if let jumpFrames = animationComponent.textures(for: "jump"), !jumpFrames.isEmpty {
                let jumpAnimDuration = Double(jumpFrames.count) * CatConstants.Animation.frameTimeJumpOver
                let jumpAnim = SKAction.animate(with: jumpFrames, timePerFrame: CatConstants.Animation.frameTimeJumpOver)
                let playJump = SKAction.run { [weak self] in
                    self?.spriteNode.removeAction(forKey: "animation")
                    self?.spriteNode.removeAction(forKey: "walkAnimation")
                    self?.spriteNode.run(jumpAnim)
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
            let capturedCurrentState = currentState
            let capturedSessionColor = sessionColor
            let capturedSessionTintFactor = sessionTintFactor
            let resumeWalk = SKAction.run { [weak self] in
                guard let self = self else { return }
                let walkAnim = capturedCurrentState == .toolUse ? "walk-b" : "walk-a"
                if let frames = self.animationComponent.textures(for: walkAnim), !frames.isEmpty {
                    let animate = SKAction.animate(with: frames, timePerFrame: CatConstants.Animation.frameTimeWalk)
                    self.spriteNode.run(SKAction.repeatForever(animate), withKey: capturedCurrentState == .toolUse ? "animation" : "walkAnimation")
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
    ///
    /// - Parameters:
    ///   - onPath: Obstacles on the exit path, already filtered and sorted by proximity.
    ///   - startX: X position before the first obstacle (the exiting cat's current X).
    ///   - groundY: Ground Y position (gravity-settled resting Y).
    ///   - goingRight: Whether the cat is exiting toward the right edge.
    ///   - sessionColor: Session tint color for walk animation.
    ///   - sessionTintFactor: Session tint blend factor for walk animation.
    ///   - onJumpOver: Callback fired at apex for each jumped obstacle.
    ///   - actions: In-out array; new SKActions are appended here.
    ///   - gcdDelay: In-out cumulative delay in seconds for GCD fallback scheduling.
    func buildExitJumpActionsLoop(
        onPath: [(cat: CatSprite, x: CGFloat)],
        startX: CGFloat,
        groundY: CGFloat,
        goingRight: Bool,
        sessionColor: SessionColor?,
        sessionTintFactor: CGFloat,
        onJumpOver: @escaping (CatSprite) -> Void,
        actions: inout [SKAction],
        gcdDelay: inout Double
    ) {
        var lastX = startX

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
            if let jumpFrames = animationComponent.textures(for: "jump"), !jumpFrames.isEmpty {
                jumpAnimDuration = Double(jumpFrames.count) * CatConstants.Animation.frameTimeJumpOver
                let jumpAnim = SKAction.animate(with: jumpFrames, timePerFrame: CatConstants.Animation.frameTimeJumpOver)
                let playJump = SKAction.run { [weak self] in
                    self?.spriteNode.removeAction(forKey: "walkAnimation")
                    self?.spriteNode.run(jumpAnim)
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
                let p1x = capturedObstX,  p1y = groundY + CatConstants.Jump.arcHeight
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

            // Ensure cat lands at ground level (bezier may not hit y exactly)
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
    }
}
