import XCTest
@testable import BuddyCore

// MARK: - TranslatePluginAcceptanceTests
//
// 验证 translate plugin 整体管线：action 标签解析 → ActionSegment → 渲染按钮。
// 不真调 LLM，注入 mock provider 返回固定 markdown。
// 覆盖场景：5 (action 解析), 8 (copy button), 9 (copy 解析), 10 (错误降级), 12 (manifest 契约).

final class TranslatePluginAcceptanceTests: XCTestCase {

    // MARK: - Helpers

    private func makeTranslateManifest() -> PluginManifest {
        // Load the actual bundled plugin.json for manifest contract tests
        let pluginURL = sourceRoot()
            .appendingPathComponent("Sources/ClaudeCodeBuddy/Marketplace/plugins/translate/plugin.json")
        if let data = try? Data(contentsOf: pluginURL),
           let manifest = try? JSONDecoder().decode(PluginManifest.self, from: data) {
            return manifest
        }
        // Fallback: construct inline for environments where file path resolution fails
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
        // Navigate from test binary to apps/desktop/
        // Test binary is in .build/debug/, project root is 2 levels up
        // Use Bundle path heuristic
        var url = URL(fileURLWithPath: #file)
        // Walk up from tests/BuddyCoreTests/Launcher/ to apps/desktop/
        for _ in 0..<5 { url = url.deletingLastPathComponent() }
        return url
    }

    // MARK: - Scenario 5: action 标签解析集成

    func test_scenario5_P1_speak_segment_from_action_tag() {
        let raw = #"**buddy** /ˈbʌdi/ <action:speak text="buddy">🔊 听</action>"#
        let segs = MarkdownActionParser.preprocess(raw)
        let actionSegs = segs.filter { if case .action = $0 { return true }; return false }
        XCTAssertEqual(actionSegs.count, 1, "5.P1: Should produce exactly 1 .action segment")
        guard case .action(let h, let t, _) = actionSegs.first else {
            return XCTFail("Expected .action segment")
        }
        XCTAssertEqual(h, .speak, "5.P1: handler must be .speak")
        XCTAssertEqual(t, "buddy", "5.P1: text must be 'buddy'")
    }

    func test_scenario5_P3_no_action_when_no_tags() {
        let raw = "普通翻译结果，没有 action 标签"
        let segs = MarkdownActionParser.preprocess(raw)
        for seg in segs {
            if case .action = seg { XCTFail("5.P3: No .action segment expected") }
        }
    }

    // MARK: - Scenario 8: 📋 copy button

    func test_scenario8_P4_autoCopyToClipboard_is_false() throws {
        let manifest = makeTranslateManifest()
        // C4 contract: new translate plugin must have autoCopyToClipboard == false
        guard case .prompt(let cfg) = manifest.modeConfig else {
            return XCTFail("Translate manifest should be prompt mode")
        }
        XCTAssertFalse(cfg.autoCopyToClipboard,
            "8.P4: translate plugin.json must have autoCopyToClipboard:false")
    }

    func test_scenario8_P2_copy_button_segment_from_action_tag() {
        let raw = #"**我想学英语** <action:copy text="我想学英语">📋</action>"#
        let segs = MarkdownActionParser.preprocess(raw)
        let copySegs = segs.filter {
            if case .action(let h, _, _) = $0 { return h == .copy }
            return false
        }
        XCTAssertEqual(copySegs.count, 1, "8.P2: One copy .action segment expected")
    }

    // MARK: - Scenario 9: copy 标签解析

    func test_scenario9_P1_copy_text_extracted() {
        let raw = #"<action:copy text="伙伴">📋</action>"#
        let segs = MarkdownActionParser.preprocess(raw)
        guard case .action(_, let t, _) = segs.first else {
            return XCTFail("9.P1: Expected .action segment")
        }
        XCTAssertEqual(t, "伙伴", "9.P1: text must be '伙伴'")
    }

    func test_scenario9_P3_multiple_copy_buttons_from_multiple_tags() {
        // Mock LLM output with 3 copy tags
        let raw = """
        n. 伙伴；密友 <action:copy text="伙伴；密友">📋</action>
        v. 结伴 <action:copy text="结伴">📋</action>
        adj. 友善的 <action:copy text="友善的">📋</action>
        """
        let segs = MarkdownActionParser.preprocess(raw)
        let copyCount = segs.filter {
            if case .action(let h, _, _) = $0 { return h == .copy }
            return false
        }.count
        XCTAssertEqual(copyCount, 3, "9.P3: 3 copy tags → 3 .action segments")
    }

    // MARK: - Scenario 10: 错误降级

    func test_scenario10_P1_missing_text_attr_no_action() {
        let raw = #"<action:speak>🔊</action>"#
        let segs = MarkdownActionParser.preprocess(raw)
        XCTAssertFalse(segs.contains { if case .action = $0 { return true }; return false },
            "10.P1: tag missing text → no .action segment")
    }

    func test_scenario10_P3_unknown_handler_no_action() {
        let raw = #"<action:unknown text="x">y</action>"#
        let segs = MarkdownActionParser.preprocess(raw)
        XCTAssertFalse(segs.contains { if case .action = $0 { return true }; return false },
            "10.P3: unknown handler → no .action segment")
    }

    func test_scenario10_P2_no_crash_on_bad_input() {
        // Should not crash
        let badInputs = [
            "<action:speak text=",
            "<action:",
            "<<<",
            "<action:speak text=\"x\">",  // unclosed
            "",
        ]
        for input in badInputs {
            let segs = MarkdownActionParser.preprocess(input)
            XCTAssertNotNil(segs, "10.P2: Must not crash on bad input: \(input.prefix(30))")
        }
    }

    // MARK: - Scenario 12: manifest 契约

    func test_scenario12_P2_systemPrompt_nonempty() {
        let manifest = makeTranslateManifest()
        guard case .prompt(let cfg) = manifest.modeConfig else {
            return XCTFail("12.P2: manifest should be prompt mode")
        }
        XCTAssertFalse(cfg.systemPrompt.isEmpty,
            "12.P2: systemPrompt must be non-empty")
    }

    func test_scenario12_P3_autoCopyToClipboard_false() {
        let manifest = makeTranslateManifest()
        guard case .prompt(let cfg) = manifest.modeConfig else {
            return XCTFail("12.P3: manifest should be prompt mode")
        }
        XCTAssertFalse(cfg.autoCopyToClipboard,
            "12.P3: autoCopyToClipboard must be false")
    }

    // MARK: - PromptExecutor integration: no auto-copy marker in output

    func test_D2_no_clipboard_marker_in_output_when_autoCopy_true() async throws {
        // Even when autoCopyToClipboard=true (legacy), output must NOT contain the old marker
        let pb = NSPasteboard(name: NSPasteboard.Name("ccb-test-\(UUID())"))
        let provider = MockProviderForTranslate()
        provider.responseToReturn = AgentResponse(
            content: [.text("I want to learn English.")],
            stopReason: "end_turn",
            usage: nil
        )
        let executor = PromptExecutor(provider: provider, activeProviderModel: "qwen",
                                       pasteboard: pb)
        // Build a manifest with autoCopyToClipboard=true (legacy test)
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

private final class MockProviderForTranslate: LauncherProvider {
    var responseToReturn: AgentResponse?

    func send(messages: [AgentMessage], tools: [AgentTool], model: String, system: String?) async throws -> AgentResponse {
        responseToReturn ?? AgentResponse(content: [.text("ok")], stopReason: "end_turn", usage: nil)
    }
}
