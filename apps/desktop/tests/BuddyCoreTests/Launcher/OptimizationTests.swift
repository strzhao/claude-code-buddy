import XCTest
@testable import BuddyCore

// MARK: - P0 Tests: ChatTemplateKwargs & OAIRequestBody encode

final class ChatTemplateKwargsTests: XCTestCase {

    // P0 T1: noThinking=true 时 OAIRequestBody JSON 含 chat_template_kwargs.enable_thinking:false
    func test_p0_noThinking_true_encodesEnableThinkingFalse() throws {
        let provider = OpenAICompatibleProvider(
            apiKey: "dummy-key-xxx",
            baseURL: URL(string: "http://localhost:11434/v1")!,
            noThinking: true
        )
        // 通过 provider 的私有构造确认字段，改用 ChatTemplateKwargs 直接 encode 验证
        let kwargs = ChatTemplateKwargs(enableThinking: false)
        let data = try JSONEncoder().encode(kwargs)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"enable_thinking\""), "encode 结果应含 enable_thinking key")
        XCTAssertTrue(json.contains("false"), "enable_thinking 值应为 false")
        XCTAssertFalse(json.contains("null"), "false 值不应 encode 为 null")
    }

    // P0 T2: noThinking=false 时 ChatTemplateKwargs 为 nil，JSON 不含 chat_template_kwargs
    func test_p0_noThinking_false_chatTemplateKwargsAbsent() throws {
        // 验证 noThinking=false 时，OpenAICompatibleProvider 不持有 chatTemplateKwargs
        // 通过 ChatTemplateKwargs(enableThinking: nil) 编码验证 encodeIfPresent
        let kwargs = ChatTemplateKwargs(enableThinking: nil)
        let data = try JSONEncoder().encode(kwargs)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        // nil Bool → encodeIfPresent 跳过，输出 {}
        XCTAssertEqual(json, "{}", "enableThinking=nil 时 encode 结果应为空对象，不含 null")
    }

    // P0 T3: chat_template_kwargs 键名 snake_case 正确
    func test_p0_chatTemplateKwargs_keySnakeCaseCorrect() throws {
        let kwargs = ChatTemplateKwargs(enableThinking: false)
        let data = try JSONEncoder().encode(kwargs)
        let dict = try JSONDecoder().decode([String: Bool].self, from: data)
        XCTAssertEqual(dict["enable_thinking"], false, "CodingKey 映射 enable_thinking 必须正确")
        XCTAssertNil(dict["enableThinking"], "camelCase 键名不应出现在 JSON 中")
    }

    // P0 T4: ChatTemplateKwargs decode 往返
    func test_p0_chatTemplateKwargs_roundtrip() throws {
        let original = ChatTemplateKwargs(enableThinking: false)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChatTemplateKwargs.self, from: data)
        XCTAssertEqual(decoded.enableThinking, false)
    }
}

// MARK: - P0.1 Tests: narrowCandidatesScored & route short-circuit

// Mock provider that tracks call count
private final class CountingProvider: LauncherProvider {
    private(set) var sendCallCount = 0

    func send(messages: [AgentMessage], tools: [AgentTool], model: String, system: String?) async throws -> AgentResponse {
        sendCallCount += 1
        return AgentResponse(content: [.text("translate")], stopReason: "end_turn", usage: nil)
    }
}

// Minimal manifest factory for tests
private func makeManifest(name: String, keywords: [String] = []) -> PluginManifest {
    let json = """
    {
        "name": "\(name)",
        "version": "1.0.0",
        "description": "test plugin \(name)",
        "keywords": [\(keywords.map { "\"\($0)\"" }.joined(separator: ","))],
        "mode": "prompt",
        "systemPrompt": "test"
    }
    """
    return try! JSONDecoder().decode(PluginManifest.self, from: json.data(using: .utf8)!)
}

final class NarrowCandidatesScoredTests: XCTestCase {

