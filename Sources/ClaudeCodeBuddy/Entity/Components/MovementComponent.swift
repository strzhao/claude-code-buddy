import SpriteKit

// MARK: - MovementComponent

/// Encapsulates all movement behaviour for a CatSprite:
///   - Organic random walk (toolUse state)
///   - Walking toward food
///   - Exit scene (simple walk-to-edge and obstacle-jumping exit)
class MovementComponent {

    // MARK: - Dependencies

    unowned let entity: CatSprite
    let jumpComponent: JumpComponent

    // MARK: - Weather

    /// Weather-driven speed multiplier (default 1.0)
    var speedMultiplier: CGFloat = 1.0

    // MARK: - Init

    init(entity: CatSprite) {
        self.entity = entity
        self.jumpComponent = JumpComponent(
            containerNode: entity.containerNode,
            spriteNode: entity.node,
            animationComponent: entity.animationComponent,
            personality: entity.personality
        )
    }

    // MARK: - Organic Random Walk (toolUse)

    /// Starts the recursive random walk used in toolUse state.
    func startRandomWalk() {
        doRandomWalkStep()
    }

    func doRandomWalkStep() {
        guard entity.currentState == .toolUse else { return }

        let containerNode = entity.containerNode

        // Graduated step distribution: mostly small, occasionally medium, rarely large
        let activityShift = entity.personality.stepSizeActivityShift
        let smallThreshold = CatConstants.Movement.walkStepSmallBaseProb - activityShift
        let mediumThreshold = smallThreshold + CatConstants.Movement.walkStepMediumBaseProb

        let stepRoll = Float.random(in: 0..<1)
        let stepRange: ClosedRange<CGFloat>
        switch stepRoll {
        case ..<smallThreshold:
            stepRange = CatConstants.Movement.walkStepSmall
        case ..<mediumThreshold:
            stepRange = CatConstants.Movement.walkStepMedium
        default:
            stepRange = CatConstants.Movement.walkStepMedium.upperBound...CatConstants.Movement.walkMaxRange
        }
        let stepMagnitude = CGFloat.random(in: stepRange)
        let direction: CGFloat = Bool.random() ? 1 : -1
        let rawTarget = entity.originX + direction * stepMagnitude

        let sceneWidth = entity.sceneWidth
        var target = sceneWidth > 0
            ? max(entity.activityMin, min(entity.effectiveActivityMax, rawTarget))
            : rawTarget

        target = adjustTargetAwayFromOtherCats(target)

        let delta = target - containerNode.position.x
        let distance = abs(delta)

        if distance < CatConstants.Movement.walkMinDistance {
            let pause = SKAction.wait(forDuration: Double.random(in: CatConstants.Movement.walkPauseRange))
            let next = SKAction.run { [weak self] in self?.doRandomWalkStep() }
            containerNode.run(SKAction.sequence([pause, next]), withKey: "randomWalk")
            return
        }

        entity.face(towardX: target)
        // Walk movement starts immediately — snap facing, don't wait for smooth turn
        if entity.node.action(forKey: "smoothTurn") != nil {
            entity.node.removeAction(forKey: "smoothTurn")
            entity.applyFacingDirection()
        }

        // --- Walk phase ---
        let speed: Double = Double.random(in: CatConstants.Movement.walkSpeedRange) * Double(speedMultiplier) * Double(entity.personality.walkSpeedMultiplier)
        let duration = max(CatConstants.Movement.walkMinDuration, Double(distance) / speed)

        // Speed-linked frame rate
        let timePerFrame = max(
            CatConstants.Movement.walkFrameTimeMin,
            min(CatConstants.Movement.walkFrameTimeMax,
                CatConstants.Animation.frameTimeWalk * (CatConstants.Movement.walkBaseSpeed / speed))
        )

        let animComponent = entity.animationComponent
        let sessionColor = entity.sessionColor
        let sessionTintFactor = entity.sessionTintFactor
        let node = entity.node
        if let walkFrames = animComponent.textures(for: "walk-b"), !walkFrames.isEmpty {
            let animate = SKAction.animate(with: walkFrames, timePerFrame: timePerFrame)
            node.run(SKAction.repeatForever(animate), withKey: "animation")
            node.color = sessionColor?.nsColor ?? .white
            node.colorBlendFactor = sessionTintFactor
        }

        // Walk-start slow: first frames play at reduced speed for acceleration feel
        if let walkAction = node.action(forKey: "animation") {
            walkAction.speed = CGFloat(1.0 / CatConstants.Movement.walkStartSlowFactor)
            let startupDelay = SKAction.wait(
                forDuration: timePerFrame * Double(CatConstants.Movement.walkStartSlowFrameCount) * CatConstants.Movement.walkStartSlowFactor
            )
            let normalSpeed = SKAction.run { [weak node] in
                node?.action(forKey: "animation")?.speed = 1.0
            }
            node.run(SKAction.sequence([startupDelay, normalSpeed]), withKey: "walkStartup")
        }

        let move = SKAction.moveTo(x: target, duration: duration)
        move.timingMode = .easeInEaseOut

        // --- Check for obstacles in the walk path and build jump actions ---
        let jumpActions = jumpComponent.buildJumpActions(
            from: containerNode.position.x,
            to: target,
            goingRight: delta > 0,
            nearbyObstacles: entity.nearbyObstacles,
            currentState: entity.currentState,
            sessionColor: sessionColor,
            sessionTintFactor: sessionTintFactor,
            activityMin: entity.activityMin,
            activityMax: entity.effectiveActivityMax
        )

        let stopWalkAndPause = SKAction.run { [weak self] in
            guard let self = self, self.entity.currentState == .toolUse else { return }
            node.removeAction(forKey: "animation")
            node.removeAction(forKey: "walkStartup")
            let standAnim = Float.random(in: 0..<1) < CatConstants.Movement.walkPawProbability ? "paw" : "idle-a"
            if let frames = animComponent.textures(for: standAnim), !frames.isEmpty {
                let animate = SKAction.animate(with: frames, timePerFrame: CatConstants.Animation.frameTimeStand)
                node.run(SKAction.repeatForever(animate), withKey: "animation")
                node.color = sessionColor?.nsColor ?? .white
                node.colorBlendFactor = sessionTintFactor
            }
            // Squash-and-settle on stop
            let squash = SKAction.scaleY(to: CatConstants.Movement.walkStopSquashScaleY,
                                          duration: CatConstants.Movement.walkStopSquashDuration)
            squash.timingMode = .easeOut
            let recover = SKAction.scaleY(to: 1.0,
                                           duration: CatConstants.Movement.walkStopRecoverDuration)
            recover.timingMode = .easeIn
            node.run(SKAction.sequence([squash, recover]), withKey: "walkSettle")
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
            // No obstacles — simple walk (physics stays dynamic)
            walkSequence.append(move)
        } else {
            // Disable physics so approach walk and Bezier arc aren't blocked by collisions
            let disablePhysics = SKAction.run { [weak self] in
                self?.entity.containerNode.physicsBody?.isDynamic = false
            }
            walkSequence.append(disablePhysics)

            walkSequence.append(contentsOf: jumpActions)

            // Walk remaining distance to target after last jump
            let remainDist = abs(target - containerNode.position.x)
            if remainDist > CatConstants.Movement.walkPostJumpMinDistance {
                let remainWalk = SKAction.moveTo(x: target, duration: max(CatConstants.Movement.walkPostJumpMinDuration, Double(remainDist) / speed))
                remainWalk.timingMode = .easeOut
                walkSequence.append(remainWalk)
            }

            // Re-enable physics after jump lands
            let enablePhysics = SKAction.run { [weak self] in
                self?.entity.containerNode.physicsBody?.isDynamic = true
            }
            walkSequence.append(enablePhysics)
        }

        if pauseDuration > 0 {
            let pause = SKAction.wait(forDuration: pauseDuration)
            containerNode.run(SKAction.sequence(walkSequence + [stopWalkAndPause, pause, next]), withKey: "randomWalk")
        } else {
            containerNode.run(SKAction.sequence(walkSequence + [next]), withKey: "randomWalk")
        }
    }

