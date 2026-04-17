import GameplayKit
import SpriteKit

final class RocketCruisingState: RocketBaseState {
    override func isValidNextState(_ stateClass: AnyClass) -> Bool { true }

    override func didEnter(from previousState: GKState?) {
        let lift = SKAction.moveBy(x: 0,
                                    y: RocketConstants.Cruising.hoverLift,
                                    duration: RocketConstants.Cruising.hoverLiftDuration)
        lift.timingMode = .easeOut
        let drift = SKAction.repeatForever(
            SKAction.sequence([
                SKAction.moveBy(
                    x: CGFloat.random(in: -RocketConstants.Cruising.walkStepMax...RocketConstants.Cruising.walkStepMax),
                    y: 0,
                    duration: Double.random(in: RocketConstants.Cruising.walkDurationMin...RocketConstants.Cruising.walkDurationMax)
                )
            ])
        )
        entity.containerNode.run(SKAction.sequence([lift, drift]),
                                  withKey: "cruising")
    }

    override func willExit(to nextState: GKState) {
        entity.containerNode.removeAction(forKey: "cruising")
        if !(nextState is RocketLiftoffState || nextState is RocketPropulsiveLandingState) {
            let drop = SKAction.moveTo(y: RocketConstants.Visual.groundY,
                                        duration: 0.3)
            entity.containerNode.run(drop)
        }
    }
}
