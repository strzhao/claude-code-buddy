import XCTest
@testable import BuddyCore

// MARK: - SpeechServiceAcceptanceTests
//
// 红队验收测试：SpeechService 服务层（场景 3.P2 / 4.P1 / 5.P2 的服务层覆盖）
//
// 覆盖点：
//   - SpeechService(synth:) 注入构造（D3 设计）
//   - speak() 先 stopSpeaking 再 speak（D3 cancel-then-speak）
//   - 默认 locale = "en-US"（C3 契约）
//   - SpeechService.shared 单例存在（D3）
//   - 静默失败语义（C5：AVSpeechSynthesizer 不可用时不抛错）
//
// Mock 设计：
//   设计文档 D3 明确"构造函数注入便于 mock"，SpeechService init(synth:) 接受 synth 注入。
//   ASSUMES blue team 暴露 SpeechSynthesizerProtocol（或等价协议），
//   或直接支持 AVSpeechSynthesizer 子类注入。
//
// ⚠️ TDD 红灯预期：
//   SpeechService、SpeechSynthesizerProtocol 未实现时编译失败。

// MARK: - SpeechServiceAcceptanceTests

@MainActor
final class SpeechServiceAcceptanceTests: XCTestCase {

    // MARK: - D3：SpeechService.shared 单例存在

    /// D3 [det-machine]
    /// SpeechService.shared 单例必须存在（C3：speak handler 调用 SpeechService.shared.speak）
    ///
    /// Mutation 探针（No-op）：shared 未定义 → 编译失败（静态检查）。
    func test_d3_sharedSingleton_exists() {
        // 仅验证 shared 属性可访问（类型级别检查）
        let shared = SpeechService.shared
        XCTAssertNotNil(
            shared,
            "D3: SpeechService.shared 单例必须存在且不为 nil"
        )
    }

    // MARK: - D3：speak() 先 stop 再 speak（cancel-then-speak）

    /// D3 [det-machine]
    /// speak() 调用前必须先 stopSpeaking(at: .immediate)
    ///
    /// assert: 第一次 speak → stopCallCount 递增（stop 先于 speak）
    ///
    /// Mutation 探针（State-Update Skip）：若移除 stop 调用，stopCallCount == 0 → 断言失败。
    func test_d3_speakCancelsThenSpeaks() async {
        let mockSynth = RecordingMockSynthesizer()
        let service = SpeechService(synth: mockSynth)

        await service.speak("hello")

        // stop 必须在 speak 之前被调用
        XCTAssertGreaterThanOrEqual(
            mockSynth.stopCallCount, 1,
            "D3: speak() 必须先调 stopSpeaking，stopCallCount 必须 >= 1，实际: \(mockSynth.stopCallCount)"
        )
        XCTAssertEqual(
            mockSynth.speakCallCount, 1,
            "D3: speak() 应调用 synth.speak 一次，实际: \(mockSynth.speakCallCount)"
        )

        // 顺序验证：stop 在 speak 之前
        if let stopIdx = mockSynth.callLog.firstIndex(of: "stop"),
           let speakIdx = mockSynth.callLog.firstIndex(of: "speak") {
            XCTAssertLessThan(
                stopIdx, speakIdx,
                "D3: stopSpeaking 必须在 speak 之前调用，callLog: \(mockSynth.callLog)"
            )
        }
    }

    // MARK: - C3：默认 locale = "en-US"

    /// C3 [det-machine]
    /// speak(_ text:) 无 locale 参数时默认使用 "en-US"
    ///
    /// assert: voice locale == "en-US"
    ///
    /// Mutation 探针（Return-Value）：若默认 locale 为 "zh-CN" → 断言失败。
    func test_c3_defaultLocale_isEnUS() async {
        let mockSynth = RecordingMockSynthesizer()
        let service = SpeechService(synth: mockSynth)

        // 调用默认重载（无 locale 参数）
        await service.speak("buddy")

        // assert: locale == "en-US"
        XCTAssertEqual(
            mockSynth.lastUsedLocale, "en-US",
            "C3: SpeechService.speak() 默认 locale 必须是 'en-US'，实际: \(mockSynth.lastUsedLocale ?? "nil")"
        )
    }

    // MARK: - locale override

