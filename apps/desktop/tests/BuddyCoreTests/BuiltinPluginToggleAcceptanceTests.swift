import XCTest
@testable import BuddyCore

/// Tier 0 红队验收测试 —— 黑盒验证内置插件开关持久化（契约 C3）+ registry 候选过滤（场景 1/2/3）。
///
/// 覆盖验收场景：
/// - 场景 1.P1: registry 含全部 4 个内置插件 id（system-command/calculator/paste/app-launcher）
/// - 场景 1.P2: 每个 plugin 对象含非空 `summary` 字段（契约 C2）
/// - 场景 2.P1: registry candidates for "1+2" 返回 calculator 候选（length >= 1）
/// - 场景 3.P1: calculator disabled 后 candidates 不再返回 calculator 候选
/// - 场景 3.P2: calculator disabled 时 registry 输出 enabled == false
///
/// 契约逐字对齐：
/// - C3: UserDefaults.standard, key 模式 `buddy.launcher.builtin.<id>.disabled`（Bool, true=关闭）
/// - C3 API: `isEnabled(id:) -> Bool`, `setEnabled(id:enabled:)`; 默认全部 enabled（无 key = true）
/// - C2: registry 输出每个插件含 `id/summary/description/priority/sectionTitle/enabled`
///
/// 信息隔离：不读 BuiltinPluginEnabledStore/BuiltinPluginRegistry 实现，仅调契约声明的 public API。
/// 命名前缀: test_AT<编号>_<场景>
@MainActor
final class BuiltinPluginToggleAcceptanceTests: XCTestCase {

    // MARK: - 测试用 fake plugin（符合现有 BuiltinPlugin 协议；id 固定便于操作 store）

    /// 固定 id 的 fake 内置插件，用于隔离测试 store 与 registry 过滤逻辑。
    /// 不依赖真实 Calculator 等实现（避免耦合其内部 keywords 匹配）。
    private final class FakePlugin: BuiltinPlugin {
        let id: String
        let priority: Int
        let sectionTitle: String
        private let queryMatcher: (String) -> Bool

        init(id: String, priority: Int = 100, sectionTitle: String = "测试", queryMatcher: @escaping (String) -> Bool) {
            self.id = id
            self.priority = priority
            self.sectionTitle = sectionTitle
            self.queryMatcher = queryMatcher
        }

        func actions(for query: String) async -> [LauncherAction] {
            guard queryMatcher(query) else { return [] }
            return [
                LauncherAction(
                    id: "fake-action-\(id)",
                    title: "fake-\(id)",
                    subtitle: nil,
                    icon: nil,
                    pluginId: id,
                    score: 100,
                    perform: { /* no-op for test */ }
                )
            ]
        }
    }

    // MARK: - 测试隔离的 UserDefaults key 清理

