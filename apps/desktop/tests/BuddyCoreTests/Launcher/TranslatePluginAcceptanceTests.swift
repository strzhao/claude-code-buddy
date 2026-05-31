import XCTest
@testable import BuddyCore

// MARK: - TranslatePluginAcceptanceTests
//
// 验证 translate plugin 的 manifest 契约 + prompt mode 通过 attach_action meta tool 产出按钮的管线。
// 旧的 <action:> 标签解析机制已废弃（改用 render-only meta tool + 底部工具条）。
// 不真调 LLM，注入 mock provider 返回固定 text + tool_calls。

final class TranslatePluginAcceptanceTests: XCTestCase {

    // MARK: - Helpers

    private func makeTranslateManifest() -> PluginManifest {
        let pluginURL = sourceRoot()
            .appendingPathComponent("Sources/ClaudeCodeBuddy/Marketplace/plugins/translate/plugin.json")
        if let data = try? Data(contentsOf: pluginURL),
           let manifest = try? JSONDecoder().decode(PluginManifest.self, from: data) {
            return manifest
        }
        return makeMockTranslateManifest()
    }

    private func makeMockTranslateManifest() -> PluginManifest {
        let json = """
        {
            "name": "translate",
            "version": "0.2.0",
            "description": "中英互译助手",
            "keywords": ["translate"],
            "mode": "prompt",
            "systemPrompt": "你是中英互译助手",
            "maxIterations": 1,
            "autoCopyToClipboard": false
        }
        """
        return try! JSONDecoder().decode(PluginManifest.self, from: json.data(using: .utf8)!)
    }

    private func sourceRoot() -> URL {
        var url = URL(fileURLWithPath: #file)
        for _ in 0..<5 { url = url.deletingLastPathComponent() }
        return url
    }

    // MARK: - manifest 契约

    func test_manifest_is_prompt_mode_with_nonempty_systemPrompt() {
        let manifest = makeTranslateManifest()
        guard case .prompt(let cfg) = manifest.modeConfig else {
            return XCTFail("translate manifest should be prompt mode")
        }
        XCTAssertFalse(cfg.systemPrompt.isEmpty, "systemPrompt must be non-empty")
    }

    func test_manifest_autoCopyToClipboard_is_false() {
        let manifest = makeTranslateManifest()
        guard case .prompt(let cfg) = manifest.modeConfig else {
            return XCTFail("translate manifest should be prompt mode")
        }
        XCTAssertFalse(cfg.autoCopyToClipboard, "autoCopyToClipboard must be false")
    }

    // MARK: - prompt mode → attach_action 按钮管线

    /// 模型返回正文 + 两个 attach_action tool_call（speak/copy）→ PluginResult.actions 收齐两个按钮。
    func test_prompt_collects_attach_action_buttons() async throws {
        let provider = MockProviderForTranslate()
        provider.streamChunks = [
            .text("**buddy** /ˈbʌdi/\n\nn. 朋友；伙伴"),
            .action(LauncherActionButton(kind: .speak, text: "buddy", label: "🔊 朗读")),
            .action(LauncherActionButton(kind: .copy, text: "朋友；伙伴", label: "📋 复制")),
            .done(reason: "stop")
        ]
        let executor = PromptExecutor(provider: provider, activeProviderModel: "qwen")
        let cfg = PromptConfig(systemPrompt: "translate", maxIterations: 1, model: nil, autoCopyToClipboard: false)
        let result = try await executor.execute(query: "buddy", config: cfg)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("buddy"), "正文应含 markdown 文本")
        XCTAssertEqual(result.actions.count, 2, "应收齐 2 个按钮")
        XCTAssertEqual(result.actions[0].kind, .speak)
        XCTAssertEqual(result.actions[0].text, "buddy")
        XCTAssertEqual(result.actions[1].kind, .copy)
        XCTAssertEqual(result.actions[1].text, "朋友；伙伴")
    }

    /// 无 tool_call 时（如纯解释/闲聊）→ actions 为空，正文照常返回。
    func test_prompt_no_buttons_when_no_tool_calls() async throws {
        let provider = MockProviderForTranslate()
        provider.streamChunks = [.text("这是一段纯解释，没有可带走的产物。"), .done(reason: "stop")]
        let executor = PromptExecutor(provider: provider, activeProviderModel: "qwen")
        let cfg = PromptConfig(systemPrompt: "chat", maxIterations: 1, model: nil, autoCopyToClipboard: false)
        let result = try await executor.execute(query: "有点累", config: cfg)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.actions.isEmpty, "无 tool_call → 无按钮")
        XCTAssertFalse(result.stdout.isEmpty, "正文照常返回")
    }

    // MARK: - D2: 输出不含旧剪贴板 marker

    func test_D2_no_clipboard_marker_in_output_when_autoCopy_true() async throws {
        let pb = NSPasteboard(name: NSPasteboard.Name("ccb-test-\(UUID())"))
        let provider = MockProviderForTranslate()
        provider.streamChunks = [.text("I want to learn English."), .done(reason: "stop")]
        let executor = PromptExecutor(provider: provider, activeProviderModel: "qwen", pasteboard: pb)
        let legacyJson = """
        {
            "name": "legacy-translate",
            "version": "0.1.0",
            "description": "legacy",
            "keywords": ["legacy"],
            "mode": "prompt",
            "systemPrompt": "translate",
            "maxIterations": 1,
            "autoCopyToClipboard": true
        }
        """
        let legacyManifest = try JSONDecoder().decode(
            PluginManifest.self, from: legacyJson.data(using: .utf8)!)
        let input = PluginInput(query: "hello", sessionId: UUID().uuidString, cwd: "/tmp")
        let result = try await executor.execute(legacyManifest, pluginDir: URL(fileURLWithPath: "/tmp"), input: input)
        XCTAssertFalse(result.stdout.contains("已复制到剪贴板"),
            "D2: '已复制到剪贴板' marker must be removed from output")
    }
}

// MARK: - Mock provider for this test file

/// 流式 mock：按 streamChunks 顺序 emit；send() 回退为单 text。
private final class MockProviderForTranslate: LauncherProvider {
    var streamChunks: [ProviderChunk] = []

    func send(messages: [AgentMessage], tools: [AgentTool], model: String, system: String?) async throws -> AgentResponse {
        AgentResponse(content: [.text("ok")], stopReason: "end_turn", usage: nil)
    }

    func sendStream(messages: [AgentMessage], tools: [AgentTool], model: String, system: String?) async throws -> AsyncThrowingStream<ProviderChunk, Error> {
        let chunks = streamChunks
        return AsyncThrowingStream { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }
}
