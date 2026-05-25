import XCTest
@testable import BuddyCore

final class UpdateCheckerTests: XCTestCase {

    private var checker: UpdateChecker!

    override func setUp() {
        super.setUp()
        checker = UpdateChecker.shared
    }

    // MARK: - Version Comparison

    func testCompareVersionsAscending() {
        XCTAssertEqual(checker.compareVersions("0.12.0", "0.12.1"), .orderedAscending)
        XCTAssertEqual(checker.compareVersions("0.11.9", "0.12.0"), .orderedAscending)
        XCTAssertEqual(checker.compareVersions("0.0.1", "1.0.0"), .orderedAscending)
    }

    func testCompareVersionsDescending() {
        XCTAssertEqual(checker.compareVersions("0.13.0", "0.12.0"), .orderedDescending)
        XCTAssertEqual(checker.compareVersions("1.0.0", "0.99.9"), .orderedDescending)
        XCTAssertEqual(checker.compareVersions("2.0.0", "1.9.9"), .orderedDescending)
    }

    func testCompareVersionsEqual() {
        XCTAssertEqual(checker.compareVersions("0.14.0", "0.14.0"), .orderedSame)
        XCTAssertEqual(checker.compareVersions("1.0.0", "1.0.0"), .orderedSame)
    }

    func testCompareVersionsMajorBeatsMinor() {
        XCTAssertEqual(checker.compareVersions("1.0.0", "0.99.99"), .orderedDescending)
        XCTAssertEqual(checker.compareVersions("0.99.99", "1.0.0"), .orderedAscending)
    }

    func testCompareVersionsMinorBeatsPatch() {
        XCTAssertEqual(checker.compareVersions("0.2.0", "0.1.99"), .orderedDescending)
    }

    func testIsUpgradingInitiallyFalse() {
        XCTAssertFalse(checker.isUpgrading)
    }

    // MARK: - Event Struct

    func testUpdateAvailableEventCreation() {
        let event = UpdateAvailableEvent(
            currentVersion: "0.12.0",
            newVersion: "0.14.0",
            htmlURL: URL(string: "https://github.com/test")!
        )
        XCTAssertEqual(event.currentVersion, "0.12.0")
        XCTAssertEqual(event.newVersion, "0.14.0")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "lastUpdateCheckTimestamp")
        super.tearDown()
    }
}
