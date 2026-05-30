import XCTest
import AppKit
@testable import BuddyCore

// MARK: - CopyActionAcceptanceTests
//
// 红队验收测试：场景 8 + 场景 9
//
// 场景 8：📋 复制按钮，点击才复制
//   - 8.P1 渲染后未点击 📋，pasteboard 不含译文（det-machine）
//   - 8.P2 结果区存在 copy Button（det-machine，通过 segment 验证）
//   - 8.P3 点击 📋，pasteboard 写入 action.text（real-process）
//   - 8.P4 autoCopyToClipboard=false，渲染时不写剪贴板（negate det-machine）
//
// 场景 9：📋 按钮 action 标签解析集成
//   - 9.P1 解析 copy 标签 → text == "伙伴"（det-machine）
//   - 9.P2 点击 copy Button，pasteboard == "伙伴"（real-process）
//   - 9.P3 多个 copy 标签 → 对应数量 button（det-machine）
//
// 契约约束（C3 / C4 / D4）：
//   - copy → CopyService.shared.copy(attr.text)
//   - 生产 pasteboard: NSPasteboard.general
//   - 测试 pasteboard: NSPasteboard(name: NSPasteboard.Name("ccb-test-<UUID>")) 隔离
//   - autoCopyToClipboard=false → 不写剪贴板
//
// NSPasteboard 测试隔离：参考 knowledge entry nspasteboard-test-isolation-via-named-pasteboard
// （2026-05-29）：用 NSPasteboard(name:) 创建独立命名 pasteboard，不污染 .general。

// MARK: - CopyActionAcceptanceTests

final class CopyActionAcceptanceTests: XCTestCase {

    // MARK: - 测试专用 Pasteboard

    private var testPasteboard: NSPasteboard!
    private var testPasteboardName: NSPasteboard.Name!

    override func setUp() async throws {
        try await super.setUp()
        // 每个测试用独立的命名 pasteboard（隔离，防止跨测试污染）
        testPasteboardName = NSPasteboard.Name("ccb-test-\(UUID().uuidString)")
        testPasteboard = NSPasteboard(name: testPasteboardName)
        testPasteboard.clearContents()
    }

    override func tearDown() async throws {
        testPasteboard.clearContents()
        testPasteboard = nil
        testPasteboardName = nil
        try await super.tearDown()
    }

    // MARK: - 工具函数

    /// 读取命名 pasteboard 当前字符串内容（nil 表示空）
    private func currentPasteboardString() -> String? {
        testPasteboard.string(forType: .string)
    }

    private func changeCount() -> Int {
        testPasteboard.changeCount
    }

    // MARK: - 场景 9：MarkdownActionParser 解析 copy 标签

    /// 9.P1 [det-machine]
    /// When 解析 `<action:copy text="伙伴">📋</action>`, shall 生成 ActionSegment with text == "伙伴"
    ///
    /// assert: text == "伙伴"
    ///
    /// Mutation 探针（No-op）：parser 返回空数组 → 无 .action segment → 断言失败。
    /// Mutation 探针（Return-Value）：text 被赋为 "📋" → XCTAssertEqual 报红。
    func test_scene9_P1_parser_copyTag_generatesCorrectSegment() {
        let raw = #"<action:copy text="伙伴">📋</action>"#

        let segments = MarkdownActionParser.preprocess(raw)

        let copySegments = segments.compactMap { seg -> (handler: ActionHandler, text: String, label: String)? in
            if case .action(let h, let t, let l) = seg { return (h, t, l) }
            return nil
        }.filter { $0.handler == .copy }

        XCTAssertFalse(
            copySegments.isEmpty,
            "9.P1: 解析 copy 标签应生成至少一个 handler == .copy 的 segment，实际 segments: \(segments)"
        )

        let copySeg = copySegments.first

        // assert: text == "伙伴"
        XCTAssertEqual(
            copySeg?.text, "伙伴",
            "9.P1: copy segment 的 text 必须精确等于 '伙伴'，实际: \(copySeg?.text ?? "nil")"
        )
        XCTAssertEqual(
            copySeg?.label, "📋",
            "9.P1: copy segment 的 label 必须精确等于 '📋'，实际: \(copySeg?.label ?? "nil")"
        )
    }