    /// Nudge proposed walk target away from nearby cats.
    /// Also avoids targets that require crossing through another cat for small steps.
    private func adjustTargetAwayFromOtherCats(_ proposedTarget: CGFloat) -> CGFloat {
        guard let obstacles = entity.nearbyObstacles?() else { return proposedTarget }
        let minDist = CatConstants.Separation.minDistance
        let myX = entity.containerNode.position.x
        var target = proposedTarget

        for obstacle in obstacles {
            // If an obstacle is between us and the target, redirect to our side
            let obstX = obstacle.x
            let crossesObstacle = (myX < obstX && target > obstX) || (myX > obstX && target < obstX)
            if crossesObstacle {
                let sameDirection: CGFloat = myX < obstX ? -1 : 1
                target = obstX + sameDirection * minDist
                target = max(entity.activityMin, min(entity.effectiveActivityMax, target))
            }

            // Also ensure target isn't too close to the obstacle
            let dist = abs(target - obstX)
            if dist < minDist {
                let direction: CGFloat = target >= obstX ? 1 : -1
                target = obstX + direction * minDist
                target = max(entity.activityMin, min(entity.effectiveActivityMax, target))
            }
        }
        return target
    }

    // MARK: - Walk To Food

    func walkToFood(_ food: FoodSprite, excitedDelay: TimeInterval = 0, onArrival: @escaping (CatSprite, FoodSprite) -> Void) {
        guard [.idle, .thinking, .toolUse].contains(entity.currentState) else { return }
        entity.currentTargetFood = food

        let containerNode = entity.containerNode
        let node = entity.node
        let targetX = food.node.position.x
        let delta = targetX - containerNode.position.x
        let distance = abs(delta)

        // Update facing direction via unified path
        entity.face(towardX: targetX)

        // Clean up state-specific animations before stopping actions
        containerNode.removeAction(forKey: "randomWalk")  // toolUse random walk
        node.zRotation = 0                                 // reset sway rotation
        node.yScale = 1.0                                  // reset scale before action cleanup
        node.position.y = 0                               // prevent residual offset

        // Stop idle animations
        node.removeAllActions()

        // Play excited reaction first (with per-cat distance-based delay), then start running
        entity.playExcitedReaction(delay: excitedDelay) { [weak self] in
            guard let self = self, self.entity.currentTargetFood === food else { return }

            // Run animation — use walk-a for food chasing
            let sessionColor = self.entity.sessionColor
            let sessionTintFactor = self.entity.sessionTintFactor
            if let frames = self.entity.animationComponent.textures(for: "walk-a"), !frames.isEmpty {
                let animate = SKAction.animate(with: frames, timePerFrame: CatConstants.Animation.frameTimeWalk)
                node.run(SKAction.repeatForever(animate), withKey: "animation")
                node.color = sessionColor?.nsColor ?? .white
                node.colorBlendFactor = sessionTintFactor
            }

            // Speed: base foodWalkSpeed px/s, +30% for distance > 200px, personality modifier
            let baseSpeed: CGFloat = CatConstants.Movement.foodWalkSpeed
            let speed = (distance > 200 ? baseSpeed * 1.3 : baseSpeed) * entity.personality.walkSpeedMultiplier
            let duration = max(0.2, Double(distance) / Double(speed))
            let move = SKAction.moveTo(x: targetX, duration: duration)
            move.timingMode = .easeIn

            let arrive = SKAction.run { [weak self] in
                guard let self = self, self.entity.currentTargetFood === food else { return }
                onArrival(self.entity, food)
            }
            containerNode.run(SKAction.sequence([move, arrive]), withKey: "foodWalk")
        }
    }

