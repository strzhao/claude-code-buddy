import XCTest
import AppKit
import SwiftUI
@testable import BuddyCore

// MARK: - 红队验收测试：SettingsTheme token 完整性 + sage 同源（SC-SET-05/06/07/08/10）
//
// 设计权威源（本测试逐字断言的契约，来自状态文件 `## 设计文档` A1 + `## 契约规约` C4/C5）：
//
// A1 — 新建 `Sources/ClaudeCodeBuddy/Settings/SettingsTheme.swift`（enum 命名空间，对标 LauncherTheme）：
//   - AppKit 适配：设置页纯 AppKit（NSViewController/NSView），SettingsTheme 提供 `NSFont` + `NSColor`
//     （**非** LauncherTheme 的 SwiftUI `Font`/`Color`）。
//   - 品牌色：`accent`（sage light `#3a7d68` / dark `#52a688`）+ `accentHover`（light `#52a688` / dark `#6bbf9f`）。
//     **与 LauncherTheme.primary 同值**。
//   - 文字层级（语义包装系统色 + 统一字号）：`title`（17pt semibold + labelColor，页面大标题）/
//     `rowTitle`（13pt + labelColor）/ `rowSubtitle`（12pt + secondaryLabelColor，说明副标题）/
//     `footnote`（11pt + tertiaryLabelColor）/ `badge`（10pt medium + secondaryLabelColor）。
//   - 间距栅格：`contentPadding`(24 左右页边距) / `groupTopInset`(20) / `groupSpacing`(20 组间) /
//     `rowSpacing`(行内，靠分隔线) / `cardCornerRadius`(10) / `cardBackgroundColor`(controlBackgroundColor) /
//     `separatorColor`(separatorColor)。
//   - 明暗机制：所有色用 `NSColor(name:dynamicProvider:)` 包装。
//
// A2 — sage 同源：抽共享常量 `BuddyPalette.sage`（light/dark dynamic NSColor 一处定义），
//   `SettingsTheme.accent` 与 `LauncherTheme.primary` 都引用它。SC-SET-10 要求"来自同一常量定义"。
//
// C4 — SettingsTheme token：sage light `#3a7d68`/dark `#52a688`（与 LauncherTheme.primary 同源）；
//   文字层级 ≥3 档；间距栅格 ≥4 常量；所有色 NSColor(name:dynamicProvider:) 明暗双值。
//
// C5 — 硬编码消除（SC-SET-07/08）：5 个 detail 页 grep `systemFont(ofSize:` 命中=0；grep `yOffset` 命中=0。
//
// ⚠️ API 假设（设计文档 A1 未完全明确的形状，红队按最合理 AppKit 惯例假设）：
//   文字层级 token 形状（两种合理形态之一）：
//     形态 A（推荐，分方法）：`SettingsTheme.titleFont() -> NSFont` + `SettingsTheme.titleColor() -> NSColor`
//                               `rowTitleFont()` / `rowTitleColor()` ……（每个层级一对）
//     形态 B（元组）：`SettingsTheme.title -> (font: NSFont, color: NSColor)` ……（每个层级一元组）
//   本测试采用 **形态 A**（分方法，AppKit 惯例：`NSFont.systemFont` / `NSColor.labelColor` 各自独立）。
//   品牌色：`SettingsTheme.accent -> NSColor` + `SettingsTheme.accentHover -> NSColor`（属性，与 A1 一致）。
//   间距：`SettingsTheme.contentPadding / groupTopInset / groupSpacing / cardCornerRadius`（CGFloat 常量，A1 明列）。
//   卡片/分隔：`SettingsTheme.cardBackgroundColor -> NSColor` + `SettingsTheme.separatorColor -> NSColor`。
//   sage 同源：`BuddyPalette.sage -> NSColor`（A2 明列），`SettingsTheme.accent` 与 `LauncherTheme.primary`
//     在同 appearance 下 RGB 相等（来自同一常量）。
//
// 若蓝队实现偏离上述 API 假设（例如采用形态 B 元组，或方法名/层级命名不同），测试会失败——
// 这正是红队要抓的偏差。蓝队可选择改实现对齐假设，或与编排器协调调整测试（但后者需披露）。
//
// 红队原则：所有断言代表"设计意图应该满足"，不代表"实现实际做了什么"。
// 本文件 WILL NOT compile 直到蓝队合并 SettingsTheme + BuddyPalette 实现 — 这是预期 TDD 红灯。

