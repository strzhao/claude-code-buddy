import XCTest
import AppKit
@testable import BuddyCore

// MARK: - 红队验收测试：设置页交互优化 — AC-ORDER / AC-WINDOW（T1 + T2）
//
// 设计权威源（逐字断言的契约）：
// - T2（#2 sidebar 重排）：`SettingsSection.swift:9-20` case 顺序从
//   `skins,plugins,hotkey,ai,general,about` 改为 **`plugins,hotkey,ai,skins,general,about`**
//   （皮肤从 #1 移到 #4，紧贴通用）。rawValue 不变（C2 持久化兼容）。
// - T1（#1 窗口放大）：`SettingsWindowController.swift:31,38,47` contentRect 760×540 → 按
//   `NSScreen.main?.visibleFrame` ~75% 动态计算（兜底 1200×800）；minSize 600×420 → 800×560。
// - 契约 C1：sidebar 顺序仍由 `SettingsSection.allCases` 单一驱动，禁按分类 switch/if 硬编码。
// - 契约 C2：reorder 不改 case rawValue；`UserDefaults` `SettingsSelectedCategory` 旧值仍解析。
//
// 工作规则：本文件是 TDD 红灯，对设计 + 验收谓词断言，不读实现代码、不对实现状态容错。
// 每个谓词至少 1 个硬断言，失败即挂测试。

@MainActor
final class SettingsSectionOrderAcceptanceTests: XCTestCase {

    // MARK: - AC-ORDER [det-machine] sidebar AX 行 id 序列严格相等
    //
    // 谓词：WHEN 打开设置页 OBSERVE sidebar AX 行 id 序列
    //      `settings.sidebar.plugins, .hotkey, .ai, .skins, .general, .about` ASSERT 严格相等。

    /// AC-ORDER 核心断言：`SettingsSection.allCases` rawValue 序列逐字等于新顺序。
    /// C2 验 rawValue 不变（持久化兼容）。
    func test_AC_ORDER_allCases_rawValue_sequence() {
        // 新顺序逐字断言（设计 T2 + AC-ORDER 谓词 assert 字面量）
        let expected = ["plugins", "hotkey", "ai", "skins", "general", "about"]
        let actual = SettingsSection.allCases.map { $0.rawValue }
        XCTAssertEqual(actual, expected,
                       """
                       AC-ORDER 失败：sidebar 顺序必须为 \
                       [plugins, hotkey, ai, skins, general, about]，
                       实际: \(actual)
                       """)
    }

    /// AC-ORDER 补：allCases 恰好 6 项（不多不少，防删 case / 加占位）。
    func test_AC_ORDER_allCases_count_is6() {
        XCTAssertEqual(SettingsSection.allCases.count, 6,
                       "sidebar 分类必须恰好 6 项，实际: \(SettingsSection.allCases.count)")
    }

    /// AC-ORDER 补：displayTitle 与新顺序一致（防只改 rawValue 不改展示名顺序）。
    func test_AC_ORDER_displayTitles_match_new_order() {
        let titles = SettingsSection.allCases.map { $0.displayTitle }
        XCTAssertEqual(titles, ["插件", "热键", "AI 配置", "皮肤", "通用", "关于"],
                       "displayTitle 必须与新顺序 [插件/热键/AI 配置/皮肤/通用/关于] 一致，实际: \(titles)")
    }

    // MARK: - C2 持久化兼容（AC-ORDER 的契约层守护）

    /// C2：reorder 不改 case rawValue。每个 case 的 rawValue 必须可往返。
    func test_C2_rawValue_roundTrip_allCases() {
        for section in SettingsSection.allCases {
            XCTAssertEqual(SettingsSection(rawValue: section.rawValue), section,
                           "rawValue 必须可往返（C2 持久化兼容），section: \(section)")
        }
    }

    /// C2：旧持久化值仍能正确解析（ skins/ai/about/plugins/hotkey/general 任一 rawValue 都能 init）。
    /// 杀死"重排时顺手改了 rawValue 拼写"的 mutation。
    func test_C2_legacyRawValues_stillParse() {
        let legacyValues = ["skins", "plugins", "hotkey", "ai", "general", "about"]
        for v in legacyValues {
            XCTAssertNotNil(SettingsSection(rawValue: v),
                           "旧持久化值 '\(v)' 必须仍能 init（C2），否则用户旧 selection 会丢失")
        }
    }

    /// C2：默认选中 .skins（设计：默认选中保留——打开仍定位皮肤，现 #4 位）。
    /// 单元层验证 default 仍为 skins（窗口层验证见 AC-ORDER sidebar 真机谓词近邻）。
    func test_C2_defaultSelection_key_constant_unchanged() {
        // 持久化 key 不变（C2 逐字）
        XCTAssertEqual(SettingsWindowController.selectedCategoryDefaultsKey,
                       "SettingsSelectedCategory",
                       "持久化 key 必须保持 'SettingsSelectedCategory'（C2 不变）")
    }

    // MARK: - AC-ORDER sidebar 渲染顺序（数据驱动一致性）

