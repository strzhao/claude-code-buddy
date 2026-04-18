import Foundation

/// Visual variant of a rocket. Different `kind` → different sprite sets + subtle
/// behavioral cues (F9 deploys / retracts landing legs across state transitions;
/// Starship 3 performs booster separation + chopstick catch).
enum RocketKind: String, CaseIterable {
    case classic
    case shuttle
    case falcon9
    case starship3

    /// Prefix used when looking up sprites from Assets/Sprites/Rocket/<prefix><anim>_<letter>.png
    var spritePrefix: String {
        switch self {
        case .classic:    return "rocket"
        case .shuttle:    return "rocket_shuttle"
        case .falcon9:    return "rocket_f9"
        case .starship3:  return "rocket_starship"
        }
    }

    /// Native canvas size for this kind's sprites. Starship renders at 72×72
    /// (content drawn at 1.5× scale by the sprite generator) so no runtime
    /// setScale is needed — the sprite is already at its intended visual size.
    var spriteSize: CGSize {
        switch self {
        case .starship3: return CGSize(width: 72, height: 72)
        default:         return CGSize(width: 48, height: 48)
        }
    }

    /// Initial scene-y for the container node. Replaces the old
    /// `groundY + yOffsetForScale` math. Other kinds sit at groundY (24), so
    /// their 48×48 sprite's bottom aligns with scene y=0 (pad bottom).
    /// Starship sits higher so its visible booster nozzle lands on OLM top
    /// (scene y=6): container.y − (72/2) + 1 = 6 → container.y = 41.
    var containerInitY: CGFloat {
        switch self {
        case .starship3: return 41
        default:         return RocketConstants.Visual.groundY
        }
    }

    /// Whether this kind uses a separate pad sprite on the ground. Starship 3
    /// is caught by Mechazilla chopsticks on the right tower instead, so it
    /// has no ground pad.
    var usesGroundPad: Bool {
        self != .starship3
    }

    /// Per-kind cruise hover lift so every rocket's primary engine ends at
    /// scene y=36 during cruise:
    ///   • Classic / Shuttle — engine at native y=6 → lift 30
    ///   • Falcon 9          — engine at native y=2 → lift 34
    ///   • Starship          — ship engine on booster's hot-staging ring
    ///                         already at y=36 → lift 0 (no vertical motion)
    var hoverLift: CGFloat {
        switch self {
        case .classic, .shuttle: return 30
        case .falcon9:           return 34
        case .starship3:         return 0
        }
    }
}