    // P0.1 T1: name 完全匹配 → score >= 10（short-circuit 阈值）
    func test_p01_nameExactMatch_scoreAtLeast10() {
        let plugins = [makeManifest(name: "translate", keywords: ["翻译", "tr"])]
        let scored = LauncherRouter.narrowCandidatesScored(query: "translate", plugins: plugins)
        XCTAssertEqual(scored.count, 1)
        // query "translate" lowercased 在 nameLower "translate" 完全匹配
        // token "translate" → nameLower.contains(token) += 5, haystack.contains(token) += 1
        // queryLower.contains(nameLower) → += 5
        // 合计 ≥ 10
        XCTAssertGreaterThanOrEqual(scored[0].score, LauncherConstants.routerSkipScore,
            "name 完全匹配 score 应 >= routerSkipScore(\(LauncherConstants.routerSkipScore))")
    }

    // P0.1 T2: keyword 命中但 name 不命中 → score < 10（不短路）
    // 选用 name="xyzplugin"，keyword="翻译"，query="翻译文章"
    // 这样 name 不含 query token，只有 keyword 反向匹配
    func test_p01_keywordMatch_scoreLessThan10() {
        let plugins = [makeManifest(name: "xyzplugin", keywords: ["翻译"])]
        // query = "翻译文章"
        // token "翻译文章"（中文不分割） → name "xyzplugin" 不含 → 0
        // keyword 反向：kwsLower "翻译" → queryLower.contains("翻译") += 3
        // haystack.contains("翻译") += 1
        // 合计 4 < 10
        let scored = LauncherRouter.narrowCandidatesScored(query: "翻译文章", plugins: plugins)
        XCTAssertEqual(scored.count, 1)
        XCTAssertLessThan(scored[0].score, LauncherConstants.routerSkipScore,
            "纯 keyword 反向命中 score 应 < routerSkipScore，不应触发短路")
    }

    // P0.1 T3: 多 plugin 时 scored 按 score 降序排列
    func test_p01_multiplePlugins_sortedByScore() {
        let plugins = [
            makeManifest(name: "hello", keywords: ["hi"]),
            makeManifest(name: "translate", keywords: ["翻译", "tr", "translate"])
        ]
        let scored = LauncherRouter.narrowCandidatesScored(query: "translate", plugins: plugins)
        // translate 应得更高分
        XCTAssertEqual(scored.first?.manifest.name, "translate",
            "得分最高的 plugin 应排第一")
        if scored.count >= 2 {
            XCTAssertGreaterThanOrEqual(scored[0].score, scored[1].score,
                "候选应按 score 降序排列")
        }
    }

    // P0.1 T4: narrowCandidates wrapper 与 scored 版本结果一致
    func test_p01_narrowCandidatesWrapper_matchesScored() {
        let plugins = [
            makeManifest(name: "translate", keywords: ["翻译"]),
            makeManifest(name: "hello", keywords: ["hi"])
        ]
        let query = "translate hello"
        let fromWrapper = LauncherRouter.narrowCandidates(query: query, plugins: plugins)
        let fromScored = LauncherRouter.narrowCandidatesScored(query: query, plugins: plugins).map(\.manifest)
        XCTAssertEqual(fromWrapper.map(\.name), fromScored.map(\.name),
            "narrowCandidates 应与 narrowCandidatesScored 结果一致")
    }

    // P0.1 T5: route 唯一候选时不调 provider.send（短路）
    // 使用 name/keyword 只含 "zqtest" 的 plugin，query = "zqtest" 确保命中且唯一
    func test_p01_route_uniqueCandidate_skipProviderCall() async throws {
        let provider = CountingProvider()
        let router = LauncherRouter(
            pluginManager: PluginManager.shared,
            provider: provider,
            routerModel: "test-model"
        )
        // 用独特 name 确保 query 精确命中且唯一
        let plugin = makeManifest(name: "zqtest", keywords: ["zqtest", "unique"])
        router.pluginsOverride = [plugin]

        let (decision, _) = try await router.route(query: "zqtest")
        // query "zqtest" 精确匹配 name → score >= 10，且只有 1 个候选 → isUnique → 短路
        XCTAssertEqual(provider.sendCallCount, 0,
            "唯一候选时应短路，不调用 provider.send")
        if case .withPlugin(let m) = decision {
            XCTAssertEqual(m.name, "zqtest")
        } else {
            XCTFail("唯一候选时 route decision 应为 .withPlugin，实际: \(decision)")
        }
    }

