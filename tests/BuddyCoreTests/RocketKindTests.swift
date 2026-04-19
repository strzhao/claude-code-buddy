import XCTest
@testable import BuddyCore

/// Per-kind geometry tests — guards the invariants the strict liftoff /
/// landing flow relies on.
///
/// Critical invariants:
///   • Starship renders at its native 72×72 canvas (no runtime 1.5× scaling).
///   • Starship's `containerInitY = 41` places booster nozzle on OLM top
///     (scene y=6); ship engine lands on scene y=36 — same cruise altitude
///     as every other kind after they lift by `hoverLift`.
///   • Only Starship skips the ground-pad sprite (uses Mechazilla instead).
final class RocketKindTests: XCTestCase {

    func testSpriteSize_starshipIs72() {
        XCTAssertEqual(RocketKind.starship3.spriteSize, CGSize(width: 72, height: 72))
    }

    func testSpriteSize_otherKindsAre48() {
        for kind in [RocketKind.classic, .shuttle, .falcon9] {
            XCTAssertEqual(kind.spriteSize, CGSize(width: 48, height: 48),
                           "\(kind) should render at 48×48")
        }
    }

    func testContainerInitY_starshipIs41() {
        XCTAssertEqual(RocketKind.starship3.containerInitY, 41,
                       "Starship sits at 41 so its booster nozzle (native y=1) is on OLM top (scene y=6).")
    }

    func testContainerInitY_otherKindsMatchGroundY() {
        let groundY = RocketConstants.Visual.groundY
        for kind in [RocketKind.classic, .shuttle, .falcon9] {
            XCTAssertEqual(kind.containerInitY, groundY,
                           "\(kind) container starts at the shared groundY")
        }
    }

    func testHoverLift_allKindsLandEnginesAtSameCruiseAltitude() {
        // Invariant: every kind's primary engine flame sits at scene y=36
        // during cruise. Starship's ship engine is already at 36 (native
        // booster+ship stack), so it lifts 0. Others need their hoverLift.
        XCTAssertEqual(RocketKind.classic.hoverLift,   30)
        XCTAssertEqual(RocketKind.shuttle.hoverLift,   30)
        XCTAssertEqual(RocketKind.falcon9.hoverLift,   34)
        XCTAssertEqual(RocketKind.starship3.hoverLift,  0)
    }

    func testUsesGroundPad_starshipFalse() {
        XCTAssertFalse(RocketKind.starship3.usesGroundPad,
                       "Starship is caught by Mechazilla — no ground pad")
    }

    func testUsesGroundPad_otherKindsTrue() {
        for kind in [RocketKind.classic, .shuttle, .falcon9] {
            XCTAssertTrue(kind.usesGroundPad, "\(kind) should render a ground pad")
        }
    }

    func testSpritePrefix_distinctPerKind() {
        let prefixes = RocketKind.allCases.map { $0.spritePrefix }
        XCTAssertEqual(prefixes.count, Set(prefixes).count,
                       "every kind needs a unique sprite prefix")
    }

    func testAllCasesCount() {
        XCTAssertEqual(RocketKind.allCases.count, 4,
                       "4 rocket kinds in rotation (classic / shuttle / falcon9 / starship3)")
    }
}
