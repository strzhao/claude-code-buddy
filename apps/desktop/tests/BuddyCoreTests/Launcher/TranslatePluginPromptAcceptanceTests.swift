import XCTest
import Combine
@testable import BuddyCore

// MARK: - TranslatePluginPromptAcceptanceTests
//
// 红队验收测试：场景 1 + 场景 2
//
// 场景 1：单词查询输出丰富词典格式
//   - 1.P1 结果区含音标（/.../ 或 [...] 格式）
//   - 1.P2 结果区含至少一个词性标注 (n.|v.|adj.|adv.)
//   - 1.P3 结果区含至少一条例句（英文，含空格，长度 >= 10）
//   - 1.P4 结果区含至少 2 个独立释义条目
//
// 场景 2：句子翻译输出简洁仅译文
//   - 2.P1 不含音标
//   - 2.P2 不含词性标注
//   - 2.P3 含中文字符
//
// 测试策略：
//   注入 MockTranslateProvider，返回符合 D5 prompt 模板的固定 markdown，
//   通过 LauncherManager.submit() → AsyncStream<AgentEvent> 消费流，
//   从 .text 事件累积输出，对输出字符串做正则断言。
//
// ⚠️ TDD 红灯预期：若蓝队尚未实现 translate plugin 的 PromptExecutor 路径，
//    sendCallCount 可能为 0，相关断言失败。

// MARK: - MockTranslateProvider

/// translate 验收专用 mock provider，可按 query 返回不同固定 markdown
private final class MockTranslateProvider: LauncherProvider, @unchecked Sendable {
    var wordResponse: AgentResponse
    var sentenceResponse: AgentResponse
    private(set) var sendCallCount = 0
    private(set) var lastCapturedUserMessage: String = ""

    init() {
        // 单词模板（buddy）：含音标 + 词性 + 多释义 + 例句 + action 标签
        // 按照 D5 prompt 格式
        wordResponse = AgentResponse(
            content: [.text(
                """
                **buddy** /ˈbʌdi/ <action:speak text="buddy">🔊 听</action>

                n. 伙伴；密友 <action:copy text="伙伴；密友">📋</action>
                n. 搭档；同伴 <action:copy text="搭档；同伴">📋</action>

                ▸ He is my best buddy. <action:speak text="He is my best buddy.">🔊</action>
                  他是我最好的朋友。 <action:copy text="他是我最好的朋友。">📋</action>
                """
            )],
            stopReason: "end_turn",
            usage: nil
        )
        // 句子模板（I want to learn English every day.）：仅译文
        sentenceResponse = AgentResponse(
            content: [.text(
                "**我想每天学英语。** <action:copy text=\"我想每天学英语。\">📋</action>"
            )],
            stopReason: "end_turn",
            usage: nil
        )
    }

    func send(
        messages: [AgentMessage],
        tools: [AgentTool],
        model: String,
        system: String?
    ) async throws -> AgentResponse {
        sendCallCount += 1
        // 取 user message 内容来路由（content 是 [AgentContent]，提取 .text）
        lastCapturedUserMessage = messages.last?.content.compactMap {
            if case .text(let s) = $0 { return s }; return nil
        }.joined() ?? ""
        let q = lastCapturedUserMessage.lowercased()
        if q.contains(" ") || q.count > 20 {
            return sentenceResponse
        }
        return wordResponse
    }
}

private func makeTranslateFactory(_ provider: LauncherProvider)
    -> (ProviderConfig, SecretStore) throws -> LauncherProvider
{
    return { _, _ in provider }
}

// MARK: - 工具函数：从 AsyncStream 累积 text 输出

private func collectOutputFromStream(
    _ stream: AsyncStream<AgentEvent>,
    timeout: TimeInterval = 5.0
) async -> String {
    var buffer = ""
    let deadline = Date().addingTimeInterval(timeout)
    for await event in stream {
        if case .text(let chunk) = event {
            buffer += chunk
        }
        if Date() > deadline { break }
    }
    return buffer
}

