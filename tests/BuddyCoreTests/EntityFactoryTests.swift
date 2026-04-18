import XCTest
@testable import BuddyCore

final class EntityFactoryTests: XCTestCase {

    func testMake_catMode_returnsCatEntity() {
        let e = EntityFactory.make(mode: .cat, sessionId: "s1")
        XCTAssertTrue(e is CatEntity)
        XCTAssertEqual(e.sessionId, "s1")
    }

    func testMake_rocketMode_returnsRocketEntity() {
        let e = EntityFactory.make(mode: .rocket, sessionId: "r")
        XCTAssertTrue(e is RocketEntity)
        XCTAssertEqual(e.sessionId, "r")
    }

    func testMake_preservesSessionId() {
        let e = EntityFactory.make(mode: .cat, sessionId: "abc-123")
        XCTAssertEqual(e.sessionId, "abc-123")
    }

    // MARK: - Rocket kind assignment

    /// Same sessionId must always resolve to the same kind — required so
    /// hot-switching cat ↔ rocket doesn't flip the visual variant.
    func testMake_rocketMode_sameSessionIdReturnsSameKind() {
        let id = "kind-stability-\(UUID().uuidString)"
        let a = EntityFactory.make(mode: .rocket, sessionId: id) as? RocketEntity
        let b = EntityFactory.make(mode: .rocket, sessionId: id) as? RocketEntity
        XCTAssertNotNil(a)
        XCTAssertNotNil(b)
        XCTAssertEqual(a?.kind, b?.kind)
    }

    /// presetKind forces a specific kind (used by showcase to reserve slots
    /// so each kind appears exactly once).
    func testPresetKind_overridesAssignment() {
        let id = "preset-\(UUID().uuidString)"
        EntityFactory.presetKind(sessionId: id, kind: .starship3)
        let e = EntityFactory.make(mode: .rocket, sessionId: id) as? RocketEntity
        XCTAssertEqual(e?.kind, .starship3)
    }

    /// When a Starship is already on scene, the factory must never assign
    /// `.starship3` — this is the at-most-one uniqueness rule wired via
    /// `EntityFactory.hasActiveStarship`.
    func testStarshipUniqueness_whenActiveStarship_neverAssignsStarship() {
        let savedHook = EntityFactory.hasActiveStarship
        defer { EntityFactory.hasActiveStarship = savedHook }
        EntityFactory.hasActiveStarship = { true }

        for trial in 0..<200 {
            let id = "starship-unique-\(trial)-\(UUID().uuidString)"
            let e = EntityFactory.make(mode: .rocket, sessionId: id) as? RocketEntity
            XCTAssertNotEqual(e?.kind, .starship3,
                              "factory should never pick starship3 while one is active")
        }
    }

    /// Weighted distribution (no-starship blocked) approximately matches the
    /// configured weights (classic 50, shuttle 30, falcon9 20, starship3 10).
    /// Loose tolerance of ±6% per kind to absorb RNG variance over 4000 trials.
    func testWeightedDistribution_matchesConfiguredWeights() {
        let savedHook = EntityFactory.hasActiveStarship
        defer { EntityFactory.hasActiveStarship = savedHook }
        EntityFactory.hasActiveStarship = { false }

        var counts: [RocketKind: Int] = [:]
        let trials = 4000
        for i in 0..<trials {
            let id = "weighted-\(i)-\(UUID().uuidString)"
            if let rocket = EntityFactory.make(mode: .rocket, sessionId: id) as? RocketEntity {
                counts[rocket.kind, default: 0] += 1
            }
        }
        let expected: [RocketKind: Double] = [
            .classic:   50.0 / 110.0,
            .shuttle:   30.0 / 110.0,
            .falcon9:   20.0 / 110.0,
            .starship3: 10.0 / 110.0,
        ]
        for (kind, target) in expected {
            let actual = Double(counts[kind, default: 0]) / Double(trials)
            XCTAssertEqual(actual, target, accuracy: 0.06,
                           "\(kind) frequency \(actual) should be near \(target)")
        }
    }
}
