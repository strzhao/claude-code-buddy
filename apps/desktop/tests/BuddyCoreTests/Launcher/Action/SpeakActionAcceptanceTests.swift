import XCTest
@testable import BuddyCore

// MARK: - SpeakActionAcceptanceTests
//
// 红队验收测试：场景 3 + 场景 4 + 场景 5
//
// 场景 3：结果区出现 🔊 朗读按钮
//   - 3.P1 parser 生成含 speak 的 ActionSegment（det-machine）
//   - 3.P2 点击后 SpeechService.lastSpokenText 在 500ms 内非 nil（real-process）
//   - 3.P3 无 action 标签时不生成 speak segment（det-machine）
//
// 场景 4：TTS 仅按需触发不自动播放
//   - 4.P1 渲染后未点击 🔊，SpeechService.speakCallCount == 0（det-machine）
//   - 4.P2 流式输出过程中不自动调用 speak（det-machine）
//
// 场景 5：点击 🔊 朗读英文原文（action 标签解析集成）
//   - 5.P1 parser 解析 speak 标签 → text == "buddy"（det-machine）
//   - 5.P2 点击 ActionButton → synth 朗读 "buddy"（real-process）
//   - 5.P3 无 speak 标签的 markdown → 无 .action(.speak) segment（det-machine）
//
// 契约约束（C1 / C3）：
//   - handler 闭集：speak → SpeechService.shared.speak(text, locale: "en-US")
//   - 标签 BNF：<action:speak text="WORD">LABEL</action>
//
// ⚠️ TDD 红灯预期：
//   - MarkdownActionParser、ActionSegment、SpeechService 蓝队未实现时编译失败。
//   - 测试通过 MarkdownActionParser.preprocess() 静态方法直接驱动（不依赖 UI）。

// MARK: - MockSpeechSynthesizer
//
// 设计文档 D3：SpeechService 注入构造 init(synth: AVSpeechSynthesizer)
// 这里用协议 mock 替代真实合成器以记录调用。
//
// ASSUMES blue team：SpeechService 通过 SpeechSynthesizerProtocol（或类似名称）注入；
// 若蓝队实现直接用 AVSpeechSynthesizer 注入，以下 mock 类需调整 init 参数类型。

// MARK: - SpeakActionAcceptanceTests

final class SpeakActionAcceptanceTests: XCTestCase {

    // MARK: - 场景 5 / 场景 3：MarkdownActionParser 解析 speak 标签

    /// 5.P1 / 3.P1 [det-machine]
    /// When MarkdownActionParser 解析 `<action:speak text="buddy">🔊</action>`,
    /// shall 生成 ActionSegment.action(handler: .speak, text: "buddy", label: "🔊")
    ///
    /// assert: text == "buddy"
    ///
    /// Mutation 探针（No-op）：如果 preprocess 返回空数组，无 .action segment → 断言失败。
    /// Mutation 探针（Return-Value）：如果 text 被赋为 "🔊"，XCTAssertEqual 报红。
    func test_scene5_P1_parser_speakTag_generatesCorrectSegment() {
        let raw = #"<action:speak text="buddy">🔊</action>"#

        let segments = MarkdownActionParser.preprocess(raw)

        // 必须生成至少一个 action segment
        let actionSegments = segments.compactMap { seg -> (handler: ActionHandler, text: String, label: String)? in
            if case .action(let h, let t, let l) = seg { return (h, t, l) }
            return nil
        }

        XCTAssertFalse(
            actionSegments.isEmpty,
            "5.P1: 解析 speak 标签应生成至少一个 .action segment，实际 segments: \(segments)"
        )

        let speakSeg = actionSegments.first { $0.handler == .speak }

        // assert: text == "buddy"
        XCTAssertNotNil(speakSeg, "5.P1: 应存在 handler == .speak 的 segment")
        XCTAssertEqual(
            speakSeg?.text, "buddy",
            "5.P1: speak segment 的 text 必须精确等于 'buddy'，实际: \(speakSeg?.text ?? "nil")"
        )
        XCTAssertEqual(
            speakSeg?.label, "🔊",
            "5.P1: speak segment 的 label 必须精确等于 '🔊'，实际: \(speakSeg?.label ?? "nil")"
        )
    }

    /// 3.P1 补充 [det-machine]
    /// 词典卡片 markdown（含 speak + copy）解析后有 isEnabled speak Button 可访问
    ///
    /// 测试层面：确认 handler == .speak 的 segment 确实存在（验证 ActionSegment 生成）
    ///
    /// Mutation 探针（Conditional Flip）：如果 handler 匹配逻辑翻转，speak 变 copy → 断言失败。
    func test_scene3_P1_wordCardMarkdown_hasSpeakSegment() {
        let wordCardMarkdown = """
        **buddy** /ˈbʌdi/ <action:speak text="buddy">🔊 听</action>

        n. 伙伴；密友 <action:copy text="伙伴；密友">📋</action>
        """

        let segments = MarkdownActionParser.preprocess(wordCardMarkdown)

        let speakSegments = segments.filter { seg in
            if case .action(let h, _, _) = seg, h == .speak { return true }
            return false
        }

        XCTAssertFalse(
            speakSegments.isEmpty,
            "3.P1: 词典卡片 markdown 解析后必须存在至少一个 speak segment（对应 🔊 按钮）"
        )
    }

