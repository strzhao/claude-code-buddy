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
}