// MARK: - TranslatePluginPromptAcceptanceTests

@MainActor
final class TranslatePluginPromptAcceptanceTests: XCTestCase {

    private var cancellables = Set<AnyCancellable>()
    private var mockProvider: MockTranslateProvider!

    override func setUp() async throws {
        try await super.setUp()
        cancellables = []
        mockProvider = MockTranslateProvider()
        LauncherManager.shared.providerFactoryOverride = makeTranslateFactory(mockProvider)
    }

    override func tearDown() async throws {
        cancellables = []
        LauncherManager.shared.providerFactoryOverride = nil
        mockProvider = nil
        try await super.tearDown()
    }

    // MARK: - 场景 1：单词查询输出丰富词典格式

    /// 1.P1 [det-machine]
    /// When 输入 `buddy` 且 plugin 响应完成,
    /// 结果区 shall 包含音标（/.../ 或 [...] 格式）
    ///
    /// Mutation 探针（No-op）：如果 submit 从不转发 text 事件，output 为空 → regex 不匹配 → 红灯。
    func test_scene1_P1_wordQuery_outputContainsPhonetic() async throws {
        // Given: mock provider 注入，输入单词 "buddy"
        let stream = LauncherManager.shared.submit("buddy")
        let output = await collectOutputFromStream(stream)

        // Then: 含音标格式 /.../ 或 [...]
        // assert: value matches `/\/.+\//` 或 `/\[.+\]/`
        let hasSlashPhonetic = output.range(
            of: #"/[^/\n]+/"#,
            options: .regularExpression
        ) != nil
        let hasBracketPhonetic = output.range(
            of: #"\[[^\]\n]+\]"#,
            options: .regularExpression
        ) != nil

        XCTAssertTrue(
            hasSlashPhonetic || hasBracketPhonetic,
            "1.P1: 单词查询结果必须包含音标（/.../  或 [...] 格式），实际输出: \(output)"
        )
    }

    /// 1.P2 [det-machine]
    /// When plugin 响应完成, 结果区 shall 包含至少一个词性标注
    ///
    /// Mutation 探针（No-op）：如果 mock 返回空文本，词性 pattern 不命中 → 红灯。
    func test_scene1_P2_wordQuery_outputContainsPartOfSpeech() async throws {
        let stream = LauncherManager.shared.submit("buddy")
        let output = await collectOutputFromStream(stream)

        // assert: 存在 value matches `/\b(n\.|v\.|adj\.|adv\.)/`
        let hasPartOfSpeech = output.range(
            of: #"\b(n\.|v\.|adj\.|adv\.)"#,
            options: .regularExpression
        ) != nil

        XCTAssertTrue(
            hasPartOfSpeech,
            "1.P2: 单词查询结果必须包含词性标注（n. / v. / adj. / adv.），实际输出: \(output)"
        )
    }

    /// 1.P3 [det-machine]
    /// When plugin 响应完成, 结果区 shall 包含至少一条例句
    /// （含空格 + 长度 >= 10 的英文句子）
    ///
    /// Mutation 探针（Return-Value Skip）：mock 返回无例句的文本 → 断言失败 → 红灯。
    func test_scene1_P3_wordQuery_outputContainsExampleSentence() async throws {
        let stream = LauncherManager.shared.submit("buddy")
        let output = await collectOutputFromStream(stream)

        // assert: 存在 value 含完整英文句子（含空格 + 长度 >= 10）
        // 找含空格且长度 >= 10 的英文字符串片段
        let lines = output.components(separatedBy: .newlines)
        let hasEnglishSentence = lines.contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // 含空格 + 长度 >= 10 + 含英文字母
            return trimmed.count >= 10
                && trimmed.contains(" ")
                && trimmed.range(of: "[A-Za-z]{2,}", options: .regularExpression) != nil
        }

