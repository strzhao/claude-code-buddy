import XCTest
@testable import BuddyCore

// MARK: - BuiltinRegistryArbitrationAcceptanceTests
//
// 红队验收测试：C10 BuiltinPluginRegistry 跨 plugin 仲裁契约 + C1/C2 协议扩展性
//
// 契约覆盖：
//   C1：BuiltinPlugin 协议签名（id, priority, sectionTitle, actions(for:)）
//   C2：LauncherAction 结构（id, title, subtitle, icon, pluginId, score, perform，Identifiable）
//   C10-a：全局排序键 = (priority 降序, score 降序, title 字典序)
//   C10-b：全局截断到 builtinActionsLimit（不超过限制）
//   C10-c：不硬抑制任何 plugin（多 plugin 同时命中，高 priority 在上）
//   C10-d：单 plugin 退化为纯 score 列表
//   C10-e：场景 13 协议扩展性最小验证（第二个 mock plugin 可注册聚合）
//
// 红队红线：不读取 BuiltinPluginRegistry.swift / AppLauncherPlugin.swift 实现。
// 测试 WILL NOT compile 直到蓝队合并实现 — 这是预期的 TDD 红灯。

// MARK: - Mock BuiltinPlugin

/// 测试专用：固定返回预设 LauncherAction 列表的内置插件。
@MainActor
private final class MockBuiltinPlugin: BuiltinPlugin {
    let id: String
    let priority: Int
    let sectionTitle: String
    private let fixedActions: [LauncherAction]

    init(id: String, priority: Int, sectionTitle: String, actions: [LauncherAction]) {
        self.id = id
        self.priority = priority
        self.sectionTitle = sectionTitle
        self.fixedActions = actions
    }

    func actions(for query: String) async -> [LauncherAction] {
        // 空 query 返回空（遵守 C4-e / C10 语义）
        guard !query.isEmpty else { return [] }
        return fixedActions
    }
}

// MARK: - Helper：构造 LauncherAction（不依赖实现细节）

@MainActor
private func makeAction(
    id: String,
    title: String,
    pluginId: String,
    score: Int
) -> LauncherAction {
    LauncherAction(
        id: id,
        title: title,
        subtitle: nil,
        icon: nil,
        pluginId: pluginId,
        score: score,
        perform: { /* mock：不执行任何操作 */ }
    )
}

// MARK: - 测试类

@MainActor
final class BuiltinRegistryArbitrationAcceptanceTests: XCTestCase {

    // MARK: - C10-a：全局排序 (priority↓, score↓, title 字典序)

    /// 两个 plugin：高 priority（p=10）+ 低 priority（p=0）。
    /// 高 priority plugin 的所有候选必须排在低 priority plugin 之前（即使低 priority 分更高）。
    func test_C10a_highPriorityPlugin_sortedBeforeLowPriority() async {
        // 低 priority plugin：分很高（1000）但 priority=0
        let lowPPlugin = MockBuiltinPlugin(
            id: "low-p",
            priority: 0,
            sectionTitle: "Low P",
            actions: [
                makeAction(id: "lp1", title: "BetaAction", pluginId: "low-p", score: 1000),
                makeAction(id: "lp2", title: "AlphaAction", pluginId: "low-p", score: 900),
            ]
        )

        // 高 priority plugin：分较低（500）但 priority=10
        let highPPlugin = MockBuiltinPlugin(
            id: "high-p",
            priority: 10,
            sectionTitle: "High P",
            actions: [
                makeAction(id: "hp1", title: "ZetaAction", pluginId: "high-p", score: 500),
                makeAction(id: "hp2", title: "GammaAction", pluginId: "high-p", score: 400),
            ]
        )

        let registry = BuiltinPluginRegistry(plugins: [lowPPlugin, highPPlugin])
        let result = await registry.actions(for: "test")

        XCTAssertFalse(result.isEmpty, "C10-a: 聚合结果不能为空")

        // 高 priority plugin 的候选（pluginId="high-p"）必须全部排在低 priority 候选（pluginId="low-p"）之前
        let highPIndices = result.enumerated().filter { $0.element.pluginId == "high-p" }.map { $0.offset }
        let lowPIndices  = result.enumerated().filter { $0.element.pluginId == "low-p"  }.map { $0.offset }

        guard let lastHighP = highPIndices.max(), let firstLowP = lowPIndices.min() else {
            XCTFail("C10-a: 两个 plugin 的候选都应出现在结果中")
            return
        }

        XCTAssertLessThan(lastHighP, firstLowP,
            "C10-a: 高 priority(10) plugin 的最后一个候选(位置\(lastHighP)) 必须排在低 priority(0) plugin 的第一个候选(位置\(firstLowP))之前")
    }

