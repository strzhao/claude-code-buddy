import AppKit

// MARK: - SettingsTheme

/// 设置窗口视觉 token 体系（A1，纯 AppKit）。
///
/// 对标 `LauncherTheme` 组织但**返回 NSFont/NSColor**（非 SwiftUI Font/Color），
/// 因为设置页是纯 AppKit（NSViewController/NSView/NSCollectionView）。
///
/// 设计目标：
/// - **品牌色**：`accent`(sage) + `accentHover` 引用 `BuddyPalette` 同源（A2）
/// - **文字层级**：`title` / `rowTitle` / `rowSubtitle` / `footnote` / `badge`（语义包装系统色 + 统一字号）
/// - **间距栅格**：`contentPadding` / `groupTopInset` / `groupSpacing` / `cardCornerRadius` 等
/// - **明暗机制**：所有色用 `NSColor(name:dynamicProvider:)` 包装（patterns/2026-05-28）
///
/// 使用：各设置页直接 `SettingsTheme.xxx`，无需手传 appearance。
enum SettingsTheme {

    // MARK: - Brand Colors (sage, A2 同源)

    /// 品牌强调色（sage），引用 BuddyPalette.sage（与 LauncherTheme.primary 同源）。
    static let accent: NSColor = BuddyPalette.sage

    /// 品牌强调色 hover 态，引用 BuddyPalette.sageHover。
    static let accentHover: NSColor = BuddyPalette.sageHover

    // MARK: - Text Tier (NSFont + NSColor)

    /// 页面大标题字体：17pt semibold。
    static func titleFont() -> NSFont {
        .systemFont(ofSize: 17, weight: .semibold)
    }

    /// 页面大标题颜色：主文字色。
    static func titleColor() -> NSColor {
        .labelColor
    }

    /// 行标题字体：13pt medium。
    static func rowTitleFont() -> NSFont {
        .systemFont(ofSize: 13, weight: .medium)
    }

    /// 行标题颜色：主文字色。
    static func rowTitleColor() -> NSColor {
        .labelColor
    }

    /// 行副标题字体：12pt regular。
    static func rowSubtitleFont() -> NSFont {
        .systemFont(ofSize: 12)
    }

    /// 行副标题颜色：次要文字色。
    static func rowSubtitleColor() -> NSColor {
        .secondaryLabelColor
    }

    /// 分组标签字体：11pt medium（对标系统设置分组标题如「通用」「系统」）。
    static func groupLabelFont() -> NSFont {
        .systemFont(ofSize: 11, weight: .medium)
    }

    /// 脚注字体：11pt regular。
    static func footnoteFont() -> NSFont {
        .systemFont(ofSize: 11)
    }

    /// 脚注颜色：三级文字色。
    static func footnoteColor() -> NSColor {
        .tertiaryLabelColor
    }

    /// badge 字体：10pt medium。
    static func badgeFont() -> NSFont {
        .systemFont(ofSize: 10, weight: .medium)
    }

    /// badge 颜色：次要文字色。
    static func badgeColor() -> NSColor {
        .secondaryLabelColor
    }

    // MARK: - Layout Spacing Grid

    /// 内容左右页边距：24pt（对标系统设置页边距）。
    static let contentPadding: CGFloat = 24

    /// 分组顶部留白：20pt（第一组距页面顶部）。
    static let groupTopInset: CGFloat = 20

    /// 分组之间的间距：20pt。
    static let groupSpacing: CGFloat = 20

    /// 分组卡片内行间距（行间分隔线之外的垂直间距）：8pt。
    static let rowSpacing: CGFloat = 8

    /// 分组卡片内左右内边距：16pt。
    static let cardContentPadding: CGFloat = 16

    /// 分组卡片圆角：10pt。
    static let cardCornerRadius: CGFloat = 10

    // MARK: - Surface Colors (dynamic, NSAppearance-aware)

    /// 分组卡片背景色：controlBackgroundColor（系统分组盒底色）。
    static let cardBackgroundColor: NSColor = .controlBackgroundColor

    /// 分隔线颜色：separatorColor（系统细分隔线）。
    static let separatorColor: NSColor = .separatorColor

    /// 警告文字颜色：systemRed 包装为 NSColor name 以保持一致 API 形态。
    static let warningColor: NSColor = .systemRed

}
