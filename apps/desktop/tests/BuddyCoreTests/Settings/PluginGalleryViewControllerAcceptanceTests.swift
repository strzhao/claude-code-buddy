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

/// 红队验收测试 (task 005): Buddy Store UI — SettingsWindowController + PluginGalleryViewController
///
/// 覆盖 13 个 AT（与 state.md `## 验证方案` Tier 0 一致）。
/// 严格基于设计文档契约，不依赖蓝队具体实现细节。
@MainActor
final class PluginGalleryViewControllerAcceptanceTests: XCTestCase {

    private var defaultsKey: String!

    override func setUp() {
        super.setUp()
        // 每个 case 用独立 UserDefaults key 隔离（避免互相污染）
        defaultsKey = "BuddyStoreSelectedTab"
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

    // MARK: - AT01: SettingsWindowController title == "Buddy Store"

    func test_AT01_settingsWindow_title_isBuddyStore() {
        let wc = SettingsWindowController()
        XCTAssertEqual(wc.window?.title, "Buddy Store",
                       "SettingsWindowController.window.title 必须为 'Buddy Store'")
    }

    // MARK: - AT02: UserDefaults 为空 → 默认 .skins

    func test_AT02_userDefaultsEmpty_defaultsToSkinsTab() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        let wc = SettingsWindowController()
        // contentViewController 应为 SkinGalleryViewController
        XCTAssertTrue(wc.window?.contentViewController is SkinGalleryViewController,
                      "UserDefaults 为空时，默认 tab 应为 .skins (contentVC = SkinGalleryViewController)")
    }

    // MARK: - AT03: 切到 plugins → UserDefaults 写入 "plugins"

    func test_AT03_switchToPlugins_writesUserDefaults() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        let wc = SettingsWindowController()
        // 通过反射查找 segmentedControl，模拟切换
        // 直接调用 segmentChanged 的方法：用 NSSegmentedControl 触发
        // 因为 segmentChanged 是 internal/private，通过设置 UserDefaults 模拟"持久化"路径
        // 这里实际只能验证设计文档承诺：切到 plugins 后该 key 应为 "plugins"
        // 蓝队实现 segmentChanged 时必须写 UserDefaults
        // 我们用一个"切 tab"的代理：调用 NSSegmentedControl click action
        guard let panel = wc.window else {
            return XCTFail("Settings window 不存在")
        }
        // 查找 NSSegmentedControl
        let segmented = findSegmentedControl(in: panel)
        guard let seg = segmented else {
            return XCTFail("未找到 NSSegmentedControl")
        }
        seg.selectedSegment = 1
        // 触发 action
        if let target = seg.target as? NSObject, let action = seg.action {
            _ = target.perform(action, with: seg)
        }
        let stored = UserDefaults.standard.string(forKey: defaultsKey)
        XCTAssertEqual(stored, "plugins",
                       "切到 plugins tab 后 UserDefaults['\(defaultsKey ?? "")'] 应为 'plugins'")
    }

    // MARK: - AT04: UserDefaults 预设 "plugins" → init 后 segmented 选中 .plugins

    func test_AT04_userDefaultsPlugins_initSelectsPluginsTab() {
        UserDefaults.standard.set("plugins", forKey: defaultsKey)
        let wc = SettingsWindowController()
        guard let panel = wc.window else {
            return XCTFail("Settings window 不存在")
        }
        // contentVC 应为 PluginGalleryViewController
        XCTAssertTrue(panel.contentViewController is PluginGalleryViewController,
                      "预设 'plugins' 时，init 后 contentVC 应为 PluginGalleryViewController")
        if let seg = findSegmentedControl(in: panel) {
            XCTAssertEqual(seg.selectedSegment, 1,
                           "预设 'plugins' 时，segmentedControl.selectedSegment 应为 1")
        }
    }

    // MARK: - AT05: PluginGalleryViewController loadView 后初始 state == .loading

    func test_AT05_initialState_isLoading() {
        let market = RedMockMarketplaceInspecting()
        let plugins = RedMockPluginToggling()
        let vc = PluginGalleryViewController(marketplace: market, plugins: plugins)
        forceLoadView(vc)
        // 不触发 viewDidAppear，state 应保持初始 .loading
        if case .loading = vc.state {
            // ok
        } else {
            XCTFail("loadView 后初始 state 应为 .loading，实际: \(vc.state)")
        }
    }

    // MARK: - AT06: mock inspect 返回 plugins=[] + sideloaded=[] → state == .empty

    func test_AT06_emptyInspect_yieldsEmptyState() async {
        let market = RedMockMarketplaceInspecting(inspectResult: .empty)
        let plugins = RedMockPluginToggling()
        let vc = PluginGalleryViewController(marketplace: market, plugins: plugins)
        forceLoadView(vc)
        await triggerAppearAndDrain(vc)
        if case .empty = vc.state {
            // ok
        } else {
            XCTFail("空 inspect 应得 state == .empty，实际: \(vc.state)")
        }
        XCTAssertGreaterThanOrEqual(market.inspectCallCount, 1, "inspect 至少被调用一次")
    }

    // MARK: - AT07: mock inspect 返回 plugins=[translate] → state == .normal 含 translate

    func test_AT07_pluginsInspect_yieldsNormalStateWithTranslate() async {
        let market = RedMockMarketplaceInspecting(
            inspectResult: .withPlugin(name: "translate", version: "0.1.0", enabled: true)
        )
        let plugins = RedMockPluginToggling()
        let vc = PluginGalleryViewController(marketplace: market, plugins: plugins)
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
        let vc = PluginGalleryViewController(marketplace: market, plugins: plugins)
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
        let vc = PluginGalleryViewController(marketplace: market, plugins: plugins)
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
        let vc = PluginGalleryViewController(marketplace: market, plugins: plugins)
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
        let vc = PluginGalleryViewController(marketplace: market, plugins: plugins)
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
        let vc = PluginGalleryViewController(marketplace: market, plugins: plugins)
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

    /// 递归在 window 中找 NSSegmentedControl。
    private func findSegmentedControl(in window: NSWindow) -> NSSegmentedControl? {
        if let content = window.contentView, let seg = findSegmentedControl(in: content) {
            return seg
        }
        // titlebar accessory views
        for accessory in window.titlebarAccessoryViewControllers {
            if let seg = findSegmentedControl(in: accessory.view) {
                return seg
            }
        }
        return nil
    }

    private func findSegmentedControl(in view: NSView) -> NSSegmentedControl? {
        if let seg = view as? NSSegmentedControl { return seg }
        for sub in view.subviews {
            if let found = findSegmentedControl(in: sub) { return found }
        }
        return nil
    }
}
