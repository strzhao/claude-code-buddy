import CoreGraphics
import Foundation

enum RocketConstants {

    enum Visual {
        static let spriteSize = CGSize(width: 48, height: 48)
        static let hitboxSize = CGSize(width: 40, height: 48)
        static let padHeight: CGFloat = 6
        static let tintFactor: CGFloat = 0.5
        /// Rocket container y so sprite's bottom edge aligns with scene y=0 (tower base).
        static let groundY: CGFloat = 24
    }

    enum Physics {
        static let bodySize = CGSize(width: 28, height: 44)
        static let restitution: CGFloat = 0.0
        static let friction: CGFloat = 1.0
        static let linearDamping: CGFloat = 1.0
    }

    enum Cruising {
        /// Per-kind lift amounts live on `RocketKind.hoverLift` now so each
        /// rocket can end with its engine at a consistent scene-y.
        /// Slow build-up off the pad (cubic ease-in).
        static let hoverLiftDuration: TimeInterval = 1.2
        /// Random walk cadence in cruising. Slower, more graceful than cat walk.
        static let walkStepMin: CGFloat = 20
        static let walkStepMax: CGFloat = 50
        static let walkDurationMin: TimeInterval = 2.5
        static let walkDurationMax: TimeInterval = 4.0
    }

    enum Landing {
        /// Scene expansion during propulsive landing.
        static let sceneExpansion: CGFloat = 120
        /// Extended descent: fast drop from apex, sharply decelerating (cubic ease-out).
        static let totalDuration: TimeInterval = 2.8
    }

    enum Liftoff {
        static let sceneExpansion: CGFloat = 200
        /// Slow start, then strong acceleration (cubic ease-in).
        static let totalDuration: TimeInterval = 2.0
    }

    /// Timing curves: cubic is sharper than the built-in easeIn/easeOut (quadratic).
    enum Curves {
        /// t³ — very slow start, accelerating (takeoff).
        static let cubicIn: (Float) -> Float = { $0 * $0 * $0 }
        /// 1-(1-t)³ — fast start, strongly decelerating (landing).
        static let cubicOut: (Float) -> Float = {
            let inv = 1 - $0
            return 1 - (inv * inv * inv)
        }
    }

    enum WarningLight {
        static let blinkInterval: TimeInterval = 0.4
    }

    /// Starship-3-specific tuning.
    enum Starship {
        /// Horizontal band (points on either side of the right tower spawn x)
        /// within which Starship 3 is allowed to drift during cruise. Keeps it
        /// anchored near Mechazilla rather than wandering the full scene.
        static let driftHalfWidth: CGFloat = 40
        /// Distance booster travels during separation before removing the node.
        static let boosterSeparationDistance: CGFloat = 220
        /// Duration of the booster free-fall animation (slower reads as heavy).
        static let boosterSeparationDuration: TimeInterval = 3.0
        /// Fade-in duration when restoring the booster beneath a landed ship.
        /// Matches the landing phase-4 duration from the strict flow spec.
        static let boosterRestoreDuration: TimeInterval = 2.0
        /// How far from the right tower Starship spawns. Negative = past the
        /// activity upper bound (tucked closer to / overlapping tower body
        /// so the short middle support arm physically contacts the ship's
        /// right-side flaps).
        static let rightTowerPadding: CGFloat = -10
        /// Horizontal offset from OLM center to "OLM edge" where the ship
        /// pauses during liftoff phase 2 (moves out to) and landing phase 1
        /// (approaches first). Negative = to the left of OLM center.
        static let olmEdgeOffset: CGFloat = -17
        /// Duration of the liftoff phase-2 lateral move AND the landing
        /// phase-3 return move. Chopstick 3-frame animation runs concurrent
        /// with both, over the same 2.0s window.
        static let lateralMoveDuration: TimeInterval = 2.0
        /// Chopstick open/close animation total duration (3 frames: closed →
        /// half → open, or reverse). Frames play at timePerFrame = this / 3.
        static let chopstickAnimationDuration: TimeInterval = 2.0
        /// Horizontal cruise speed during landing phase 1 (drift position →
        /// OLM edge). Phase-1 duration = max(minimum, |dx| / speed). 80 pt/s
        /// reads as "flying there" rather than snapping.
        static let landingApproachSpeed: CGFloat = 80
        /// Minimum phase-1 duration so even short approaches still feel like
        /// flight rather than a teleport.
        static let landingApproachMinDuration: TimeInterval = 1.5
    }
}
