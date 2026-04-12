import GameplayKit
import SpriteKit

final class CatPermissionRequestState: GKState, ResumableState {

    unowned let entity: CatSprite

    init(entity: CatSprite) {
        self.entity = entity
    }

    // MARK: - Transitions

    override func isValidNextState(_ stateClass: AnyClass) -> Bool {
        switch stateClass {
        case is CatIdleState.Type,
             is CatThinkingState.Type,
             is CatToolUseState.Type:
            return true
        default:
            return false
        }
    }

    // MARK: - Entry

    override func didEnter(from previousState: GKState?) {
        let toolDescription = entity.pendingToolDescription
        startPermissionRequestLoop(toolDescription: toolDescription)
    }

    // MARK: - Exit

    override func willExit(to nextState: GKState) {
        entity.node.removeAction(forKey: "animation")
        entity.node.removeAction(forKey: "stateEffect")
        entity.node.removeAction(forKey: "shakeEffect")
        entity.removeAlertOverlay()
        entity.hideLabel()
        // Restore color to session tint
        entity.node.color = entity.sessionColor?.nsColor ?? .orange
        entity.node.colorBlendFactor = entity.sessionTintFactor
    }

    // MARK: - ResumableState

    func resume() {
        let toolDescription = entity.pendingToolDescription
        startPermissionRequestLoop(toolDescription: toolDescription)
    }

    // MARK: - Permission Request Animation

    private func startPermissionRequestLoop(toolDescription: String?) {
        let node = entity.node

        // Scared animation (fast loop)
        if let frames = entity.animationComponent.textures(for: "scared"), !frames.isEmpty {
            let animate = SKAction.animate(with: frames, timePerFrame: CatConstants.Animation.frameTimeScared)
            let loop = SKAction.repeatForever(animate)
            node.run(loop, withKey: "animation")
            node.texture = frames[0]
        }

        // Red color override
        node.color = CatConstants.Visual.permissionColor
        node.colorBlendFactor = CatConstants.Visual.permissionBlendFactor

        // Bounce scale pulse (Y-only to preserve facing direction)
        let scaleUp = SKAction.scaleY(to: CatConstants.Animation.bounceScaleY, duration: CatConstants.Animation.bounceDuration)
        scaleUp.timingMode = .easeIn
        let scaleDown = SKAction.scaleY(to: 1.0, duration: CatConstants.Animation.bounceDuration)
        scaleDown.timingMode = .easeOut
        let bounce = SKAction.repeatForever(SKAction.sequence([scaleUp, scaleDown]))
        node.run(bounce, withKey: "stateEffect")

        // Horizontal shake
        let shakeRight = SKAction.moveBy(x: CatConstants.Animation.shakeDeltaX, y: 0, duration: CatConstants.Animation.shakeDuration)
        let shakeLeft = SKAction.moveBy(x: -CatConstants.Animation.shakeDeltaX * 2, y: 0, duration: CatConstants.Animation.shakeDuration)
        let shakeBack = SKAction.moveBy(x: CatConstants.Animation.shakeDeltaX, y: 0, duration: CatConstants.Animation.shakeDuration)
        let shake = SKAction.repeatForever(SKAction.sequence([shakeRight, shakeLeft, shakeBack]))
        node.run(shake, withKey: "shakeEffect")

        // Show tool description label
        let displayText = toolDescription ?? "Permission?"
        entity.showLabel(text: displayText)
        // Override label color to white for visibility on red cat
        entity.labelNode?.fontColor = .white
        entity.shadowLabelNode?.fontColor = CatConstants.Visual.permissionLabelShadowColor

        // "!" badge positioned to the right of the label text
        entity.addAlertOverlay(afterLabel: displayText)

        // Show tab name above the tool description
        entity.tabNameNode?.isHidden = false
        entity.tabNameShadowNode?.isHidden = false
    }
}
