import SpriteKit
import GameplayKit

// MARK: - InteractionComponent

/// Encapsulates fright reaction and hover scale behaviours for a CatEntity.
class InteractionComponent {

    // MARK: - Dependencies

    unowned let entity: CatEntity

    // MARK: - Init

    init(entity: CatEntity) {
        self.entity = entity
    }

    // MARK: - Hover Scale

    private static let hoverScale: CGFloat = CatConstants.Visual.hoverScale
    private static let hoverDuration: TimeInterval = CatConstants.Visual.hoverDuration

    func applyHoverScale() {
        entity.containerNode.removeAction(forKey: "hoverScale")
        let targetScale = entity.tokenScale * InteractionComponent.hoverScale
        let scale = SKAction.scale(to: targetScale, duration: InteractionComponent.hoverDuration)
        scale.timingMode = .easeOut
        entity.containerNode.run(scale, withKey: "hoverScale")
    }

    func removeHoverScale() {
        entity.containerNode.removeAction(forKey: "hoverScale")
        let scale = SKAction.scale(to: entity.tokenScale, duration: InteractionComponent.hoverDuration)
        scale.timingMode = .easeOut
        entity.containerNode.run(scale, withKey: "hoverScale")
    }

    // MARK: - Fright Reaction

    /// True when running in a real SpriteKit scene with display link (not in XCTest).
    private var hasDisplayLink: Bool { entity.containerNode.scene?.view != nil }

    /// Primary entry: called on the cat that was jumped over, passing the jumper's x position.
    func playFrightReaction(awayFromX jumperX: CGFloat) {
        // Don't interrupt permission-request state (it's already alert)
        guard entity.currentState != .permissionRequest else { return }

        entity.containerNode.physicsBody?.isDynamic = false
        entity.node.removeAllActions()

        // Decide escape direction: flee away from jumper
        let myX = entity.containerNode.position.x
        var fleeRight = myX > jumperX   // flee to the same side we're on relative to jumper

        // Check if fleeing direction has another cat; flip if opposite is clear
        if let obstacles = entity.nearbyObstacles?() {
            let fleeTarget = fleeRight
                ? myX + CatConstants.Fright.fleeDistance
                : myX - CatConstants.Fright.fleeDistance
            let minDist = CatConstants.Separation.minDistance

            let hasObstacleInFleeDir = obstacles.contains { obs in
                let obsX = obs.x  // named tuple
                if fleeRight {
                    return obsX > myX && obsX < fleeTarget + minDist
                } else {
                    return obsX < myX && obsX > fleeTarget - minDist
                }
            }

            if hasObstacleInFleeDir {
                let oppositeTarget = fleeRight
                    ? myX - CatConstants.Fright.fleeDistance
                    : myX + CatConstants.Fright.fleeDistance
                let hasObstacleInOpposite = obstacles.contains { obs in
                    let obsX = obs.x
                    if fleeRight {
                        return obsX < myX && obsX > oppositeTarget - minDist
                    } else {
                        return obsX > myX && obsX < oppositeTarget + minDist
                    }
                }
                if !hasObstacleInOpposite {
                    fleeRight = !fleeRight
                }
            }
        }

        let rawTarget = fleeRight ? myX + CatConstants.Fright.fleeDistance : myX - CatConstants.Fright.fleeDistance
        let clampedTarget: CGFloat
        if entity.sceneWidth > 0 {
            clampedTarget = max(entity.activityMin, min(entity.effectiveActivityMax, rawTarget))
        } else {
            clampedTarget = rawTarget
        }
        let slideDelta = clampedTarget - myX
        let reboundDelta = -slideDelta * CatConstants.Fright.reboundFactor

        // Face the flee direction
        entity.face(right: fleeRight)

        guard let scaredFrames = entity.animationComponent.textures(for: "scared"), !scaredFrames.isEmpty else {
            // Fallback: just re-enable physics and resume
            entity.containerNode.physicsBody?.isDynamic = true
            return
        }

        let scaredAnim = SKAction.animate(with: scaredFrames, timePerFrame: CatConstants.Animation.frameTimeScared)
        let slide      = SKAction.moveBy(x: slideDelta, y: 0, duration: CatConstants.Fright.slideDuration)
        slide.timingMode = .easeOut
        let rebound    = SKAction.moveBy(x: reboundDelta, y: 0, duration: CatConstants.Fright.reboundDuration)
        rebound.timingMode = .easeInEaseOut

        let recover = SKAction.run { [weak self] in
            guard let self = self else { return }
            self.entity.containerNode.physicsBody?.isDynamic = true
            if self.entity.currentState == .eating {
                // Use switchState so food is properly released
                self.entity.switchState(to: .idle)
            } else if self.entity.isOutOfBounds() {
                // Skip resume — BuddyScene boundary recovery will handle it
                return
            } else {
                // Re-apply steady state animation via ResumableState protocol
                (self.entity.stateMachine.currentState as? ResumableState)?.resume()
            }
        }

        entity.node.run(scaredAnim, withKey: "frightReaction")

        // Movement runs on containerNode (holds world position)
        let moveSequence = SKAction.sequence([
            SKAction.wait(forDuration: Double(scaredFrames.count) * CatConstants.Animation.frameTimeScared),
            slide,
            rebound,
            recover
        ])
        entity.containerNode.run(moveSequence, withKey: "frightMove")

        // GCD fallback for tests without a display link
        let scaredDuration = Double(scaredFrames.count) * CatConstants.Animation.frameTimeScared
        DispatchQueue.main.asyncAfter(deadline: .now() + CatConstants.Fright.gcdInitialOffset) { [weak self] in
            guard let self = self, !self.hasDisplayLink,
                  self.entity.containerNode.physicsBody?.isDynamic == false else { return }
            self.entity.containerNode.position.x += slideDelta
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + scaredDuration + CatConstants.Fright.slideDuration) { [weak self] in
            guard let self = self, !self.hasDisplayLink,
                  self.entity.containerNode.physicsBody?.isDynamic == false else { return }
            self.entity.containerNode.position.x += reboundDelta
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + scaredDuration + CatConstants.Fright.slideDuration + CatConstants.Fright.reboundDuration + CatConstants.Fright.gcdSettleOffset) { [weak self] in
            guard let self = self, !self.hasDisplayLink,
                  self.entity.containerNode.physicsBody?.isDynamic == false else { return }
            self.entity.containerNode.physicsBody?.isDynamic = true
            if self.entity.currentState == .eating {
                self.entity.switchState(to: .idle)
            } else if self.entity.isOutOfBounds() {
                return
            } else {
                (self.entity.stateMachine.currentState as? ResumableState)?.resume()
            }
        }
    }

    /// Convenience overload: react based on exit direction enum.
    func playFrightReaction(frightenedBy direction: ExitDirection) {
        let jumperX: CGFloat
        switch direction {
        case .left:
            jumperX = entity.containerNode.position.x - 1
        case .right:
            jumperX = entity.containerNode.position.x + 1
        }
        playFrightReaction(awayFromX: jumperX)
    }

    /// Convenience overload: pass the jumper CatEntity directly.
    func playFrightReaction(frightenedBy jumper: CatEntity) {
        playFrightReaction(awayFromX: jumper.containerNode.position.x)
    }
}
