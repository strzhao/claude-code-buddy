import Foundation

/// Factory for creating concrete SessionEntity instances based on EntityMode.
enum EntityFactory {
    static func make(mode: EntityMode, sessionId: String) -> SessionEntity {
        switch mode {
        case .cat:    return CatEntity(sessionId: sessionId)
        case .rocket: return RocketEntity(sessionId: sessionId, kind: rocketKind(for: sessionId))
        }
    }

    /// Round-robin assignment across all rocket kinds (classic → shuttle → F9 → starship3 → repeat).
    /// Same sessionId always returns the same kind (cached) so hot-switches don't flip it.
    ///
    /// CONSTRAINT: `.starship3` may only be assigned once at a time. If the scene already
    /// hosts a Starship via `hasActiveStarship`, we skip to the next kind in the rotation.
    private static var kindCache: [String: RocketKind] = [:]
    private static var rocketCounter = 0

    /// Hook wired by BuddyScene so the factory can check whether a Starship is
    /// already on scene. Defaults to `false` for tests / early boot.
    static var hasActiveStarship: () -> Bool = { false }

    private static func rocketKind(for sessionId: String) -> RocketKind {
        if let cached = kindCache[sessionId] { return cached }
        let all = RocketKind.allCases
        // Try at most `all.count` times to find a kind that isn't blocked by the
        // starship uniqueness rule.
        var chosen: RocketKind = all[rocketCounter % all.count]
        for _ in 0..<all.count {
            let candidate = all[rocketCounter % all.count]
            rocketCounter += 1
            if candidate == .starship3 && hasActiveStarship() {
                continue   // skip, try next rotation slot
            }
            chosen = candidate
            break
        }
        kindCache[sessionId] = chosen
        return chosen
    }

    /// Pre-assign a specific kind to a sessionId before any rocket is built.
    /// Used by the showcase feature to force one rocket per kind.
    static func presetKind(sessionId: String, kind: RocketKind) {
        kindCache[sessionId] = kind
    }
}
