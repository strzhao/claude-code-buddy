import XCTest
@testable import BuddyCore

/// 蓝队单元测试 — C3 BuiltinPluginEnabledStore 开关持久化
///
/// 契约 C3（SOURCE OF TRUTH: BuiltinPluginEnabledStore.swift）：
/// - 存储：UserDefaults.standard，key 模式 `buddy.launcher.builtin.<id>.disabled`（Bool，true=关闭）
/// - API：isEnabled(id:) -> Bool、setEnabled(id:enabled:)。默认全部 enabled（无 key = true）
/// - 关闭语义：Registry.actions(for:) 跳过 disabled（候选过滤，见 RegistryEnabledFilterTests）
final class BuiltinPluginEnabledStoreTests: XCTestCase {

    // MARK: - 隔离的 UserDefaults（避免污染 .standard）

    /// 每个测试用独立 suite，setUp 创建、tearDown 清空，互不影响。
    private var defaults: UserDefaults!
    private var store: BuiltinPluginEnabledStore!

    override func setUp() {
        super.setUp()
        let suiteName = "test-builtin-enabled-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        // 兜底清空（新 suite 理论为空）
        for key in defaults.dictionaryRepresentation().keys {
            defaults.removeObject(forKey: key)
        }
        store = BuiltinPluginEnabledStore(defaults: defaults)
    }

    override func tearDown() {
        // 清空 suite 并移除（避免跨测试残留）
        if let d = defaults {
            for key in d.dictionaryRepresentation().keys {
                d.removeObject(forKey: key)
            }
        }
        defaults = nil
        store = nil
        super.tearDown()
    }

    // MARK: - 默认 enabled

    func test_isEnabled_defaultsToTrue_whenNoKey() {
        // 无 key = 默认启用
        XCTAssertTrue(store.isEnabled(id: "calculator"), "无 key 时默认 enabled")
        XCTAssertTrue(store.isEnabled(id: "paste"))
        XCTAssertTrue(store.isEnabled(id: "any-plugin"))
    }

    // MARK: - setEnabled false → disabled

    func test_setEnabled_false_marksDisabled() {
        store.setEnabled(id: "calculator", enabled: false)
        XCTAssertFalse(store.isEnabled(id: "calculator"))
    }

    func test_setEnabled_false_writesDisabledKeyTrue() {
        store.setEnabled(id: "calculator", enabled: false)
        let key = "buddy.launcher.builtin.calculator.disabled"
        // key 存在且 == true（disabled 语义）
        XCTAssertNotNil(defaults.object(forKey: key), "disabled key 必须被写入")
        XCTAssertTrue(defaults.bool(forKey: key), "disabled key 值 = true")
    }

    // MARK: - setEnabled true → re-enabled

    func test_setEnabled_true_afterDisabled_reEnables() {
        store.setEnabled(id: "calculator", enabled: false)
        XCTAssertFalse(store.isEnabled(id: "calculator"))

        store.setEnabled(id: "calculator", enabled: true)
        XCTAssertTrue(store.isEnabled(id: "calculator"))
    }

    // MARK: - 隔离性：不同 id 互不影响

    func test_setEnabled_oneId_doesNotAffectOthers() {
        store.setEnabled(id: "calculator", enabled: false)
        XCTAssertFalse(store.isEnabled(id: "calculator"))
        XCTAssertTrue(store.isEnabled(id: "paste"), "其他插件不受影响")
        XCTAssertTrue(store.isEnabled(id: "system-command"))
    }

    // MARK: - 持久化（同 suite 内跨 store 实例）

    func test_persistence_acrossStoreInstances_sameDefaults() {
        store.setEnabled(id: "app-launcher", enabled: false)

        // 新 store 实例（同 defaults）应读到持久化状态
        let store2 = BuiltinPluginEnabledStore(defaults: defaults)
        XCTAssertFalse(store2.isEnabled(id: "app-launcher"), "状态必须持久化到 defaults")
    }

    // MARK: - reset（测试 helper）

