import XCTest
@testable import BuddyCore

/// 蓝队单元测试 — LauncherManager 即时候选管线（C5/C7 契约）
/// 测试 Enter 分流、debounce、空清空、clearInstantActions 等
@MainActor
final class LauncherManagerInstantTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        LauncherManager.shared.setup()
        if LauncherManager.shared.isVisible {
            LauncherManager.shared.hide()
        }
        // 重置注入点
        LauncherManager.shared.instantDebounceMsOverride = 0
        LauncherManager.shared.registryOverride = nil
    }

    override func tearDown() async throws {
        // 清理
        LauncherManager.shared.clearInstantActions()
        LauncherManager.shared.instantDebounceMsOverride = nil
        LauncherManager.shared.registryOverride = nil
        try await super.tearDown()
    }

    // MARK: - C7 空清空

    func test_updateQuery_emptyQuery_immediatelyClearsInstantActions() async {
        // 先注入一些 actions
        let registry = makeRegistryWithFixedActions([
            makeAction(id: "a1", title: "App1")
        ])
        LauncherManager.shared.registryOverride = registry
        LauncherManager.shared.instantDebounceMsOverride = 0

        // 触发非空 query
        LauncherManager.shared.updateQuery("app")
        // 等待 debounce
        try? await Task.sleep(nanoseconds: 50_000_000)

        // 空 query → 立即清空
        LauncherManager.shared.updateQuery("")
        XCTAssertTrue(LauncherManager.shared.instantActions.isEmpty, "空 query 应立即清空 instantActions")
        XCTAssertEqual(LauncherManager.shared.instantSelectedIndex, -1)
    }

    // MARK: - C7 debounce

    func test_updateQuery_setsInstantActions_afterDebounce() async {
        let registry = makeRegistryWithFixedActions([
            makeAction(id: "safari1", title: "Safari")
        ])
        LauncherManager.shared.registryOverride = registry
        LauncherManager.shared.instantDebounceMsOverride = 0  // 跳过等待

        LauncherManager.shared.updateQuery("saf")
        // 给 Task 时间完成
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertFalse(LauncherManager.shared.instantActions.isEmpty, "debounce 后应有候选")
        XCTAssertEqual(LauncherManager.shared.instantSelectedIndex, 0, "有候选时 selectedIndex 应为 0")
    }

    // MARK: - C5 Enter 分流

    func test_performSelectedInstantAction_withNoSelection_returnsFalse() {
        // 没有 instant actions → performSelectedInstantAction 返回 false
        LauncherManager.shared.clearInstantActions()
        let result = LauncherManager.shared.performSelectedInstantAction()
        XCTAssertFalse(result, "无选中 instant action 时应返回 false，不消费 Enter")
    }

    func test_performSelectedInstantAction_withAction_returnsTrue() async {
        var performed = false
        let action = LauncherAction(
            id: "test1",
            title: "Test App",
            subtitle: nil,
            icon: nil,
            pluginId: "app-launcher",
            score: 100,
            perform: { performed = true }
        )
        let registry = makeRegistryWithFixedActions([action])
        LauncherManager.shared.registryOverride = registry
        LauncherManager.shared.instantDebounceMsOverride = 0

        LauncherManager.shared.updateQuery("test")
        try? await Task.sleep(nanoseconds: 100_000_000)

        // 确保有候选
        XCTAssertFalse(LauncherManager.shared.instantActions.isEmpty)

        let result = LauncherManager.shared.performSelectedInstantAction()
        XCTAssertTrue(result, "有选中 instant action 时应返回 true，消费 Enter")
        XCTAssertTrue(performed, "perform 闭包应被执行")
    }

    func test_performSelectedInstantAction_onLaunchError_setsErrorState() async {
        let action = LauncherAction(
            id: "broken1",
            title: "Broken App",
            subtitle: nil,
            icon: nil,
            pluginId: "app-launcher",
            score: 100,
            perform: { throw LauncherError.appLaunchFailed("BrokenApp") }
        )
        let registry = makeRegistryWithFixedActions([action])
        LauncherManager.shared.registryOverride = registry
        LauncherManager.shared.instantDebounceMsOverride = 0

        LauncherManager.shared.updateQuery("broken")
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertFalse(LauncherManager.shared.instantActions.isEmpty)

        let result = LauncherManager.shared.performSelectedInstantAction()
        XCTAssertTrue(result, "即使失败也应消费 Enter 返回 true")
        XCTAssertNotNil(LauncherManager.shared.lastInstantError, "启动失败应设置 lastInstantError（C9）")
        XCTAssertEqual(LauncherManager.shared.stage, .error, "启动失败应进入 error 态")
    }

    // MARK: - clearInstantActions

    func test_clearInstantActions_resetsState() async {
        let registry = makeRegistryWithFixedActions([makeAction(id: "a1", title: "App1")])
        LauncherManager.shared.registryOverride = registry
        LauncherManager.shared.instantDebounceMsOverride = 0

        LauncherManager.shared.updateQuery("app")
        try? await Task.sleep(nanoseconds: 100_000_000)

        LauncherManager.shared.clearInstantActions()
        XCTAssertTrue(LauncherManager.shared.instantActions.isEmpty)
        XCTAssertEqual(LauncherManager.shared.instantSelectedIndex, -1)
    }

    // MARK: - show/hide 清空

    func test_show_clearsInstantState() async {
        let registry = makeRegistryWithFixedActions([makeAction(id: "a1", title: "App1")])
        LauncherManager.shared.registryOverride = registry
        LauncherManager.shared.instantDebounceMsOverride = 0

        LauncherManager.shared.updateQuery("app")
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(LauncherManager.shared.instantActions.isEmpty)

        LauncherManager.shared.show()
        XCTAssertTrue(LauncherManager.shared.instantActions.isEmpty, "show() 应清空 instantActions")
        XCTAssertEqual(LauncherManager.shared.instantSelectedIndex, -1)
        LauncherManager.shared.hide()
    }

    func test_hide_clearsInstantState() async {
        let registry = makeRegistryWithFixedActions([makeAction(id: "a1", title: "App1")])
        LauncherManager.shared.registryOverride = registry
        LauncherManager.shared.instantDebounceMsOverride = 0
        LauncherManager.shared.show()

        LauncherManager.shared.updateQuery("app")
        try? await Task.sleep(nanoseconds: 100_000_000)

        LauncherManager.shared.hide()
        XCTAssertTrue(LauncherManager.shared.instantActions.isEmpty, "hide() 应清空 instantActions")
        XCTAssertEqual(LauncherManager.shared.instantSelectedIndex, -1)
    }

    // MARK: - moveInstantSelection

    func test_moveInstantSelection_up_wrapsAround() async {
        let actions = [
            makeAction(id: "a1", title: "App1"),
            makeAction(id: "a2", title: "App2"),
            makeAction(id: "a3", title: "App3")
        ]
        let registry = makeRegistryWithFixedActions(actions)
        LauncherManager.shared.registryOverride = registry
        LauncherManager.shared.instantDebounceMsOverride = 0

        LauncherManager.shared.updateQuery("app")
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(LauncherManager.shared.instantSelectedIndex, 0)
        LauncherManager.shared.moveInstantSelection(up: true)
        // 循环：从 0 上移到末尾
        XCTAssertEqual(LauncherManager.shared.instantSelectedIndex, actions.count - 1)
    }

    func test_moveInstantSelection_down_wrapsAround() async {
        let actions = [
            makeAction(id: "a1", title: "App1"),
            makeAction(id: "a2", title: "App2")
        ]
        let registry = makeRegistryWithFixedActions(actions)
        LauncherManager.shared.registryOverride = registry
        LauncherManager.shared.instantDebounceMsOverride = 0

        LauncherManager.shared.updateQuery("app")
        try? await Task.sleep(nanoseconds: 100_000_000)

        // 手动设到末尾
        LauncherManager.shared.moveInstantSelection(up: false)  // 0→1
        LauncherManager.shared.moveInstantSelection(up: false)  // 1→0（循环）
        XCTAssertEqual(LauncherManager.shared.instantSelectedIndex, 0)
    }

    // MARK: - 辅助方法

    private func makeAction(id: String, title: String) -> LauncherAction {
        LauncherAction(
            id: id,
            title: title,
            subtitle: nil,
            icon: nil,
            pluginId: "test-plugin",
            score: 100,
            perform: {}
        )
    }

    private func makeRegistryWithFixedActions(_ actions: [LauncherAction]) -> BuiltinPluginRegistry {
        let plugin = FixedActionsPlugin(mockActions: actions)
        return BuiltinPluginRegistry(plugins: [plugin])
    }
}

// MARK: - Mock 固定候选插件

private struct FixedActionsPlugin: BuiltinPlugin {
    let id = "test-plugin"
    let priority = 0
    let sectionTitle = "测试"
    let mockActions: [LauncherAction]

    func actions(for query: String) async -> [LauncherAction] {
        guard !query.isEmpty else { return [] }
        return mockActions
    }
}