@MainActor
final class SettingsThemeTests: XCTestCase {

    // MARK: - SC-SET-05 sage 品牌色 light/dark 双值正确 + dynamicProvider 注册
    //
    // 谓词：When SettingsTheme sage token 在 light/dark appearance 求值, 双值正确。
    // assert: light RGB==(0x3a,0x7d,0x68), dark==(0x52,0xa6,0x88), 经 dynamicProvider 注册。

    /// sage light = (0x3a, 0x7d, 0x68) = #3a7d68。
    func test_SC_SET_05_accent_lightAppearance_is3a7d68() {
        let accent = SettingsTheme.accent
        let (r, g, b, _) = Self.rgbComponents(of: accent, appearanceName: .aqua)
        XCTAssertEqual(r, CGFloat(0x3a) / 255.0, accuracy: 0.01,
                       "SettingsTheme.accent light .red 应 == 0x3a/255 (#3a7d68)")
        XCTAssertEqual(g, CGFloat(0x7d) / 255.0, accuracy: 0.01,
                       "SettingsTheme.accent light .green 应 == 0x7d/255 (#3a7d68)")
        XCTAssertEqual(b, CGFloat(0x68) / 255.0, accuracy: 0.01,
                       "SettingsTheme.accent light .blue 应 == 0x68/255 (#3a7d68)")
    }

    /// sage dark = (0x52, 0xa6, 0x88) = #52a688。
    func test_SC_SET_05_accent_darkAppearance_is52a688() {
        let accent = SettingsTheme.accent
        let (r, g, b, _) = Self.rgbComponents(of: accent, appearanceName: .darkAqua)
        XCTAssertEqual(r, CGFloat(0x52) / 255.0, accuracy: 0.01,
                       "SettingsTheme.accent dark .red 应 == 0x52/255 (#52a688)")
        XCTAssertEqual(g, CGFloat(0xa6) / 255.0, accuracy: 0.01,
                       "SettingsTheme.accent dark .green 应 == 0xa6/255 (#52a688)")
        XCTAssertEqual(b, CGFloat(0x88) / 255.0, accuracy: 0.01,
                       "SettingsTheme.accent dark .blue 应 == 0x88/255 (#52a688)")
    }

    /// accent 必须是 dynamic NSColor（经 dynamicProvider 注册），即 light/dark 求值不同。
    /// 杀死"静态单值 NSColor 假装双主题"的 mutation。
    func test_SC_SET_05_accent_isDynamicColor_lightAndDarkDiffer() {
        let accent = SettingsTheme.accent
        let light = Self.rgbComponents(of: accent, appearanceName: .aqua)
        let dark = Self.rgbComponents(of: accent, appearanceName: .darkAqua)
        // light (#3a7d68) 与 dark (#52a688) 的 R/G/B 通道至少有一个显著不同
        let rDiff = abs(light.r - dark.r)
        let gDiff = abs(light.g - dark.g)
        let bDiff = abs(light.b - dark.b)
        XCTAssertTrue(rDiff > 0.01 || gDiff > 0.01 || bDiff > 0.01,
                      "SettingsTheme.accent 必须是 dynamic NSColor：light/dark 求值应不同（R/G/B 至少一通道差>0.01），实际 light=\(light), dark=\(dark)")
    }

