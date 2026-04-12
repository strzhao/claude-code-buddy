import CoreGraphics

/// Describes how weather affects entity behavior parameters
struct BehaviorModifier {
    var walkSpeedMultiplier: CGFloat = 1.0
    var idleSleepWeightBoost: Double = 0.0

    static let clear = BehaviorModifier()
    static let cloudy = BehaviorModifier(idleSleepWeightBoost: 0.05)
    static let rain = BehaviorModifier(walkSpeedMultiplier: 0.7, idleSleepWeightBoost: 0.15)
    static let snow = BehaviorModifier(walkSpeedMultiplier: 0.5, idleSleepWeightBoost: 0.25)
    static let wind = BehaviorModifier(walkSpeedMultiplier: 1.2)
}
