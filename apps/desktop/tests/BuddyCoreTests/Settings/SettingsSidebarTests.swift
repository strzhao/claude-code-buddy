import XCTest
import AppKit
@testable import BuddyCore

// MARK: - 蓝队单元测试：SettingsSection 枚举 + SettingsSidebarViewController 数据驱动
//
// 覆盖可自动化验证的契约：
//   - 契约 3：6 项顺序 [皮肤/插件/热键/AI 配置/通用/关于]
//   - 契约 2：allCases 单一数据源
//   - 契约 4：持久化 key `SettingsSelectedCategory` + 默认 .skins
//   - 契约 7：AX identifier 命名
//
// SC-01..SC-14 完整验收测试归红队（SettingsSidebarAcceptanceTests），
// 本文件只锁编译期可验证的不变量。

@MainActor
final class SettingsSidebarTests: XCTestCase {

    // MARK: - SettingsSection 枚举契约（契约 3）

    func test_section_allCases_count_is6() {
        XCTAssertEqual(SettingsSection.allCases.count, 6,
                       "sidebar 分类必须恰好 6 项（含 AI 配置）")
    }

    func test_section_order_is_skins_plugins_hotkey_ai_general_about() {
        let rawValues = SettingsSection.allCases.map { $0.rawValue }
        XCTAssertEqual(rawValues, ["skins", "plugins", "hotkey", "ai", "general", "about"],
                       "sidebar 顺序必须为 [皮肤/插件/热键/AI 配置/通用/关于]")
    }

    func test_section_displayTitles_match_order() {
        let titles = SettingsSection.allCases.map { $0.displayTitle }
        XCTAssertEqual(titles, ["皮肤", "插件", "热键", "AI 配置", "通用", "关于"],
                       "displayTitle 必须与 rawValue 顺序一致，中文展示名")
    }

    func test_section_rawValue_roundTrip() {
        for section in SettingsSection.allCases {
            XCTAssertEqual(SettingsSection(rawValue: section.rawValue), section,
                           "rawValue 必须可往返")
        }
        XCTAssertEqual(SettingsSection(rawValue: "ai"), .ai,
                     "AI 配置 rawValue 'ai' 必须可往返")
    }

    // MARK: - 持久化 key 契约（契约 4）

    func test_selectedCategoryDefaultsKey_isSettingsSelectedCategory() {
        XCTAssertEqual(SettingsWindowController.selectedCategoryDefaultsKey,
                       "SettingsSelectedCategory",
                       "持久化 key 必须为 'SettingsSelectedCategory'（旧 BuddyStoreSelectedTab 废弃）")
    }

    // MARK: - Sidebar 数据驱动（契约 2 + SC-12）

    func test_sidebar_numberOfRows_equals_allCases_count() {
        let sidebar = SettingsSidebarViewController()
        // force loadView（NSTableView dataSource 需要 tableView 已就绪）
        _ = sidebar.view
        let tableView = sidebar.testHook_tableView
        XCTAssertEqual(tableView.numberOfRows, SettingsSection.allCases.count,
                       "sidebar numberOfRows 必须等于 SettingsSection.allCases.count（数据驱动）")
    }

    func test_sidebar_cellView_titles_match_allCases() {
        let sidebar = SettingsSidebarViewController()
        _ = sidebar.view
        let tableView = sidebar.testHook_tableView
        let titles = (0..<tableView.numberOfRows).compactMap { row -> String? in
            guard tableView.numberOfColumns > 0 else { return nil }
            let view = tableView.view(atColumn: 0, row: row, makeIfNecessary: true)
            return (view as? NSTableCellView)?.textField?.stringValue
        }
        XCTAssertEqual(titles, SettingsSection.allCases.map { $0.displayTitle },
                       "sidebar cell 标题必须从 allCases 数据驱动渲染")
    }

    // MARK: - AX identifier 命名（契约 7）

    func test_sidebar_cellView_accessibilityIdentifier() {
        let sidebar = SettingsSidebarViewController()
        _ = sidebar.view
        let tableView = sidebar.testHook_tableView
        for (row, section) in SettingsSection.allCases.enumerated() {
            guard tableView.numberOfColumns > 0 else {
                return XCTFail("tableView 无 column")
            }
            let view = tableView.view(atColumn: 0, row: row, makeIfNecessary: true)
            let identifier = view?.accessibilityIdentifier()
            XCTAssertEqual(identifier, "settings.sidebar.\(section.rawValue)",
                           "sidebar item AX identifier 必须为 'settings.sidebar.\(section.rawValue)'")
        }
    }
}