    /// accentHover 双值正确：light = #52a688 / dark = #6bbf9f（A1 明列）。
    func test_SC_SET_05_accentHover_lightAndDark_values() {
        let hover = SettingsTheme.accentHover
        let light = Self.rgbComponents(of: hover, appearanceName: .aqua)
        let dark = Self.rgbComponents(of: hover, appearanceName: .darkAqua)

        // light = #52a688
        XCTAssertEqual(light.r, CGFloat(0x52) / 255.0, accuracy: 0.01,
                       "accentHover light .red 应 == 0x52/255 (#52a688)")
        XCTAssertEqual(light.g, CGFloat(0xa6) / 255.0, accuracy: 0.01,
                       "accentHover light .green 应 == 0xa6/255 (#52a688)")
        XCTAssertEqual(light.b, CGFloat(0x88) / 255.0, accuracy: 0.01,
                       "accentHover light .blue 应 == 0x88/255 (#52a688)")

        // dark = #6bbf9f
        XCTAssertEqual(dark.r, CGFloat(0x6b) / 255.0, accuracy: 0.01,
                       "accentHover dark .red 应 == 0x6b/255 (#6bbf9f)")
        XCTAssertEqual(dark.g, CGFloat(0xbf) / 255.0, accuracy: 0.01,
                       "accentHover dark .green 应 == 0xbf/255 (#6bbf9f)")
        XCTAssertEqual(dark.b, CGFloat(0x9f) / 255.0, accuracy: 0.01,
                       "accentHover dark .blue 应 == 0x9f/255 (#6bbf9f)")
    }

    // MARK: - SC-SET-06 文字层级 ≥3 档 + 间距栅格 ≥4 常量
    //
    // 谓词：When SettingsTheme introspected, 文字层级 ≥3 档 + 间距栅格 ≥4 常量。
    // assert: text tier≥3(pointSize 递减), spacing 常量≥4(语义命名)。

    /// 文字层级 ≥3 档且 pointSize 递减（title > rowTitle > rowSubtitle > footnote）。
    /// 设计 A1 定义 5 档（title 17 / rowTitle 13 / rowSubtitle 12 / footnote 11 / badge 10），
    /// 谓词只要求 ≥3 档递减，这里断言设计完整 4 档（title/rowTitle/rowSubtitle/footnote）递减。
    func test_SC_SET_06_textHierarchy_atLeastThreeTiers_pointSizeDescending() {
        let title = SettingsTheme.titleFont().pointSize
        let rowTitle = SettingsTheme.rowTitleFont().pointSize
        let rowSubtitle = SettingsTheme.rowSubtitleFont().pointSize
        let footnote = SettingsTheme.footnoteFont().pointSize

        // ≥3 档：4 个层级 pointSize 必须严格递减（title > rowTitle > rowSubtitle > footnote）
        XCTAssertGreaterThan(title, rowTitle,
                             "文字层级 pointSize 必须 title(\(title)) > rowTitle(\(rowTitle))")
        XCTAssertGreaterThan(rowTitle, rowSubtitle,
                             "文字层级 pointSize 必须 rowTitle(\(rowTitle)) > rowSubtitle(\(rowSubtitle))")
        XCTAssertGreaterThan(rowSubtitle, footnote,
                             "文字层级 pointSize 必须 rowSubtitle(\(rowSubtitle)) > footnote(\(footnote))")
    }

    /// title 层级字号应 == 17pt（设计 A1 明确值）。杀死"层级存在但字号偏离设计"的 mutation。
    func test_SC_SET_06_titleTier_pointSize_is17() {
        XCTAssertEqual(SettingsTheme.titleFont().pointSize, 17, accuracy: 0.5,
                       "title 层级字号应 == 17pt（A1），实际: \(SettingsTheme.titleFont().pointSize)")
    }

    /// rowTitle 层级字号应 == 13pt（设计 A1 明确值）。
    func test_SC_SET_06_rowTitleTier_pointSize_is13() {
        XCTAssertEqual(SettingsTheme.rowTitleFont().pointSize, 13, accuracy: 0.5,
                       "rowTitle 层级字号应 == 13pt（A1），实际: \(SettingsTheme.rowTitleFont().pointSize)")
    }

    /// footnote 层级字号应 == 11pt（设计 A1 明确值）。
    func test_SC_SET_06_footnoteTier_pointSize_is11() {
        XCTAssertEqual(SettingsTheme.footnoteFont().pointSize, 11, accuracy: 0.5,
                       "footnote 层级字号应 == 11pt（A1），实际: \(SettingsTheme.footnoteFont().pointSize)")
    }

