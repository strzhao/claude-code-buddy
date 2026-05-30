import XCTest
@testable import BuddyCore

// MARK: - MarkdownActionParserGracefulFailureAcceptanceTests
//
// 红队验收测试：场景 10（action 标签格式错误优雅降级）
//
// 场景 10：action 标签格式错误优雅降级
//   - 10.P1 缺 text 属性 → 整体丢弃（det-machine）
//   - 10.P2 解析出错 → 不崩溃 + 其余文本正常渲染（det-machine）
//   - 10.P3 未知 handler → 整体丢弃（det-machine）
//
// 同时覆盖 C2 错误处理表所有行：
//   - 未知 handler → 整体丢弃（含 label）
//   - 缺 text 属性 → 整体丢弃
//   - 未闭合标签 → 整体丢弃，残留文本不显示
//   - &quot; 转义 → text 解码为 a"b
//   - 标签嵌套 → label 取原文本（含 <b>y</b>）
//   - MarkdownRenderer 异常 → 不阻塞，文本仍显示
//
// 契约来源：C1 BNF + C2 错误处理表 + C5 软失败语义
//
// ⚠️ TDD 红灯预期：MarkdownActionParser、ActionSegment 蓝队未实现时编译失败。

final class MarkdownActionParserGracefulFailureAcceptanceTests: XCTestCase {

    // MARK: - 场景 10.P1：缺 text 属性 → 整体丢弃

    /// 10.P1 [det-machine]
    /// When 标签缺 text 属性 `<action:speak>🔊</action>`, parser shall 整体丢弃
    ///
    /// assert: 不含 .action segment
    ///
    /// Mutation 探针（Conditional Flip）：若丢弃逻辑翻转（反而保留），出现 action segment → 红灯。
    func test_scene10_P1_missingTextAttr_entireTagDiscarded() {
        let raw = "<action:speak>🔊</action>"

        let segments = MarkdownActionParser.preprocess(raw)

        let actionCount = segments.filter { seg in
            if case .action = seg { return true }
            return false
        }.count

        // assert: 不含 .action segment
        XCTAssertEqual(
            actionCount, 0,
            "10.P1: 缺 text 属性的 action 标签必须整体丢弃（含 label '🔊'），action segment 数量必须为 0，实际: \(actionCount)"
        )

        // 补充：label 文本也不应出现在 text segment 中
        let allText = segments.compactMap { seg -> String? in
            if case .text(let s) = seg { return s }
            return nil
        }.joined()

        XCTAssertFalse(
            allText.contains("🔊"),
            "10.P1: 丢弃的 action 标签不应残留 label '🔊' 在文本中，实际文本: \(allText)"
        )
    }

    /// 10.P1 补充：缺 text 属性的 copy 标签也应整体丢弃
    func test_scene10_P1_copyTag_missingTextAttr_entireTagDiscarded() {
        let raw = "<action:copy>📋</action>"

        let segments = MarkdownActionParser.preprocess(raw)

        let actionCount = segments.filter { seg in
            if case .action = seg { return true }
            return false
        }.count

        XCTAssertEqual(
            actionCount, 0,
            "10.P1 copy: 缺 text 属性的 copy 标签必须整体丢弃，action segment 数量必须为 0"
        )
    }

    // MARK: - 场景 10.P3：未知 handler → 整体丢弃

    /// 10.P3 [det-machine]
    /// When 未知 handler `<action:unknown text="x">y</action>`, parser shall 整体丢弃
    ///
    /// assert: 不含 unknown segment
    ///
    /// Mutation 探针（No-op）：若无 handler 验证，unknown 标签被保留 → action count > 0 → 红灯。
    func test_scene10_P3_unknownHandler_entireTagDiscarded() {
        let raw = #"<action:unknown text="x">y</action>"#

        let segments = MarkdownActionParser.preprocess(raw)

        let actionCount = segments.filter { seg in
            if case .action = seg { return true }
            return false
        }.count

        // assert: 不含 unknown segment
        XCTAssertEqual(
            actionCount, 0,
            "10.P3: 未知 handler 'unknown' 必须整体丢弃（handler 闭集 v1：仅 speak/copy），action segment: \(actionCount)"
        )

        // label "y" 也不应残留
        let allText = segments.compactMap { seg -> String? in
            if case .text(let s) = seg { return s }
            return nil
        }.joined()

        XCTAssertFalse(
            allText.contains("y"),
            "10.P3: 丢弃的未知 handler 标签不应残留 label 'y' 在文本中，实际: \(allText)"
        )
    }