    // MARK: - Boundary Recovery Walk

    /// Walks the cat back into activity bounds from an out-of-bounds position.
    func walkBackIntoBounds(targetX: CGFloat) {
        let containerNode = entity.containerNode
        let node = entity.node
        let myX = containerNode.position.x
        let distance = abs(targetX - myX)

        guard distance > CatConstants.Movement.walkMinDistance else {
            containerNode.position.x = targetX
            entity.outOfBoundsSince = nil
            return
        }

        // Face toward the target
        entity.face(towardX: targetX)

        // Remove any existing recovery action to avoid stacking
        containerNode.removeAction(forKey: CatConstants.BoundaryRecovery.actionKey)
        containerNode.removeAction(forKey: "randomWalk")

        // Play walk animation
        if let frames = entity.animationComponent.textures(for: "walk-a"), !frames.isEmpty {
            let animate = SKAction.animate(with: frames, timePerFrame: 0.10)
            node.run(SKAction.repeatForever(animate), withKey: "animation")
            node.color = entity.sessionColor?.nsColor ?? .white
            node.colorBlendFactor = entity.sessionTintFactor
        }

        // Walk to target
        let duration = max(
            CatConstants.BoundaryRecovery.recoveryMinDuration,
            Double(distance) / CatConstants.BoundaryRecovery.recoveryWalkSpeed
        )
        let move = SKAction.moveTo(x: targetX, duration: duration)
        move.timingMode = .easeInEaseOut

        // After arriving, restore the current state's animation
        let recover = SKAction.run { [weak self] in
            guard let self = self else { return }
            self.entity.outOfBoundsSince = nil
            self.entity.node.removeAction(forKey: "animation")
            (self.entity.stateMachine?.currentState as? ResumableState)?.resume()
        }

        containerNode.run(
            SKAction.sequence([move, recover]),
            withKey: CatConstants.BoundaryRecovery.actionKey
        )
    }