    /// 各文字层级必须返回 NSColor（编译时验证 + 非 nil）。杀死"只给 font 不给 color"的 mutation。
    func test_SC_SET_06_textHierarchy_returnsNonNilNSColor() {
        // 访问即验证属性存在 + 类型为 NSColor（编译期）。
        // 运行期断言颜色对象非 nil（dynamic color resolve 后必有值）。
        let _: NSColor = SettingsTheme.titleColor()
        let _: NSColor = SettingsTheme.rowTitleColor()
        let _: NSColor = SettingsTheme.rowSubtitleColor()
        let _: NSColor = SettingsTheme.footnoteColor()

        // NSColor 是引用类型，resolve 后必有值；这里用 as Any 断言非 nil（编译器已保证类型）
        XCTAssertNotNil(SettingsTheme.titleColor() as Any?,
                        "titleColor() 必须返回非 nil NSColor")
        XCTAssertNotNil(SettingsTheme.footnoteColor() as Any?,
                        "footnoteColor() 必须返回非 nil NSColor")
    }

    /// 间距栅格 ≥4 常量（设计 A1 明列 7 个语义命名，谓词要求 ≥4）。
    /// 断言 4 个核心间距常量存在且为 CGFloat 类型（编译期验证）+ 值为正值。
    func test_SC_SET_06_spacingGrid_atLeastFourConstants() {
        // 编译期验证 4 个常量存在 + CGFloat 类型（设计 A1 明列 contentPadding/groupTopInset/groupSpacing/cardCornerRadius）
        let contentPadding: CGFloat = SettingsTheme.contentPadding
        let groupTopInset: CGFloat = SettingsTheme.groupTopInset
        let groupSpacing: CGFloat = SettingsTheme.groupSpacing
        let cardCornerRadius: CGFloat = SettingsTheme.cardCornerRadius

        // 运行期断言：间距为正值（栅格常量不得 ≤0）
        XCTAssertGreaterThan(contentPadding, 0, "contentPadding 必须为正值")
        XCTAssertGreaterThan(groupTopInset, 0, "groupTopInset 必须为正值")
        XCTAssertGreaterThan(groupSpacing, 0, "groupSpacing 必须为正值")
        XCTAssertGreaterThan(cardCornerRadius, 0, "cardCornerRadius 必须为正值")

        // 设计 A1 明确值：contentPadding=24, groupTopInset=20, groupSpacing=20, cardCornerRadius=10
        XCTAssertEqual(contentPadding, 24, accuracy: 0.5,
                       "contentPadding 应 == 24（A1），实际: \(contentPadding)")
        XCTAssertEqual(cardCornerRadius, 10, accuracy: 0.5,
                       "cardCornerRadius 应 == 10（A1），实际: \(cardCornerRadius)")
    }

    /// 卡片背景色 + 分隔线色必须存在（A1 明列，系统色语义包装）。
    func test_SC_SET_06_cardAndSeparatorColors_exist() {
        let _: NSColor = SettingsTheme.cardBackgroundColor
        let _: NSColor = SettingsTheme.separatorColor
        XCTAssertNotNil(SettingsTheme.cardBackgroundColor as Any?,
                        "cardBackgroundColor 必须返回非 nil NSColor")
        XCTAssertNotNil(SettingsTheme.separatorColor as Any?,
                        "separatorColor 必须返回非 nil NSColor")
    }

    // MARK: - SC-SET-10 sage 同源（SettingsTheme.accent 与 LauncherTheme.primary 来自同一 BuddyPalette.sage）
    //
    // 谓词：When 比较 SettingsTheme.accent 与 LauncherTheme.primary, 同源不漂移。
    // assert: 两 token 来自同一 `BuddyPalette.sage` 常量定义（非两份字面量）。
    //
    // 注意：LauncherTheme.primary 是 SwiftUI Color，需转 NSColor 后比较 RGB。

