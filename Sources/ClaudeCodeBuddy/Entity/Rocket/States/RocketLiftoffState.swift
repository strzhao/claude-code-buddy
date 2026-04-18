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

        // Starship 3: chopsticks swing OPEN at liftoff so they clear the rising stack.
        if entity.kind == .starship3,
           let scene = entity.containerNode.scene as? BuddyScene {
            scene.setChopsticks(open: true)
        }

        let (frames, fps) = RocketSpriteLoader.frames(for: "liftoff", kind: entity.kind)
        if frames.count > 1 {
            let anim = SKAction.repeatForever(
                SKAction.animate(with: frames, timePerFrame: 1.0 / fps)
            )
            entity.node.run(anim, withKey: "liftoffFrames")
        } else {
            entity.node.texture = frames.first
        }

        // Pad drops by exactly the rocket's ascent magnitude (cubic ease-in, same duration).
        entity.slidePadDown(by: RocketConstants.Liftoff.sceneExpansion,
                            duration: RocketConstants.Liftoff.totalDuration,
                            curve: RocketConstants.Curves.cubicIn)

        // Liftoff profile: cubic ease-in — ignition crawl, then hard acceleration.
        let ascend = SKAction.moveBy(x: 0,
                                      y: RocketConstants.Liftoff.sceneExpansion,
                                      duration: RocketConstants.Liftoff.totalDuration)
        ascend.timingFunction = RocketConstants.Curves.cubicIn
        // Fade starts in the second half so the rocket is fully visible at ignition.
        let fade = SKAction.sequence([
            SKAction.wait(forDuration: RocketConstants.Liftoff.totalDuration * 0.5),
            SKAction.fadeOut(withDuration: RocketConstants.Liftoff.totalDuration * 0.5)
        ])
        entity.containerNode.run(SKAction.group([ascend, fade]),
                                  withKey: "liftoff")
    }

    override func willExit(to nextState: GKState) {
        entity.node.removeAction(forKey: "liftoffFrames")
        entity.containerNode.removeAction(forKey: "liftoff")
    }
}