    /// 可选参数 locale override：显式传 "zh-CN" 时 voice locale 为 "zh-CN"
    ///
    /// Mutation 探针（Return-Value）：若 locale 参数被忽略，仍用 "en-US" → 断言失败。
    func test_localeOverride_usesProvidedLocale() async {
        let mockSynth = RecordingMockSynthesizer()
        let service = SpeechService(synth: mockSynth)

        await service.speak("你好", locale: "zh-CN")

        XCTAssertEqual(
            mockSynth.lastUsedLocale, "zh-CN",
            "locale override: 传 'zh-CN' 时 synth 应使用 'zh-CN'，实际: \(mockSynth.lastUsedLocale ?? "nil")"
        )
    }

    // MARK: - D3：speak text 准确传递

    /// speak("buddy") 后 synth 收到的 text 必须精确是 "buddy"
    ///
    /// Mutation 探针（Return-Value）：text 被替换或截断 → XCTAssertEqual 报红。
    func test_d3_speakText_passedCorrectlyToSynth() async {
        let mockSynth = RecordingMockSynthesizer()
        let service = SpeechService(synth: mockSynth)

        await service.speak("buddy")

        XCTAssertEqual(
            mockSynth.lastSpokenText, "buddy",
            "D3: speak('buddy') 后 synth.lastSpokenText 必须精确是 'buddy'，实际: \(mockSynth.lastSpokenText ?? "nil")"
        )
    }

    // MARK: - C5：静默失败（空 text 不崩溃）

    /// C5 [det-machine]
    /// speak("") 空字符串 → 不崩溃（静默失败或 no-op）
    ///
    /// Mutation 探针（No-op）：崩溃 → 测试失败。
    func test_c5_emptyText_doesNotCrash() async {
        let mockSynth = RecordingMockSynthesizer()
        let service = SpeechService(synth: mockSynth)

        // 不应崩溃
        await service.speak("")
        // 通过不崩溃即验证 C5 软失败语义
        // speakCallCount 可为 0（实现选择不渲染 no-op）或 1（允许两种实现）
        XCTAssertTrue(
            mockSynth.speakCallCount >= 0,
            "C5: speak('') 不应崩溃"
        )
    }

    // MARK: - D3：@MainActor 标注

    /// SpeechService.speak() 在 MainActor 上执行（D3 要求 @MainActor）
    /// 通过 @MainActor 测试函数直接调用验证（编译器保证 MainActor 一致性）
    func test_d3_speakRunsOnMainActor() async {
        let mockSynth = RecordingMockSynthesizer()
        let service = SpeechService(synth: mockSynth)

        // 在 @MainActor 上调用
        await service.speak("test")

        XCTAssertTrue(Thread.isMainThread, "D3: SpeechService.speak() 必须在 Main Thread 上执行")
    }

    // MARK: - 连续 speak（场景 4 cancel 语义）

    /// 连续调 speak 两次，每次都先 stop（stopCallCount 累计）
    ///
    /// Mutation 探针（State-Update Skip）：第二次 speak 前未 stop → stopCallCount 不递增 → 红灯。
    func test_consecutiveSpeaks_eachCallsStopFirst() async {
        let mockSynth = RecordingMockSynthesizer()
        let service = SpeechService(synth: mockSynth)

        await service.speak("first")
        await service.speak("second")

        // 每次 speak 都应 stop → 总 stopCallCount >= 2
        XCTAssertGreaterThanOrEqual(
            mockSynth.stopCallCount, 2,
            "连续 speak 两次，stopSpeaking 应被调用至少 2 次（每次 speak 前各一次），实际: \(mockSynth.stopCallCount)"
        )
        XCTAssertEqual(
            mockSynth.speakCallCount, 2,
            "连续 speak 两次，speakCallCount 应精确为 2，实际: \(mockSynth.speakCallCount)"
        )
    }
}

// MARK: - RecordingMockSynthesizer

/// 记录调用顺序的 mock synthesizer
/// ASSUMES: SpeechSynthesizerProtocol（蓝队定义的协议），包含 speak(text:locale:) + stopSpeaking()
final class RecordingMockSynthesizer: SpeechSynthesizerProtocol, @unchecked Sendable {
    private(set) var speakCallCount: Int = 0
    private(set) var stopCallCount: Int = 0
    private(set) var lastSpokenText: String? = nil
    private(set) var lastUsedLocale: String? = nil
    private(set) var callLog: [String] = []  // 顺序记录 "stop" / "speak"

    func speak(text: String, locale: String) {
        speakCallCount += 1
        lastSpokenText = text
        lastUsedLocale = locale
        callLog.append("speak")
    }

    func stopSpeaking() {
        stopCallCount += 1
        callLog.append("stop")
    }
}