        XCTAssertTrue(
            hasEnglishSentence,
            "1.P3: 单词查询结果必须包含至少一条例句（含空格、长度 >= 10 的英文句），实际输出: \(output)"
        )
    }

    /// 1.P4 [det-machine]
    /// When plugin 响应完成, 结果区 shall 包含至少 2 个独立释义条目
    ///
    /// Mutation 探针（Boundary）：若释义只有 1 条，count >= 2 断言失败 → 红灯。
    func test_scene1_P4_wordQuery_outputContainsAtLeastTwoDefinitions() async throws {
        let stream = LauncherManager.shared.submit("buddy")
        let output = await collectOutputFromStream(stream)

        // assert: count >= 2
        // 计算含 "n." / "v." / "adj." / "adv." 的行数作为释义计数
        let definitionLines = output.components(separatedBy: .newlines).filter { line in
            line.range(of: #"\b(n\.|v\.|adj\.|adv\.)"#, options: .regularExpression) != nil
        }

        XCTAssertGreaterThanOrEqual(
            definitionLines.count, 2,
            "1.P4: 单词查询结果必须包含至少 2 个独立释义条目，实际释义行数: \(definitionLines.count)，输出: \(output)"
        )
    }

    // MARK: - 场景 2：句子翻译输出简洁仅译文

    /// 2.P1 [det-machine]
    /// When 输入长度 > 1 token 且含空格, plugin shall 返回仅含译文（不含音标）
    ///
    /// Mutation 探针（No-op）：如果 submit 返回单词格式（含音标），断言失败 → 红灯。
    func test_scene2_P1_sentenceQuery_outputNotContainsPhonetic() async throws {
        let stream = LauncherManager.shared.submit("I want to learn English every day.")
        let output = await collectOutputFromStream(stream)

        // assert: 不存在 value matches `/\/.+\//`
        let hasPhonetic = output.range(
            of: #"/[^/\n]+/"#,
            options: .regularExpression
        ) != nil

        XCTAssertFalse(
            hasPhonetic,
            "2.P1: 句子翻译结果不应含音标（/.../），实际输出: \(output)"
        )
    }

    /// 2.P2 [det-machine]
    /// When 句子翻译完成, 结果区 shall 不含词性标注
    ///
    /// Mutation 探针（Conditional Flip）：如果句子也返回词性，断言失败 → 红灯。
    func test_scene2_P2_sentenceQuery_outputNotContainsPartOfSpeech() async throws {
        let stream = LauncherManager.shared.submit("I want to learn English every day.")
        let output = await collectOutputFromStream(stream)

        // assert: 不存在 value matches `/\b(n\.|v\.|adj\.)/`
        let hasPartOfSpeech = output.range(
            of: #"\b(n\.|v\.|adj\.)"#,
            options: .regularExpression
        ) != nil

        XCTAssertFalse(
            hasPartOfSpeech,
            "2.P2: 句子翻译结果不应含词性标注（n. / v. / adj.），实际输出: \(output)"
        )
    }

    /// 2.P3 [det-machine]
    /// When 句子翻译完成, 结果区 shall 包含中文字符
    ///
    /// Mutation 探针（Return-Value Skip）：如果 mock 返回纯英文，CJK 范围 pattern 不命中 → 红灯。
    func test_scene2_P3_sentenceQuery_outputContainsChinese() async throws {
        let stream = LauncherManager.shared.submit("I want to learn English every day.")
        let output = await collectOutputFromStream(stream)

        // assert: value matches `/[一-鿿]/`（CJK 统一汉字区块）
        let hasChinese = output.range(
            of: "[\u{4E00}-\u{9FFF}]",
            options: .regularExpression
        ) != nil

        XCTAssertTrue(
            hasChinese,
            "2.P3: 句子翻译结果必须包含中文字符，实际输出: \(output)"
        )
    }
}
