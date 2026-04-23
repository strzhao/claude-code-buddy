import SpriteKit

// MARK: - AnimationTransitionManager

/// Central coordinator for smooth animation transitions with personality awareness.
/// One instance per cat, created on demand (lightweight, no retained state).
class AnimationTransitionManager {

    unowned let node: SKSpriteNode
    unowned let containerNode: SKNode
    let personality: CatPersonality

    init(node: SKSpriteNode, containerNode: SKNode, personality: CatPersonality) {
        self.node = node
        self.containerNode = containerNode
        self.personality = personality
    }

    // MARK: - Smooth Direction Turn

    /// Gradually flip xScale with a slight rotation during the turn.
    func smoothTurn(toRight targetRight: Bool, duration: TimeInterval = 0.2) {
        let currentScale = node.xScale
        let spriteFacesRight = SkinPackManager.shared.activeSkin.manifest.spriteFacesRight ?? true
        let targetScale: CGFloat = targetRight == spriteFacesRight ? 1.0 : -1.0

        // Already facing the right way — nothing to do
        if abs(currentScale - targetScale) < 0.01 { return }

        let turnAction = EasingCurves.catTurn.customAction(withDuration: duration) { [weak self] node, progress in
            guard let self = self else { return }
            let interpolated = currentScale + (targetScale - currentScale) * progress
            node.xScale = interpolated
            // Slight tilt during turn for natural feel
            let maxRotation: CGFloat = targetScale > currentScale ? 0.08 : -0.08
            node.zRotation = maxRotation * sin(progress * .pi)
            // Sync label scale compensation
            self.updateLabelCompensation(facingRight: targetScale > 0)
        }

        let resetRotation = SKAction.run { [weak self] in
            self?.node.zRotation = 0
        }

        node.run(SKAction.sequence([turnAction, resetRotation]), withKey: "smoothTurn")
    }

    // MARK: - Ease-Out Handoff

    /// Speed up the current animation, then replace it with the next action.
    func easeOutHandoff(
        currentActionKey: String,
        nextAction: SKAction,
        handoffDuration: TimeInterval = 0.15
    ) {
        // Speed up remaining frames of current animation
        if let current = node.action(forKey: currentActionKey) {
            current.speed = 2.5
        }

        let wait = SKAction.wait(forDuration: handoffDuration)
        let startNext = SKAction.run { [weak self] in
            guard let self = self else { return }
            self.node.removeAction(forKey: currentActionKey)
            self.node.run(nextAction)
        }
        node.run(SKAction.sequence([wait, startNext]), withKey: "easeOutHandoff")
    }

    // MARK: - Anticipation + Follow-Through

    /// Chain wind-up → main action → settle as a single sequence.
    func anticipate(
        mainAction: SKAction,
        windUp: SKAction? = nil,
        settle: SKAction? = nil,
        curve: EasingCurves = .catJump
    ) -> SKAction {
        var sequence: [SKAction] = []
        if let windUp = windUp {
            var w = windUp
            w.timingMode = curve.timingMode
            sequence.append(w)
        }
        sequence.append(mainAction)
        if let settle = settle {
            var s = settle
            s.timingMode = EasingCurves.catLand.timingMode
            sequence.append(s)
        }
        return SKAction.sequence(sequence)
    }

    /// Chain main action → settle as a single sequence.
    func followThrough(
        mainAction: SKAction,
        settle: SKAction,
        curve: EasingCurves = .catLand
    ) -> SKAction {
        var s = settle
        s.timingMode = curve.timingMode
        return SKAction.sequence([mainAction, s])
    }

    // MARK: - Enhanced Breathing

    /// Personality-influenced breathing with higher amplitude than the base 2%.
    func startEnhancedBreathing(baseAmplitude: CGFloat, duration: TimeInterval) {
        // personality multiplier: 0.94–1.3×
        let multiplier = 0.5 + personality.playfulness * 0.8
        let amplitude = baseAmplitude * multiplier
        let maxScaleY = 1.0 + amplitude

        let breatheIn = SKAction.scaleY(to: maxScaleY, duration: duration)
        breatheIn.timingMode = EasingCurves.catBreathe.timingMode
        let breatheOut = SKAction.scaleY(to: 1.0, duration: duration)
        breatheOut.timingMode = EasingCurves.catBreathe.timingMode

        let breathe = SKAction.repeatForever(SKAction.sequence([breatheIn, breatheOut]))
        node.run(breathe, withKey: "breathing")
    }

    // MARK: - Weather Visual Reactions

    /// Play a one-shot visual reaction to weather changes.
    func playWeatherReaction(for weather: WeatherState) {
        switch weather {
        case .rain:
            let hunch = SKAction.scaleY(to: 0.95, duration: 0.3)
            hunch.timingMode = .easeOut
            let recover = SKAction.scaleY(to: 1.0, duration: 0.3)
            recover.timingMode = .easeIn
            node.run(SKAction.sequence([hunch, recover]), withKey: "weatherReaction")

        case .snow:
            let shiver = SKAction.sequence([
                SKAction.moveBy(x: 2, y: 0, duration: 0.1),
                SKAction.moveBy(x: -4, y: 0, duration: 0.1),
                SKAction.moveBy(x: 2, y: 0, duration: 0.1),
            ])
            node.run(SKAction.repeat(shiver, count: 3), withKey: "weatherReaction")

        case .wind:
            let lean = SKAction.rotate(toAngle: 0.1, duration: 0.2)
            lean.timingMode = .easeOut
            let unlean = SKAction.rotate(toAngle: 0, duration: 0.2)
            unlean.timingMode = .easeIn
            node.run(SKAction.sequence([lean, unlean]), withKey: "weatherReaction")

        default:
            node.removeAction(forKey: "weatherReaction")
        }
    }

    // MARK: - Helpers

    private func updateLabelCompensation(facingRight: Bool) {
        // Walk up to find the CatSprite that owns this node
        // The node's name is "catSprite_<sessionId>"
        guard let nodeName = node.name, nodeName.hasPrefix("catSprite_") else { return }
        let sessionId = String(nodeName.dropFirst("catSprite_".count))
        // We can't easily reach the CatSprite from here, so this is handled
        // by the caller (CatSprite.applyFacingDirection) after smoothTurn.
    }
}
