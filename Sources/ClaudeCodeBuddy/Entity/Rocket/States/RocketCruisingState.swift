import GameplayKit
import SpriteKit

/// Cruising = rocket left the pad / tower and is flying.
///
/// Two totally separate entry paths, picked on `entity.kind`:
///   • Conventional rockets (classic / shuttle / F9): retract animation,
///     pad slides down, container rises `hoverLift`pt with cubic ease-in.
///   • Starship: chopsticks retract horizontally, booster tumbles away,
///     NO vertical rise (ship already has its on-OLM altitude) — only
///     horizontal drift.
final class RocketCruisingState: RocketBaseState {
    override func isValidNextState(_ stateClass: AnyClass) -> Bool { true }

    override func didEnter(from previousState: GKState?) {
        if entity.kind == .starship3 {
            didEnterStarship(from: previousState)
        } else {
            didEnterConventional()
        }
    }

    override func willExit(to nextState: GKState) {
        entity.node.removeAction(forKey: "cruiseFrames")
        entity.containerNode.removeAction(forKey: "cruiseLift")
        entity.containerNode.removeAction(forKey: "cruiseDrift")
        entity.containerNode.removeAction(forKey: "starshipLiftoff")

        // Drop back to the pad only when exiting to a non-motion state
        // (not Liftoff / Landing / Abort which own their own vertical motion).
        // Starship never drops back — its altitude is managed by OnPad / Landing.
        guard entity.kind != .starship3 else { return }
        let keepAloft = nextState is RocketLiftoffState
            || nextState is RocketPropulsiveLandingState
            || nextState is RocketAbortStandbyState
        if !keepAloft {
            let drop = SKAction.moveTo(y: entity.kind.containerInitY,
                                        duration: 0.3)
            entity.containerNode.run(drop)
        }
    }

    // MARK: - Conventional rockets

    private func didEnterConventional() {
        entity.node.run(buildNodeAction(), withKey: "cruiseFrames")

        let groundY = entity.kind.containerInitY
        let isOnPad = entity.containerNode.position.y <= groundY + 1
        let hover = entity.kind.hoverLift

        if isOnPad && hover > 0 {
            entity.slidePadDown(by: hover,
                                duration: RocketConstants.Cruising.hoverLiftDuration,
                                curve: RocketConstants.Curves.cubicIn)

            let lift = SKAction.moveBy(x: 0,
                                        y: hover,
                                        duration: RocketConstants.Cruising.hoverLiftDuration)
            lift.timingFunction = RocketConstants.Curves.cubicIn
            let beginDrift = SKAction.run { [weak self] in self?.scheduleCruise() }
            entity.containerNode.run(SKAction.sequence([lift, beginDrift]),
                                      withKey: "cruiseLift")
        } else {
            scheduleCruise()
        }
    }

    // MARK: - Starship
    //
    // Two entry paths based on `previousState`:
    //
    //   FRESH LIFTOFF from OnPad (strict flow, no vertical motion):
    //     Phase 2 | 2.0s | Full stack translates x: anchor → anchor−17
    //                     concurrent with chopstick 3-frame animation
    //                     (closed → half → open). Ship texture stays at the
    //                     last onpad frame (ship-alone, NO flame) — ignition
    //                     only happens when the booster actually separates.
    //     Phase 3 | 3.0s non-blocking | Booster reparents to scene and
    //                     free-falls; ship ignites (cruise frames with small
    //                     Raptor flame) and enters horizontal drift.
    //
    //   RESUME from Abort (permission cleared): just pick back up drifting
    //     from the current position. No chopstick animation, no booster
    //     separation (already separated), no phase-2 lateral move.

    private func didEnterStarship(from previousState: GKState?) {
        if previousState is RocketAbortStandbyState {
            // Resume — silently swap abort frames back to cruise frames and
            // resume drifting. Position is preserved.
            entity.node.run(cruiseLoopAction(), withKey: "cruiseFrames")
            scheduleCruise()
            return
        }

        // Fresh liftoff from OnPad.
        // Phase 2 — lateral move + concurrent chopstick open animation. The
        // SUPER HEAVY booster lights at phase 2 start (ship is still dead —
        // ship texture stays at the last onpad frame, ship-alone, no flame).
        if let scene = entity.containerNode.scene as? BuddyScene {
            scene.setChopsticks(open: true, animated: true)
        }
        entity.setBoosterIgnited(true)
        // Mirror the lateral slide onto the scene-level flame plume so it
        // visibly drifts out of the OLM vents with the booster.
        entity.moveBoosterFlame(
            by: RocketConstants.Starship.olmEdgeOffset,
            duration: RocketConstants.Starship.lateralMoveDuration
        )

        let lateral = SKAction.moveBy(
            x: RocketConstants.Starship.olmEdgeOffset,
            y: 0,
            duration: RocketConstants.Starship.lateralMoveDuration
        )
        lateral.timingMode = .linear

        // Phase 3 fires when phase 2 completes — at the separation INSTANT:
        //   • Booster flame cuts (spent stage, dead weight).
        //   • Booster reparents to scene and begins its free-fall.
        //   • Ship Raptors ignite — cruise frames with small Raptor flame.
        //   • Ship enters horizontal drift.
        let startPhase3 = SKAction.run { [weak self, weak entity] in
            guard let self = self, let entity = entity else { return }
            entity.setBoosterIgnited(false)
            entity.separateBooster()
            entity.node.run(self.cruiseLoopAction(), withKey: "cruiseFrames")
            self.scheduleCruise()
        }

        entity.containerNode.run(
            SKAction.sequence([lateral, startPhase3]),
            withKey: "starshipLiftoff"
        )
    }

