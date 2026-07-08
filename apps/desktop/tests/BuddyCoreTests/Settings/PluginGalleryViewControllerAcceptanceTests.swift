import XCTest
import AppKit
@testable import BuddyCore

// MARK: - Mock dependencies (红队独立实现，不复用蓝队 mock)

/// 模拟 MarketplaceInspecting。
/// - `inspectResult`: 强制 inspect 返回值
/// - `inspectError`: 若非 nil，inspect 抛出此错误
/// - `reseedError`: 若非 nil，reseed 抛出此错误
private final class RedMockMarketplaceInspecting: MarketplaceInspecting {
    var inspectResult: MarketplaceInspection
    var inspectError: Error?
    var reseedError: Error?
    private(set) var inspectCallCount = 0
    private(set) var reseedCallCount = 0

    init(inspectResult: MarketplaceInspection = .empty,
         inspectError: Error? = nil,
         reseedError: Error? = nil) {
        self.inspectResult = inspectResult
        self.inspectError = inspectError
        self.reseedError = reseedError
    }

    func inspect() throws -> MarketplaceInspection {
        inspectCallCount += 1
        if let err = inspectError { throw err }
        return inspectResult
    }

    func reseed() async throws {
        reseedCallCount += 1
        if let err = reseedError { throw err }
    }
}

/// 模拟 PluginToggling。记录 disable/enable 调用名。
private final class RedMockPluginToggling: PluginToggling {
    private(set) var disabledNames: [String] = []
    private(set) var enabledNames: [String] = []
    var disableError: Error?
    var enableError: Error?

    func disable(name: String) throws {
        disabledNames.append(name)
        if let err = disableError { throw err }
    }

    func enable(name: String) throws {
        enabledNames.append(name)
        if let err = enableError { throw err }
    }
}

private extension MarketplaceInspection {
    static let empty = MarketplaceInspection(
        plugins: [],
        sideloadedPlugins: [],
        lastSyncedAt: nil,
        consecutiveSyncFailures: 0
    )

    static func withPlugin(name: String, version: String = "0.1.0", enabled: Bool = true) -> MarketplaceInspection {
        MarketplaceInspection(
            plugins: [
                .init(name: name, version: version, enabled: enabled, source: "test")
            ],
            sideloadedPlugins: [],
            lastSyncedAt: nil,
            consecutiveSyncFailures: 0
        )
    }

    static func withSideloaded(name: String, enabled: Bool = true) -> MarketplaceInspection {
        MarketplaceInspection(
            plugins: [],
            sideloadedPlugins: [
                .init(name: name, enabled: enabled)
            ],
            lastSyncedAt: nil,
            consecutiveSyncFailures: 0
        )
    }
}

/// 红队验收测试: Buddy Store UI — SettingsWindowController + PluginGalleryViewController
///
/// 覆盖 13 个 AT（与 state.md `## 验证方案` Tier 0 一致）。
/// 严格基于设计文档契约，不依赖蓝队具体实现细节。
///
/// **契约演进（2026-06-23 sidebar 重构）**：
/// AT01/AT02/AT03/AT04 从 segmentedControl/"Buddy Store" 旧契约演进为
/// NSSplitViewController sidebar 新契约：
///   - AT01: title 从 "Buddy Store" 改 "设置"（state.md 方案决策）
///   - AT02/AT04: contentVC 不再是 SkinGallery/PluginGallery（现在是 SettingsSplitViewController），
///     改为断言 splitViewController.detailViewController 的 child VC 类型
///   - AT03: 持久化 key 从 BuddyStoreSelectedTab 改 SettingsSelectedCategory（契约 4）
/// AT05-AT13（PluginGallery 内部逻辑）零改动。
@MainActor
final class PluginGalleryViewControllerAcceptanceTests: XCTestCase {

    private var defaultsKey: String!

    override func setUp() {
        super.setUp()
        // sidebar 重构后持久化 key（契约 4）
        defaultsKey = SettingsWindowController.selectedCategoryDefaultsKey
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        super.tearDown()
    }

    // MARK: - Helpers

    /// 等待 main actor 上的 Task 串行执行完毕（让 viewDidAppear 内的 Task 完成）。
    private func drainMainActor() async {
        // 让出当前 actor 一次，让排队的 @MainActor Task 执行
        await Task.yield()
        await Task.yield()
        await Task.yield()
    }

    /// 强制 view 加载（loadView 执行）。
    private func forceLoadView(_ vc: NSViewController) {
        _ = vc.view
    }

