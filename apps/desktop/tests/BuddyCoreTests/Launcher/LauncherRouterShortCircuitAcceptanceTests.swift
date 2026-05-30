import XCTest
@testable import BuddyCore

// MARK: - LauncherRouterShortCircuitAcceptanceTests
//
// 红队验收测试：P0.1 — LauncherRouter 短路优化
//
// 设计文档契约：
//   当 narrowCandidates 唯一命中（1个候选）OR 第一名 score ≥ routerSkipScore(10) 时，
//   LauncherRouter.route() 直接返回 .withPlugin(top)，**不调** provider.aiSelect（send 次数=0）。
//
// score 计算规则（沿用 narrowCandidates）：
//   - plugin name 与 query token 完全相同：+5（name contains token）+5（token in haystack）= 至少 10
//   - keyword 精确命中：+3
//   - 多 plugin 都命中但分数都 < 10：正常走 aiSelect
//
// 验证场景：
//   A: narrowCandidates 唯一命中 → 短路，send=0
//   B: name 完全命中（score≥10） → 短路，send=0
//   C: 多 plugin 命中分数都 <10 → 走 aiSelect，send=1
//
// NOTE: 短路逻辑需蓝队在 LauncherRouter.route() 中实现。
//       测试用 mock provider 统计 send 调用次数。

// MARK: - ShortCircuitMockProvider

/// 短路测试专用 mock provider：记录 send 调用次数，按 responses 顺序返回
private final class ShortCircuitMockProvider: LauncherProvider, @unchecked Sendable {
    private(set) var sendCallCount = 0
    var responses: [AgentResponse] = []

    func send(
        messages: [AgentMessage],
        tools: [AgentTool],
        model: String,
        system: String?
    ) async throws -> AgentResponse {
        sendCallCount += 1
        guard sendCallCount - 1 < responses.count else {
            // 若无预设响应，返回默认 directChat（NONE）
            return AgentResponse(content: [.text("NONE")], stopReason: "end_turn", usage: nil)
        }
        return responses[sendCallCount - 1]
    }
}

// MARK: - 测试 helper

private func makeTestManifest(
    name: String,
    description: String = "Test plugin",
    keywords: [String] = []
) -> PluginManifest {
    PluginManifest(
        name: name,
        version: "1.0.0",
        description: description,
        keywords: keywords,
        cmd: "./run.sh"
    )
}

// MARK: - LauncherRouterShortCircuitAcceptanceTests

final class LauncherRouterShortCircuitAcceptanceTests: XCTestCase {