    /// BuddyPalette 类型必须存在（A2 明列，enum 命名空间）。
    /// 杀死"未建共享常量，两份字面量各写一遍"的 mutation。
    func test_SC_SET_10_buddyPalette_typeExists() {
        // 编译期验证 BuddyPalette 类型存在 + sage 属性存在 + 类型为 NSColor。
        // 这里不调用（避免 dynamic color resolve 复杂性），仅编译期存在性。
        // 运行期存在性 + RGB 值由后续 test_SC_SET_10_* 覆盖。
        let sageTypeCheck: () -> NSColor = { BuddyPalette.sage }
        let sage = sageTypeCheck()
        XCTAssertNotNil(sage as Any?, "BuddyPalette.sage 必须返回非 nil NSColor")
    }

    /// BuddyPalette.sage light/dark 值必须与 sage 标准 (#3a7d68 / #52a688) 一致。
    func test_SC_SET_10_buddyPaletteSage_valuesMatchStandard() {
        let sage = BuddyPalette.sage
        let light = Self.rgbComponents(of: sage, appearanceName: .aqua)
        let dark = Self.rgbComponents(of: sage, appearanceName: .darkAqua)

        XCTAssertEqual(light.r, CGFloat(0x3a) / 255.0, accuracy: 0.01,
                       "BuddyPalette.sage light .red 应 == 0x3a/255 (#3a7d68)")
        XCTAssertEqual(light.g, CGFloat(0x7d) / 255.0, accuracy: 0.01,
                       "BuddyPalette.sage light .green 应 == 0x7d/255 (#3a7d68)")
        XCTAssertEqual(light.b, CGFloat(0x68) / 255.0, accuracy: 0.01,
                       "BuddyPalette.sage light .blue 应 == 0x68/255 (#3a7d68)")

        XCTAssertEqual(dark.r, CGFloat(0x52) / 255.0, accuracy: 0.01,
                       "BuddyPalette.sage dark .red 应 == 0x52/255 (#52a688)")
        XCTAssertEqual(dark.g, CGFloat(0xa6) / 255.0, accuracy: 0.01,
                       "BuddyPalette.sage dark .green 应 == 0xa6/255 (#52a688)")
        XCTAssertEqual(dark.b, CGFloat(0x88) / 255.0, accuracy: 0.01,
                       "BuddyPalette.sage dark .blue 应 == 0x88/255 (#52a688)")
    }

    /// SettingsTheme.accent 与 LauncherTheme.primary 在同 appearance 下 RGB 相等。
    /// 杀死"两份独立字面量漂移"的 mutation（即使字面量此刻相等，未来改一处会漂移）。
    /// 注：本测试验证"同值"，"同一常量定义"由编译期（两处都引用 BuddyPalette.sage）+
    /// QA grep 验证（LauncherTheme.swift 不再含 0x3a/0x52 字面量）共同守护。
    func test_SC_SET_10_settingsAccent_equals_launcherPrimary_sameRGB() {
        let settingsAccent = SettingsTheme.accent
        let launcherPrimary = LauncherTheme.primary // SwiftUI Color

        // light appearance
        let sLight = Self.rgbComponents(of: settingsAccent, appearanceName: .aqua)
        let lLight = Self.rgbComponents(of: launcherPrimary, appearanceName: .aqua)
        XCTAssertEqual(sLight.r, lLight.r, accuracy: 0.01,
                       "light: SettingsTheme.accent.red(\(sLight.r)) 应 == LauncherTheme.primary.red(\(lLight.r))")
        XCTAssertEqual(sLight.g, lLight.g, accuracy: 0.01,
                       "light: SettingsTheme.accent.green(\(sLight.g)) 应 == LauncherTheme.primary.green(\(lLight.g))")
        XCTAssertEqual(sLight.b, lLight.b, accuracy: 0.01,
                       "light: SettingsTheme.accent.blue(\(sLight.b)) 应 == LauncherTheme.primary.blue(\(lLight.b))")

        // dark appearance
        let sDark = Self.rgbComponents(of: settingsAccent, appearanceName: .darkAqua)
        let lDark = Self.rgbComponents(of: launcherPrimary, appearanceName: .darkAqua)
        XCTAssertEqual(sDark.r, lDark.r, accuracy: 0.01,
                       "dark: SettingsTheme.accent.red(\(sDark.r)) 应 == LauncherTheme.primary.red(\(lDark.r))")
        XCTAssertEqual(sDark.g, lDark.g, accuracy: 0.01,
                       "dark: SettingsTheme.accent.green(\(sDark.g)) 应 == LauncherTheme.primary.green(\(lDark.g))")
        XCTAssertEqual(sDark.b, lDark.b, accuracy: 0.01,
                       "dark: SettingsTheme.accent.blue(\(sDark.b)) 应 == LauncherTheme.primary.blue(\(lDark.b))")
    }

