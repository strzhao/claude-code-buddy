import XCTest
@testable import BuddyCore

final class TokenLevelTests: XCTestCase {

    // MARK: - Level From Tokens

    func testLevelFromZeroTokens() {
        XCTAssertEqual(TokenLevel.from(totalTokens: 0), .lv1)
    }

    func testLevelFromNegativeTokens() {
        XCTAssertEqual(TokenLevel.from(totalTokens: -100), .lv1)
    }

    func testLevelBoundaryLv2() {
        XCTAssertEqual(TokenLevel.from(totalTokens: 99_999), .lv1)
        XCTAssertEqual(TokenLevel.from(totalTokens: 100_000), .lv2)
    }

    func testLevelBoundaryLv3() {
        XCTAssertEqual(TokenLevel.from(totalTokens: 299_999), .lv2)
        XCTAssertEqual(TokenLevel.from(totalTokens: 300_000), .lv3)
    }

    func testLevelBoundaryLv4() {
        XCTAssertEqual(TokenLevel.from(totalTokens: 499_999), .lv3)
        XCTAssertEqual(TokenLevel.from(totalTokens: 500_000), .lv4)
    }

    func testLevelBoundaryLv8() {
        XCTAssertEqual(TokenLevel.from(totalTokens: 2_999_999), .lv7)
        XCTAssertEqual(TokenLevel.from(totalTokens: 3_000_000), .lv8)
    }

    func testLevelBoundaryLv11() {
        XCTAssertEqual(TokenLevel.from(totalTokens: 9_999_999), .lv10)
        XCTAssertEqual(TokenLevel.from(totalTokens: 10_000_000), .lv11)
    }

    func testLevelBoundaryLv14() {
        XCTAssertEqual(TokenLevel.from(totalTokens: 29_999_999), .lv13)
        XCTAssertEqual(TokenLevel.from(totalTokens: 30_000_000), .lv14)
    }

    func testLevelBoundaryLv16() {
        XCTAssertEqual(TokenLevel.from(totalTokens: 99_999_999), .lv15)
        XCTAssertEqual(TokenLevel.from(totalTokens: 100_000_000), .lv16)
    }

    func testLevelExtremeHighTokens() {
        XCTAssertEqual(TokenLevel.from(totalTokens: 1_000_000_000), .lv16)
        XCTAssertEqual(TokenLevel.from(totalTokens: Int.max), .lv16)
    }

    // MARK: - Scale Values

    func testScaleStartAndEnd() {
        XCTAssertEqual(TokenLevel.lv1.scale, 1.0)
        XCTAssertEqual(TokenLevel.lv16.scale, 1.8)
    }

    func testScaleMonotonicallyIncreasing() {
        var prevScale: CGFloat = 0
        for level in TokenLevel.allCases {
            XCTAssertGreaterThan(level.scale, prevScale, "\(level) scale should be greater than previous")
            prevScale = level.scale
        }
    }

    func testAllLevelsExist() {
        XCTAssertEqual(TokenLevel.allCases.count, 16)
    }

    // MARK: - Window Height

    func testWindowHeightValues() {
        XCTAssertEqual(TokenLevel.lv1.windowHeight, 80)
        XCTAssertEqual(TokenLevel.lv16.windowHeight, 150)
    }

    func testWindowHeightMonotonicallyIncreasing() {
        var prevHeight: CGFloat = 0
        for level in TokenLevel.allCases {
            XCTAssertGreaterThan(level.windowHeight, prevHeight, "\(level) windowHeight should be greater than previous")
            prevHeight = level.windowHeight
        }
    }

    // MARK: - Display Formatting

    func testFormatTokensSmall() {
        XCTAssertEqual(TokenLevel.formatTokens(0), "0")
        XCTAssertEqual(TokenLevel.formatTokens(500), "500")
    }

    func testFormatTokensThousands() {
        XCTAssertEqual(TokenLevel.formatTokens(1_500), "1.5K")
        XCTAssertEqual(TokenLevel.formatTokens(100_000), "100K")
        XCTAssertEqual(TokenLevel.formatTokens(500_000), "500K")
    }

    func testFormatTokensMillions() {
        XCTAssertEqual(TokenLevel.formatTokens(1_200_000), "1.2M")
        XCTAssertEqual(TokenLevel.formatTokens(5_000_000), "5.0M")
        XCTAssertEqual(TokenLevel.formatTokens(50_000_000), "50M")
    }

    func testFormatTokensNegative() {
        XCTAssertEqual(TokenLevel.formatTokens(-100), "0")
    }

    // MARK: - Display Names

    func testDisplayName() {
        XCTAssertEqual(TokenLevel.lv1.displayName, "Lv1")
        XCTAssertEqual(TokenLevel.lv16.displayName, "Lv16")
    }

    func testLevelUpText() {
        let text = TokenLevel.lv7.levelUpText(tokens: 2_000_000)
        XCTAssertEqual(text, "2.0M tokens")
    }

    func testTooltipText() {
        let text = TokenLevel.lv11.tooltipText(tokens: 10_500_000)
        XCTAssertEqual(text, "10M tokens")
    }

    // MARK: - Comparable

    func testComparable() {
        XCTAssertTrue(TokenLevel.lv1 < TokenLevel.lv2)
        XCTAssertTrue(TokenLevel.lv15 < TokenLevel.lv16)
        XCTAssertFalse(TokenLevel.lv3 < TokenLevel.lv1)
    }

    // MARK: - CatSprite Integration

    func testApplyTokenLevelIdempotent() {
        let cat = CatSprite(sessionId: "test-token")
        let changed = cat.applyTokenLevel(totalTokens: 150_000)
        XCTAssertTrue(changed)
        XCTAssertEqual(cat.currentTokenLevel, .lv2)
        XCTAssertEqual(cat.tokenScale, 1.05, accuracy: 0.001)

        let unchanged = cat.applyTokenLevel(totalTokens: 200_000)
        XCTAssertFalse(unchanged)
    }

    func testApplyTokenLevelProgression() {
        let cat = CatSprite(sessionId: "test-token")
        XCTAssertEqual(cat.currentTokenLevel, .lv1)
        XCTAssertEqual(cat.tokenScale, 1.0)

        cat.applyTokenLevel(totalTokens: 2_500_000)
        XCTAssertEqual(cat.currentTokenLevel, .lv7)
        XCTAssertEqual(cat.tokenScale, 1.30, accuracy: 0.001)

        cat.applyTokenLevel(totalTokens: 200_000_000)
        XCTAssertEqual(cat.currentTokenLevel, .lv16)
        XCTAssertEqual(cat.tokenScale, 1.8, accuracy: 0.001)
    }

    func testEnterSceneUsesTokenScale() {
        let cat = CatSprite(sessionId: "test-token")
        cat.applyTokenLevel(totalTokens: 5_000_000)

        cat.enterScene(sceneSize: CGSize(width: 800, height: 120))
        XCTAssertEqual(cat.containerNode.xScale, 1.4, accuracy: 0.001)
        XCTAssertEqual(cat.containerNode.yScale, 1.4, accuracy: 0.001)
    }
}
