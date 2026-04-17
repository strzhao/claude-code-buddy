import GameplayKit
import SpriteKit
import AppKit

final class RocketAbortStandbyState: RocketBaseState {
    override func isValidNextState(_ stateClass: AnyClass) -> Bool { true }

    override func didEnter(from previousState: GKState?) {
        entity.containerNode.removeAllActions()
        entity.node.color = .systemRed
        let strobe = SKAction.repeatForever(
            SKAction.sequence([
                SKAction.fadeAlpha(to: 0.6, duration: 0.25),
                SKAction.fadeAlpha(to: 1.0, duration: 0.25)
            ])
        )
        entity.node.run(strobe, withKey: "abort")
    }

    override func willExit(to nextState: GKState) {
        entity.node.removeAction(forKey: "abort")
        entity.node.color = entity.sessionColor?.nsColor ?? .white
        entity.node.alpha = 1.0
    }
}