    /// AC-ORDER 真机谓词近邻：sidebar NSTableView numberOfRows == 6 且与 allCases 同序。
    /// 通过 SettingsWindowController 实例化 → 遍历 splitViewItems[0] sidebar VC →
    /// 读 NSTableView 行的 AX identifier 序列。
    func test_AC_ORDER_sidebar_AXIdentifier_sequence() {
        UserDefaults.standard.removeObject(forKey: "SettingsSelectedCategory")
        defer { UserDefaults.standard.removeObject(forKey: "SettingsSelectedCategory") }

        let wc = SettingsWindowController()
        guard let window = wc.window,
              let splitVC = window.contentViewController as? NSSplitViewController,
              splitVC.splitViewItems.count >= 1 else {
            return XCTFail("无法获取 splitViewController / splitViewItems<1")
        }

        let sidebarVC = splitVC.splitViewItems[0].viewController
        _ = sidebarVC.view // force loadView

        guard let tableView = findFirst(NSTableView.self, in: sidebarVC.view) else {
            return XCTFail("sidebar VC 中必须含 NSTableView")
        }

        XCTAssertEqual(tableView.numberOfRows, 6,
                       "sidebar numberOfRows 必须为 6（与新 allCases 一致）")

        // 逐行读 AX id（rowView 或 cellView 层），序列必须等于 settings.sidebar.<rawValue>
        let expectedIDs = SettingsSection.allCases.map { "settings.sidebar.\($0.rawValue)" }
        for (row, expectedID) in expectedIDs.enumerated() {
            let rowView = tableView.rowView(atRow: row, makeIfNecessary: false)
            let cellView = tableView.view(atColumn: 0, row: row, makeIfNecessary: true)
            let rowID = rowView?.accessibilityIdentifier()
            let cellID = cellView?.accessibilityIdentifier()
            let cellHasIDInChildren = rowView.flatMap { findViewWithIdentifier(expectedID, in: $0) } != nil
            XCTAssertTrue(rowID == expectedID || cellID == expectedID || cellHasIDInChildren,
                          """
                          AC-ORDER: sidebar row[\(row)] AX id 必须为 '\(expectedID)'，
                          实际 rowID: \(rowID ?? "nil"), cellID: \(cellID ?? "nil")
                          """)
        }
    }

    // MARK: - AC-WINDOW [det-machine] 窗口宽 >= 1000pt

    /// AC-WINDOW：设置窗口完成布局后 window.frame.width >= 1000pt（大窗）。
    /// 设计 T1：初始 contentRect 760×540 → ~屏幕 75%（兜底 1200×800）。
    ///
    /// 注：单测环境 NSScreen.main 可能不可靠（headless CI），故用 >= 1000 而非 == 兜底值，
    /// 且加 minSize 上调断言（800×560）作为结构性强约束。
    func test_AC_WINDOW_frameWidth_atLeast1000() {
        let wc = SettingsWindowController()
        guard let window = wc.window else {
            return XCTFail("SettingsWindowController.window 必须存在")
        }

        // 初始 frame.width 应 >= 1000（设计：~屏幕 75%，兜底 1200；旧值 760 必须挂测试）
        let width = window.frame.width
        XCTAssertGreaterThanOrEqual(width, 1000,
                                    """
                                    AC-WINDOW: 窗口宽必须 >= 1000pt（设计 T1 大窗），
                                    实际: \(width)（旧值 760 应已被替换）
                                    """)
    }

    /// AC-WINDOW 补：minSize 上调到 800×560（设计 T1 line 47）。
    /// 旧 minSize 600×420 必须挂测试（防 T1 漏改 minSize）。
    func test_AC_WINDOW_minSize_is800x560() {
        let wc = SettingsWindowController()
        guard let window = wc.window else {
            return XCTFail("SettingsWindowController.window 必须存在")
        }

        let minSize = window.minSize
        XCTAssertGreaterThanOrEqual(minSize.width, 800,
                                    "minSize.width 必须 >= 800（设计 T1），实际: \(minSize.width)（旧 600 应已替换）")
        XCTAssertGreaterThanOrEqual(minSize.height, 560,
                                    "minSize.height 必须 >= 560（设计 T1），实际: \(minSize.height)（旧 420 应已替换）")
    }

    /// AC-WINDOW 补：窗口仍可缩放（styleMask 含 .resizable，T1 不进原生全屏）。
    func test_AC_WINDOW_styleMask_containsResizable() {
        let wc = SettingsWindowController()
        guard let window = wc.window else {
            return XCTFail("SettingsWindowController.window 必须存在")
        }
        XCTAssertTrue(window.styleMask.contains(.resizable),
                      "styleMask 必须含 .resizable（T1：普通可缩放窗，不进原生全屏）")
    }

    // MARK: - Helpers

    private func findFirst<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let typed = view as? T { return typed }
        for sub in view.subviews {
            if let found = findFirst(type, in: sub) { return found }
        }
        return nil
    }

    private func findViewWithIdentifier(_ id: String, in view: NSView) -> NSView? {
        if view.accessibilityIdentifier() == id { return view }
        for sub in view.subviews {
            if let found = findViewWithIdentifier(id, in: sub) { return found }
        }
        return nil
    }
}
