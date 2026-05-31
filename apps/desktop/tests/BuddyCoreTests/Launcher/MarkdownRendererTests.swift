import XCTest
@testable import BuddyCore

final class MarkdownRendererTests: XCTestCase {

    // 1. 标题 `# H1` → AttributedString 不为空，且包含标题文字
    func test_render_heading_producesNonEmptyResult() {
        let input = "# Hello World"
        let result = MarkdownRenderer.render(input)
        let text = String(result.characters)
        XCTAssertFalse(text.isEmpty, "Rendered heading should not be empty")
        XCTAssertTrue(text.contains("Hello World"), "Rendered heading should contain 'Hello World'")
    }

    // 2. 列表 `- item` → 不为空
    func test_render_list_producesNonEmptyResult() {
        let input = "- item1\n- item2\n- item3"
        let result = MarkdownRenderer.render(input)
        let text = String(result.characters)
        XCTAssertFalse(text.isEmpty, "Rendered list should not be empty")
        XCTAssertTrue(text.contains("item1"), "Rendered list should contain 'item1'")
        XCTAssertTrue(text.contains("item2"), "Rendered list should contain 'item2'")
    }

    // 3. 代码块 → 不崩溃，且包含代码文字
    func test_render_codeBlock_doesNotCrash() {
        let input = "```swift\nlet x = 1\n```"
        // 不崩溃是关键
        let result = MarkdownRenderer.render(input)
        let text = String(result.characters)
        XCTAssertFalse(text.isEmpty, "Rendered code block should not be empty")
    }

    // 4. 链接 `[text](url)` → 不崩溃，包含文字
    func test_render_link_doesNotCrash() {
        let input = "[Click here](https://example.com)"
        let result = MarkdownRenderer.render(input)
        let text = String(result.characters)
        XCTAssertFalse(text.isEmpty, "Rendered link should not be empty")
        XCTAssertTrue(text.contains("Click here"), "Rendered link should contain link text")
    }

    // 5. 未闭合代码块（流式中间态）→ 不崩溃，降级渲染
    func test_render_unclosedCodeBlock_doesNotCrash() {
        let input = "```swift\nlet x = 1"  // 未闭合
        // 关键：不崩溃
        let result = MarkdownRenderer.render(input)
        let text = String(result.characters)
        XCTAssertFalse(text.isEmpty, "Rendering unclosed code block should not crash and return something")
    }

    // 6. 流式累积 5 段，每段渲染都不崩溃
    func test_render_streamingAccumulation_doesNotCrash() {
        let segments = [
            "# Title\n\n",
            "- item1\n",
            "- item2\n\n",
            "```swift\nlet x = 1\n",     // 未闭合
            "let y = 2\n```\n"
        ]

        var buffer = ""
        for segment in segments {
            buffer += segment
            // 每段累积后渲染，不崩溃
            let result = MarkdownRenderer.render(buffer)
            let text = String(result.characters)
            XCTAssertFalse(text.isEmpty, "Accumulated render should not be empty after segment: \(segment.prefix(20))")
        }

        // 最终完整渲染
        let finalResult = MarkdownRenderer.render(buffer)
        let finalText = String(finalResult.characters)
        XCTAssertTrue(finalText.contains("Title"), "Final render should contain 'Title'")
        XCTAssertTrue(finalText.contains("item1"), "Final render should contain 'item1'")
    }

    // 7. renderError 包含 ⚠️ 前缀
    func test_renderError_containsWarningPrefix() {
        let error = LauncherError.providerNotConfigured
        let result = MarkdownRenderer.renderError(error)
        let text = String(result.characters)
        XCTAssertTrue(text.contains("⚠️"), "renderError should contain ⚠️ prefix")
    }

    // 8. renderError 包含错误描述
    func test_renderError_containsErrorDescription() {
        let error = LauncherError.maxIterations
        let result = MarkdownRenderer.renderError(error)
        let text = String(result.characters)
        XCTAssertFalse(text.isEmpty, "renderError should not be empty")
        XCTAssertTrue(
            text.contains("Agent") || text.contains("循环") || text.contains("迭代"),
            "renderError for maxIterations should contain relevant Chinese text"
        )
    }

    // 9. 空字符串 → 不崩溃
    func test_render_emptyString_doesNotCrash() {
        let result = MarkdownRenderer.render("")
        let text = String(result.characters)
        // 空字符串可能产生空结果，不崩溃即可
        XCTAssertNotNil(result, "render('') should not return nil")
        _ = text  // 不崩溃
    }

