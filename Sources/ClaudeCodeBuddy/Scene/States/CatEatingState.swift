import GameplayKit
import SpriteKit

final class CatEatingState: GKState {

    unowned let entity: CatSprite

    init(entity: CatSprite) {
        self.entity = entity
    }

    // MARK: - Transitions

    override func isValidNextState(_ stateClass: AnyClass) -> Bool {
        // Eating can only transition to idle
        return stateClass is CatIdleState.Type
    }

    // MARK: - Entry

    override func didEnter(from previousState: GKState?) {
        // Actual eating animation is driven by CatSprite.startEating()
        // which starts the animation sequence and then calls switchState(.idle)
        // Nothing to do here — startEating() sets up the animation directly
    }

    // MARK: - Exit

    override func willExit(to nextState: GKState) {
        entity.node.removeAction(forKey: "animation")
    }
}
