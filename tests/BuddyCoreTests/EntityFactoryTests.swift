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
}