    /// 模拟 viewDidAppear 触发，并等 refresh 完成。
    private func triggerAppearAndDrain(_ vc: NSViewController) async {
        vc.viewDidAppear()
        await drainMainActor()
        await drainMainActor()
    }

    // MARK: - AT01: SettingsWindowController title == "设置"（契约演进：旧 "Buddy Store"）

    func test_AT01_settingsWindow_title_isSettings() {
        let wc = SettingsWindowController()
        XCTAssertEqual(wc.window?.title, "设置",
                       "SettingsWindowController.window.title 必须为 '设置'")
    }

    // MARK: - AT02: UserDefaults 为空 → 默认选中 skins（detail child = SkinGalleryViewController）

    func test_AT02_userDefaultsEmpty_defaultsToSkinsSection() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        let wc = SettingsWindowController()
        guard let splitVC = wc.splitViewController else {
            return XCTFail("splitViewController 必须存在")
        }
        XCTAssertEqual(splitVC.selectedSection, .skins,
                       "UserDefaults 为空时，默认选中 skins 分类")
        XCTAssertTrue(splitVC.detailChildViewController is SkinGalleryViewController,
                      "默认选中 skins 时，detail child 应为 SkinGalleryViewController")
    }

    // MARK: - AT03: 切到 plugins → UserDefaults 写入 "plugins"（契约 4，新 key）

    func test_AT03_switchToPlugins_writesUserDefaults() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        let wc = SettingsWindowController()
        guard let splitVC = wc.splitViewController else {
            return XCTFail("splitViewController 必须存在")
        }
        // 通过 splitVC testHook 驱动 sidebar 选中 plugins
        splitVC.testHook_selectSection(.plugins)

        let stored = UserDefaults.standard.string(forKey: defaultsKey)
        XCTAssertEqual(stored, "plugins",
                       "切到 plugins 后 UserDefaults['\(defaultsKey)'] 应为 'plugins'")
        XCTAssertTrue(splitVC.detailChildViewController is PluginGalleryViewController,
                      "选中 plugins 后 detail child 应为 PluginGalleryViewController")
    }

    // MARK: - AT04: UserDefaults 预设 "plugins" → init 后选中 plugins + detail child 正确

    func test_AT04_userDefaultsPlugins_initSelectsPluginsSection() {
        UserDefaults.standard.set("plugins", forKey: defaultsKey)
        let wc = SettingsWindowController()
        guard let splitVC = wc.splitViewController else {
            return XCTFail("splitViewController 必须存在")
        }
        XCTAssertEqual(splitVC.selectedSection, .plugins,
                       "预设 'plugins' 时，init 后选中应为 plugins")
        XCTAssertTrue(splitVC.detailChildViewController is PluginGalleryViewController,
                      "预设 'plugins' 时，init 后 detail child 应为 PluginGalleryViewController")
    }

    // MARK: - AT05: PluginGalleryViewController loadView 后初始 state == .loading

    func test_AT05_initialState_isLoading() {
        let market = RedMockMarketplaceInspecting()
        let plugins = RedMockPluginToggling()
        let vc = PluginGalleryViewController(marketplace: market, plugins: plugins, builtinRegistry: BuiltinPluginRegistry(plugins: []))
        forceLoadView(vc)
        // 不触发 viewDidAppear，state 应保持初始 .loading
        if case .loading = vc.state {
            // ok
        } else {
            XCTFail("loadView 后初始 state 应为 .loading，实际: \(vc.state)")
        }
    }

    // MARK: - AT06: mock inspect 返回 plugins=[] + sideloaded=[] → state == .normal（仅 settingsEntry）
    //
    // 契约演进：settingsEntry（虚拟「插件设置」项）恒为 row 0，全局区面板入口永远可达。
    // 空 inspect 不再落入 .empty，而是 .normal(plugins: [settingsEntry])（仅含虚拟项）。
    func test_AT06_emptyInspect_yieldsNormalWithOnlySettingsEntry() async {
        let market = RedMockMarketplaceInspecting(inspectResult: .empty)
        let plugins = RedMockPluginToggling()
        let vc = PluginGalleryViewController(marketplace: market, plugins: plugins, builtinRegistry: BuiltinPluginRegistry(plugins: []))
        forceLoadView(vc)
        await triggerAppearAndDrain(vc)
        guard case .normal(let entries) = vc.state else {
            XCTFail("空 inspect 应得 state == .normal (仅 settingsEntry)，实际: \(vc.state)")
            return
        }
        XCTAssertEqual(entries.count, 1, "空 inspect 后应仅含 settingsEntry 虚拟项")
        XCTAssertEqual(entries[0].name, "插件设置", "唯一项应为 settingsEntry")
        XCTAssertEqual(entries[0].source, "settings", "settingsEntry.source == 'settings' 标记虚拟项")
        XCTAssertGreaterThanOrEqual(market.inspectCallCount, 1, "inspect 至少被调用一次")
    }

    // MARK: - AT07: mock inspect 返回 plugins=[translate] → state == .normal 含 translate

    func test_AT07_pluginsInspect_yieldsNormalStateWithTranslate() async {
        let market = RedMockMarketplaceInspecting(
            inspectResult: .withPlugin(name: "translate", version: "0.1.0", enabled: true)
        )
        let plugins = RedMockPluginToggling()
        let vc = PluginGalleryViewController(marketplace: market, plugins: plugins, builtinRegistry: BuiltinPluginRegistry(plugins: []))
        forceLoadView(vc)
        await triggerAppearAndDrain(vc)
        guard case .normal(let entries) = vc.state else {
            return XCTFail("应得 state == .normal，实际: \(vc.state)")
        }
        XCTAssertTrue(entries.contains(where: { $0.name == "translate" }),
                      "normal 状态应包含 name=translate 条目，实际 entries: \(entries.map { $0.name })")
    }

    // MARK: - AT08: mock inspect throw → state == .error

    func test_AT08_inspectThrows_yieldsErrorState() async {
        let market = RedMockMarketplaceInspecting(
            inspectError: LauncherError.pluginInvalid("simulated")
        )
        let plugins = RedMockPluginToggling()
        let vc = PluginGalleryViewController(marketplace: market, plugins: plugins, builtinRegistry: BuiltinPluginRegistry(plugins: []))
        forceLoadView(vc)
        await triggerAppearAndDrain(vc)
        if case .error = vc.state {
            // ok
        } else {
            XCTFail("inspect 抛错应得 state == .error，实际: \(vc.state)")
        }
    }

    // MARK: - AT09: error 态 reseed 按钮可见；其他态隐藏

    func test_AT09_reseedButton_visibilityFollowsState() async {
        // 1) error 态
        let market1 = RedMockMarketplaceInspecting(
            inspectError: LauncherError.pluginInvalid("simulated")
        )
        let vc1 = PluginGalleryViewController(marketplace: market1, plugins: RedMockPluginToggling())
        forceLoadView(vc1)
        await triggerAppearAndDrain(vc1)
        let reseedBtn1 = findReseedButton(in: vc1.view)
        XCTAssertNotNil(reseedBtn1, "error 态 view hierarchy 中应有 reseed 按钮")
        XCTAssertEqual(reseedBtn1?.isHidden, false, "error 态 reseed 按钮应可见")

        // 2) normal 态
        let market2 = RedMockMarketplaceInspecting(
            inspectResult: .withPlugin(name: "translate")
        )
        let vc2 = PluginGalleryViewController(marketplace: market2, plugins: RedMockPluginToggling())
        forceLoadView(vc2)
        await triggerAppearAndDrain(vc2)
        let reseedBtn2 = findReseedButton(in: vc2.view)
        // 按钮可以存在但应隐藏
        if let btn = reseedBtn2 {
            XCTAssertTrue(btn.isHidden, "normal 态 reseed 按钮应隐藏")
        }

        // 3) empty 态
        let market3 = RedMockMarketplaceInspecting(inspectResult: .empty)
        let vc3 = PluginGalleryViewController(marketplace: market3, plugins: RedMockPluginToggling())
        forceLoadView(vc3)
        await triggerAppearAndDrain(vc3)
        let reseedBtn3 = findReseedButton(in: vc3.view)
        if let btn = reseedBtn3 {
            XCTAssertTrue(btn.isHidden, "empty 态 reseed 按钮应隐藏")
        }
    }

    // MARK: - AT10: toggleButtonClicked(name=translate, tag=0) → plugins.disable("translate")

    func test_AT10_toggleButton_tag0_callsDisable() async {
        let market = RedMockMarketplaceInspecting(
            inspectResult: .withPlugin(name: "translate", enabled: true)
        )
        let plugins = RedMockPluginToggling()
        let vc = PluginGalleryViewController(marketplace: market, plugins: plugins, builtinRegistry: BuiltinPluginRegistry(plugins: []))
        forceLoadView(vc)
        await triggerAppearAndDrain(vc)

        let button = NSButton(title: "禁用", target: vc, action: #selector(PluginGalleryViewController.toggleButtonClicked(_:)))
        button.identifier = NSUserInterfaceItemIdentifier("translate")
        button.tag = 0
        vc.toggleButtonClicked(button)
        await drainMainActor()
        await drainMainActor()

        XCTAssertTrue(plugins.disabledNames.contains("translate"),
                      "tag=0 应触发 disable('translate')，实际 disabledNames: \(plugins.disabledNames)")
        XCTAssertFalse(plugins.enabledNames.contains("translate"),
                       "tag=0 不应触发 enable")
    }

    // MARK: - AT11: toggleButtonClicked(name=translate, tag=1) → plugins.enable("translate")

    func test_AT11_toggleButton_tag1_callsEnable() async {
        let market = RedMockMarketplaceInspecting(
            inspectResult: .withPlugin(name: "translate", enabled: false)
        )
        let plugins = RedMockPluginToggling()
        let vc = PluginGalleryViewController(marketplace: market, plugins: plugins, builtinRegistry: BuiltinPluginRegistry(plugins: []))
        forceLoadView(vc)
        await triggerAppearAndDrain(vc)

        let button = NSButton(title: "启用", target: vc, action: #selector(PluginGalleryViewController.toggleButtonClicked(_:)))
        button.identifier = NSUserInterfaceItemIdentifier("translate")
        button.tag = 1
        vc.toggleButtonClicked(button)
        await drainMainActor()
        await drainMainActor()

        XCTAssertTrue(plugins.enabledNames.contains("translate"),
                      "tag=1 应触发 enable('translate')，实际 enabledNames: \(plugins.enabledNames)")
        XCTAssertFalse(plugins.disabledNames.contains("translate"),
                       "tag=1 不应触发 disable")
    }

    // MARK: - AT12: 非法 name "translate; rm -rf /" → 不调 plugins.disable

    func test_AT12_invalidName_doesNotCallDisable() async {
        let market = RedMockMarketplaceInspecting()
        let plugins = RedMockPluginToggling()
        let vc = PluginGalleryViewController(marketplace: market, plugins: plugins, builtinRegistry: BuiltinPluginRegistry(plugins: []))
        forceLoadView(vc)

        let button = NSButton(title: "禁用", target: vc, action: #selector(PluginGalleryViewController.toggleButtonClicked(_:)))
        button.identifier = NSUserInterfaceItemIdentifier("translate; rm -rf /")
        button.tag = 0
        vc.toggleButtonClicked(button)
        await drainMainActor()
        await drainMainActor()

        XCTAssertTrue(plugins.disabledNames.isEmpty,
                      "非法 name 不应调 disable，实际 disabledNames: \(plugins.disabledNames)")
        XCTAssertTrue(plugins.enabledNames.isEmpty,
                      "非法 name 不应调 enable，实际 enabledNames: \(plugins.enabledNames)")
    }

    // MARK: - AT13: sideloaded 渲染 → state.normal 含 isSideloaded=true 的 weather

    func test_AT13_sideloaded_rendersWithSideloadedFlag() async {
        let market = RedMockMarketplaceInspecting(
            inspectResult: .withSideloaded(name: "weather", enabled: true)
        )
        let plugins = RedMockPluginToggling()
        let vc = PluginGalleryViewController(marketplace: market, plugins: plugins, builtinRegistry: BuiltinPluginRegistry(plugins: []))
        forceLoadView(vc)
        await triggerAppearAndDrain(vc)

        guard case .normal(let entries) = vc.state else {
            return XCTFail("应得 state == .normal，实际: \(vc.state)")
        }
        guard let weather = entries.first(where: { $0.name == "weather" }) else {
            return XCTFail("entries 中应含 name=weather，实际: \(entries.map { $0.name })")
        }
        XCTAssertTrue(weather.isSideloaded,
                      "weather 应标记 isSideloaded=true")
    }

    // MARK: - View hierarchy helpers

    /// 递归在 view tree 中找标题含"重新初始化"的 NSButton（reseed 按钮）。
    private func findReseedButton(in view: NSView) -> NSButton? {
        if let btn = view as? NSButton, btn.title.contains("重新初始化") {
            return btn
        }
        for sub in view.subviews {
            if let found = findReseedButton(in: sub) { return found }
        }
        return nil
    }
}
