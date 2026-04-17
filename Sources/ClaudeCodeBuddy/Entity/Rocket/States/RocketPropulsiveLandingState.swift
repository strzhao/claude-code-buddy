import GameplayKit
import SpriteKit

final class RocketPropulsiveLandingState: RocketBaseState {
    override func isValidNextState(_ stateClass: AnyClass) -> Bool { true }

    override func didEnter(from previousState: GKState?) {
        EventBus.shared.sceneExpansionRequested.send(
            SceneExpansionRequest(
                height: RocketConstants.Landing.sceneExpansion,
                duration: RocketConstants.Landing.totalDuration
            )
        )
        let descend = SKAction.moveBy(x: 0,
                                       y: -RocketConstants.Landing.sceneExpansion,
                                       duration: RocketConstants.Landing.totalDuration)
        descend.timingMode = .easeIn
        let settle = SKAction.run { [weak entity] in
            entity?.stateMachine.enter(RocketOnPadState.self)
        }
        entity.containerNode.run(SKAction.sequence([descend, settle]),
                                  withKey: "propulsiveLanding")
    }

    override func willExit(to nextState: GKState) {
        entity.containerNode.removeAction(forKey: "propulsiveLanding")
    }
}