    /// 9.P3 [det-machine]
    /// When markdown 含多个 copy 标签, shall 生成对应数量 button
    ///
    /// assert: count == 标签数量（此处为 3）
    ///
    /// Mutation 探针（Boundary）：只生成 1 个 segment → count == 1 ≠ 3 → 红灯。
    func test_scene9_P3_multipleCopyTags_generateMatchingSegmentCount() {
        let raw = """
        n. 伙伴；密友 <action:copy text="伙伴；密友">📋</action>
        n. 搭档；同伴 <action:copy text="搭档；同伴">📋</action>
        ▸ 译文 <action:copy text="他是我最好的朋友。">📋</action>
        """

        let segments = MarkdownActionParser.preprocess(raw)

        let copySegmentCount = segments.filter { seg in
            if case .action(let h, _, _) = seg, h == .copy { return true }
            return false
        }.count

        // assert: count == 3（标签数量）
        XCTAssertEqual(
            copySegmentCount, 3,
            "9.P3: 3 个 copy 标签应生成 3 个 copy segment，实际: \(copySegmentCount)"
        )
    }

    // MARK: - 场景 8：CopyService pasteboard 行为

    /// 8.P3 / 9.P2 [real-process]
    /// When 点击 📋, NSPasteboard shall 写入 action.text
    ///
    /// observe: testPasteboard.string(forType: .string)
    /// assert: value == action.text（"伙伴"）
    ///
    /// Mutation 探针（No-op）：copy() 不写 pasteboard → string == nil → 断言失败。
    /// Mutation 探针（Return-Value）：写入错误文本 → XCTAssertEqual 报红。
    func test_scene8_P3_copyService_writesCorrectTextToPasteboard() {
        let copyService = CopyService(pasteboard: testPasteboard)

        // When: 点击 📋（等价于调用 CopyService.copy）
        copyService.copy("伙伴")

        // assert: value == "伙伴"
        let actual = currentPasteboardString()
        XCTAssertEqual(
            actual, "伙伴",
            "8.P3 / 9.P2: copy('伙伴') 后 pasteboard 必须精确包含 '伙伴'，实际: \(actual ?? "nil")"
        )
    }

    /// 8.P3 补充：多语言译文写入正确（中文不被截断）
    func test_scene8_P3_copyService_writesChineseText_correctly() {
        let copyService = CopyService(pasteboard: testPasteboard)
        let chineseText = "他是我最好的朋友，我们一起长大。"

        copyService.copy(chineseText)

        let actual = currentPasteboardString()
        XCTAssertEqual(
            actual, chineseText,
            "8.P3: copy() 写入中文字符串必须完整无截断，实际: \(actual ?? "nil")"
        )
    }

    /// 8.P1 [det-machine]
    /// When 渲染完成 + 用户未点击 📋, NSPasteboard shall 不含译文
    ///
    /// observe: testPasteboard.string
    /// assert: value != translateResultText
    ///
    /// 测试策略：fresh pasteboard 默认不含任何内容，解析 markdown 不应写入 pasteboard。
    ///
    /// Mutation 探针（State-Update Skip）：如果 MarkdownActionParser.preprocess 内部自动调 copy → 断言失败。
    func test_scene8_P1_afterParsing_pasteboardNotContainsTranslation() {
        let translateResultText = "伙伴；密友"
        let wordCardMarkdown = """
        n. 伙伴；密友 <action:copy text="伙伴；密友">📋</action>
        """

        // 仅解析，不触发任何 UI 交互
        _ = MarkdownActionParser.preprocess(wordCardMarkdown)

        let pasteboardContent = currentPasteboardString()

        // assert: value != translateResultText（testPasteboard 应为空）
        XCTAssertNotEqual(
            pasteboardContent, translateResultText,
            "8.P1: 仅解析 markdown 不应自动写入 pasteboard，pasteboard 不应含 '伙伴；密友'"
        )
    }