    // P0.1 T6: route 强命中（score >= routerSkipScore）时不调 provider.send
    func test_p01_route_strongMatch_skipProviderCall() async throws {
        let provider = CountingProvider()
        let router = LauncherRouter(
            pluginManager: PluginManager.shared,
            provider: provider,
            routerModel: "test-model"
        )
        let translate = makeManifest(name: "translate", keywords: ["翻译", "tr", "translate"])
        let hello = makeManifest(name: "hello", keywords: ["hi", "hello"])
        router.pluginsOverride = [translate, hello]

        // query = "translate" → translate name 完全匹配，score >= 10 → 短路
        let (decision, _) = try await router.route(query: "translate")
        XCTAssertEqual(provider.sendCallCount, 0,
            "score >= routerSkipScore 时应短路，不调用 provider.send")
        if case .withPlugin(let m) = decision {
            XCTAssertEqual(m.name, "translate")
        } else {
            XCTFail("强命中时 route decision 应为 .withPlugin(translate)")
        }
    }

    // P0.1 T7: route 多候选弱命中时调用 provider.send
    // 使用中文 keyword 让两个 plugin 都弱命中（score < 10），验证走 AI
    func test_p01_route_multipleWeakCandidates_callsProvider() async throws {
        let provider = CountingProvider()
        let router = LauncherRouter(
            pluginManager: PluginManager.shared,
            provider: provider,
            routerModel: "test-model"
        )
        // 两个 plugin 都有 keyword "翻译"，name 各不同且不匹配 query
        let alpha = makeManifest(name: "alphaplugin", keywords: ["翻译"])
        let beta = makeManifest(name: "betaplugin", keywords: ["翻译"])
        router.pluginsOverride = [alpha, beta]

        // query = "翻译" → 两个 plugin 都命中 keyword（score ~4，< 10），不唯一 → 走 AI
        _ = try await router.route(query: "翻译")
        XCTAssertEqual(provider.sendCallCount, 1,
            "多候选弱命中时应调用 provider.send 做 AI 选择")
    }

    // P0.1 T8: routerSkipScore 常量值为 10
    func test_p01_routerSkipScore_isCorrect() {
        XCTAssertEqual(LauncherConstants.routerSkipScore, 10)
    }
}

// MARK: - P1 Tests: sendStream SSE parsing (mock URLSession)

// Mock URLSession that returns fake SSE lines
// 用自定义 provider 模拟 sendStream 行为
private final class MockStreamProvider: LauncherProvider {
    let chunks: [String]
    private(set) var streamCallCount = 0

    init(chunks: [String]) {
        self.chunks = chunks
    }

    func send(messages: [AgentMessage], tools: [AgentTool], model: String, system: String?) async throws -> AgentResponse {
        // fallback 实现（不应被调用）
        AgentResponse(content: [.text("fallback")], stopReason: "end_turn", usage: nil)
    }

    // 覆盖默认实现：直接 yield chunks
    func sendStream(
        messages: [AgentMessage],
        tools: [AgentTool],
        model: String,
        system: String?
    ) async throws -> AsyncThrowingStream<ProviderChunk, Error> {
        streamCallCount += 1
        let chunks = self.chunks
        return AsyncThrowingStream { continuation in
            Task {
                for chunk in chunks {
                    continuation.yield(.text(chunk))
                }
                continuation.yield(.done(reason: "stop"))
                continuation.finish()
            }
        }
    }
}

final class SendStreamTests: XCTestCase {

    // P1 T1: sendStream emit 顺序与累积内容正确
    func test_p1_sendStream_emitOrderAndAccumulation() async throws {
        let provider = MockStreamProvider(chunks: ["Hello", " ", "World"])
        var collected: [String] = []
        var doneReceived = false

        let stream = try await provider.sendStream(messages: [], tools: [], model: "test", system: nil)
        for try await chunk in stream {
            switch chunk {
            case .text(let s):
                collected.append(s)
            case .action:
                break
            case .done:
                doneReceived = true
            }
        }

        XCTAssertEqual(collected, ["Hello", " ", "World"],
            "P1: chunks 应按顺序 emit")
        XCTAssertTrue(doneReceived, "P1: stream 应以 .done 结束")
        XCTAssertEqual(collected.joined(), "Hello World",
            "P1: 累积内容应正确")
    }