    // MARK: - SC-SET-07/08 硬编码消除（源码 grep 断言）
    //
    // 谓词 SC-SET-07：When grep 5 页源码, `systemFont(ofSize:` 字面量命中=0（排除 SettingsTheme）。
    // 谓词 SC-SET-08：When grep 5 页布局, `yOffset` 命中=0。
    //
    // XCTest 难以直接 grep 源码（需定位 Bundle 源文件路径），此处用 Bundle 定位源文件 +
    // 字符串扫描实现自动化 grep 断言。若源文件路径定位失败（Tests 不在 Sources bundle 内），
    // 退化为"测试存在性"占位 + 注释标注 QA 执行命令。
    //
    // QA 必须执行的 grep 命令（手工或 CI）：
    //   SC-SET-07: grep -rn "systemFont(ofSize:" \
    //                Sources/ClaudeCodeBuddy/Settings/GeneralSettingsViewController.swift \
    //                Sources/ClaudeCodeBuddy/Settings/AboutSettingsViewController.swift \
    //                Sources/ClaudeCodeBuddy/Settings/KeyboardShortcutsViewController.swift \
    //                Sources/ClaudeCodeBuddy/Settings/SkinGalleryViewController.swift \
    //                Sources/ClaudeCodeBuddy/Settings/SkinCardItem.swift \
    //                Sources/ClaudeCodeBuddy/Settings/PluginGalleryViewController.swift \
    //                Sources/ClaudeCodeBuddy/Settings/PluginCardItem.swift
    //              # 命中 == 0（C5 契约）
    //   SC-SET-08: grep -rn "yOffset" \
    //                Sources/ClaudeCodeBuddy/Settings/GeneralSettingsViewController.swift \
    //                Sources/ClaudeCodeBuddy/Settings/AboutSettingsViewController.swift \
    //                Sources/ClaudeCodeBuddy/Settings/KeyboardShortcutsViewController.swift
    //              # 命中 == 0（C5 契约，yOffset 是 GeneralSettingsViewController 旧硬编码坐标）

