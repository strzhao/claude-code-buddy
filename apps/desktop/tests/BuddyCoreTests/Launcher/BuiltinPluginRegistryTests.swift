import XCTest
@testable import BuddyCore

/// 蓝队单元测试 — BuiltinPluginRegistry 仲裁合并算法（C10 契约）
@MainActor
final class BuiltinPluginRegistryTests: XCTestCase {

    // MARK: - Mock 插件

    /// 高优先级 mock 插件
    private struct HighPriorityPlugin: BuiltinPlugin {
        let id = "high"
        let priority = 100
        let sectionTitle = "高优先"
        let mockActions: [LauncherAction]
        func actions(for query: String) async -> [LauncherAction] {
            guard !query.isEmpty else { return [] }
            return mockActions
        }
    }

    /// 低优先级 mock 插件
    private struct LowPriorityPlugin: BuiltinPlugin {
        let id = "low"
        let priority = 0
        let sectionTitle = "低优先"
        let mockActions: [LauncherAction]
        func actions(for query: String) async -> [LauncherAction] {
            guard !query.isEmpty else { return [] }
            return mockActions
        }
    }

    private func makeAction(id: String, title: String, pluginId: String, score: Int) -> LauncherAction {
        LauncherAction(
            id: id,
            title: title,
            subtitle: nil,
            icon: nil,
            pluginId: pluginId,
            score: score,
            perform: {}
        )
    }

    // MARK: - C10 仲裁排序

    func test_registry_highPriorityFirst() async {
        let highAction = makeAction(id: "h1", title: "High App", pluginId: "high", score: 100)
        let lowAction = makeAction(id: "l1", title: "Low App", pluginId: "low", score: 200)
        // lowAction 分数更高，但 priority 低

        let registry = BuiltinPluginRegistry(plugins: [
            LowPriorityPlugin(mockActions: [lowAction]),
            HighPriorityPlugin(mockActions: [highAction])
        ])

        let result = await registry.actions(for: "app")
        XCTAssertEqual(result.count, 2)
        // 高 priority 插件先出现
        XCTAssertEqual(result[0].pluginId, "high", "高 priority 插件的候选应排首位")
    }

    func test_registry_samePriority_sortByScoreDescending() async {
        let act1 = makeAction(id: "a1", title: "Apple", pluginId: "p1", score: 500)
        let act2 = makeAction(id: "a2", title: "Apex", pluginId: "p1", score: 300)
        let act3 = makeAction(id: "a3", title: "Acorn", pluginId: "p1", score: 700)

        struct SamePriorityPlugin: BuiltinPlugin {
            let id = "p1"
            let priority = 0
            let sectionTitle = "Test"
            let mockActions: [LauncherAction]
            func actions(for query: String) async -> [LauncherAction] {
                guard !query.isEmpty else { return [] }
                return mockActions
            }
        }

        let registry = BuiltinPluginRegistry(plugins: [SamePriorityPlugin(mockActions: [act1, act2, act3])])
        let result = await registry.actions(for: "a")
        XCTAssertEqual(result.map(\.id), ["a3", "a1", "a2"], "同 priority 按 score 降序")
    }

    func test_registry_sameScore_sortByTitleAscending() async {
        let act1 = makeAction(id: "z", title: "Zebra", pluginId: "p1", score: 100)
        let act2 = makeAction(id: "a", title: "Apple", pluginId: "p1", score: 100)
        let act3 = makeAction(id: "m", title: "Mango", pluginId: "p1", score: 100)

        struct P: BuiltinPlugin {
            let id = "p1"
            let priority = 0
            let sectionTitle = "T"
            let mockActions: [LauncherAction]
            func actions(for query: String) async -> [LauncherAction] {
                guard !query.isEmpty else { return [] }
                return mockActions
            }
        }

        let registry = BuiltinPluginRegistry(plugins: [P(mockActions: [act1, act2, act3])])
        let result = await registry.actions(for: "a")
        XCTAssertEqual(result.map(\.title), ["Apple", "Mango", "Zebra"], "同分按 title 字典序")
    }

    func test_registry_limit_truncates() async {
        let actions = (1...20).map {
            makeAction(id: "a\($0)", title: "App \($0)", pluginId: "p", score: $0)
        }

        struct P: BuiltinPlugin {
            let id = "p"
            let priority = 0
            let sectionTitle = "T"
            let mockActions: [LauncherAction]
            func actions(for query: String) async -> [LauncherAction] {
                guard !query.isEmpty else { return [] }
                return mockActions
            }
        }

        let registry = BuiltinPluginRegistry(plugins: [P(mockActions: actions)])
        registry.limitOverride = 5
        let result = await registry.actions(for: "app")
        XCTAssertEqual(result.count, 5, "截断到 limitOverride=5")
    }

    func test_registry_emptyQuery_returnsEmpty() async {
        let highAction = makeAction(id: "h1", title: "High", pluginId: "high", score: 100)
        let registry = BuiltinPluginRegistry(plugins: [
            HighPriorityPlugin(mockActions: [highAction])
        ])
        let result = await registry.actions(for: "")
        XCTAssertTrue(result.isEmpty, "空 query 应返回 []")
    }

    func test_registry_noHardSuppression() async {
        // 两个 plugin 都有结果，不硬抑制任一
        let highAction = makeAction(id: "h1", title: "High App", pluginId: "high", score: 100)
        let lowAction = makeAction(id: "l1", title: "Low App", pluginId: "low", score: 50)

        let registry = BuiltinPluginRegistry(plugins: [
            LowPriorityPlugin(mockActions: [lowAction]),
            HighPriorityPlugin(mockActions: [highAction])
        ])
        registry.limitOverride = 10

        let result = await registry.actions(for: "app")
        XCTAssertEqual(result.count, 2, "两个 plugin 的候选应都在结果中（不硬抑制）")
    }
}
