import XCTest
@testable import BuddyCore

// MARK: - 红队验收测试：SettingsTheme stage-0 栅格 token 扩展（2026-07-09）

/// 黑盒验收测试：基于设计文档承诺的 stage-0 间距栅格 scale + 布局常量 + 语义 token 对齐 scale，
/// 逐项断言所有 CGFloat 静态常量的精确值与对齐关系。
///
/// 本文件**不读取**蓝队 `Sources/ClaudeCodeBuddy/Settings/SettingsTheme.swift` 实现，
/// 也不读蓝队的 `SettingsThemeTests.swift`，仅对设计文档承诺的"外部可观测常量值"下断言。
///
/// 设计权威源（唯一真相）：
/// - **scale（4 倍数）**：spacingXs=4 / spacingSm=8 / spacingMd=12 / spacingLg=16
///   / spacingXl=24 / spacingXxl=32 / spacingSection=48
/// - **布局常量**：contentMaxWidth=780 / sidebarWidth=200 / pluginListWidth=240
///   / minRowHeight=44 / contentTopInset=48
/// - **语义 token 对齐 scale（语义名保留，值==对应 scale）**：
///   contentPadding==spacingXl(24) / cardContentPadding==spacingLg(16)
///   / rowSpacing==spacingSm(8) / groupSpacing==spacingXl(24)
///   / groupTopInset==spacingXl(24)
///
/// 所有均为 `SettingsTheme.<名>` 形式访问（CGFloat 静态常量）。
///
/// 验收维度：
/// - D1（scale 精确值）：7 个 spacing 常量逐值断言，杀死"栅格值漂移"回归。
/// - D2（布局常量精确值）：5 个 layout 常量逐值断言，杀死"窗口/面板宽度回归"。
/// - D3（语义 token 对齐 scale）：5 个语义 token 必须等于对应 scale 常量引用
///   （不硬编码数值，而是 `== SettingsTheme.spacingXl` 形式），杀死"语义 token 与
///   scale 解耦漂移"回归——即 scale 改动时语义 token 必须跟随，否则破坏单一栅格真相源。
final class SettingsThemeAcceptanceTests: XCTestCase {

    // MARK: - D1：scale 间距栅格（4 倍数）精确值

    /// D1 [scale-precision]：7 个 spacing 常量必须精确等于设计承诺的 4 倍数栅格值。
    /// 杀死"栅格值漂移"（如 spacingMd 被改成 16 破坏 4pt 基线）的回归。
    func test_spacingScale_values() {
        XCTAssertEqual(SettingsTheme.spacingXs, 4,
                       "D1 违反：spacingXs 必须为 4（4pt 基线最小栅格）")
        XCTAssertEqual(SettingsTheme.spacingSm, 8,
                       "D1 违反：spacingSm 必须为 8")
        XCTAssertEqual(SettingsTheme.spacingMd, 12,
                       "D1 违反：spacingMd 必须为 12")
        XCTAssertEqual(SettingsTheme.spacingLg, 16,
                       "D1 违反：spacingLg 必须为 16")
        XCTAssertEqual(SettingsTheme.spacingXl, 24,
                       "D1 违反：spacingXl 必须为 24")
        XCTAssertEqual(SettingsTheme.spacingXxl, 32,
                       "D1 违反：spacingXxl 必须为 32")
        XCTAssertEqual(SettingsTheme.spacingSection, 48,
                       "D1 违反：spacingSection 必须为 48（分区级大间距）")
    }

    // MARK: - D2：布局常量精确值

    /// D2 [layout-precision]：5 个布局常量必须精确等于设计承诺值。
    /// 杀死"内容区宽度/侧边栏宽度/最小行高/顶部 inset 回归"（如 contentMaxWidth 被改成 800
    /// 导致内容区溢出 sidebar 比例失调）的回归。
    func test_layoutConstants_values() {
        XCTAssertEqual(SettingsTheme.contentMaxWidth, 780,
                       "D2 违反：contentMaxWidth 必须为 780（设置内容区最大宽度）")
        XCTAssertEqual(SettingsTheme.sidebarWidth, 200,
                       "D2 违反：sidebarWidth 必须为 200（左侧分类导航宽度）")
        XCTAssertEqual(SettingsTheme.pluginListWidth, 240,
                       "D2 违反：pluginListWidth 必须为 240（插件列表列宽）")
        XCTAssertEqual(SettingsTheme.minRowHeight, 44,
                       "D2 违反：minRowHeight 必须为 44（Apple HIG 可点击行最小高度）")
        XCTAssertEqual(SettingsTheme.contentTopInset, 48,
                       "D2 违反：contentTopInset 必须为 48（内容区顶部 inset）")
    }

    // MARK: - D3：语义 token 对齐 scale（引用相等，非硬编码数值）

    /// D3 [semantic-aligned-to-scale]：5 个语义 token 必须等于对应 scale 常量引用
    /// （断言 `== SettingsTheme.spacingX*` 形式，非硬编码数值）。
    /// 杀死"语义 token 与 scale 解耦漂移"回归——scale 改动时语义 token 必须跟随，
    /// 否则破坏"单一栅格真相源"（语义名是 scale 的别名，值不能独立漂移）。
    func test_semanticTokens_alignedToScale() {
        XCTAssertEqual(SettingsTheme.contentPadding, SettingsTheme.spacingXl,
                       "D3 违反：contentPadding 必须对齐 spacingXl（内容内边距用大栅格）")
        XCTAssertEqual(SettingsTheme.cardContentPadding, SettingsTheme.spacingLg,
                       "D3 违反：cardContentPadding 必须对齐 spacingLg（卡片内边距用中栅格）")
        XCTAssertEqual(SettingsTheme.rowSpacing, SettingsTheme.spacingSm,
                       "D3 违反：rowSpacing 必须对齐 spacingSm（行间距用小栅格）")
        XCTAssertEqual(SettingsTheme.groupSpacing, SettingsTheme.spacingXl,
                       "D3 违反：groupSpacing 必须对齐 spacingXl（分组间距用大栅格）")
        XCTAssertEqual(SettingsTheme.groupTopInset, SettingsTheme.spacingXl,
                       "D3 违反：groupTopInset 必须对齐 spacingXl（分组顶部 inset 用大栅格）")
    }
}
