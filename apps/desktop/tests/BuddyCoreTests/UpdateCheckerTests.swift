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

    // MARK: - Releases Redirect 换源（绕过 GitHub API 60/h 限流）

    /// 契约：从 releases/latest 的 redirect 最终 URL 提取版本号（纯函数，绕过网络）。
    func testReleaseInfoFromRedirectURL() throws {
        let url = URL(string: "https://github.com/strzhao/claude-code-buddy/releases/tag/v0.37.6")!
        let info = try UpdateChecker.releaseInfo(fromRedirectURL: url)
        XCTAssertEqual(info.tagName, "v0.37.6", "应从 redirect URL 末段提取 tag")
        XCTAssertEqual(info.version, "0.37.6", "应去掉 v 前缀得到版本号")
        XCTAssertEqual(info.htmlURL.absoluteString,
                       "https://github.com/strzhao/claude-code-buddy/releases/tag/v0.37.6")
    }

    /// 契约：redirect URL 末段非 v* tag 时抛 invalidResponse。
    func testReleaseInfoFromRedirectURLInvalidThrows() {
        let url = URL(string: "https://github.com/strzhao/claude-code-buddy/releases")!
        XCTAssertThrowsError(try UpdateChecker.releaseInfo(fromRedirectURL: url)) { error in
            XCTAssertTrue(error is UpdateError, "无效 redirect URL 应抛 UpdateError")
        }
    }

    // MARK: - UpdateError 友好提示（LocalizedError）

    /// 契约：UpdateError 的 localizedDescription 是中文友好提示，而非 Swift 默认英文技术信息。
    func testUpdateErrorLocalizedDescriptionIsFriendly() {
        XCTAssertTrue(UpdateError.invalidResponse.localizedDescription.contains("检查更新"),
                      "invalidResponse 应有中文友好提示")
        XCTAssertTrue(UpdateError.invalidURL.localizedDescription.contains("更新"),
                      "invalidURL 应有中文友好提示")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "lastUpdateCheckTimestamp")
        super.tearDown()
    }
}