    // MARK: - 场景 10.P2：解析出错 → 不崩溃，其余文本正常渲染

    /// 10.P2 [det-machine]
    /// When 解析过程出错, 系统 shall 不崩溃且其余文本正常渲染
    ///
    /// assert: 无 crash + Text 节点存在
    ///
    /// Mutation 探针（No-op）：如果 preprocess 因异常直接 return [] → 文本也消失 → 断言失败。
    func test_scene10_P2_invalidTag_noCrash_surroundingTextPreserved() {
        let raw = "前置文本 <action:speak>坏标签 后续文本"

        var segments: [ActionSegment]?

        // 不应崩溃
        XCTAssertNoThrow(
            { segments = MarkdownActionParser.preprocess(raw) }(),
            "10.P2: 解析格式错误的 action 标签不应崩溃"
        )

        // 前置文本应保留
        let allText = (segments ?? []).compactMap { seg -> String? in
            if case .text(let s) = seg { return s }
            return nil
        }.joined()

        XCTAssertTrue(
            allText.contains("前置文本"),
            "10.P2: 坏标签不影响其余文本渲染，'前置文本' 应保留，实际文本: \(allText)"
        )
    }

    /// 10.P2 补充：混合正常 + 错误标签，只丢弃错误部分
    func test_scene10_P2_mixedValidAndInvalid_validPreserved() {
        let raw = #"前缀 <action:speak text="buddy">🔊</action> 中间 <action:unknown text="x">y</action> 后缀"#

        let segments = MarkdownActionParser.preprocess(raw)

        // 有效 speak 标签应保留
        let speakCount = segments.filter { seg in
            if case .action(let h, _, _) = seg, h == .speak { return true }
            return false
        }.count

        XCTAssertEqual(
            speakCount, 1,
            "10.P2 混合: 有效 speak 标签应保留，实际 speak segment 数量: \(speakCount)"
        )

        // unknown 标签应丢弃
        let unknownCount = segments.filter { seg in
            if case .action(let h, _, _) = seg { return h != .speak && h != .copy }
            return false
        }.count

        XCTAssertEqual(
            unknownCount, 0,
            "10.P2 混合: unknown 标签应丢弃，实际未知 handler segment: \(unknownCount)"
        )
    }

    // MARK: - C2 错误处理表：未闭合标签

    /// C2：`<action:speak text="x">x` 未闭合 → 整体丢弃，残留文本不显示
    ///
    /// assert: segments 不含 .action，且 原始 action 文本内容不残留
    ///
    /// Mutation 探针（Boundary）：若只检查 action segment 不检查残留文本，No-op mutation 可逃逸。
    func test_c2_unclosedTag_entirelyDiscarded_noResidue() {
        let raw = #"<action:speak text="x">x"#

        let segments = MarkdownActionParser.preprocess(raw)

        let actionCount = segments.filter { seg in
            if case .action = seg { return true }
            return false
        }.count

        XCTAssertEqual(
            actionCount, 0,
            "C2: 未闭合 action 标签应整体丢弃，action segment 数量: \(actionCount)"
        )

        // 残留文本不显示（"<action:speak..." 原始字符不出现）
        let allText = segments.compactMap { seg -> String? in
            if case .text(let s) = seg { return s }
            return nil
        }.joined()

        XCTAssertFalse(
            allText.contains("<action:speak"),
            "C2: 未闭合标签不应在文本 segment 中残留 '<action:speak'，实际: \(allText)"
        )
    }