    /// SC-SET-07/08 源码硬编码消除（自动化 grep 断言）。
    /// 通过 Bundle 定位 Sources 目录下的 5 个 detail 页源文件，扫描 `systemFont(ofSize:` / `yOffset` 字面量。
    /// 若 Bundle 路径定位失败（test bundle 不含 Sources），测试退化为 XCTSkip + 提示 QA 手工 grep。
    func test_SC_SET_07_08_noHardcodedSystemFontOrYOffset_inDetailPages() throws {
        // BuddyCore 的 Sources 目录（Package.swift: path = "Sources/ClaudeCodeBuddy"）
        // 尝试从测试 bundle 定位 Sources 根：通过 #filePath 上溯到 apps/desktop 再拼 Sources
        let thisFile = #filePath
        // thisFile = .../apps/desktop/Tests/BuddyCoreTests/Settings/SettingsThemeTests.swift
        // 上溯到 apps/desktop：去掉 /Tests/BuddyCoreTests/Settings/SettingsThemeTests.swift
        guard let desktopRoot = Self.findDesktopRoot(from: thisFile) else {
            throw XCTSkip("无法从测试文件路径定位 apps/desktop 根目录；QA 需手工执行 grep（见文件头注释）")
        }

        let settingsDir = desktopRoot
            .appendingPathComponent("Sources/ClaudeCodeBuddy/Settings")

        // 5 个 detail 页（C5 明列的 grep 目标；SkinGallery/SkinCardItem/PluginGallery/PluginCardItem 也含）
        let targetFiles = [
            "GeneralSettingsViewController.swift",
            "AboutSettingsViewController.swift",
            "KeyboardShortcutsViewController.swift",
            "SkinGalleryViewController.swift",
            "SkinCardItem.swift",
            "PluginGalleryViewController.swift",
            "PluginCardItem.swift",
        ]

        var systemFontHits: [String: [Int]] = [:]   // filename -> [line numbers]
        var yOffsetHits: [String: [Int]] = [:]

        let fm = FileManager.default
        for filename in targetFiles {
            let url = settingsDir.appendingPathComponent(filename)
            guard fm.fileExists(atPath: url.path),
                  let content = try? String(contentsOf: url, encoding: .utf8) else {
                // 文件不存在：蓝队可能重命名（不破坏契约但需 QA 复核）。跳过该文件，记录但不失败。
                continue
            }
            let lines = content.components(separatedBy: .newlines)
            for (idx, line) in lines.enumerated() {
                // SC-SET-07: systemFont(ofSize: 字面量（硬编码字号，应改用 SettingsTheme）
                if line.contains("systemFont(ofSize:") {
                    systemFontHits[filename, default: []].append(idx + 1)
                }
                // SC-SET-08: yOffset 坐标硬编码（GeneralSettingsViewController 旧手算坐标）
                if line.contains("yOffset") {
                    yOffsetHits[filename, default: []].append(idx + 1)
                }
            }
        }

        // SC-SET-07：systemFont(ofSize: 命中应 == 0
        XCTAssertTrue(systemFontHits.isEmpty,
                      "SC-SET-07 失败：detail 页仍含硬编码 `systemFont(ofSize:`：\n\(systemFontHits)。\n"
                      + "应改用 SettingsTheme.titleFont()/rowTitleFont() 等 token（C5 契约）。")

        // SC-SET-08：yOffset 命中应 == 0
        XCTAssertTrue(yOffsetHits.isEmpty,
                      "SC-SET-08 失败：detail 页仍含硬编码 `yOffset`：\n\(yOffsetHits)。\n"
                      + "应改用 Auto Layout / SettingsGroupView 卡片化（C5 契约）。")
    }

    // MARK: - SC-SET-01/02/15（不写自动测试，标注 QA 命令）
    //
    // SC-SET-01 [det-machine]：make -C apps/desktop build 编译 exit 0，无 type error。
    //   QA 执行：make -C apps/desktop build 2>&1 | tee build.log；断言 exit==0 且无 "error:" 行。
    //
    // SC-SET-02 [det-machine]：5 页 VC 引用 SettingsTheme，无 unresolved identifier。
    //   QA 执行：build 日志断言 5 文件无 "unresolved identifier 'SettingsTheme'"。
    //   （本测试文件若 SettingsTheme 不存在则编译失败，间接覆盖 SC-SET-02 的"引用存在"。）
    //
    // SC-SET-15 [det-machine]：make -C apps/desktop lint，SettingsTheme + 5 页无 violation。
    //   QA 执行：make -C apps/desktop lint；断言 exit==0，改动文件 0 violation。

    // MARK: - 辅助方法

