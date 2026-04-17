import GameplayKit
import SpriteKit

final class RocketOnPadState: RocketBaseState {
    override func isValidNextState(_ stateClass: AnyClass) -> Bool { true }

    override func didEnter(from previousState: GKState?) {
        entity.node.run(SKAction.repeatForever(
            SKAction.sequence([
                SKAction.fadeAlpha(to: 0.9, duration: 0.6),
                SKAction.fadeAlpha(to: 1.0, duration: 0.6)
            ])
        ), withKey: "onPad")
    }

    override func willExit(to nextState: GKState) {
        entity.node.removeAction(forKey: "onPad")
        entity.node.alpha = 1.0
    }
}
