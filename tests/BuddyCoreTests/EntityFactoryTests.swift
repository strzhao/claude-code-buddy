import XCTest
@testable import BuddyCore

final class EntityFactoryTests: XCTestCase {

    // MARK: - Setup
    //
    // Tests override `EntityFactory.weights` / `unlockEnabled` / hook closures
    // directly (they're `static var` for that purpose). We snapshot + restore
    // them around each test so cases stay independent.

    private var savedWeights: [RocketKind: Int] = [:]
    private var savedUnlock: Bool = true
    private var savedHasStarship: () -> Bool = { false }
    private var savedRocketCount: () -> Int = { 0 }

    override func setUp() {
        super.setUp()
        savedWeights = EntityFactory.weights
        savedUnlock = EntityFactory.unlockEnabled
        savedHasStarship = EntityFactory.hasActiveStarship
        savedRocketCount = EntityFactory.activeRocketCount
    }

    override func tearDown() {
        EntityFactory.weights = savedWeights
        EntityFactory.unlockEnabled = savedUnlock
        EntityFactory.hasActiveStarship = savedHasStarship
        EntityFactory.activeRocketCount = savedRocketCount
        super.tearDown()
    }

    // MARK: - Basic mode routing

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
        EntityFactory.unlockEnabled = false    // flat pool so ss is eligible
        EntityFactory.hasActiveStarship = { true }