    /// 同 priority 内，按 score 降序排列。
    func test_C10a_samePriority_sortedByScoreDescending() async {
        let actions = [
            makeAction(id: "a1", title: "LowScore",  pluginId: "p1", score: 10),
            makeAction(id: "a2", title: "HighScore",  pluginId: "p1", score: 100),
            makeAction(id: "a3", title: "MidScore",   pluginId: "p1", score: 50),
        ]
        let plugin = MockBuiltinPlugin(id: "p1", priority: 0, sectionTitle: "Test", actions: actions)
        let registry = BuiltinPluginRegistry(plugins: [plugin])
        let result = await registry.actions(for: "q")

        XCTAssertEqual(result.count, 3, "C10-a: 应返回全部 3 条")
        // 按 score 降序：100, 50, 10
        XCTAssertEqual(result[0].score, 100, "C10-a: 第1条 score 应为 100，实际 \(result[0].score)")
        XCTAssertEqual(result[1].score, 50,  "C10-a: 第2条 score 应为 50，实际 \(result[1].score)")
        XCTAssertEqual(result[2].score, 10,  "C10-a: 第3条 score 应为 10，实际 \(result[2].score)")
    }

    /// 同 priority + 同 score，按 title 字典序排列。
    func test_C10a_samePriorityAndScore_sortedByTitleLexicographic() async {
        let actions = [
            makeAction(id: "z", title: "Zeta",  pluginId: "p1", score: 100),
            makeAction(id: "a", title: "Alpha", pluginId: "p1", score: 100),
            makeAction(id: "m", title: "Mu",    pluginId: "p1", score: 100),
        ]
        let plugin = MockBuiltinPlugin(id: "p1", priority: 0, sectionTitle: "Test", actions: actions)
        let registry = BuiltinPluginRegistry(plugins: [plugin])
        let result = await registry.actions(for: "q")

        XCTAssertEqual(result.count, 3, "C10-a: 应返回全部 3 条")
        // 字典序：Alpha < Mu < Zeta
        XCTAssertEqual(result[0].title, "Alpha", "C10-a: 同分时第1条按字典序应为 'Alpha'，实际 \(result[0].title)")
        XCTAssertEqual(result[1].title, "Mu",    "C10-a: 同分时第2条按字典序应为 'Mu'，实际 \(result[1].title)")
        XCTAssertEqual(result[2].title, "Zeta",  "C10-a: 同分时第3条按字典序应为 'Zeta'，实际 \(result[2].title)")
    }

    // MARK: - C10-b：全局截断到 builtinActionsLimit

    /// 注入超过 limit 的候选，断言结果不超过 builtinActionsLimit（设计文档示例值 8）。
    func test_C10b_globalLimit_truncatesTotal() async {
        // 注入 15 条高分候选
        let actions = (1...15).map { i in
            makeAction(id: "a\(i)", title: "Action\(i)", pluginId: "p1", score: 100 - i)
        }
        let plugin = MockBuiltinPlugin(id: "p1", priority: 0, sectionTitle: "Test", actions: actions)
        let registry = BuiltinPluginRegistry(plugins: [plugin])
        let result = await registry.actions(for: "q")

        XCTAssertLessThanOrEqual(result.count, LauncherConstants.builtinActionsLimit,
            "C10-b: 聚合结果必须截断到 builtinActionsLimit(\(LauncherConstants.builtinActionsLimit))，实际 \(result.count) 条")
    }

