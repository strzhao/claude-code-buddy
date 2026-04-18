import GameplayKit
import SpriteKit

/// Propulsive landing = rocket returning from flight.
///
/// Two totally separate entry paths, picked on `entity.kind`:
///   • Conventional rockets: find safe landing x (avoid other pads),
///     short horizontal pan if needed, pad rises + vertical descent
///     with cubic ease-out, transition to OnPad.
///   • Starship: pan back to the fixed OLM anchor x, open chopsticks
///     to RECEIVE the ship, wait the landing beat (NO vertical move —
///     ship is already at its tower altitude), close chopsticks to
///     "catch", transition to OnPad.
final class RocketPropulsiveLandingState: RocketBaseState {
    override func isValidNextState(_ stateClass: AnyClass) -> Bool { true }

    override func didEnter(from previousState: GKState?) {
        if entity.kind == .starship3 {
            // Starship does NOT play landing frames — those frames animate
            // the ship vertically in the canvas (yOff 8→4→0) and would make
            // it look like the ship rises then descends. Keep whatever
            // texture is currently showing (usually the last cruise frame).
            didEnterStarship()
        } else {
            playLandingFrames()
            didEnterConventional()
        }
    }

    override func willExit(to nextState: GKState) {
        entity.node.removeAction(forKey: "landingFrames")
        // Starship keeps cruiseFrames running through the landing so the
        // Raptor flame stays animated — stop it now before OnPad swaps in
        // its own onpad-frame loop.
        entity.node.removeAction(forKey: "cruiseFrames")
        entity.containerNode.removeAction(forKey: "propulsiveLanding")
    }

    // MARK: - Conventional rockets

    private func didEnterConventional() {
        let currentY = entity.containerNode.position.y
        let groundY = entity.kind.containerInitY

        // Already at / below the pad → no-op, jump to OnPad.
        if currentY <= groundY + 0.5 {
            entity.stateMachine.enter(RocketOnPadState.self)
            return
        }

        let descent = max(currentY - groundY, 0)
        let duration = RocketConstants.Landing.totalDuration

        let scene = entity.containerNode.scene as? BuddyScene
        let currentX = entity.containerNode.position.x
        let targetX = scene?.findSafeLandingX(excluding: entity.sessionId,
                                              near: currentX) ?? currentX

        var sequence: [SKAction] = []
        if abs(targetX - currentX) > 1 {
            let pan = SKAction.moveTo(x: targetX, duration: 0.5)
            pan.timingMode = .easeInEaseOut
            sequence.append(pan)
        }

        // Pad rises to meet the descending rocket.
        sequence.append(SKAction.run { [weak self] in
            guard let self = self else { return }
            self.entity.slidePadUp(by: descent,
                                    duration: duration,
                                    curve: RocketConstants.Curves.cubicOut)
        })

        let descend = SKAction.moveTo(y: groundY, duration: duration)
        descend.timingFunction = RocketConstants.Curves.cubicOut
        sequence.append(descend)

        sequence.append(SKAction.run { [weak entity] in
            entity?.stateMachine.enter(RocketOnPadState.self)
        })

        entity.containerNode.run(SKAction.sequence(sequence),
                                  withKey: "propulsiveLanding")
    }

    // MARK: - Starship
    //
    // Strict landing flow (no vertical motion — cruise y = onpad y = 41):
    //   Phase 1 | |dx| / 150 pt/s | Horizontal pan from drift x to OLM edge
    //                   (anchor + olmEdgeOffset). No fixed duration.
    //   Phase 3 | 2.0s | Translate from OLM edge back to anchor, concurrent
    //                   with chopstick 3-frame animation (open → half → closed).
    //   Phase 4 | 2.0s | Booster fade-in (serial, runs in OnPad via
    //                   restoreBoosterFadeIn → boosterRestoreDuration).
    //   Phase 5 | instant | OnPad snap (current state machine transition).

    private func didEnterStarship() {
        let scene = entity.containerNode.scene as? BuddyScene
        let anchorX = scene?.starshipAnchorX() ?? entity.containerNode.position.x
        let edgeX = anchorX + RocketConstants.Starship.olmEdgeOffset
        let currentX = entity.containerNode.position.x

        // Keep the Raptor cruise frames flickering throughout landing so the
        // ship visibly thrusts on its approach (Cruising.willExit stops them).
        let (cruiseFrames, fps) = RocketSpriteLoader.frames(for: "cruise", kind: entity.kind)
        if cruiseFrames.count > 1 {
            let loop = SKAction.repeatForever(
                SKAction.animate(with: cruiseFrames, timePerFrame: 1.0 / fps)
            )
            entity.node.run(loop, withKey: "cruiseFrames")
        }

        var sequence: [SKAction] = []

        // Phase 1 — pan to OLM edge at cruise speed (≤ landingApproachSpeed).
        // Linear timing reads as sustained flight rather than ease-snap.
        let dxPhase1 = abs(edgeX - currentX)
        if dxPhase1 > 1 {
            let phase1Dur = max(
                RocketConstants.Starship.landingApproachMinDuration,
                Double(dxPhase1 / RocketConstants.Starship.landingApproachSpeed)
            )
            let pan = SKAction.moveTo(x: edgeX, duration: phase1Dur)
            pan.timingMode = .linear
            sequence.append(pan)
        }

        // Phase 3 — kick off chopstick close animation (runs on rightBoundary
        // in parallel), then translate container back to OLM center over the
        // same 2.0s window. Ship flame keeps animating (cruiseFrames still
        // running).
        sequence.append(SKAction.run { [weak entity] in
            guard let entity = entity,
                  let scene = entity.containerNode.scene as? BuddyScene else { return }
            scene.setChopsticks(open: false, animated: true)
        })
        let moveIn = SKAction.moveTo(x: anchorX, duration: RocketConstants.Starship.lateralMoveDuration)
        moveIn.timingMode = .linear
        sequence.append(moveIn)

        // Phase 5 — transition to OnPad (which drives phase 4 via
        // restoreBoosterFadeIn, 2.0s).
        sequence.append(SKAction.run { [weak entity] in
            entity?.stateMachine.enter(RocketOnPadState.self)
        })

        entity.containerNode.run(SKAction.sequence(sequence),
                                  withKey: "propulsiveLanding")
    }

    // MARK: - Shared

    private func playLandingFrames() {
        let (frames, _) = RocketSpriteLoader.frames(for: "landing", kind: entity.kind)
        if let first = frames.first { entity.node.texture = first }
        guard frames.count > 1 else { return }
        let perFrame = RocketConstants.Landing.totalDuration / Double(frames.count)
        let anim = SKAction.animate(with: frames, timePerFrame: perFrame)
        entity.node.run(anim, withKey: "landingFrames")
    }
}