    // MARK: - Exit Scene (simple, no obstacles)

    func exitScene(sceneWidth: CGFloat, completion: @escaping () -> Void) {
        let containerNode = entity.containerNode
        let node = entity.node
        node.removeAllActions()
        containerNode.removeAllActions()
        containerNode.setScale(entity.tokenScale)

        // Walk to the nearest edge (scaled offset for larger cats)
        let offset = CatConstants.Movement.exitOffscreenOffset * entity.tokenScale
        let edgeX: CGFloat = containerNode.position.x < sceneWidth / 2 ? -offset : sceneWidth + offset
        let duration = Double(abs(edgeX - containerNode.position.x)) / CatConstants.Movement.exitWalkSpeed

        // Face the exit direction
        entity.face(right: edgeX > containerNode.position.x)

        // Play walk animation during exit
        let sessionColor = entity.sessionColor
        let sessionTintFactor = entity.sessionTintFactor
        if let frames = entity.animationComponent.textures(for: "walk-a"), !frames.isEmpty {
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
            guard let self = self, !self.jumpComponent.hasDisplayLink else { return }
            containerNode.position.x = edgeX
            safeCompletion()
        }
    }

    // MARK: - Exit Scene (with obstacle jumping)

    /// Exit variant that jumps over any cats on the path, triggering fright reactions.
    func exitScene(
        sceneWidth: CGFloat,
        obstacles: [(cat: CatSprite, x: CGFloat)],
        onJumpOver: @escaping (CatSprite) -> Void,
        completion: @escaping () -> Void
    ) {
        let containerNode = entity.containerNode
        let node = entity.node
        node.removeAllActions()
        containerNode.removeAllActions()
        containerNode.setScale(entity.tokenScale)
        containerNode.physicsBody?.isDynamic = false
        containerNode.physicsBody?.collisionBitMask = 0

        let myX = containerNode.position.x
        let groundY = containerNode.position.y  // actual resting Y (gravity-settled)
        let goingRight = myX >= sceneWidth / 2
        let offset = CatConstants.Movement.exitOffscreenOffset * entity.tokenScale
        let edgeX: CGFloat = goingRight ? sceneWidth + offset : -offset

        // Face exit direction
        entity.face(right: goingRight)

        var completionFired = false
        let safeCompletion: () -> Void = {
            guard !completionFired else { return }
            completionFired = true
            completion()
        }

        let sessionColor = entity.sessionColor
        let sessionTintFactor = entity.sessionTintFactor

        // Helper: start looping walk-a animation
        func startWalkAnim() {
            if let frames = entity.animationComponent.textures(for: "walk-a"), !frames.isEmpty {
                let animate = SKAction.animate(with: frames, timePerFrame: CatConstants.Animation.frameTimeExitWalk)
                node.run(SKAction.repeatForever(animate), withKey: "walkAnimation")
                node.texture = frames[0]
                node.color = sessionColor?.nsColor ?? .white
                node.colorBlendFactor = sessionTintFactor
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
                guard let self = self, !self.jumpComponent.hasDisplayLink else { return }
                containerNode.position.x = edgeX
                safeCompletion()
            }
            return
        }

        // Build action sequence: for each obstacle, walk-near → jump-over → continue
        var actions: [SKAction] = []
        var gcdDelay: Double = 0  // cumulative delay for GCD fallback scheduling
        var lastLandX: CGFloat = myX

        startWalkAnim()

        jumpComponent.buildExitJumpActionsLoop(
            onPath: onPath,
            startX: myX,
            groundY: groundY,
            goingRight: goingRight,
            sessionColor: sessionColor,
            sessionTintFactor: sessionTintFactor,
            activityMin: entity.activityMin,
            activityMax: entity.effectiveActivityMax,
            onJumpOver: onJumpOver,
            actions: &actions,
            gcdDelay: &gcdDelay,
            lastLandX: &lastLandX
        )

        // Final walk to edge
        let finalDist = abs(edgeX - lastLandX)
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
            guard let self = self, !self.jumpComponent.hasDisplayLink else { return }
            containerNode.position.x = edgeX
            safeCompletion()
        }
    }
}
