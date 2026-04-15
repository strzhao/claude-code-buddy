import XCTest
import SpriteKit
@testable import BuddyCore

// MARK: - BedAndLabelVisualTests

final class BedAndLabelVisualTests: XCTestCase {

    // MARK: - Fix 1: 猫屋放大 2x 常量值验证

    func testBedRenderSizeIs48x28() {
        let bedRenderSize = CatConstants.TaskComplete.bedRenderSize
        XCTAssertEqual(bedRenderSize.width, 48,
                       "bedRenderSize.width 应为 48（放大 2x 后）")
        XCTAssertEqual(bedRenderSize.height, 28,
                       "bedRenderSize.height 应为 28（放大 2x 后）")
    }

    func testSlotSpacingIsNegative56() {
        XCTAssertEqual(CatConstants.TaskComplete.slotSpacing, -56,
                       "slotSpacing 应为 -56（负数表示向左延伸）")
    }

    func testFirstSlotOffsetIsNegative60() {
        XCTAssertEqual(CatConstants.TaskComplete.firstSlotOffset, -60,
                       "firstSlotOffset 应为 -60（负数表示在边界左侧）")
    }

    // MARK: - Fix 2: 降低 debug tab name 标签常量值验证

    func testTabLabelYOffsetIs18() {
        XCTAssertEqual(CatConstants.Visual.tabLabelYOffset, 18,
                       "tabLabelYOffset 应为 18（降低标签位置以适应窗口）")
    }

    func testTabLabelShadowYOffsetIs17() {
        XCTAssertEqual(CatConstants.Visual.tabLabelShadowYOffset, 17,
                       "tabLabelShadowYOffset 应为 17（比主标签低 1px 作为阴影）")
    }

    // MARK: - 验收标准 3：标签在窗口内可见

    func testTabLabelFitsWithinWindowHeight() {
        let groundY = CatConstants.Visual.groundY
        let yOffset = CatConstants.Visual.tabLabelYOffset
        let fontSize = CatConstants.Visual.tabLabelFontSize

        // 默认窗口高度为 80px
        let defaultWindowHeight: CGFloat = 80

        // 标签底部 Y 坐标
        let labelBottomY = groundY + yOffset
        // 标签顶部 Y 坐标（假设文字基线在底部，加上字体高度）
        let labelTopY = labelBottomY + fontSize

        XCTAssertLessThanOrEqual(labelTopY, defaultWindowHeight,
                                 "标签顶部 Y(\(labelTopY)) 应 ≤ 窗口高度(\(defaultWindowHeight))")
    }

    func testTabLabelShadowFitsWithinWindowHeight() {
        let groundY = CatConstants.Visual.groundY
        let shadowYOffset = CatConstants.Visual.tabLabelShadowYOffset
        let fontSize = CatConstants.Visual.tabLabelFontSize

        // 默认窗口高度为 80px
        let defaultWindowHeight: CGFloat = 80

        // 阴影标签顶部 Y 坐标
        let shadowTopY = groundY + shadowYOffset + fontSize

        XCTAssertLessThanOrEqual(shadowTopY, defaultWindowHeight,
                                 "阴影标签顶部 Y(\(shadowTopY)) 应 ≤ 窗口高度(\(defaultWindowHeight))")
    }

    // MARK: - 验收标准 4：猫屋尺寸与猫匹配

    func testBedRenderSizeWidthFitsCat() {
        let bedWidth = CatConstants.TaskComplete.bedRenderSize.width
        let catPlaceholderSize = CatConstants.Physics.placeholderSize.width

        XCTAssertGreaterThanOrEqual(bedWidth, catPlaceholderSize,
                                   "猫屋宽度(\(bedWidth)) 应 ≥ 猫咪宽度(\(catPlaceholderSize))")
    }

    // MARK: - 综合验证：常量组合的合理性

    func testBedConstantsAreConsistentWith2xScale() {
        let bedRenderSize = CatConstants.TaskComplete.bedRenderSize
        let slotSpacing = CatConstants.TaskComplete.slotSpacing
        let firstSlotOffset = CatConstants.TaskComplete.firstSlotOffset

        // 验证 bedRenderSize 符合 2x 放大比例
        XCTAssertEqual(bedRenderSize.width, 48, "bedRenderSize.width 应为 24x2=48")
        XCTAssertEqual(bedRenderSize.height, 28, "bedRenderSize.height 应为 14x2=28")

        // 验证 slotSpacing 符合 2x 放大比例（原值 -48 → -56）
        XCTAssertEqual(slotSpacing, -56, "slotSpacing 应为原值的约 1.16x（考虑猫宽度）")

        // 验证 firstSlotOffset 符合 2x 放大比例（原值 -52 → -60）
        XCTAssertEqual(firstSlotOffset, -60, "firstSlotOffset 应为原值的约 1.15x")
    }

    func testTabLabelOffsetPairMaintainsShadowRelationship() {
        let mainYOffset = CatConstants.Visual.tabLabelYOffset
        let shadowYOffset = CatConstants.Visual.tabLabelShadowYOffset

        // 阴影应比主标签低 1px（常见做法）
        XCTAssertEqual(shadowYOffset, mainYOffset - 1,
                       "阴影 Y 偏移应比主标签低 1px")
    }
}
