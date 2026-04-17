import GameplayKit
import SpriteKit

final class RocketSystemsCheckState: RocketBaseState {
    override func isValidNextState(_ stateClass: AnyClass) -> Bool { true }

    override func didEnter(from previousState: GKState?) {
        entity.node.run(SKAction.repeatForever(
            SKAction.sequence([
                SKAction.fadeAlpha(to: 0.7, duration: 0.2),
                SKAction.fadeAlpha(to: 1.0, duration: 0.2)
            ])
        ), withKey: "systemsCheck")
    }

    override func willExit(to nextState: GKState) {
        entity.node.removeAction(forKey: "systemsCheck")
        entity.node.alpha = 1.0
    }
}