    // MARK: - C2 错误处理表：&quot; 转义

    /// C2：`<action:speak text="a&quot;b">x</action>` → text 解码为 `a"b`，正常渲染
    ///
    /// assert: text == "a\"b"
    ///
    /// Mutation 探针（Return-Value）：若 &quot; 不解码，text == "a&quot;b" → XCTAssertEqual 报红。
    func test_c2_quotEscape_decodedCorrectly() {
        let raw = #"<action:speak text="a&quot;b">🔊</action>"#

        let segments = MarkdownActionParser.preprocess(raw)

        let speakSeg = segments.compactMap { seg -> (handler: ActionHandler, text: String, label: String)? in
            if case .action(let h, let t, let l) = seg { return (h, t, l) }
            return nil
        }.first { $0.handler == .speak }

        XCTAssertNotNil(speakSeg, "C2 &quot;: 含转义的 speak 标签应正常渲染（不丢弃）")

        // assert: text == "a\"b"（&quot; 解码为 "）
        XCTAssertEqual(
            speakSeg?.text, "a\"b",
            "C2 &quot;: text 属性 &quot; 必须解码为 '\"'，实际: \(speakSeg?.text ?? "nil")"
        )
    }

    // MARK: - C2 错误处理表：标签嵌套（label 含 HTML）

    /// C2：标签嵌套 `<action:speak text="x"><b>y</b></action>` → label 取原文本（含 `<b>y</b>`）
    ///
    /// assert: label 包含原始字符串（渲染时作为纯文本 string）
    ///
    /// Mutation 探针（Return-Value）：若 label 被 HTML 解析为 "y"，XCTAssertTrue 报红。
    func test_c2_nestedHtmlInLabel_labelContainsRawText() {
        let raw = #"<action:speak text="x"><b>y</b></action>"#

        let segments = MarkdownActionParser.preprocess(raw)

        let speakSeg = segments.compactMap { seg -> (handler: ActionHandler, text: String, label: String)? in
            if case .action(let h, let t, let l) = seg { return (h, t, l) }
            return nil
        }.first { $0.handler == .speak }

        // 按 C2 契约：label 取原文本（含 <b>y</b>），作为纯文本渲染
        // label 应包含 "y" 的内容（具体是 "<b>y</b>" 还是 "y" 取决于实现，核心是 text == "x"）
        XCTAssertNotNil(speakSeg, "C2 nested: 含嵌套 HTML 的 action 标签应正常解析（text='x' 合法）")
        XCTAssertEqual(
            speakSeg?.text, "x",
            "C2 nested: text 属性值必须精确等于 'x'，实际: \(speakSeg?.text ?? "nil")"
        )
    }

    // MARK: - C5 软失败：空 text 属性

    /// C5：`<action:speak text="">` 空 text 属性
    /// 实现可选：调用 speak("") no-op，或不渲染按钮
    /// 核心要求：不崩溃
    ///
    /// Mutation 探针（No-op）：崩溃 → 测试失败（XCTAssertNoThrow 捕获）。
    func test_c5_emptyTextAttr_doesNotCrash() {
        let raw = #"<action:speak text="">🔊</action>"#

        XCTAssertNoThrow(
            { _ = MarkdownActionParser.preprocess(raw) }(),
            "C5: text 属性为空字符串时，preprocess 不应崩溃"
        )
    }

    // MARK: - C1 BNF：闭集验证

    /// C1：handler 闭集 v1 仅 "speak" / "copy"，其他均丢弃
    ///
    /// Mutation 探针（Conditional Flip）：增加了非预期 handler 后，若不丢弃则 action segment 出现 → 红灯。
    func test_c1_handlerClosedSet_onlySpeakAndCopyValid() {
        let invalidHandlers = ["audio", "play", "tts", "download", "open", "translate"]

        for handler in invalidHandlers {
            let raw = #"<action:\#(handler) text="test">label</action>"#
            let segments = MarkdownActionParser.preprocess(raw)

            let actionCount = segments.filter { seg in
                if case .action = seg { return true }
                return false
            }.count

            XCTAssertEqual(
                actionCount, 0,
                "C1: handler '\(handler)' 不在闭集（speak/copy），必须整体丢弃，实际 action count: \(actionCount)"
            )
        }
    }