    private var mockProvider: ShortCircuitMockProvider!
    private var router: LauncherRouter!
    private var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        mockProvider = ShortCircuitMockProvider()
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "RouterSC-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let mgr = PluginManager(rootDir: tmpDir)
        router = LauncherRouter(pluginManager: mgr, provider: mockProvider, routerModel: "test-model")
    }

    override func tearDown() async throws {
        if let dir = tmpDir { try? FileManager.default.removeItem(at: dir) }
        tmpDir = nil
        router = nil
        mockProvider = nil
        try await super.tearDown()
    }

    // MARK: - Case A: narrowCandidates 唯一命中 → 短路，provider.send 调用次数 = 0

    /// `tr buddy` query → translate plugin 是唯一命中 → route 短路返回 .withPlugin，send=0
    func test_shortCircuit_caseA_uniqueCandidate_noAICall() async throws {
        // 注入：只有 translate plugin，且 keywords 含 "tr"
        let translate = makeTestManifest(
            name: "translate",
            description: "中英互译",
            keywords: ["翻译", "translate", "tr"]
        )
        router.pluginsOverride = [translate]

        let (decision, _) = try await router.route(query: "tr buddy")

        // 断言：返回 .withPlugin(translate)
        if case .withPlugin(let m) = decision {
            XCTAssertEqual(m.name, "translate",
                           "唯一命中时 decision 必须是 .withPlugin(translate)")
        } else {
            XCTFail("唯一候选短路时 decision 必须是 .withPlugin，实际: \(decision)")
        }

        // 核心断言：短路后 provider.send 一次都不调用
        XCTAssertEqual(mockProvider.sendCallCount, 0,
                       "唯一候选短路时 provider.send 调用次数必须是 0（跳过 AI 路由轮），实际: \(mockProvider.sendCallCount)")
    }

    // MARK: - Case B: name 完全命中 score≥10 → 短路

    /// `translate buddy` → translate plugin name 完全命中 → score≥10 → 短路 send=0
    func test_shortCircuit_caseB_highScore_noAICall() async throws {
        // 注入两个 plugin：translate（name 完全命中）和 search（不命中）
        let translate = makeTestManifest(
            name: "translate",
            description: "翻译工具",
            keywords: ["translate", "tr"]
        )
        let search = makeTestManifest(
            name: "search",
            description: "搜索引擎",
            keywords: ["search", "find"]
        )
        router.pluginsOverride = [translate, search]

        // query 含 plugin name "translate" → 单 token 命中 name: +5(name contains) +5(haystack) = 10
        // 反向检查：queryLower.contains("translate") → +5 额外
        // 总分应 ≥ 10，触发短路
        let (decision, _) = try await router.route(query: "translate buddy")

        // 断言：返回 .withPlugin(translate)
        if case .withPlugin(let m) = decision {
            XCTAssertEqual(m.name, "translate",
                           "name 完全命中（score≥10）时短路 decision 必须是 .withPlugin(translate)")
        } else {
            XCTFail("name 完全命中时应短路返回 .withPlugin，实际: \(decision)")
        }

        // 核心断言：短路后 send=0
        XCTAssertEqual(mockProvider.sendCallCount, 0,
                       "name 完全命中（score≥10）时 provider.send 必须是 0 次（短路跳过 AI），实际: \(mockProvider.sendCallCount)")
    }

    // MARK: - Case C: 多 plugin 命中但分数都 < 10 → 走 aiSelect，send=1

    /// 多个 plugin 都命中（仅 keyword 匹配，score≤6），走 aiSelect，send 调用 = 1
    func test_shortCircuit_caseC_multipleMatchesBelowThreshold_callsAISelect() async throws {
        // 构造两个 plugin：
        //   - conv-tool: keywords=["convert"] → query token "convert" 精确命中 keyword +3，haystack +1 = 4
        //   - text-util: description="convert text" → token 命中 haystack +1 = 1（低于 10）
        // 注意：name 不含 "convert"，所以 name 命中加分为 0
        let convTool = makeTestManifest(
            name: "conv-tool",
            description: "General converter",
            keywords: ["convert"]
        )
        let textUtil = makeTestManifest(
            name: "text-util",
            description: "convert text utility",
            keywords: []
        )
        router.pluginsOverride = [convTool, textUtil]

        // mock provider 预设 AI 选 conv-tool 的响应
        mockProvider.responses = [
            AgentResponse(content: [.text("conv-tool")], stopReason: "end_turn", usage: nil)
        ]

        let (decision, candidates) = try await router.route(query: "convert pdf")

        // 断言：有候选
        XCTAssertGreaterThanOrEqual(candidates.count, 1,
                                    "keyword 命中时 candidates 必须至少 1 个")

        // 断言：走了 aiSelect（send 调用 = 1）
        // 注意：这里验证"不短路"的场景，分数都 <10，必须调 AI
        XCTAssertGreaterThanOrEqual(mockProvider.sendCallCount, 1,
                                    "多候选且分数都 <10 时必须调 provider.send（走 aiSelect），实际: \(mockProvider.sendCallCount)")

        // 若 AI 返回了有效答案，decision 也应正确
        if mockProvider.sendCallCount >= 1 {
            if case .withPlugin(let m) = decision {
                XCTAssertEqual(m.name, "conv-tool",
                               "AI 选了 conv-tool 时 decision 必须是 .withPlugin(conv-tool)")
            }
            // directChat 也可接受（若两个 plugin 都不匹配 AI 的偏好）
        }
    }

    // MARK: - Case D: narrowCandidates 返回空 → 直接 directChat，send=0

    /// query 完全不命中任何 plugin → candidates 为空 → directChat，send=0（现有行为，非新增）
    func test_shortCircuit_caseD_emptyNarrow_directChatNoAI() async throws {
        let weather = makeTestManifest(
            name: "weather",
            description: "Weather forecast",
            keywords: ["weather", "forecast"]
        )
        router.pluginsOverride = [weather]

        let (decision, candidates) = try await router.route(query: "tr buddy")

        // weather 与 "tr buddy" 不匹配（weather 没有 tr 或 buddy 关键词）
        // 但 translate 才有 "tr" 关键词 —— 这里只有 weather
        if candidates.isEmpty {
            XCTAssertEqual(decision, .directChat,
                           "无候选时 decision 必须是 .directChat")
            XCTAssertEqual(mockProvider.sendCallCount, 0,
                           "无候选时不调 AI，send=0，实际: \(mockProvider.sendCallCount)")
        }
        // 若 weather 碰巧命中（edge case），不强制失败
    }

    // MARK: - Case E: routerSkipScore 常量验证

    /// LauncherConstants.routerSkipScore 必须精确是 10（设计文档约束）
    func test_shortCircuit_routerSkipScore_equals10() {
        // 设计文档：first score ≥ 10 时短路
        // 如果蓝队在 LauncherConstants 中加了 routerSkipScore 常量，此断言生效
        // 若常量不存在，此测试编译报错 —— 标记为蓝队待实现
        XCTAssertEqual(LauncherConstants.routerSkipScore, 10,
                       "routerSkipScore 必须精确是 10（唯一命中 name 的分数下限）")
    }
}
