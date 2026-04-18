import Foundation

/// Factory for creating concrete SessionEntity instances based on EntityMode.
enum EntityFactory {
    static func make(mode: EntityMode, sessionId: String) -> SessionEntity {
        switch mode {
        case .cat:    return CatEntity(sessionId: sessionId)
        case .rocket: return RocketEntity(sessionId: sessionId, kind: rocketKind(for: sessionId))
        }
    }

    /// Weighted-random assignment per rocket kind. Same sessionId always
    /// returns the same kind (cached) so hot-switches don't flip it.
    ///
    ///   classic 50 | shuttle 30 | falcon9 20 | starship3 10
    ///
    /// CONSTRAINT: `.starship3` is capped at one instance at a time. When the
    /// scene already hosts a Starship (`hasActiveStarship`), it drops out of
    /// the pool and the remaining three kinds are re-rolled by their weights
    /// (showcase uses `presetKind` to bypass this path entirely).
    private static var kindCache: [String: RocketKind] = [:]

    private static let kindWeights: [(RocketKind, Int)] = [
        (.classic,   50),
        (.shuttle,   30),
        (.falcon9,   20),
        (.starship3, 10),
    ]

    /// Hook wired by BuddyScene so the factory can check whether a Starship is
    /// already on scene. Defaults to `false` for tests / early boot.
    static var hasActiveStarship: () -> Bool = { false }

    private static func rocketKind(for sessionId: String) -> RocketKind {
        if let cached = kindCache[sessionId] { return cached }
        let pool = hasActiveStarship()
            ? kindWeights.filter { $0.0 != .starship3 }
            : kindWeights
        let total = pool.reduce(0) { $0 + $1.1 }
        var roll = Int.random(in: 0..<total)
        var chosen = pool.first!.0
        for (kind, weight) in pool {
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
}