    /// 两个 plugin 各有候选，合计超过 limit，断言合并后仍截断。
    func test_C10b_twoPlugins_globalLimitAppliedAfterMerge() async {
        let actionsA = (1...8).map { i in
            makeAction(id: "a\(i)", title: "ActionA\(i)", pluginId: "pa", score: 200 - i)
        }
        let actionsB = (1...8).map { i in
            makeAction(id: "b\(i)", title: "ActionB\(i)", pluginId: "pb", score: 100 - i)
        }
        let pluginA = MockBuiltinPlugin(id: "pa", priority: 10, sectionTitle: "A", actions: actionsA)
        let pluginB = MockBuiltinPlugin(id: "pb", priority: 0,  sectionTitle: "B", actions: actionsB)

        let registry = BuiltinPluginRegistry(plugins: [pluginA, pluginB])
        let result = await registry.actions(for: "q")

        XCTAssertLessThanOrEqual(result.count, LauncherConstants.builtinActionsLimit,
            "C10-b: 两个 plugin 合并后仍截断到 builtinActionsLimit(\(LauncherConstants.builtinActionsLimit))，实际 \(result.count) 条")
    }

    // MARK: - C10-c：不硬抑制任何 plugin（多 plugin 同时命中）

    /// 低 priority plugin 的候选不会被完全抹去，只是排在后面（不硬抑制）。
    func test_C10c_noHardSuppression_lowPriorityStillAppears() async {
        let highPActions = (1...3).map { i in
            makeAction(id: "hp\(i)", title: "HighPAction\(i)", pluginId: "high-p", score: 100)
        }
        let lowPActions = [
            makeAction(id: "lp1", title: "LowPAction1", pluginId: "low-p", score: 500),
        ]
        let highP = MockBuiltinPlugin(id: "high-p", priority: 10, sectionTitle: "H", actions: highPActions)
        let lowP  = MockBuiltinPlugin(id: "low-p",  priority: 0,  sectionTitle: "L", actions: lowPActions)

        let registry = BuiltinPluginRegistry(plugins: [highP, lowP])
        let result = await registry.actions(for: "q")

        // 低 priority plugin 的候选应出现（不被硬抑制）
        let hasLowP = result.contains { $0.pluginId == "low-p" }
        XCTAssertTrue(hasLowP,
            "C10-c: 低 priority plugin 候选不能被硬抑制，必须出现在结果中（只是排在高 priority 之后）")

        // 但高 priority 组排在前面
        let firstLowPIdx  = result.firstIndex { $0.pluginId == "low-p" }
        let lastHighPIdx  = result.lastIndex  { $0.pluginId == "high-p" }
        if let lp = firstLowPIdx, let hp = lastHighPIdx {
            XCTAssertGreaterThan(lp, hp,
                "C10-c: 低 priority 的第一条(位置\(lp))应排在高 priority 的最后一条(位置\(hp))之后")
        }
    }

    // MARK: - C10-d：单 plugin 退化为纯 score 列表

    /// 只有 1 个 plugin 时，结果 = 该 plugin 的 actions 按 score 降序（无 sectionTitle 分组影响）。
    func test_C10d_singlePlugin_pureScoreList() async {
        let actions = [
            makeAction(id: "a1", title: "C", pluginId: "only", score: 10),
            makeAction(id: "a2", title: "A", pluginId: "only", score: 30),
            makeAction(id: "a3", title: "B", pluginId: "only", score: 20),
        ]
        let plugin = MockBuiltinPlugin(id: "only", priority: 0, sectionTitle: "Only", actions: actions)
        let registry = BuiltinPluginRegistry(plugins: [plugin])
        let result = await registry.actions(for: "q")

        XCTAssertEqual(result.count, 3, "C10-d: 单 plugin 应返回全部 3 条")
        // 按 score 降序：30, 20, 10
        XCTAssertEqual(result[0].score, 30, "C10-d: score 降序第1: 30，实际 \(result[0].score)")
        XCTAssertEqual(result[1].score, 20, "C10-d: score 降序第2: 20，实际 \(result[1].score)")
        XCTAssertEqual(result[2].score, 10, "C10-d: score 降序第3: 10，实际 \(result[2].score)")
    }

    // MARK: - C10-e + 场景 13：协议扩展性最小验证