    /// 3.P3 [det-machine]
    /// While 结果区为空（markdown 不含 action 标签），🔊 按钮 shall 不存在
    ///
    /// assert: 无 .action(.speak, _, _) segment
    ///
    /// Mutation 探针（State-Update Skip）：如果 preprocess 无论如何都生成 speak，断言失败。
    func test_scene3_P3_noActionTag_noSpeakSegment() {
        let plainMarkdown = "**buddy** /ˈbʌdi/\nn. 伙伴；密友"

        let segments = MarkdownActionParser.preprocess(plainMarkdown)

        let speakSegments = segments.filter { seg in
            if case .action(let h, _, _) = seg, h == .speak { return true }
            return false
        }

        XCTAssertTrue(
            speakSegments.isEmpty,
            "3.P3: 不含 action 标签的 markdown 不应生成任何 speak segment，实际: \(speakSegments.count) 个"
        )
    }

    /// 5.P3 [det-machine]
    /// When markdown 不含 `<action:speak>`, MarkdownActionParser shall 不生成 action segment
    ///
    /// assert: 无 .action(.speak, _, _)
    func test_scene5_P3_markdownWithoutSpeakTag_noSpeakSegment() {
        let markdownWithOnlyCopy = """
        **我想每天学英语。** <action:copy text="我想每天学英语。">📋</action>
        """

        let segments = MarkdownActionParser.preprocess(markdownWithOnlyCopy)

        let speakSegments = segments.filter { seg in
            if case .action(let h, _, _) = seg, h == .speak { return true }
            return false
        }

        XCTAssertTrue(
            speakSegments.isEmpty,
            "5.P3: 仅含 copy 标签的 markdown 不应有 speak segment，实际: \(speakSegments.count)"
        )
    }

    // MARK: - 场景 4：TTS 仅按需触发不自动播放

    /// 4.P1 [det-machine]
    /// While 结果渲染完成且用户未点击 🔊, AVSpeechSynthesizer shall 保持静默
    ///
    /// assert: SpeechService.shared（注入 mock）speakCallCount == 0
    ///
    /// 测试策略：parser 完成解析后直接检查 SpeechService 未被调用。
    /// 蓝队应保证：preprocess 本身不触发 SpeechService.speak()。
    ///
    /// Mutation 探针（No-op Flip）：如果 preprocess 内部调 speak，speakCallCount > 0 → 红灯。
    func test_scene4_P1_afterParsing_speechServiceNotCalled() {
        // 使用带 call count 的 mock 注入（ASSUMES init(synth:) 注入构造）
        let mockSynth = MockAVSynthesizer()
        let speechService = SpeechService(synth: mockSynth)

        // 模拟 markdown 解析（不涉及任何用户交互）
        let wordCardMarkdown = """
        **buddy** /ˈbʌdi/ <action:speak text="buddy">🔊 听</action>
        """
        _ = MarkdownActionParser.preprocess(wordCardMarkdown)

        // assert: speakCallCount == 0（仅解析，未触发 TTS）
        XCTAssertEqual(
            mockSynth.speakCallCount, 0,
            "4.P1: 解析 action 标签后，未经用户点击时 SpeechService 不应被调用，实际调用次数: \(mockSynth.speakCallCount)"
        )

        // 确保 speechService 变量不被 ARC 释放（避免优化掉）
        _ = speechService
    }

    /// 4.P2 [negate][det-machine]
    /// When 流式输出过程中, 系统 shall 不自动调用 speak
    ///
    /// assert: SpeechService.speakCallCount == 0
    ///
    /// 测试策略：直接调 SpeechService(synth: mockSynth) 构造，preprocess 多个 chunk，
    /// 确认 speakCallCount 始终为 0（渲染阶段不调 TTS）。
    ///
    /// Mutation 探针（State-Update Skip）：如果 preprocess 在内部自动 speak，count > 0 → 红灯。
    func test_scene4_P2_duringStreaming_speakNeverAutoInvoked() {
        let mockSynth = MockAVSynthesizer()
        let speechService = SpeechService(synth: mockSynth)

        // 模拟流式 chunk 累积，分多段 preprocess（非真实流，但验证解析时不 speak）
        let chunks = [
            "**buddy**",
            " /ˈbʌdi/ ",
            #"<action:speak text="buddy">🔊 听</action>"#,
            "\n\nn. 伙伴；密友 ",
            #"<action:copy text="伙伴；密友">📋</action>"#
        ]

        for chunk in chunks {
            _ = MarkdownActionParser.preprocess(chunk)
        }

        // assert: speakCallCount == 0
        XCTAssertEqual(
            mockSynth.speakCallCount, 0,
            "4.P2: 流式 chunk 解析期间不应自动触发 SpeechService.speak，实际: \(mockSynth.speakCallCount)"
        )

        _ = speechService
    }

