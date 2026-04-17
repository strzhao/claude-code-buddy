import XCTest
@testable import BuddyCore

final class EntityModeTests: XCTestCase {

    func testRawValue_cat() {
        XCTAssertEqual(EntityMode.cat.rawValue, "cat")
    }

    func testRawValue_rocket() {
        XCTAssertEqual(EntityMode.rocket.rawValue, "rocket")
    }

    func testFromRawValue_valid() {
        XCTAssertEqual(EntityMode(rawValue: "cat"), .cat)
        XCTAssertEqual(EntityMode(rawValue: "rocket"), .rocket)
    }

    func testFromRawValue_invalid() {
        XCTAssertNil(EntityMode(rawValue: "fish"))
    }

    func testAllCases() {
        XCTAssertEqual(EntityMode.allCases.count, 2)
    }
}
