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
             is CatEatingState.Type,
             is CatTaskCompleteState.Type:
            return true
        default:
            return false
        }
    }

    // MARK: - Entry

    override func didEnter(from previousState: GKState?) {
        let node = entity.node
        let posX = entity.containerNode.position.x
        // Prevent originX from anchoring near the edges (food ratchet effect).
        // If the cat is within 25% of either boundary, nudge originX toward center.
        let range = entity.effectiveActivityMax - entity.activityMin
        let edgeMargin = max(range * 0.25, CatConstants.Movement.walkBoundaryMargin * 2)
        let clampedOriginX: CGFloat
        if posX < entity.activityMin + edgeMargin {
            clampedOriginX = entity.activityMin + edgeMargin
        } else if posX > entity.effectiveActivityMax - edgeMargin {
            clampedOriginX = entity.effectiveActivityMax - edgeMargin
        } else {
            clampedOriginX = posX
        }
        entity.originX = clampedOriginX
        // Standing pose — random walk will switch to walk animation when moving
        if let frames = entity.animationComponent.textures(for: "idle-a"), !frames.isEmpty {
            node.texture = frames[0]
            node.color = entity.sessionColor?.nsColor ?? .white
            node.colorBlendFactor = entity.sessionTintFactor
        }
        entity.movementComponent.startRandomWalk()
        entity.animationComponent.startBreathing()
    }

    // MARK: - Exit

    override func willExit(to nextState: GKState) {
        entity.node.removeAction(forKey: "animation")
        entity.containerNode.removeAction(forKey: "randomWalk")
        entity.node.removeAction(forKey: "breathing")
    }

    func prepareExitActions() -> [String: SKAction] {
        [:]
    }

    // MARK: - ResumableState

    func resume() {
        didEnter(from: nil)
    }
}
