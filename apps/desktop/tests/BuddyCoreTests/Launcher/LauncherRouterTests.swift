import XCTest
@testable import BuddyCore

// MARK: - RouterMockProvider

/// 固定回复的 mock provider，用于 router 单元测试（区别于 LauncherAgentTests 里的 MockProvider）
private final class RouterMockProvider: LauncherProvider {
    let reply: String

    init(reply: String) {
        self.reply = reply
    }

    func send(messages: [AgentMessage], tools: [AgentTool], model: String, system: String?) async throws -> AgentResponse {
        AgentResponse(
            content: [.text(reply)],
            stopReason: "end_turn",
            usage: nil
        )
    }
}

// MARK: - Helper

private func makeManifest(name: String, description: String, keywords: [String] = []) -> PluginManifest {
    PluginManifest(
        name: name,
        version: "1.0.0",
        description: description,
        keywords: keywords,
        cmd: "./run.sh",
        args: [],
        env: nil,
        timeout: nil,
        requiredPath: nil
    )
}

// MARK: - Tests

final class LauncherRouterTests: XCTestCase {

    // MARK: narrowCandidates

    /// 场景 1：评分算法（name +5/kw +3/contains +1）
    func test_narrowCandidates_scoringAlgorithm() {
        let translate = makeManifest(name: "translate", description: "Translate text", keywords: ["translation"])
        let search = makeManifest(name: "search", description: "Search the web", keywords: ["web"])
        let calc = makeManifest(name: "calc", description: "Calculator tool", keywords: ["math"])

        let provider = RouterMockProvider(reply: "NONE")
        let router = LauncherRouter(
            pluginManager: PluginManager(rootDir: URL(fileURLWithPath: "/nonexistent")),
            provider: provider,
            routerModel: "test-model"
        )

        // "translate" 命中 name(+5) + desc contains(+1) + kw contains(+1)
        let results = router.narrowCandidates(query: "translate this text", plugins: [translate, search, calc])
        XCTAssertEqual(results.first?.name, "translate")
        XCTAssertTrue(results.count >= 1)
        // search 和 calc 不命中
        XCTAssertFalse(results.contains { $0.name == "calc" })
    }

    /// 场景 2：空 plugin 列表 → directChat，不调 provider
    func test_narrowCandidates_emptyPlugins_returnsEmpty() {
        let provider = RouterMockProvider(reply: "NONE")
        let router = LauncherRouter(
            pluginManager: PluginManager(rootDir: URL(fileURLWithPath: "/nonexistent")),
            provider: provider,
            routerModel: "test-model"
        )
        let result = router.narrowCandidates(query: "hello", plugins: [])
        XCTAssertTrue(result.isEmpty)
    }

    /// 场景 3：keyword 不匹配 → 候选为空（不调 provider.send）
    func test_narrowCandidates_noMatch_returnsEmpty() {
        let translate = makeManifest(name: "translate", description: "Translate text", keywords: ["translation"])
        let provider = RouterMockProvider(reply: "translate")
        let router = LauncherRouter(
            pluginManager: PluginManager(rootDir: URL(fileURLWithPath: "/nonexistent")),
            provider: provider,
            routerModel: "test-model"
        )
        let result = router.narrowCandidates(query: "calculate 1+1", plugins: [translate])
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: aiSelect

    /// 场景 4：keyword 匹配 + AI 选中 → (.withPlugin, candidates)
    func test_aiSelect_aiPicksPlugin() async throws {
        let translate = makeManifest(name: "translate", description: "Translate text", keywords: ["translation"])
        let provider = RouterMockProvider(reply: "translate")
        let router = LauncherRouter(
            pluginManager: PluginManager(rootDir: URL(fileURLWithPath: "/nonexistent")),
            provider: provider,
            routerModel: "test-model"
        )
        let decision = try await router.aiSelect(query: "translate this", candidates: [translate])
        XCTAssertEqual(decision, .withPlugin(translate))
    }

    /// 场景 5：keyword 匹配 + AI NONE → (.directChat, candidates)
    func test_aiSelect_aiReturnsNONE_directChat() async throws {
        let translate = makeManifest(name: "translate", description: "Translate text", keywords: ["translation"])
        let provider = RouterMockProvider(reply: "NONE")
        let router = LauncherRouter(
            pluginManager: PluginManager(rootDir: URL(fileURLWithPath: "/nonexistent")),
            provider: provider,
            routerModel: "test-model"
        )
        let decision = try await router.aiSelect(query: "translate this", candidates: [translate])
        XCTAssertEqual(decision, .directChat)
    }

    /// 场景 6：AI hallucinate 非候选名 → (.directChat) 兜底
    func test_aiSelect_aiHallucinate_fallbackDirectChat() async throws {
        let translate = makeManifest(name: "translate", description: "Translate text", keywords: ["translation"])
        let provider = RouterMockProvider(reply: "nonexistent-plugin-xyz")
        let router = LauncherRouter(
            pluginManager: PluginManager(rootDir: URL(fileURLWithPath: "/nonexistent")),
            provider: provider,
            routerModel: "test-model"
        )
        let decision = try await router.aiSelect(query: "translate this", candidates: [translate])
        XCTAssertEqual(decision, .directChat)
    }

    // MARK: routerMaxCandidates

    /// 候选列表最多 5 个
    func test_narrowCandidates_maxCandidates() {
        let plugins = (1...10).map { i in
            makeManifest(name: "plugin\(i)", description: "tool \(i)", keywords: ["helper"])
        }
        let provider = RouterMockProvider(reply: "NONE")
        let router = LauncherRouter(
            pluginManager: PluginManager(rootDir: URL(fileURLWithPath: "/nonexistent")),
            provider: provider,
            routerModel: "test-model"
        )
        let result = router.narrowCandidates(query: "helper", plugins: plugins)
        XCTAssertLessThanOrEqual(result.count, LauncherConstants.routerMaxCandidates)
    }

    // MARK: Chinese query

    /// 场景 9：中文 query（plugin keywords=["翻译"] + query="请翻译这段" → 命中）
    func test_narrowCandidates_chineseQuery_matches() {
        let translate = makeManifest(name: "translate", description: "翻译工具", keywords: ["翻译"])
        let provider = RouterMockProvider(reply: "NONE")
        let router = LauncherRouter(
            pluginManager: PluginManager(rootDir: URL(fileURLWithPath: "/nonexistent")),
            provider: provider,
            routerModel: "test-model"
        )
        let result = router.narrowCandidates(query: "请翻译这段", plugins: [translate])
        XCTAssertFalse(result.isEmpty, "中文 query 应命中 keywords=[\"翻译\"] 的 plugin")
        XCTAssertEqual(result.first?.name, "translate")
    }
}
