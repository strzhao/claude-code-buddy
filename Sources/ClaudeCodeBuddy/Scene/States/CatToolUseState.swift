import GameplayKit
import SpriteKit

final class CatToolUseState: GKState, ResumableState {

    unowned let entity: CatSprite

    init(entity: CatSprite) {
        self.entity = entity
    }

    // MARK: - Transitions

    override func isValidNextState(_ stateClass: AnyClass) -> Bool {
        switch stateClass {
        case is CatIdleState.Type,
             is CatThinkingState.Type,
             is CatPermissionRequestState.Type,
             is CatEatingState.Type:
            return true
        default:
            return false
        }
    }

    // MARK: - Entry

    override func didEnter(from previousState: GKState?) {
        let node = entity.node
        // Standing pose — random walk will switch to walk animation when moving
        if let frames = entity.animationComponent.textures(for: "idle-a"), !frames.isEmpty {
            node.texture = frames[0]
            node.color = entity.sessionColor?.nsColor ?? .white
            node.colorBlendFactor = entity.sessionTintFactor
        }
        entity.originX = entity.containerNode.position.x
        entity.startRandomWalk()
        entity.animationComponent.startBreathing()
    }

    // MARK: - Exit

    override func willExit(to nextState: GKState) {
        entity.node.removeAction(forKey: "animation")
        entity.containerNode.removeAction(forKey: "randomWalk")
        entity.node.removeAction(forKey: "breathing")
    }

    // MARK: - ResumableState

    func resume() {
        didEnter(from: nil)
    }
}
