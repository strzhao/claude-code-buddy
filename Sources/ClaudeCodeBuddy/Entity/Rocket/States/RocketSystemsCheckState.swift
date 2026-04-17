import GameplayKit

final class RocketSystemsCheckState: RocketBaseState {
    override func isValidNextState(_ stateClass: AnyClass) -> Bool { true }
    override func didEnter(from previousState: GKState?) { /* Task 3.5 */ }
    override func willExit(to nextState: GKState) { entity.containerNode.removeAllActions() }
}
