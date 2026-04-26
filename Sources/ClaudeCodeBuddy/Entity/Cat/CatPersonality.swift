import Foundation

// MARK: - CatPersonality

/// Per-cat personality traits that influence behavior parameters.
/// Generated randomly per session, not persisted.
struct CatPersonality {

    /// Normalized idle sub-state weights.
    struct IdleWeights {
        let sleep: Float
        let breathe: Float
        let blink: Float
        let clean: Float
    }
    /// Activity level (0.3–1.0) — affects idle sub-state switching frequency and movement likelihood.
    let activity: CGFloat
    /// Curiosity (0.3–1.0) — affects look-around probability after events.
    let curiosity: CGFloat
    /// Timidness (0.3–1.0) — affects fright reaction intensity and duration.
    let timidness: CGFloat
    /// Playfulness (0.3–1.0) — affects excited reaction magnitude and bounce height.
    let playfulness: CGFloat

    static func random() -> CatPersonality {
        CatPersonality(
            activity: CGFloat.random(in: 0.3...1.0),
            curiosity: CGFloat.random(in: 0.3...1.0),
            timidness: CGFloat.random(in: 0.3...1.0),
            playfulness: CGFloat.random(in: 0.3...1.0)
        )
    }

    /// Fixed personality for deterministic tests.
    static let balanced = CatPersonality(
        activity: 0.65,
        curiosity: 0.65,
        timidness: 0.5,
        playfulness: 0.65
    )

    // MARK: - Idle Weights

    /// Calculate personality-modified idle sub-state weights, normalized to sum = 1.0.
    func modifiedIdleWeights(
        baseSleep: Float,
        baseBreathe: Float,
        baseBlink: Float,
        baseClean: Float
    ) -> IdleWeights {
        let activityFloat = Float(activity)
        let curiosityFloat = Float(curiosity)

        // Higher activity → less sleep, more cleaning
        let sleepMod = 1.0 - (activityFloat - 0.3) * 0.5
        let cleanMod = 1.0 + (activityFloat - 0.3) * 0.3
        // Higher curiosity → more blinking (looking around)
        let blinkMod = 1.0 + (curiosityFloat - 0.3) * 0.4

        let sleep = baseSleep * sleepMod
        let breathe = baseBreathe
        let blink = baseBlink * blinkMod
        let clean = baseClean * cleanMod

        let total = sleep + breathe + blink + clean
        return IdleWeights(sleep: sleep / total, breathe: breathe / total, blink: blink / total, clean: clean / total)
    }

    // MARK: - Behavior Modifiers

    /// Walk speed modifier (range ~1.04–1.2).
    var walkSpeedMultiplier: CGFloat {
        0.8 + (activity * 0.4)
    }

    /// Fright distance modifier (range ~0.98–1.4).
    var frightDistanceMultiplier: CGFloat {
        0.8 + (timidness * 0.6)
    }

    /// Excited hop height in pixels (range ~4.5–8.0, base is 6.0).
    var excitedHopHeight: CGFloat {
        3.0 + (playfulness * 5.0)
    }

    /// Jump velocity modifier (range ~0.975–1.15).
    var jumpVelocityMultiplier: CGFloat {
        0.9 + (playfulness * 0.25)
    }

    /// Shift in step-size probability: higher activity biases toward larger steps.
    var stepSizeActivityShift: Float {
        Float(max(0, activity - 0.3)) * 0.28
    }
}