    // 10. 纯文本（无 markdown 格式）→ 原样返回文字
    func test_render_plainText_preservesText() {
        let input = "Hello, 世界！"
        let result = MarkdownRenderer.render(input)
        let text = String(result.characters)
        XCTAssertTrue(
            text.contains("Hello") && text.contains("世界"),
            "Plain text should be preserved in rendered output"
        )
    }

    // MARK: - 泄漏的 <action> 标签剥离（按钮只走 tool_calls 通道）

    // 11. 自闭合 <action .../> 标签从正文剥离，正文其余内容保留
    func test_stripLeakedActionTags_selfClosing_removed() {
        let input = "He is my best buddy.\n<action kind=\"speak\" text=\"He is my best buddy.\"/>"
        let out = MarkdownRenderer.stripLeakedActionTags(input)
        XCTAssertFalse(out.contains("<action"), "self-closing action tag must be stripped")
        XCTAssertTrue(out.contains("He is my best buddy."), "surrounding prose must survive")
    }

    // 12. 渲染输出里不残留任何 <action 字面
    func test_render_doesNotLeakActionMarkup() {
        let input = "**buddy** n. 朋友\n<action kind=\"speak\" text=\"buddy\"/>\n<action kind=\"copy\" text=\"朋友\"/>"
        let text = String(MarkdownRenderer.render(input).characters)
        XCTAssertFalse(text.contains("<action"), "rendered text must not contain raw action markup")
        XCTAssertFalse(text.contains("kind="), "rendered text must not contain tag attributes")
        XCTAssertTrue(text.contains("buddy"), "translation body must remain visible")
    }

    // 13. 成对 <action>...</action> 标签剥离
    func test_stripLeakedActionTags_paired_removed() {
        let input = "正文\n<action kind=\"copy\" text=\"x\">复制</action>\n结尾"
        let out = MarkdownRenderer.stripLeakedActionTags(input)
        XCTAssertFalse(out.contains("<action"))
        XCTAssertFalse(out.contains("</action>"))
        XCTAssertTrue(out.contains("正文") && out.contains("结尾"))
    }

    // 14. 流式中途未闭合的 `<action ...` 尾巴也截掉，避免边打字边闪
    func test_stripLeakedActionTags_streamingPartialTail_removed() {
        let input = "完整译文。\n<action kind=\"speak\" text=\"hel"
        let out = MarkdownRenderer.stripLeakedActionTags(input)
        XCTAssertFalse(out.contains("<action"), "unclosed trailing action fragment must be stripped")
        XCTAssertTrue(out.contains("完整译文。"), "body before the fragment must survive")
    }

    // 15. 无标签的普通文本不受影响
    func test_stripLeakedActionTags_noTags_unchanged() {
        let input = "这是一段没有任何标签的纯文本。\n带 < 和 > 符号也不误删。"
        XCTAssertEqual(MarkdownRenderer.stripLeakedActionTags(input), input)
    }

    // 16. 真实泄漏样本：列表项内的成对标签 → 标签删掉 + 残留空 bullet 整行去掉
    //     来自 dry-run：`*   <action kind="speak" text="He's my best buddy."></action>`
    func test_stripLeakedActionTags_realSample_listItemPairedTag() {
        let input = "**buddy** 释义：\n*   <action kind=\"speak\" text=\"He's my best buddy.\"></action>\n下一段"
        let out = MarkdownRenderer.stripLeakedActionTags(input)
        XCTAssertFalse(out.contains("<action"), "tag must be gone")
        XCTAssertFalse(out.contains("He's my best buddy."), "leaked button text inside tag must be gone")
        XCTAssertFalse(out.contains("\n*   \n") || out.hasSuffix("*   "), "empty bullet residue must be removed")
        XCTAssertTrue(out.contains("释义") && out.contains("下一段"), "real prose must survive")
    }

    // 17. 真实泄漏样本：落单的开标签 <action>（无 /> 无配对）也要清掉
    func test_stripLeakedActionTags_orphanOpenTag_removed() {
        let input = "正文一\n<action>\n正文二"
        let out = MarkdownRenderer.stripLeakedActionTags(input)
        XCTAssertFalse(out.contains("<action"), "orphan open tag must be stripped")
        XCTAssertTrue(out.contains("正文一") && out.contains("正文二"))
    }

    // 18. 落单的闭标签 </action> 也清掉
    func test_stripLeakedActionTags_orphanCloseTag_removed() {
        let input = "结果文本</action>"
        let out = MarkdownRenderer.stripLeakedActionTags(input)
        XCTAssertFalse(out.contains("</action>"))
        XCTAssertTrue(out.contains("结果文本"))
    }
}
