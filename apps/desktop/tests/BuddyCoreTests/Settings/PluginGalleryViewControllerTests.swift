import XCTest
import AppKit
@testable import BuddyCore

// MARK: - Mocks

final class MockMarketplaceInspecting: MarketplaceInspecting {
    var inspectResult: Result<MarketplaceInspection, Error> = .success(
        MarketplaceInspection(
            plugins: [],
            sideloadedPlugins: [],
            lastSyncedAt: nil,
            consecutiveSyncFailures: 0
        )
    )
    var reseedError: Error?
    private(set) var inspectCallCount = 0
    private(set) var reseedCallCount = 0

    func inspect() throws -> MarketplaceInspection {
        inspectCallCount += 1
        return try inspectResult.get()
    }

    func reseed() async throws {
        reseedCallCount += 1
        if let reseedError {
            throw reseedError
        }
    }
}

final class MockPluginToggling: PluginToggling {
    private(set) var disableCalls: [String] = []
    private(set) var enableCalls: [String] = []
    var disableError: Error?
    var enableError: Error?

    func disable(name: String) throws {
        disableCalls.append(name)
        if let disableError {
            throw disableError
        }
    }

    func enable(name: String) throws {
        enableCalls.append(name)
        if let enableError {
            throw enableError
        }
    }
}

// MARK: - Tests

@MainActor
final class PluginGalleryViewControllerTests: XCTestCase {

    private func makeInspection(
        plugins: [MarketplaceInspection.PluginInspection] = [],
        sideloaded: [MarketplaceInspection.SideloadedInspection] = []
    ) -> MarketplaceInspection {
        MarketplaceInspection(
            plugins: plugins,
            sideloadedPlugins: sideloaded,
            lastSyncedAt: nil,
            consecutiveSyncFailures: 0
        )
    }

    // T1: init 默认 state == .loading
    func test_initialState_isLoading() {
        let vc = PluginGalleryViewController(
            marketplace: MockMarketplaceInspecting(),
            plugins: MockPluginToggling()
        )
        XCTAssertEqual(vc.state, .loading)
    }