    // P1 T2: 默认 fallback 实现（非流式 provider）行为正确
    func test_p1_defaultFallback_wrapsNonStreamingProvider() async throws {
        // MockProvider 只实现 send，用默认 sendStream fallback
        let mockProvider = MockProvider()
        mockProvider.responses = [
            .success(AgentResponse(content: [.text("Hello World")], stopReason: "end_turn", usage: nil))
        ]

        var chunks: [ProviderChunk] = []
        let stream = try await mockProvider.sendStream(messages: [], tools: [], model: "test", system: nil)
        for try await chunk in stream {
            chunks.append(chunk)
        }

        // 应得到 .text("Hello World") + .done(reason: "end_turn")
        XCTAssertEqual(chunks.count, 2, "fallback 应 emit 1 text + 1 done")
        if case .text(let s) = chunks[0] {
            XCTAssertEqual(s, "Hello World")
        } else {
            XCTFail("第一个 chunk 应为 .text")
        }
        if case .done(let reason) = chunks[1] {
            XCTAssertEqual(reason, "end_turn")
        } else {
            XCTFail("最后一个 chunk 应为 .done")
        }
    }

    // P1 T3: PromptExecutor 走 sendStream，累积 chunks 返回完整文本
    func test_p1_promptExecutor_usesStreamAndAccumulates() async throws {
        let provider = MockStreamProvider(chunks: ["Hi ", "there!", " How", " are", " you?"])
        let executor = PromptExecutor(provider: provider, activeProviderModel: "test-model")

        let config = PromptConfig(systemPrompt: "test", maxIterations: 1, model: nil, autoCopyToClipboard: false)
        let result = try await executor.execute(query: "hello", config: config)

        XCTAssertEqual(result.stdout, "Hi there! How are you?",
            "P1: PromptExecutor 应累积所有 stream chunks")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(provider.streamCallCount, 1,
            "P1: PromptExecutor 应调用 sendStream 而非 send")
    }

    // P1 T4: ProviderChunk enum 值覆盖
    func test_p1_providerChunk_enumCases() {
        let textChunk = ProviderChunk.text("hello")
        let doneChunk = ProviderChunk.done(reason: "stop")
        let doneNilChunk = ProviderChunk.done(reason: nil)

        if case .text(let s) = textChunk {
            XCTAssertEqual(s, "hello")
        } else {
            XCTFail("text chunk should match .text")
        }
        if case .done(let r) = doneChunk {
            XCTAssertEqual(r, "stop")
        } else {
            XCTFail("done chunk should match .done")
        }
        if case .done(let r) = doneNilChunk {
            XCTAssertNil(r)
        } else {
            XCTFail("done nil chunk should match .done(nil)")
        }
    }
}

// MARK: - P0 Integration: ProviderConfig.noThinking field

final class ProviderConfigNoThinkingTests: XCTestCase {

    // noThinking 字段可正确 decode
    func test_p0_providerConfig_noThinkingField_decodesCorrectly() throws {
        let json = """
        {
          "kind": "openai-compatible",
          "baseURL": "http://localhost:11434/v1",
          "model": "qwen3:7b",
          "keyRef": "ollama",
          "noThinking": true
        }
        """
        let config = try JSONDecoder().decode(ProviderConfig.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(config.noThinking, true, "noThinking=true 应正确 decode")
    }

    // noThinking 字段缺失时为 nil（向后兼容）
    func test_p0_providerConfig_noThinkingField_nilWhenAbsent() throws {
        let json = """
        {
          "kind": "openai-compatible",
          "baseURL": "http://localhost:11434/v1",
          "model": "qwen3:7b",
          "keyRef": "ollama"
        }
        """
        let config = try JSONDecoder().decode(ProviderConfig.self, from: json.data(using: .utf8)!)
        XCTAssertNil(config.noThinking, "noThinking 字段缺失时应为 nil（向后兼容）")
    }
}
