import SpriteKit

// MARK: - EasingCurves

/// Cat-specific timing curves for natural-looking animations.
enum EasingCurves {
    /// Gradual acceleration from standstill.
    case catWalkStart
    /// Deceleration to stop.
    case catWalkStop
    /// Smooth rotation for direction changes.
    case catTurn
    /// Rapid acceleration at takeoff.
    case catJump
    /// Impact + settle for landing.
    case catLand
    /// Organic breathing rhythm.
    case catBreathe
    /// Fast onset, gradual recovery.
    case catStartle
    /// Bouncy overshoot and settle.
    case catExcited

    var timingMode: SKActionTimingMode {
        switch self {
        case .catWalkStart: return .easeIn
        case .catWalkStop: return .easeOut
        case .catTurn: return .easeInEaseOut
        case .catJump: return .easeOut
        case .catLand: return .easeIn
        case .catBreathe: return .easeInEaseOut
        case .catStartle: return .easeOut
        case .catExcited: return .easeOut
        }
    }

    /// Duration multiplier relative to base duration.
    var durationMultiplier: CGFloat {
        switch self {
        case .catWalkStart: return 0.3
        case .catWalkStop: return 0.4
        case .catTurn: return 0.2
        case .catJump: return 0.1
        case .catLand: return 0.2
        case .catBreathe: return 1.0
        case .catStartle: return 0.15
        case .catExcited: return 0.2
        }
    }

    /// Create a custom action with this easing curve applied.
    func customAction(withDuration duration: TimeInterval, actionBlock: @escaping (SKNode, CGFloat) -> Void) -> SKAction {
        let action = SKAction.customAction(withDuration: duration) { node, elapsed in
            let progress = CGFloat(elapsed) / CGFloat(duration)
            actionBlock(node, progress)
        }
        action.timingMode = timingMode
        return action
    }
}
