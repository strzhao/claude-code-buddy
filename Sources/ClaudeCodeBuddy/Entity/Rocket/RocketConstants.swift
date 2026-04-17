import CoreGraphics
import Foundation

enum RocketConstants {

    enum Visual {
        static let spriteSize = CGSize(width: 48, height: 48)
        static let hitboxSize = CGSize(width: 40, height: 48)
        static let padHeight: CGFloat = 6
        static let tintFactor: CGFloat = 0.5
        static let groundY: CGFloat = 4
    }

    enum Physics {
        static let bodySize = CGSize(width: 28, height: 44)
        static let restitution: CGFloat = 0.0
        static let friction: CGFloat = 1.0
        static let linearDamping: CGFloat = 1.0
    }

    enum Cruising {
        /// How high above the pad the rocket lifts during cruising.
        static let hoverLift: CGFloat = 30
        static let hoverLiftDuration: TimeInterval = 0.4
        /// Random walk cadence in cruising.
        static let walkStepMin: CGFloat = 20
        static let walkStepMax: CGFloat = 80
        static let walkDurationMin: TimeInterval = 1.2
        static let walkDurationMax: TimeInterval = 2.2
    }

    enum Landing {
        /// Scene expansion during propulsive landing.
        static let sceneExpansion: CGFloat = 120
        static let totalDuration: TimeInterval = 1.2
    }

    enum Liftoff {
        static let sceneExpansion: CGFloat = 200
        static let totalDuration: TimeInterval = 0.8
    }

    enum WarningLight {
        static let blinkInterval: TimeInterval = 0.4
    }
}
