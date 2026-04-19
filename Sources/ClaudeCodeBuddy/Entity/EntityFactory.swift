import Foundation

/// Factory for creating concrete SessionEntity instances based on EntityMode.
enum EntityFactory {
    static func make(mode: EntityMode, sessionId: String) -> SessionEntity {
        switch mode {
        case .cat:    return CatEntity(sessionId: sessionId)
        case .rocket: return RocketEntity(sessionId: sessionId, kind: rocketKind(for: sessionId))
        }
    }

    // MARK: - Rocket kind selection
    //
    // Two orthogonal concepts:
    //
    //   1. `weights` — a weight per kind. Source: `BUDDY_ROCKET_WEIGHTS` env
    //      var (`classic=50,shuttle=25,falcon9=15,starship3=10` default).
    //      Applies in BOTH unlock=on and unlock=off modes.
    //
    //   2. "pool" — the kinds eligible for a given pick. Under
    //      `BUDDY_ROCKET_UNLOCK=on` (default), the pool grows with the count
    //      of rockets already on scene (tier 1 → classic only; tier 4+ →
    //      all four). Under `BUDDY_ROCKET_UNLOCK=off`, the pool is always
    //      all four.
    //
    // Special cases:
    //   • starship3 1-cap: if a Starship is already on scene, it is removed
    //     from the pool regardless of mode.
    //   • Zero-weight fallback: if the total weight across the final pool is
    //     zero (e.g. env var nukes every relevant kind's weight, or the 1-cap
    //     leaves only zero-weighted kinds), pick uniformly from the pool so
    //     we never divide by zero / stall.

    private static var kindCache: [String: RocketKind] = [:]

    private static let defaultWeights: [RocketKind: Int] = [
        .classic:   50,
        .shuttle:   25,
        .falcon9:   15,
        .starship3: 10,
    ]

    /// Kinds unlocked at each tier (index = tier - 1). Pool composition only;
    /// weights come from `weights` dict.
    private static let tierKinds: [[RocketKind]] = [
        [.classic],
        [.classic, .shuttle],
        [.classic, .shuttle, .falcon9],
        [.classic, .shuttle, .falcon9, .starship3],
    ]

    /// Mutable so tests can swap in custom values without re-reading env.
    /// Production: populated once from env / defaults at first access.
    static var weights: [RocketKind: Int] = loadWeights()
    static var unlockEnabled: Bool = loadUnlockFlag()

    /// Returns true iff the scene currently hosts a Starship. Injected by
    /// BuddyScene — defaults to false for tests / early boot.
    static var hasActiveStarship: () -> Bool = { false }

    /// Returns the current number of live rocket entities on scene. Used by
    /// the unlock-tier computation. Injected by BuddyScene.
    static var activeRocketCount: () -> Int = { 0 }

    private static func rocketKind(for sessionId: String) -> RocketKind {
        if let cached = kindCache[sessionId] { return cached }

        // Step 1: pool composition
        var pool: [RocketKind]
        if unlockEnabled {
            let tier = min(activeRocketCount() + 1, tierKinds.count)
            pool = tierKinds[tier - 1]
        } else {
            pool = [.classic, .shuttle, .falcon9, .starship3]
        }

        // Step 2: 1-cap
        if hasActiveStarship() {
            pool.removeAll { $0 == .starship3 }
        }

        // Step 3: build weighted candidates, then fall back to uniform if
        // every weight is zero (prevents divide-by-zero and honours "ensure
        // tier unlock can actually pick" semantics even with adversarial env).
        var candidates: [(RocketKind, Int)] = pool.map { ($0, weights[$0, default: 0]) }
        let total = candidates.reduce(0) { $0 + $1.1 }
        if total == 0 {
            if candidates.isEmpty {
                candidates = [(.classic, 1)]
            } else {
                candidates = candidates.map { ($0.0, 1) }
            }
        }

        // Step 4: weighted random
        let sum = candidates.reduce(0) { $0 + $1.1 }
        var roll = Int.random(in: 0..<sum)
        var chosen = candidates[0].0
        for (kind, weight) in candidates {
            if roll < weight {
                chosen = kind
                break
            }
            roll -= weight
        }
        kindCache[sessionId] = chosen
        return chosen
    }

    /// Pre-assign a specific kind to a sessionId before any rocket is built.
    /// Used by the showcase feature to force one rocket per kind.
    static func presetKind(sessionId: String, kind: RocketKind) {
        kindCache[sessionId] = kind
    }

    // MARK: - Env var parsing

    /// Parses `BUDDY_ROCKET_WEIGHTS` — format: `kind=weight` comma-separated,
    /// e.g. `classic=50,shuttle=25,falcon9=15,starship3=10`. Missing kinds
    /// default to 0 when the env var is set (so users can zero out specific
    /// kinds by omission); when the env var is not set at all, defaults to
    /// `defaultWeights`. Invalid tokens log a warning and are skipped.
    private static func loadWeights() -> [RocketKind: Int] {
        guard let raw = ProcessInfo.processInfo.environment["BUDDY_ROCKET_WEIGHTS"],
              !raw.isEmpty else {
            return defaultWeights
        }
        var parsed: [RocketKind: Int] = [
            .classic: 0, .shuttle: 0, .falcon9: 0, .starship3: 0,
        ]
        var anyValid = false
        for token in raw.split(separator: ",") {
            let parts = token.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2,
                  let kind = RocketKind(rawValue: parts[0].trimmingCharacters(in: .whitespaces)),
                  let value = Int(parts[1].trimmingCharacters(in: .whitespaces)),
                  value >= 0 else {
                NSLog("[EntityFactory] BUDDY_ROCKET_WEIGHTS: ignoring malformed token '\(token)'")
                continue
            }
            parsed[kind] = value
            anyValid = true
        }
        if !anyValid {
            NSLog("[EntityFactory] BUDDY_ROCKET_WEIGHTS had no valid entries — falling back to defaults")
            return defaultWeights
        }
        return parsed
    }

    /// Parses `BUDDY_ROCKET_UNLOCK` — anything other than `off/0/false`
    /// (case-insensitive) is treated as on.
    private static func loadUnlockFlag() -> Bool {
        guard let raw = ProcessInfo.processInfo.environment["BUDDY_ROCKET_UNLOCK"] else {
            return true
        }
        switch raw.lowercased() {
        case "off", "0", "false", "no": return false
        default: return true
        }
    }

    /// Test-only hook: re-reads env vars into the static state. Production
    /// code doesn't need this — the statics are initialized at first access.
    static func reloadConfigFromEnv() {
        weights = loadWeights()
        unlockEnabled = loadUnlockFlag()
        kindCache.removeAll()
    }
}