        for trial in 0..<200 {
            let id = "starship-unique-\(trial)-\(UUID().uuidString)"
            let e = EntityFactory.make(mode: .rocket, sessionId: id) as? RocketEntity
            XCTAssertNotEqual(e?.kind, .starship3,
                              "factory should never pick starship3 while one is active")
        }
    }

    // MARK: - Tier unlock

    /// Tier 1 (no rockets on scene) — pool is {classic} only, regardless of
    /// weights. Even a starship3-heavy env var shouldn't leak through.
    func testUnlock_tier1_onlyClassic() {
        EntityFactory.unlockEnabled = true
        EntityFactory.activeRocketCount = { 0 }
        EntityFactory.hasActiveStarship = { false }
        EntityFactory.weights = [
            .classic: 0, .shuttle: 0, .falcon9: 0, .starship3: 100,
        ]

        for trial in 0..<100 {
            let id = "tier1-\(trial)-\(UUID().uuidString)"
            let e = EntityFactory.make(mode: .rocket, sessionId: id) as? RocketEntity
            XCTAssertEqual(e?.kind, .classic,
                           "tier 1 should only produce classic, regardless of weights")
        }
    }

    /// Tier 4 (≥3 rockets) with default weights — all four kinds appear in
    /// roughly the configured proportions (50/25/15/10).
    func testUnlock_tier4_defaultWeights() {
        EntityFactory.unlockEnabled = true
        EntityFactory.activeRocketCount = { 3 }
        EntityFactory.hasActiveStarship = { false }
        EntityFactory.weights = [
            .classic: 50, .shuttle: 25, .falcon9: 15, .starship3: 10,
        ]

        var counts: [RocketKind: Int] = [:]
        let trials = 4000
        for i in 0..<trials {
            let id = "tier4-\(i)-\(UUID().uuidString)"
            if let rocket = EntityFactory.make(mode: .rocket, sessionId: id) as? RocketEntity {
                counts[rocket.kind, default: 0] += 1
            }
        }
        let expected: [RocketKind: Double] = [
            .classic:   0.50,
            .shuttle:   0.25,
            .falcon9:   0.15,
            .starship3: 0.10,
        ]
        for (kind, target) in expected {
            let actual = Double(counts[kind, default: 0]) / Double(trials)
            XCTAssertEqual(actual, target, accuracy: 0.04,
                           "\(kind) frequency \(actual) should be near \(target)")
        }
    }

    /// Tier 4 with an already-active starship — pool shrinks to {c,s,f}, so
    /// starship3 never appears and the other three share the probability
    /// mass renormalised over their weights (50/25/15 → 55.6/27.8/16.7).
    func testUnlock_tier4_withActiveStarship_excludesStarship() {
        EntityFactory.unlockEnabled = true
        EntityFactory.activeRocketCount = { 4 }
        EntityFactory.hasActiveStarship = { true }
        EntityFactory.weights = [
            .classic: 50, .shuttle: 25, .falcon9: 15, .starship3: 10,
        ]

        for trial in 0..<300 {
            let id = "cap-\(trial)-\(UUID().uuidString)"
            let e = EntityFactory.make(mode: .rocket, sessionId: id) as? RocketEntity
            XCTAssertNotEqual(e?.kind, .starship3)
        }
    }

    // MARK: - Flat mode (unlock off)

    /// unlock=off + starship3=100 + no active starship → 100% starship3.
    func testFlat_starshipHeavy_firstPickIsStarship() {
        EntityFactory.unlockEnabled = false
        EntityFactory.hasActiveStarship = { false }
        EntityFactory.activeRocketCount = { 0 }
        EntityFactory.weights = [
            .classic: 0, .shuttle: 0, .falcon9: 0, .starship3: 100,
        ]

        for trial in 0..<100 {
            let id = "flat-ss-\(trial)-\(UUID().uuidString)"
            let e = EntityFactory.make(mode: .rocket, sessionId: id) as? RocketEntity
            XCTAssertEqual(e?.kind, .starship3)
        }
    }

    /// unlock=off + starship3=100 + starship already present → 1-cap removes
    /// starship3, leaving c/s/f all with weight 0. Zero-weight fallback kicks
    /// in and picks uniformly among the remaining three (~33% each).
    func testFlat_starshipHeavy_afterStarshipActive_uniformFallback() {
        EntityFactory.unlockEnabled = false
        EntityFactory.hasActiveStarship = { true }
        EntityFactory.weights = [
            .classic: 0, .shuttle: 0, .falcon9: 0, .starship3: 100,
        ]

        var counts: [RocketKind: Int] = [:]
        let trials = 3000
        for i in 0..<trials {
            let id = "flat-fallback-\(i)-\(UUID().uuidString)"
            if let rocket = EntityFactory.make(mode: .rocket, sessionId: id) as? RocketEntity {
                counts[rocket.kind, default: 0] += 1
            }
        }
        XCTAssertEqual(counts[.starship3, default: 0], 0,
                       "1-cap must exclude starship3 entirely")
        // Uniform over three kinds → 1/3 ± 4%
        for kind in [RocketKind.classic, .shuttle, .falcon9] {
            let actual = Double(counts[kind, default: 0]) / Double(trials)
            XCTAssertEqual(actual, 1.0 / 3.0, accuracy: 0.04,
                           "\(kind) should be ~33.3% under uniform fallback")
        }
    }

    // MARK: - Env var parsing

    /// Malformed env var → log warning + fall back to defaults. We exercise
    /// this via a direct call to `reloadConfigFromEnv` after installing the
    /// malformed value.
    func testLoadWeights_malformedEnv_fallsBackToDefaults() {
        setenv("BUDDY_ROCKET_WEIGHTS", "bogus=foo,classic=-5,", 1)
        defer { unsetenv("BUDDY_ROCKET_WEIGHTS") }
        EntityFactory.reloadConfigFromEnv()

        // `classic=-5` is ignored (not a valid non-negative int) and
        // `bogus=foo` is ignored too → no valid entries → fallback to
        // defaults (50/25/15/10).
        XCTAssertEqual(EntityFactory.weights[.classic], 50)
        XCTAssertEqual(EntityFactory.weights[.shuttle], 25)
        XCTAssertEqual(EntityFactory.weights[.falcon9], 15)
        XCTAssertEqual(EntityFactory.weights[.starship3], 10)
    }

    /// Partial env var — kinds omitted default to 0 so users can pin the
    /// distribution to specific kinds.
    func testLoadWeights_partialEnv_missingKindsDefaultToZero() {
        setenv("BUDDY_ROCKET_WEIGHTS", "starship3=100", 1)
        defer { unsetenv("BUDDY_ROCKET_WEIGHTS") }
        EntityFactory.reloadConfigFromEnv()

        XCTAssertEqual(EntityFactory.weights[.classic], 0)
        XCTAssertEqual(EntityFactory.weights[.shuttle], 0)
        XCTAssertEqual(EntityFactory.weights[.falcon9], 0)
        XCTAssertEqual(EntityFactory.weights[.starship3], 100)
    }

    func testLoadUnlockFlag_offVariants_treatedAsOff() {
        for value in ["off", "OFF", "0", "false", "no"] {
            setenv("BUDDY_ROCKET_UNLOCK", value, 1)
            EntityFactory.reloadConfigFromEnv()
            XCTAssertFalse(EntityFactory.unlockEnabled,
                           "BUDDY_ROCKET_UNLOCK=\(value) should disable unlock")
        }
        unsetenv("BUDDY_ROCKET_UNLOCK")
        EntityFactory.reloadConfigFromEnv()
        XCTAssertTrue(EntityFactory.unlockEnabled, "default should be on")
    }

    func testLoadUnlockFlag_onVariants_treatedAsOn() {
        for value in ["on", "1", "true", "yes", "whatever"] {
            setenv("BUDDY_ROCKET_UNLOCK", value, 1)
            EntityFactory.reloadConfigFromEnv()
            XCTAssertTrue(EntityFactory.unlockEnabled,
                          "BUDDY_ROCKET_UNLOCK=\(value) should NOT disable unlock")
        }
        unsetenv("BUDDY_ROCKET_UNLOCK")
        EntityFactory.reloadConfigFromEnv()
    }

    func testLoadWeights_whitespaceTolerance() {
        setenv("BUDDY_ROCKET_WEIGHTS", "classic = 30 , shuttle=20,  falcon9=15 ,starship3=5", 1)
        defer { unsetenv("BUDDY_ROCKET_WEIGHTS") }
        EntityFactory.reloadConfigFromEnv()

        XCTAssertEqual(EntityFactory.weights[.classic], 30)
        XCTAssertEqual(EntityFactory.weights[.shuttle], 20)
        XCTAssertEqual(EntityFactory.weights[.falcon9], 15)
        XCTAssertEqual(EntityFactory.weights[.starship3], 5)
    }

    func testLoadWeights_emptyEnv_fallsBackToDefaults() {
        setenv("BUDDY_ROCKET_WEIGHTS", "", 1)
        defer { unsetenv("BUDDY_ROCKET_WEIGHTS") }
        EntityFactory.reloadConfigFromEnv()

        XCTAssertEqual(EntityFactory.weights[.classic], 50)
        XCTAssertEqual(EntityFactory.weights[.shuttle], 25)
        XCTAssertEqual(EntityFactory.weights[.falcon9], 15)
        XCTAssertEqual(EntityFactory.weights[.starship3], 10)
    }

    // MARK: - Tier coverage (2 & 3)

    /// Tier 2 — pool is {classic, shuttle}; default weights → classic 50,
    /// shuttle 25 → normalized to 66.7 / 33.3. falcon9 / starship3 must
    /// never appear.
    func testUnlock_tier2_twoKindsOnly() {
        EntityFactory.unlockEnabled = true
        EntityFactory.activeRocketCount = { 1 }
        EntityFactory.hasActiveStarship = { false }
        EntityFactory.weights = [
            .classic: 50, .shuttle: 25, .falcon9: 15, .starship3: 10,
        ]

        var counts: [RocketKind: Int] = [:]
        let trials = 3000
        for i in 0..<trials {
            let id = "tier2-\(i)-\(UUID().uuidString)"
            if let r = EntityFactory.make(mode: .rocket, sessionId: id) as? RocketEntity {
                counts[r.kind, default: 0] += 1
            }
        }
        XCTAssertEqual(counts[.falcon9, default: 0], 0)
        XCTAssertEqual(counts[.starship3, default: 0], 0)
        let classicRatio = Double(counts[.classic, default: 0]) / Double(trials)
        let shuttleRatio = Double(counts[.shuttle, default: 0]) / Double(trials)
        XCTAssertEqual(classicRatio, 50.0 / 75.0, accuracy: 0.05)
        XCTAssertEqual(shuttleRatio, 25.0 / 75.0, accuracy: 0.05)
    }

    /// Tier 3 — pool is {c, s, f}; starship3 must never appear.
    func testUnlock_tier3_noStarship() {
        EntityFactory.unlockEnabled = true
        EntityFactory.activeRocketCount = { 2 }
        EntityFactory.hasActiveStarship = { false }
        EntityFactory.weights = [
            .classic: 50, .shuttle: 25, .falcon9: 15, .starship3: 10,
        ]

        for trial in 0..<300 {
            let id = "tier3-\(trial)-\(UUID().uuidString)"
            let e = EntityFactory.make(mode: .rocket, sessionId: id) as? RocketEntity
            XCTAssertNotEqual(e?.kind, .starship3)
        }
    }

    /// Counts beyond 3 (tier cap) still use tier 4 pool — no out-of-bounds.
    func testUnlock_countBeyondTier4_stillUsesTier4() {
        EntityFactory.unlockEnabled = true
        EntityFactory.activeRocketCount = { 99 }  // way above max tier
        EntityFactory.hasActiveStarship = { false }
        EntityFactory.weights = [
            .classic: 0, .shuttle: 0, .falcon9: 0, .starship3: 100,
        ]

        for trial in 0..<30 {
            let id = "tier-cap-\(trial)-\(UUID().uuidString)"
            let e = EntityFactory.make(mode: .rocket, sessionId: id) as? RocketEntity
            XCTAssertEqual(e?.kind, .starship3)
        }
    }

    /// Unlock=on with env-overridden weights — tier 4 should honor custom
    /// weights exactly like flat mode does.
    func testUnlock_tier4_honorsCustomWeights() {
        EntityFactory.unlockEnabled = true
        EntityFactory.activeRocketCount = { 3 }
        EntityFactory.hasActiveStarship = { false }
        EntityFactory.weights = [
            .classic: 10, .shuttle: 10, .falcon9: 10, .starship3: 70,
        ]

        var starship = 0
        let trials = 2000
        for i in 0..<trials {
            let id = "tier4-custom-\(i)-\(UUID().uuidString)"
            if let r = EntityFactory.make(mode: .rocket, sessionId: id) as? RocketEntity,
               r.kind == .starship3 {
                starship += 1
            }
        }
        let actual = Double(starship) / Double(trials)
        XCTAssertEqual(actual, 0.70, accuracy: 0.05)
    }
}
