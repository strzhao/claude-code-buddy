import GameplayKit
import SpriteKit

final class RocketLiftoffState: RocketBaseState {
    override func isValidNextState(_ stateClass: AnyClass) -> Bool { true }

    override func didEnter(from previousState: GKState?) {
        EventBus.shared.sceneExpansionRequested.send(
            SceneExpansionRequest(
                height: RocketConstants.Liftoff.sceneExpansion,
                duration: RocketConstants.Liftoff.totalDuration
            )
        )
        let ascend = SKAction.moveBy(x: 0,
                                      y: RocketConstants.Liftoff.sceneExpansion,
                                      duration: RocketConstants.Liftoff.totalDuration)
        ascend.timingMode = .easeOut
        let fade = SKAction.fadeOut(withDuration: 0.3)
        entity.containerNode.run(SKAction.group([ascend, fade]),
                                  withKey: "liftoff")
    }

    override func willExit(to nextState: GKState) {
        entity.containerNode.removeAction(forKey: "liftoff")
    }
}
