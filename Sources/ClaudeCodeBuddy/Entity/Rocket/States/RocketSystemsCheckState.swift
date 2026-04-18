import GameplayKit
import SpriteKit

final class RocketSystemsCheckState: RocketBaseState {
    override func isValidNextState(_ stateClass: AnyClass) -> Bool { true }

    override func didEnter(from previousState: GKState?) {
        entity.ensurePadVisible()
        let (frames, fps) = RocketSpriteLoader.frames(for: "systems", kind: entity.kind)
        guard frames.count > 1 else {
            entity.node.texture = frames.first
            return
        }
        let loop = SKAction.repeatForever(
            SKAction.animate(with: frames, timePerFrame: 1.0 / fps)
        )
        entity.node.run(loop, withKey: "systemsCheck")
    }

    override func willExit(to nextState: GKState) {
        entity.node.removeAction(forKey: "systemsCheck")
    }
}