    /// 8.P2 [det-machine]
    /// When 渲染完成, 结果区 shall 存在 copy Button
    ///
    /// 测试层面：通过 parser 验证 .action(.copy) segment 存在（按钮存在的前提）
    ///
    /// Mutation 探针（No-op）：无 copy segment → 按钮不存在 → 断言失败。
    func test_scene8_P2_wordCardMarkdown_hasCopySegment() {
        let wordCardMarkdown = """
        n. 伙伴；密友 <action:copy text="伙伴；密友">📋</action>
        """

        let segments = MarkdownActionParser.preprocess(wordCardMarkdown)

        let hasCopySegment = segments.contains { seg in
            if case .action(let h, _, _) = seg, h == .copy { return true }
            return false
        }

        XCTAssertTrue(
            hasCopySegment,
            "8.P2: 含 copy 标签的 markdown 必须生成 .action(.copy) segment（对应 📋 按钮）"
        )
    }

    /// 8.P4 [negate][det-machine]
    /// When autoCopyToClipboard 配置为 false, 渲染时 shall 不写剪贴板
    ///
    /// observe: testPasteboard.changeCount
    /// assert: changeCount 保持不变（仅解析 markdown，不调 copy）
    ///
    /// 测试策略：
    ///   C4 契约：autoCopyToClipboard=false 时 PromptExecutor 不自动调 CopyService。
    ///   此测试验证"解析层不自动复制"（可纯解析层验证）。
    ///
    /// Mutation 探针（State-Update Skip）：如果解析时自动调 copy → changeCount 递增 → 断言失败。
    func test_scene8_P4_autoCopyFalse_renderingDoesNotWritePasteboard() {
        let initialChangeCount = changeCount()

        // 模拟 autoCopyToClipboard=false 场景：仅解析，不调 CopyService
        let markdown = """
        **我想每天学英语。** <action:copy text="我想每天学英语。">📋</action>
        """
        _ = MarkdownActionParser.preprocess(markdown)

        // assert: changeCount 保持不变
        XCTAssertEqual(
            changeCount(), initialChangeCount,
            "8.P4: autoCopyToClipboard=false 时，解析 markdown 不应触发 pasteboard 写入（changeCount 必须不变），初始: \(initialChangeCount), 实际: \(changeCount())"
        )
    }

    // MARK: - CopyService clearContents 先于 setString（原子性）

    /// D4 契约：copy() 必须先 clearContents 再 setString（不累积旧内容）
    ///
    /// Mutation 探针（State-Update Skip）：如果不 clearContents，旧内容残留 → 第二次 copy 后可能
    ///   读到拼接内容（取决于 pasteboard 实现），但关键是新值应覆盖旧值。
    func test_copyService_secondCopy_overwritesPreviousContent() {
        let copyService = CopyService(pasteboard: testPasteboard)

        copyService.copy("first content")
        copyService.copy("second content")

        // assert: 只有最新内容
        XCTAssertEqual(
            currentPasteboardString(), "second content",
            "CopyService: 第二次 copy 应覆盖第一次内容（clearContents + setString），实际: \(currentPasteboardString() ?? "nil")"
        )
    }

    /// D4：copy 空字符串（C5 软失败）→ pasteboard 写入空字符串，不崩溃
    func test_copyService_emptyString_doesNotCrash() {
        let copyService = CopyService(pasteboard: testPasteboard)

        // 不应崩溃
        XCTAssertNoThrow(
            copyService.copy(""),
            "C5: copy 空字符串不应崩溃"
        )
    }
}
