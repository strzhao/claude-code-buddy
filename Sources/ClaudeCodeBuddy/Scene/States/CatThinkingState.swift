import GameplayKit
import SpriteKit

final class CatThinkingState: GKState, ResumableState {

    unowned let entity: CatSprite

    init(entity: CatSprite) {
        self.entity = entity
    }

    // MARK: - Transitions

    override func isValidNextState(_ stateClass: AnyClass) -> Bool {
        switch stateClass {
        case is CatIdleState.Type,
             is CatToolUseState.Type,
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

        // If transitioning from idle, play blink (wake-up) first, then start thinking loop
        if previousState is CatIdleState,
           let blinkFrames = entity.textures(for: "idle-b") {
            let blink = SKAction.animate(with: blinkFrames, timePerFrame: CatConstants.Animation.frameTimeBlink)
            let enter = SKAction.run { [weak self] in
                guard let self = self, self.stateMachine?.currentState is CatThinkingState else { return }
                self.startThinkingLoop()
            }
            node.run(SKAction.sequence([blink, enter]), withKey: "transition")
        } else {
            startThinkingLoop()
        }
    }

    // MARK: - Exit

    override func willExit(to nextState: GKState) {
        entity.node.removeAction(forKey: "animation")
        entity.node.removeAction(forKey: "stateEffect")
        entity.node.removeAction(forKey: "breathing")
        entity.node.removeAction(forKey: "transition")
    }

    // MARK: - ResumableState

    func resume() {
        startThinkingLoop()
    }

    // MARK: - Thinking Loop

    private func startThinkingLoop() {
        let node = entity.node
        // Paw animation
        if let frames = entity.textures(for: "paw"), !frames.isEmpty {
            let animate = SKAction.animate(with: frames, timePerFrame: CatConstants.Animation.frameTimePaw)
            let loop = SKAction.repeatForever(animate)
            node.run(loop, withKey: "animation")
            node.texture = frames[0]
            node.color = entity.sessionColor?.nsColor ?? .white
            node.colorBlendFactor = entity.sessionTintFactor
        }
        // Gentle sway ±3°
        let swayRight = SKAction.rotate(toAngle: CatConstants.Animation.swayAngle, duration: CatConstants.Animation.swayDuration)
        swayRight.timingMode = .easeInEaseOut
        let swayLeft = SKAction.rotate(toAngle: -CatConstants.Animation.swayAngle, duration: CatConstants.Animation.swayDuration)
        swayLeft.timingMode = .easeInEaseOut
        let sway = SKAction.repeatForever(SKAction.sequence([swayRight, swayLeft]))
        node.run(sway, withKey: "stateEffect")
        entity.startBreathing()
    }
}