    // MARK: - Shared

    /// Loads cruise frames + optional retract pre-roll (non-Starship only).
    private func buildNodeAction() -> SKAction {
        let loop = cruiseLoopAction()
        // Starship skips the retract pre-roll: its retract_b frame uses
        // yOff=2 which caused a visible 2pt vertical jitter during the
        // phase-2 lateral move. Starship liftoff is procedural (lateral
        // slide + booster separation), not a scripted retract animation.
        guard entity.kind != .starship3 else { return loop }

        let (retractFrames, _) = RocketSpriteLoader.frames(for: "retract", kind: entity.kind)
        if retractFrames.count >= 2 {
            let retract = SKAction.animate(with: retractFrames, timePerFrame: 0.15)
            return SKAction.sequence([retract, loop])
        }
        return loop
    }

    /// Cruise-frame loop (no retract pre-roll). Kept separate so Starship's
    /// liftoff can schedule it explicitly at phase 3.
    private func cruiseLoopAction() -> SKAction {
        let (cruiseFrames, fps) = RocketSpriteLoader.frames(for: "cruise", kind: entity.kind)
        if let f = cruiseFrames.first { entity.node.texture = f }
        guard cruiseFrames.count > 1 else {
            return SKAction.wait(forDuration: 0.01)
        }
        return SKAction.repeatForever(
            SKAction.animate(with: cruiseFrames, timePerFrame: 1.0 / fps)
        )
    }

    /// Small horizontal step. Step magnitude 20-50pt over 2.5-4.0s.
    /// Non-Starship kinds are capped to avoid the OLM area.
    private func scheduleCruise() {
        let bounds = entity.activityBounds
        let padding: CGFloat = RocketConstants.Visual.spriteSize.width / 2

        let scene = entity.containerNode.scene as? BuddyScene
        let minX = bounds.lowerBound + padding
        let maxX: CGFloat
        if entity.kind == .starship3 {
            // Starship drift stays to the LEFT of the OLM edge — never crosses
            // back over the OLM or into the right tower. Container x cap =
            // anchor + olmEdgeOffset (= anchor − 17).
            let anchor = scene?.starshipAnchorX() ?? bounds.upperBound
            maxX = anchor + RocketConstants.Starship.olmEdgeOffset
        } else {
            let effectiveUpper = scene?.effectiveUpperBound(for: entity.kind) ?? bounds.upperBound
            maxX = effectiveUpper - padding
        }
        guard minX < maxX else { return }

        let currentX = entity.containerNode.position.x
        let stepMin = RocketConstants.Cruising.walkStepMin
        let stepMax = RocketConstants.Cruising.walkStepMax
        let magnitude = CGFloat.random(in: stepMin...stepMax)

        let distToLeft = currentX - minX
        let distToRight = maxX - currentX
        let direction: CGFloat
        if distToLeft < stepMax && distToRight >= stepMax {
            direction = 1
        } else if distToRight < stepMax && distToLeft >= stepMax {
            direction = -1
        } else {
            direction = Bool.random() ? 1 : -1
        }
        var targetX = currentX + direction * magnitude
        targetX = min(max(targetX, minX), maxX)
        if abs(targetX - currentX) < 1 {
            targetX = min(max(currentX - direction * magnitude, minX), maxX)
        }

        let duration = Double.random(in: RocketConstants.Cruising.walkDurationMin
                                        ... RocketConstants.Cruising.walkDurationMax)
        let move = SKAction.moveTo(x: targetX, duration: duration)
        move.timingMode = .easeInEaseOut
        let next = SKAction.run { [weak self] in self?.scheduleCruise() }
        entity.containerNode.run(SKAction.sequence([move, next]),
                                  withKey: "cruiseDrift")
    }
}