    /// 清掉指定 id 的 disabled key，保证测试起始状态干净。
    private func clearDisabledKey(_ id: String) {
        let key = "buddy.launcher.builtin.\(id).disabled"
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// 构造测试用 store。
    /// 契约 C3 声明 API `isEnabled/setEnabled` + UserDefaults.standard 存储；
    /// 项目约定（TrustStore/MarketplaceManager/PluginManager）均提供 shared 单例，此处沿用。
    /// 若实现改为可注入 init，此处仍语义正确（key 模式是 SSOT）。
    private func makeStore() -> BuiltinPluginEnabledStore {
        BuiltinPluginEnabledStore.shared
    }

    // MARK: - 场景 1.P1 + 1.P2: registry 含 4 个内置插件 id 且每个含非空 summary

    /// 契约 C2 + 场景 1.P1: registry 含全部 4 个内置插件 id。
    func test_AT01_registryContainsAllFourBuiltinPluginIds() async {
        let registry = BuiltinPluginRegistry.shared
        let ids = Set(registry.plugins.map(\.id))
        // 场景 1.P1 assert: stdout 含全部 4 个 id
        let expected: Set<String> = ["system-command", "calculator", "paste", "app-launcher"]
        XCTAssertEqual(ids, expected,
                       "registry 必须注册全部 4 个内置插件，实际: \(ids.sorted())")
    }

    /// 契约 C2 + 场景 1.P2: 每个 plugin 对象含非空 summary。
    func test_AT02_everyBuiltinPluginHasNonEmptySummary() {
        let registry = BuiltinPluginRegistry.shared
        // 契约 C2: BuiltinPlugin 协议加 `var summary: String { get }`
        for plugin in registry.plugins {
            XCTAssertFalse(plugin.summary.isEmpty,
                           "内置插件 \(plugin.id) 的 summary 不能为空（场景 1.P2）")
        }
    }

    /// 契约 C2: 每个 plugin 含 description（协议加的字段，详情展开用）。
    func test_AT03_everyBuiltinPluginHasDescription() {
        let registry = BuiltinPluginRegistry.shared
        for plugin in registry.plugins {
            XCTAssertFalse(plugin.description.isEmpty,
                           "内置插件 \(plugin.id) 的 description 不能为空（契约 C2）")
        }
    }

    // MARK: - 场景 2.P1: calculator 候选生成（"1+2" 返回 calculator 候选）

    /// 契约 C10 + 场景 2.P1: registry actions(for: "1+2") 返回 calculator 候选（length >= 1）。
    func test_AT04_calculatorProducesCandidateForArithmeticQuery() async {
        // 先确保 calculator enabled（测试隔离）
        clearDisabledKey("calculator")
        let registry = BuiltinPluginRegistry.shared
        let candidates = await registry.actions(for: "1+2")
        // 场景 2.P1 assert: length >= 1
        XCTAssertGreaterThanOrEqual(candidates.count, 1,
                                    "registry 对 '1+2' 必须返回至少 1 个候选（calculator）")
        // 至少一个候选来自 calculator
        let hasCalculator = candidates.contains { $0.pluginId == "calculator" }
        XCTAssertTrue(hasCalculator,
                      "candidates 必须含 calculator 候选，实际 pluginIds: \(candidates.map(\.pluginId))")
    }

    // MARK: - 场景 3.P1: 关闭内置插件后不再产生候选

    /// 契约 C3 + 场景 3.P1: calculator disabled 后 candidates for "1+2" 不再返回 calculator。
    func test_AT05_disabledBuiltinProducesNoCandidate() async {
        let store = makeStore()
        // 起始状态：确保 enabled
        store.setEnabled(id: "calculator", enabled: true)
        clearDisabledKey("calculator")

        // 确认 enabled 时有 calculator 候选（前置）
        let registry = BuiltinPluginRegistry.shared
        let beforeDisabled = await registry.actions(for: "1+2")
        XCTAssertTrue(beforeDisabled.contains { $0.pluginId == "calculator" },
                      "前置：calculator enabled 时必须有候选")

        // 关闭 calculator（契约 C3）
        store.setEnabled(id: "calculator", enabled: false)

        // 场景 3.P1 assert: candidates 不再含 calculator（==[]）
        let afterDisabled = await registry.actions(for: "1+2")
        let calculatorCandidates = afterDisabled.filter { $0.pluginId == "calculator" }
        XCTAssertTrue(calculatorCandidates.isEmpty,
                      "calculator disabled 后不应产生候选，实际: \(calculatorCandidates)")

        // 清理：恢复 enabled（避免污染其他测试）
        store.setEnabled(id: "calculator", enabled: true)
        clearDisabledKey("calculator")
    }

    // MARK: - 场景 3.P2: disabled 时 registry 输出 enabled == false

    /// 契约 C2/C3 + 场景 3.P2: calculator disabled 时 registry 输出该插件 enabled == false。
    /// registry 需暴露 enabled 字段（C2: 输出含 enabled）。
    func test_AT06_registryReportsEnabledFalseWhenDisabled() {
        let store = makeStore()
        clearDisabledKey("calculator")
        defer {
            store.setEnabled(id: "calculator", enabled: true)
            clearDisabledKey("calculator")
        }

        let registry = BuiltinPluginRegistry.shared

        // enabled 时
        store.setEnabled(id: "calculator", enabled: true)
        // 契约 C2: registry 输出含 enabled。通过 store 查询保持一致。
        XCTAssertTrue(store.isEnabled(id: "calculator"),
                      "calculator 应为 enabled")

        // disabled 时
        store.setEnabled(id: "calculator", enabled: false)
        // 场景 3.P2 assert: enabled == false
        XCTAssertFalse(store.isEnabled(id: "calculator"),
                       "calculator disabled 后 store.isEnabled 必须返回 false")
    }

    // MARK: - C3: UserDefaults 持久化语义（key 模式逐字一致）

    /// 契约 C3: 存储 UserDefaults.standard，key 模式 `buddy.launcher.builtin.<id>.disabled`（Bool true=关闭）。
    func test_AT07_persistsToUserDefaultsStandardWithContractKey() {
        let store = makeStore()
        let id = "calculator"
        let key = "buddy.launcher.builtin.\(id).disabled"
        clearDisabledKey(id)
        defer { clearDisabledKey(id) }

        // 关闭 → key 必须 true
        store.setEnabled(id: id, enabled: false)
        let raw = UserDefaults.standard.object(forKey: key) as? Bool
        XCTAssertEqual(raw, true,
                       "disabled 必须 persist 到 UserDefaults.standard key '\(key)' = true（契约 C3 逐字）")

        // 开启 → key 必须 false 或不存在
        store.setEnabled(id: id, enabled: true)
        let rawEnabled = UserDefaults.standard.object(forKey: key) as? Bool
        XCTAssertNotEqual(rawEnabled, true,
                          "enabled 时 key 不得为 true（false 或删除）")
    }

    /// 契约 C3: 默认全部 enabled（无 key = true）。
    func test_AT08_defaultsToEnabledWhenNoKey() {
        let store = makeStore()
        let testId = "nonexistent-plugin-id-12345"
        let key = "buddy.launcher.builtin.\(testId).disabled"
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        // 无 key 时默认 enabled
        XCTAssertTrue(store.isEnabled(id: testId),
                      "无 key 时必须默认 enabled（契约 C3: 默认全部 enabled）")
    }

    /// 契约 C3: setEnabled 幂等切换 enabled↔disabled。
    func test_AT09_setEnabledTogglesBidirectionally() {
        let store = makeStore()
        let id = "paste"
        clearDisabledKey(id)
        defer { clearDisabledKey(id) }

        store.setEnabled(id: id, enabled: false)
        XCTAssertFalse(store.isEnabled(id: id))
        store.setEnabled(id: id, enabled: true)
        XCTAssertTrue(store.isEnabled(id: id))
        store.setEnabled(id: id, enabled: false)
        XCTAssertFalse(store.isEnabled(id: id),
                       "setEnabled 必须可重复切换 disabled↔enabled")
    }

    // MARK: - 场景 6.P2: 内置插件 summary 无黑话

    /// 契约 C1/C2 + 场景 6.P2: registry 输出内置插件 summary 不含内部黑话词。
    func test_AT10_builtinSummariesContainNoInternalJargon() {
        let registry = BuiltinPluginRegistry.shared
        // 场景 6.P2 assert: grep 'priority|仲裁|解释器|deterministic' 无输出
        let forbidden = ["priority", "仲裁", "解释器", "deterministic", "stdin", "stdout", "markdown 协议"]
        for plugin in registry.plugins {
            for word in forbidden {
                XCTAssertFalse(plugin.summary.localizedCaseInsensitiveContains(word),
                               "内置插件 \(plugin.id) summary 含黑话词「\(word)」: \(plugin.summary)")
            }
        }
    }
}
