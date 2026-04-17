import XCTest
@testable import BuddyCore

final class EntityFactoryTests: XCTestCase {

    func testMake_catMode_returnsCatEntity() {
        let e = EntityFactory.make(mode: .cat, sessionId: "s1")
        XCTAssertTrue(e is CatEntity)
        XCTAssertEqual(e.sessionId, "s1")
    }

    func testMake_rocketMode_phase1_throwsOrFallsBack() {
        let e = EntityFactory.make(mode: .rocket, sessionId: "s2")
        XCTAssertTrue(e is CatEntity, "Phase 1 rocket mode should fall back to CatEntity")
    }

    func testMake_preservesSessionId() {
        let e = EntityFactory.make(mode: .cat, sessionId: "abc-123")
        XCTAssertEqual(e.sessionId, "abc-123")
    }
}