    func test_reset_removesKey_backToDefault() {
        store.setEnabled(id: "calculator", enabled: false)
        XCTAssertFalse(store.isEnabled(id: "calculator"))

        store.reset(id: "calculator")
        XCTAssertTrue(store.isEnabled(id: "calculator"), "reset 后回默认 enabled")
    }

    // MARK: - key 前缀契约（C3 逐字）

    func test_keyPrefix_isBuddyLauncherBuiltin() {
        // 契约 C3：key 前缀 buddy.launcher.builtin.，后缀 .disabled
        XCTAssertEqual(BuiltinPluginEnabledStore.keyPrefix, "buddy.launcher.builtin.")
        XCTAssertEqual(BuiltinPluginEnabledStore.disabledSuffix, ".disabled")

        store.setEnabled(id: "my-plugin", enabled: false)
        let expectedKey = "buddy.launcher.builtin.my-plugin.disabled"
        XCTAssertNotNil(defaults.object(forKey: expectedKey), "key 必须严格匹配契约前缀+后缀")
    }
}

/// 蓝队单元测试 — C3 Registry.actions(for:) 跳过 disabled 插件（场景 3.P1）
///
/// 关闭语义：disabled 的插件不产生候选（不响应）。验证 Registry 聚合时过滤。
final class BuiltinPluginRegistryEnabledFilterTests: XCTestCase {

    /// mock 插件：始终返回 1 个候选（便于验证是否被过滤）
    @MainActor
    private struct AlwaysOnePlugin: BuiltinPlugin {
        let id: String
        let priority: Int = 100
        let sectionTitle = "测试"
        let summary = "测试插件摘要"
        let description = "测试插件详细说明"
        func actions(for query: String) async -> [LauncherAction] {
            guard !query.isEmpty else { return [] }
            return [LauncherAction(id: "act-\(id)", title: "Act \(id)", subtitle: nil, icon: nil, pluginId: id, score: 500, perform: {})]
        }
    }

    @MainActor
    func test_actions_skipsDisabledPlugin() async {
        let enabledStore = makeIsolatedStore()
        let pluginA = AlwaysOnePlugin(id: "a")
        let pluginB = AlwaysOnePlugin(id: "b")
        let registry = BuiltinPluginRegistry(
            plugins: [pluginA, pluginB],
            enabledStore: enabledStore
        )

        // 初始：两个插件都 enabled → 2 个候选
        let initial = await registry.actions(for: "query")
        XCTAssertEqual(initial.count, 2)

        // 禁用 b → 只剩 a 的候选
        enabledStore.setEnabled(id: "b", enabled: false)
        let afterDisable = await registry.actions(for: "query")
        XCTAssertEqual(afterDisable.count, 1)
        XCTAssertEqual(afterDisable.first?.pluginId, "a", "disabled 的 b 候选必须被过滤")
    }

    @MainActor
    func test_actions_allDisabled_returnsEmpty() async {
        let enabledStore = makeIsolatedStore()
        let registry = BuiltinPluginRegistry(
            plugins: [AlwaysOnePlugin(id: "a"), AlwaysOnePlugin(id: "b")],
            enabledStore: enabledStore
        )

        enabledStore.setEnabled(id: "a", enabled: false)
        enabledStore.setEnabled(id: "b", enabled: false)

        let result = await registry.actions(for: "query")
        XCTAssertTrue(result.isEmpty, "全部 disabled 时无候选")
    }

    @MainActor
    func test_isEnabled_reflectsStore() {
        let enabledStore = makeIsolatedStore()
        let registry = BuiltinPluginRegistry(
            plugins: [AlwaysOnePlugin(id: "a")],
            enabledStore: enabledStore
        )

        XCTAssertTrue(registry.isEnabled(id: "a"))
        enabledStore.setEnabled(id: "a", enabled: false)
        XCTAssertFalse(registry.isEnabled(id: "a"))
    }

    /// 用独立 UserDefaults suite 隔离（避免污染 .standard 影响其他测试）。
    private func makeIsolatedStore() -> BuiltinPluginEnabledStore {
        let suiteName = "test-registry-filter-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return BuiltinPluginEnabledStore(defaults: defaults)
    }
}