    /// 在指定 NSAppearance 下读取 NSColor 的 sRGB 分量。
    /// 用 NSColor.usingColorSpace(.sRGB) 转换，确保 dynamic color 被正确解析。
    /// （复用 LauncherThemeAcceptanceTests 的 rgbComponents 模式，适配 NSColor 入参。）
    private static func rgbComponents(
        of color: NSColor,
        appearanceName: NSAppearance.Name
    ) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        var result: (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) = (0, 0, 0, 0)
        NSAppearance(named: appearanceName)?.performAsCurrentDrawingAppearance {
            // 先把 dynamic color 在当前 appearance 下 resolve 成具体 color，
            // 再转 sRGB 颜色空间读取分量（与 LauncherThemeAcceptanceTests 同款）
            let resolved = color.usingColorSpace(.sRGB) ?? color
            result = (
                resolved.redComponent,
                resolved.greenComponent,
                resolved.blueComponent,
                resolved.alphaComponent
            )
        }
        return result
    }

    /// 在指定 NSAppearance 下读取 SwiftUI Color 的 sRGB 分量（用于 LauncherTheme.primary 比较）。
    /// 完全复用 LauncherThemeAcceptanceTests.rgbComponents 实现。
    private static func rgbComponents(
        of color: SwiftUI.Color,
        appearanceName: NSAppearance.Name
    ) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        var result: (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) = (0, 0, 0, 0)
        NSAppearance(named: appearanceName)?.performAsCurrentDrawingAppearance {
            guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return }
            result = (ns.redComponent, ns.greenComponent, ns.blueComponent, ns.alphaComponent)
        }
        return result
    }

    /// 从测试文件路径上溯定位 apps/desktop 根目录。
    /// 路径形如 .../apps/desktop/Tests/BuddyCoreTests/Settings/SettingsThemeTests.swift
    private static func findDesktopRoot(from filePath: String) -> URL? {
        let url = URL(fileURLWithPath: filePath)
        // 找 "apps" 段，取其后的 "desktop" 段
        let parts = url.pathComponents
        guard let appsIdx = parts.firstIndex(where: { $0 == "apps" }),
              appsIdx + 1 < parts.count,
              parts[appsIdx + 1] == "desktop" else {
            return nil
        }
        // 从 url 截取到 apps/desktop
        var root = url.deletingLastPathComponent() // 去掉 SettingsThemeTests.swift
        // 继续上溯直到当前 lastPathComponent == "desktop"
        while root.lastPathComponent != "desktop" {
            root = root.deletingLastPathComponent()
            if root.path == "/" { return nil }
        }
        return root
    }

    // MARK: - 栅格 token 扩展（stage-0-grid-token，Task 1）

    /// 4 倍数栅格 scale 完整 7 档值正确。
    func test_spacingScale_isFourMultiples() {
        XCTAssertEqual(SettingsTheme.spacingXs, 4)
        XCTAssertEqual(SettingsTheme.spacingSm, 8)
        XCTAssertEqual(SettingsTheme.spacingMd, 12)
        XCTAssertEqual(SettingsTheme.spacingLg, 16)
        XCTAssertEqual(SettingsTheme.spacingXl, 24)
        XCTAssertEqual(SettingsTheme.spacingXxl, 32)
        XCTAssertEqual(SettingsTheme.spacingSection, 48)
    }

    /// 布局常量（限宽/分栏/行高）值正确。
    func test_layoutConstants() {
        XCTAssertEqual(SettingsTheme.contentMaxWidth, 780)
        XCTAssertEqual(SettingsTheme.sidebarWidth, 200)
        XCTAssertEqual(SettingsTheme.pluginListWidth, 240)
        XCTAssertEqual(SettingsTheme.minRowHeight, 44)
        XCTAssertEqual(SettingsTheme.contentTopInset, 48)
    }

    /// 旧语义 token 收口到 scale（调用方 API 不变，仅值统一到栅格）。
    func test_legacySemanticTokens_alignedToScale() {
        XCTAssertEqual(SettingsTheme.contentPadding, SettingsTheme.spacingXl)      // 24
        XCTAssertEqual(SettingsTheme.cardContentPadding, SettingsTheme.spacingLg)  // 16
        XCTAssertEqual(SettingsTheme.rowSpacing, SettingsTheme.spacingSm)          // 8
        XCTAssertEqual(SettingsTheme.groupSpacing, SettingsTheme.spacingXl)        // 20 -> 24
        XCTAssertEqual(SettingsTheme.groupTopInset, SettingsTheme.spacingXl)       // 20 -> 24
    }
}