    // T2: refresh 成功 + 非空 → .normal
    func test_refresh_withPlugins_setsNormal() async {
        let mock = MockMarketplaceInspecting()
        mock.inspectResult = .success(makeInspection(plugins: [
            .init(name: "translate", version: "0.1.0", enabled: true, source: "local-subdir: plugins/translate")
        ]))
        let vc = PluginGalleryViewController(marketplace: mock, plugins: MockPluginToggling(), builtinRegistry: BuiltinPluginRegistry(plugins: []))
        _ = vc.view
        await vc.refresh()

        guard case .normal(let entries) = vc.state else {
            XCTFail("expected .normal, got \(vc.state)")
            return
        }
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].name, "translate")
        XCTAssertEqual(entries[0].version, "0.1.0")
        XCTAssertFalse(entries[0].isSideloaded)
        XCTAssertTrue(entries[0].enabled)
        XCTAssertEqual(mock.inspectCallCount, 1)
    }

    // T3: refresh 返回空 plugins + 空 sideloaded → .empty
    func test_refresh_withEmpty_setsEmpty() async {
        let mock = MockMarketplaceInspecting()
        mock.inspectResult = .success(makeInspection())
        let vc = PluginGalleryViewController(marketplace: mock, plugins: MockPluginToggling(), builtinRegistry: BuiltinPluginRegistry(plugins: []))
        _ = vc.view
        await vc.refresh()
        XCTAssertEqual(vc.state, .empty)
    }

    // T4: refresh 抛错 → .error
    func test_refresh_whenInspectThrows_setsError() async {
        struct BoomError: LocalizedError {
            var errorDescription: String? { "boom" }
        }
        let mock = MockMarketplaceInspecting()
        mock.inspectResult = .failure(BoomError())
        let vc = PluginGalleryViewController(marketplace: mock, plugins: MockPluginToggling(), builtinRegistry: BuiltinPluginRegistry(plugins: []))
        _ = vc.view
        await vc.refresh()

        guard case .error(let msg) = vc.state else {
            XCTFail("expected .error, got \(vc.state)")
            return
        }
        XCTAssertTrue(msg.contains("boom"), "msg should contain 'boom', got: \(msg)")
    }

    // T5: sideloaded entry 渲染（B1 修复）
    func test_refresh_includesSideloaded() async {
        let mock = MockMarketplaceInspecting()
        mock.inspectResult = .success(makeInspection(
            sideloaded: [.init(name: "weather", enabled: true)]
        ))
        let vc = PluginGalleryViewController(marketplace: mock, plugins: MockPluginToggling(), builtinRegistry: BuiltinPluginRegistry(plugins: []))
        _ = vc.view
        await vc.refresh()

        guard case .normal(let entries) = vc.state else {
            XCTFail("expected .normal, got \(vc.state)")
            return
        }
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].name, "weather")
        XCTAssertTrue(entries[0].isSideloaded)
        XCTAssertEqual(entries[0].version, "—")
    }

    // T6: toggleButtonClicked tag=0 → disable
    func test_toggleButtonClicked_tagZero_callsDisable() async {
        let plugins = MockPluginToggling()
        let mock = MockMarketplaceInspecting()
        mock.inspectResult = .success(makeInspection())
        let vc = PluginGalleryViewController(marketplace: mock, plugins: plugins)
        _ = vc.view

        let button = NSButton(title: "禁用", target: nil, action: nil)
        button.identifier = NSUserInterfaceItemIdentifier("translate")
        button.tag = 0
        vc.toggleButtonClicked(button)

        // 等待 Task @MainActor 完成
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(plugins.disableCalls, ["translate"])
        XCTAssertEqual(plugins.enableCalls, [])
    }

    // T7: toggleButtonClicked tag=1 → enable
    func test_toggleButtonClicked_tagOne_callsEnable() async {
        let plugins = MockPluginToggling()
        let mock = MockMarketplaceInspecting()
        mock.inspectResult = .success(makeInspection())
        let vc = PluginGalleryViewController(marketplace: mock, plugins: plugins)
        _ = vc.view

        let button = NSButton(title: "启用", target: nil, action: nil)
        button.identifier = NSUserInterfaceItemIdentifier("translate")
        button.tag = 1
        vc.toggleButtonClicked(button)

        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(plugins.enableCalls, ["translate"])
        XCTAssertEqual(plugins.disableCalls, [])
    }

    // T8: sanitize 白名单 — 非法 name 静默 ignore（NOT 调 disable/enable）
    func test_toggleButtonClicked_invalidName_skipsCall() async {
        let plugins = MockPluginToggling()
        let vc = PluginGalleryViewController(
            marketplace: MockMarketplaceInspecting(),
            plugins: plugins
        )
        _ = vc.view

        for invalidName in ["../etc/passwd", "Foo Bar", "UPPER", "with/slash", ""] {
            let button = NSButton(title: "禁用", target: nil, action: nil)
            button.identifier = NSUserInterfaceItemIdentifier(invalidName)
            button.tag = 0
            vc.toggleButtonClicked(button)
        }

        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(plugins.disableCalls, [], "非法 name 不应触发 disable")
        XCTAssertEqual(plugins.enableCalls, [])
    }

    // T9: handleReseedButton 调 marketplace.reseed
    func test_handleReseedButton_callsReseed() async {
        let mock = MockMarketplaceInspecting()
        mock.inspectResult = .success(makeInspection())
        let vc = PluginGalleryViewController(marketplace: mock, plugins: MockPluginToggling(), builtinRegistry: BuiltinPluginRegistry(plugins: []))
        _ = vc.view
        vc.handleReseedButton()

        await Task.yield()
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertGreaterThanOrEqual(mock.reseedCallCount, 1)
    }
}

// MARK: - 契约演进说明（T6）
//
// 历史版本（task 005）：SettingsWindowController 用 segmentedControl 三 tab，
// 枚举 `SettingsWindowController.Tab`（skins/plugins/hotkey），持久化 key
// `BuddyStoreSelectedTab`。
//
// 2026-06-23 sidebar 重构（state.md）：窗口改 NSSplitViewController + sidebar，
// 5 分类（皮肤/插件/热键/通用/关于），枚举迁移到 `SettingsSection`（单一数据源），
// 持久化 key 改 `SettingsSelectedCategory`，默认 .skins。
// 旧 Tab 枚举 + BuddyStoreSelectedTab key 废弃（不迁移，读不到→默认 skins）。
//
// 本测试类从"Tab 枚举 rawValue + 旧 key 名"断言演进为
// "SettingsSection.allCases + 新 key 名"断言。
// PluginGalleryViewController 内部逻辑测试（上方 T1-T9）保留零改动。
final class SettingsWindowControllerTabPersistenceTests: XCTestCase {

    override func tearDown() {
        UserDefaults.standard.removeObject(
            forKey: SettingsWindowController.selectedCategoryDefaultsKey)
        super.tearDown()
    }

    func test_sectionEnum_rawValues() {
        XCTAssertEqual(SettingsSection.skins.rawValue, "skins")
        XCTAssertEqual(SettingsSection.plugins.rawValue, "plugins")
        XCTAssertEqual(SettingsSection(rawValue: "plugins"), .plugins)
        XCTAssertEqual(SettingsSection(rawValue: "skins"), .skins)
        XCTAssertNil(SettingsSection(rawValue: "nope"))
    }

    func test_defaultsKey_isExpected() {
        XCTAssertEqual(SettingsWindowController.selectedCategoryDefaultsKey,
                       "SettingsSelectedCategory")
    }
}