    /// 第二个 mock plugin（模拟"计算器"）可注册到 Registry 并参与聚合——
    /// 验证协议零侵入扩展性，不要求计算器真实实现。
    func test_C10e_scenario13_secondMockPlugin_aggregatesCorrectly() async {
        let appPlugin = MockBuiltinPlugin(
            id: "app-launcher",
            priority: 0,
            sectionTitle: "应用",
            actions: [
                makeAction(id: "app1", title: "Safari", pluginId: "app-launcher", score: 80),
            ]
        )
        let calcPlugin = MockBuiltinPlugin(
            id: "calculator",
            priority: 10,    // 计算器属解释器型，给高 priority
            sectionTitle: "计算",
            actions: [
                makeAction(id: "calc1", title: "= 42", pluginId: "calculator", score: 1000),
            ]
        )

        // 注入两个 plugin，零侵入 Registry（场景 13：协议扩展性）
        let registry = BuiltinPluginRegistry(plugins: [appPlugin, calcPlugin])
        let result = await registry.actions(for: "q")

        // 两个 plugin 的候选都应出现
        let hasApp  = result.contains { $0.pluginId == "app-launcher" }
        let hasCalc = result.contains { $0.pluginId == "calculator" }
        XCTAssertTrue(hasApp,  "C10-e: app-launcher plugin 候选必须出现")
        XCTAssertTrue(hasCalc, "C10-e: calculator plugin 候选必须出现")

        // calculator（priority=10）排在 app-launcher（priority=0）之前
        let calcIdx = result.firstIndex { $0.pluginId == "calculator" }
        let appIdx  = result.firstIndex { $0.pluginId == "app-launcher" }
        if let ci = calcIdx, let ai = appIdx {
            XCTAssertLessThan(ci, ai,
                "C10-e（场景 13）: calculator(priority=10) 必须排在 app-launcher(priority=0) 之前")
        }
    }

    // MARK: - C1：BuiltinPlugin 协议签名验证（协议可被任意实现）

    /// 任意遵守 BuiltinPlugin 协议的类型可被 Registry 接受——无需改 Registry。
    func test_C1_builtinPlugin_protocol_anyConformanceAccepted() async {
        // MockBuiltinPlugin 遵守 BuiltinPlugin 协议，可直接传入 Registry
        let p1 = MockBuiltinPlugin(id: "mock-1", priority: 5, sectionTitle: "M1",
            actions: [makeAction(id: "m1a", title: "MockAction", pluginId: "mock-1", score: 50)])
        let registry = BuiltinPluginRegistry(plugins: [p1])

        // 调用 actions(for:)，协议方法签名正确
        let result = await registry.actions(for: "q")
        XCTAssertFalse(result.isEmpty, "C1: 任意 BuiltinPlugin 实现必须可被 Registry 聚合")
    }

    // MARK: - C2：LauncherAction 结构字段

    /// LauncherAction 包含 id, title, pluginId, score 字段，且 Identifiable（id 唯一标识）。
    func test_C2_launcherAction_identifiable_fieldAccess() {
        let action = makeAction(id: "test-id", title: "TestTitle", pluginId: "test-plugin", score: 42)
        XCTAssertEqual(action.id, "test-id",         "C2: id 字段正确")
        XCTAssertEqual(action.title, "TestTitle",    "C2: title 字段正确")
        XCTAssertEqual(action.pluginId, "test-plugin","C2: pluginId 字段正确")
        XCTAssertEqual(action.score, 42,             "C2: score 字段正确")
    }

    /// LauncherAction.perform 可 throw（() throws -> Void），签名正确。
    func test_C2_launcherAction_performCanThrow() {
        var performed = false
        let action = LauncherAction(
            id: "throw-test",
            title: "ThrowTest",
            subtitle: nil,
            icon: nil,
            pluginId: "test",
            score: 0,
            perform: { performed = true }
        )
        XCTAssertNoThrow(try action.perform(), "C2: perform 不抛错时应正常执行")
        XCTAssertTrue(performed, "C2: perform 被调用后 side effect 生效")
    }

    // MARK: - 空 query 场景

    /// 空 query 时 Registry 返回 []（遵守 C4-e 语义，所有 plugin 均不返回候选）。
    func test_emptyQuery_registryReturnsEmpty() async {
        let plugin = MockBuiltinPlugin(
            id: "p1",
            priority: 0,
            sectionTitle: "Test",
            actions: [makeAction(id: "a1", title: "Something", pluginId: "p1", score: 100)]
        )
        let registry = BuiltinPluginRegistry(plugins: [plugin])
        let result = await registry.actions(for: "")

        XCTAssertTrue(result.isEmpty,
            "空 query 时 Registry 必须返回 []，实际 \(result.count) 条")
    }
}