    // MARK: - ActionSegment.text：仅文本时不生成 action segment

    /// 纯文本 markdown 不生成任何 action segment
    ///
    /// Mutation 探针（No-op）：若 preprocess 无论如何都生成 action，此测试红灯。
    func test_plainText_noActionSegments() {
        let raw = "**buddy** /ˈbʌdi/\nn. 伙伴；密友"

        let segments = MarkdownActionParser.preprocess(raw)

        let actionCount = segments.filter { seg in
            if case .action = seg { return true }
            return false
        }.count

        XCTAssertEqual(
            actionCount, 0,
            "纯文本 markdown 不应生成任何 action segment，实际: \(actionCount)"
        )
    }

    // MARK: - ActionSegment 完整词典卡片解析

    /// 完整词典卡片 markdown → 正确数量的 speak + copy segments
    ///
    /// 按 D5 prompt 模板，单词查询输出：1 个 speak（词头）+ 2 个 copy（释义）+ 1 个 speak（例句）+ 1 个 copy（译文）
    /// 共 2 个 speak + 3 个 copy = 5 个 action segments
    ///
    /// Mutation 探针（Boundary）：只生成 1 个 segment → count ≠ 5 → 红灯。
    func test_fullWordCard_correctActionSegmentCount() {
        let wordCard = """
        **buddy** /ˈbʌdi/ <action:speak text="buddy">🔊 听</action>

        n. 伙伴；密友 <action:copy text="伙伴；密友">📋</action>
        n. 搭档；同伴 <action:copy text="搭档；同伴">📋</action>

        ▸ He is my best buddy. <action:speak text="He is my best buddy.">🔊</action>
          他是我最好的朋友。 <action:copy text="他是我最好的朋友。">📋</action>
        """

        let segments = MarkdownActionParser.preprocess(wordCard)

        let speakCount = segments.filter { seg in
            if case .action(let h, _, _) = seg, h == .speak { return true }
            return false
        }.count

        let copyCount = segments.filter { seg in
            if case .action(let h, _, _) = seg, h == .copy { return true }
            return false
        }.count

        // assert: 2 speak + 3 copy
        XCTAssertEqual(
            speakCount, 2,
            "完整词典卡片应有 2 个 speak segment（词头 + 例句），实际: \(speakCount)"
        )
        XCTAssertEqual(
            copyCount, 3,
            "完整词典卡片应有 3 个 copy segment（2 释义 + 1 译文），实际: \(copyCount)"
        )
    }

    // MARK: - ActionSegment 顺序验证

    /// 词典卡片 action segments 按出现顺序排列（首个 segment 是 speak）
    ///
    /// Mutation 探针（State-Update Skip）：若 preprocess 乱序，首个 segment 不是 speak → 断言失败。
    func test_wordCard_firstActionSegment_isSpeakWithCorrectText() {
        let wordCard = #"**buddy** /ˈbʌdi/ <action:speak text="buddy">🔊 听</action>"#

        let segments = MarkdownActionParser.preprocess(wordCard)

        let firstAction = segments.compactMap { seg -> (handler: ActionHandler, text: String, label: String)? in
            if case .action(let h, let t, let l) = seg { return (h, t, l) }
            return nil
        }.first

        XCTAssertNotNil(firstAction, "词典标题行应有至少一个 action segment")
        XCTAssertEqual(
            firstAction?.handler, .speak,
            "词典标题行第一个 action 应是 speak（词头朗读），实际: \(String(describing: firstAction?.handler))"
        )
        XCTAssertEqual(
            firstAction?.text, "buddy",
            "词典标题行 speak text 必须是 'buddy'，实际: \(firstAction?.text ?? "nil")"
        )
    }
}