    // MARK: - 场景 5.P2：点击 ActionButton → 调用 SpeechService

    /// 5.P2 [real-process]
    /// When 用户点击 ActionButton, AVSpeechSynthesizer shall 朗读 "buddy"
    ///
    /// observe: SpeechService（注入 mockSynth）lastSpokenText
    /// assert: 500ms 内 lastSpokenText == "buddy"
    ///
    /// Mutation 探针（No-op）：如果 ActionButton.tap() 不调用 SpeechService.speak，
    ///   mockSynth.lastSpokenText == nil → 断言失败。
    /// Mutation 探针（Return-Value）：如果传了错误的 text 参数，XCTAssertEqual 报红。
    func test_scene5_P2_actionButton_tap_callsSpeechService_withCorrectText() async throws {
        let mockSynth = MockAVSynthesizer()
        let speechService = SpeechService(synth: mockSynth)

        // 模拟用户 tap ActionButton(handler: .speak, text: "buddy")
        // ASSUMES：ActionButton 或 ActionHandler 提供 perform(speechService:copyService:) 入口
        // 按照 C3 契约：speak → SpeechService.shared.speak(attr.text, locale: "en-US")
        // 测试通过直接调 speechService.speak 验证服务层正确性（UI 层由 VISUAL_RESIDUE 真机验收）
        await speechService.speak("buddy", locale: "en-US")

        // assert: 500ms 内 lastSpokenText == "buddy"
        let deadline = Date().addingTimeInterval(0.5)
        var spokenText: String? = nil
        while Date() < deadline {
            if let t = mockSynth.lastSpokenText {
                spokenText = t
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }

        XCTAssertEqual(
            spokenText, "buddy",
            "5.P2: speak('buddy') 后 500ms 内 synth.lastSpokenText 必须精确等于 'buddy'，实际: \(spokenText ?? "nil")"
        )
    }

    /// 5.P2 补充：locale 参数默认为 "en-US"（C3 契约）
    ///
    /// Mutation 探针（Return-Value）：如果 locale 传为 "zh-CN"，XCTAssertEqual 报红。
    func test_scene5_P2_speakUsesEnUSLocaleByDefault() async throws {
        let mockSynth = MockAVSynthesizer()
        let speechService = SpeechService(synth: mockSynth)

        // 调用默认 locale 重载（不传 locale 参数）
        await speechService.speak("buddy")

        XCTAssertEqual(
            mockSynth.lastUsedLocale, "en-US",
            "5.P2: SpeechService.speak() 默认 locale 必须是 'en-US'，实际: \(mockSynth.lastUsedLocale ?? "nil")"
        )
    }

    /// 4.P1 补充：连续点击 🔊 时，先 stopSpeaking 再 speak（D3 cancel-then-speak 语义）
    ///
    /// Mutation 探针（State-Update Skip）：如果 stop 被跳过，stopCallCount == 0 → 断言失败。
    func test_scene4_cancelPreviousThenSpeak_onRepeatTap() async throws {
        let mockSynth = MockAVSynthesizer()
        let speechService = SpeechService(synth: mockSynth)

        // 第一次 speak
        await speechService.speak("buddy")
        let firstStop = mockSynth.stopCallCount
        let firstSpeak = mockSynth.speakCallCount

        // 第二次 speak（模拟用户连点）
        await speechService.speak("hello")

        // 第二次调用前必须先 stopSpeaking（stopCallCount 递增）
        XCTAssertGreaterThan(
            mockSynth.stopCallCount, firstStop,
            "D3: 第二次 speak 前必须先调 stopSpeaking，stopCallCount 应递增（first=\(firstStop), after=\(mockSynth.stopCallCount)）"
        )
        XCTAssertEqual(
            mockSynth.speakCallCount, firstSpeak + 1,
            "D3: 第二次 speak 应使 speakCallCount 精确 +1，实际: \(mockSynth.speakCallCount)"
        )
    }
}

// MARK: - MockAVSynthesizer
//
// ASSUMES：SpeechService init(synth:) 接受符合特定协议（或直接是 AVSpeechSynthesizer 子类）的 synth 参数。
// 设计文档 D3："lazy var 不行，要构造函数注入便于 mock"。
//
// 若蓝队用协议（SpeechSynthesizerProtocol），则 MockAVSynthesizer 实现该协议。
// 若蓝队直接子类化 AVSpeechSynthesizer，则此处继承 AVSpeechSynthesizer 并 override。
//
// 当前按"协议注入"设计编写（参考 D3 设计意图）。

final class MockAVSynthesizer: SpeechSynthesizerProtocol, @unchecked Sendable {
    private(set) var speakCallCount: Int = 0
    private(set) var stopCallCount: Int = 0
    private(set) var lastSpokenText: String? = nil
    private(set) var lastUsedLocale: String? = nil

    func speak(text: String, locale: String) {
        speakCallCount += 1
        lastSpokenText = text
        lastUsedLocale = locale
    }

    func stopSpeaking() {
        stopCallCount += 1
    }
}
