import GameplayKit
import SpriteKit

// MARK: - IdleSubState

enum IdleSubState {
    case sleep, breathe, blink, clean
}

// MARK: - CatIdleState

final class CatIdleState: GKState, ResumableState {

    unowned let entity: CatSprite

    /// Current idle sub-state.
    var idleSubState: IdleSubState = .breathe

    init(entity: CatSprite) {
        self.entity = entity
    }

    // MARK: - Transitions

    override func isValidNextState(_ stateClass: AnyClass) -> Bool {
        switch stateClass {
        case is CatThinkingState.Type,
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

        // Transition animation: coming from toolUse/thinking/eating → clean once (grooming = wind-down)
        let needsCleanTransition = previousState is CatToolUseState
            || previousState is CatThinkingState
            || previousState is CatEatingState

        // Reset color tint
        node.color = entity.sessionColor?.nsColor ?? .orange
        node.colorBlendFactor = entity.sessionTintFactor

        if needsCleanTransition, let cleanFrames = entity.textures(for: "clean"), !cleanFrames.isEmpty {
            let clean = SKAction.animate(with: cleanFrames, timePerFrame: CatConstants.Animation.frameTimeClean)
            let enter = SKAction.run { [weak self] in
                guard let self = self, self.stateMachine?.currentState is CatIdleState else { return }
                self.startIdleLoop()
            }
            node.run(SKAction.sequence([clean, enter]), withKey: "transition")
        } else {
            startIdleLoop()
        }
    }

    // MARK: - Exit

    override func willExit(to nextState: GKState) {
        entity.node.removeAction(forKey: "idleLoop")
        entity.node.removeAction(forKey: "idleTransition")
        entity.node.removeAction(forKey: "transition")
    }

    // MARK: - ResumableState

    func resume() {
        entity.node.color = entity.sessionColor?.nsColor ?? .orange
        entity.node.colorBlendFactor = entity.sessionTintFactor
        startIdleLoop()
    }

    // MARK: - Idle Sub-State Machine

    func startIdleLoop() {
        idleSubState = pickNextIdleSubState()
        runIdleSubState()
    }

    func pickNextIdleSubState() -> IdleSubState {
        // Weighted random: sleep 70%, breathe 10%, blink 10%, clean 10%
        let roll = Float.random(in: 0..<1)
        switch roll {
        case ..<CatConstants.Idle.sleepWeight:             return .sleep
        case ..<CatConstants.Idle.breatheWeightCumulative: return .breathe
        case ..<CatConstants.Idle.blinkWeightCumulative:   return .blink
        default:                                           return .clean
        }
    }

    func runIdleSubState() {
        guard stateMachine?.currentState is CatIdleState else { return }
        let node = entity.node

        switch idleSubState {
        case .sleep:
            if let frames = entity.textures(for: "sleep"), !frames.isEmpty {
                let animDuration = 1.0 / Double(frames.count)
                let animate = SKAction.animate(with: frames, timePerFrame: animDuration)
                let loopSleep = SKAction.repeat(animate, count: CatConstants.Idle.sleepLoopCount)
                let wait = SKAction.wait(forDuration: CatConstants.Idle.sleepWaitDuration, withRange: CatConstants.Idle.sleepWaitRange)
                let next = SKAction.run { [weak self] in
                    guard let self = self, self.stateMachine?.currentState is CatIdleState else { return }
                    self.idleSubState = self.pickNextIdleSubState()
                    self.runIdleSubState()
                }
                node.run(SKAction.sequence([loopSleep, wait, next]), withKey: "idleLoop")
                node.texture = frames[0]
                node.color = entity.sessionColor?.nsColor ?? .white
                node.colorBlendFactor = entity.sessionTintFactor
            } else {
                idleSubState = .breathe
                runIdleSubState()
            }

        case .breathe:
            playIdleAnimation(animName: "idle-a", looping: true)
            scheduleNextIdleTransition(after: SKAction.wait(forDuration: CatConstants.Idle.breatheWaitDuration, withRange: CatConstants.Idle.breatheWaitRange))

        case .blink:
            if let frames = entity.textures(for: "idle-b"), !frames.isEmpty {
                let duration = CatConstants.Idle.blinkAnimDuration / Double(frames.count)
                let animate = SKAction.animate(with: frames, timePerFrame: duration)
                let next = SKAction.run { [weak self] in
                    guard let self = self, self.stateMachine?.currentState is CatIdleState else { return }
                    self.idleSubState = self.pickNextIdleSubState()
                    self.runIdleSubState()
                }
                node.run(SKAction.sequence([animate, next]), withKey: "idleLoop")
                node.texture = frames[0]
                node.color = entity.sessionColor?.nsColor ?? .white
                node.colorBlendFactor = entity.sessionTintFactor
            } else {
                idleSubState = .sleep
                runIdleSubState()
            }

        case .clean:
            if let frames = entity.textures(for: "clean"), !frames.isEmpty {
                let duration = CatConstants.Idle.cleanAnimDuration / Double(frames.count)
                let animate = SKAction.animate(with: frames, timePerFrame: duration)
                let next = SKAction.run { [weak self] in
                    guard let self = self, self.stateMachine?.currentState is CatIdleState else { return }
                    self.idleSubState = self.pickNextIdleSubState()
                    self.runIdleSubState()
                }
                node.run(SKAction.sequence([animate, next]), withKey: "idleLoop")
                node.texture = frames[0]
                node.color = entity.sessionColor?.nsColor ?? .white
                node.colorBlendFactor = entity.sessionTintFactor
            } else {
                idleSubState = .sleep
                runIdleSubState()
            }
        }
    }

    private func playIdleAnimation(animName: String, looping: Bool) {
        guard let frames = entity.textures(for: animName), !frames.isEmpty else { return }
        let animate = SKAction.animate(with: frames, timePerFrame: CatConstants.Animation.frameTimeIdleA)
        let action = looping ? SKAction.repeatForever(animate) : animate
        entity.node.run(action, withKey: "idleLoop")
        entity.node.texture = frames[0]
        entity.node.color = entity.sessionColor?.nsColor ?? .white
        entity.node.colorBlendFactor = entity.sessionTintFactor
    }

    private func scheduleNextIdleTransition(after waitAction: SKAction) {
        let pickAndRun = SKAction.run { [weak self] in
            guard let self = self, self.stateMachine?.currentState is CatIdleState else { return }
            self.idleSubState = self.pickNextIdleSubState()
            self.entity.node.removeAction(forKey: "idleLoop")
            self.runIdleSubState()
        }
        entity.node.run(SKAction.sequence([waitAction, pickAndRun]), withKey: "idleTransition")
    }
}
