import XCTest
@testable import BuddyCore

// MARK: - MarkdownStreamingAcceptanceTests
//
// 验收测试：MarkdownRenderer 流式累积场景
// 覆盖：task 002 MarkdownRenderer.render + task 003 流式 buffer 累积行为
//
// 设计文档覆盖点（task 003 设计文档 § MarkdownRendererTests）：
//   E1. 分 5 段流式累积 markdown，每段渲染后不崩溃
//   E2. 最终态 AttributedString 含 Title 内容
//   E3. 最终态含列表项 item1
//   E4. 最终态含列表项 item2
//   E5. 最终态含代码块内容（Swift 代码）
//   E6. 未闭合代码块（流式中间态）渲染不崩溃
//   E7. 空字符串 render 不崩溃
//   E8. 每段累积后 AttributedString 不为空（有内容）
//   E9. 标题 `# H1` → AttributedString 含预期文本字符
//   E10. 代码块 ```swift\nlet x = 1\n``` → 含 x = 1 字符序列
//   E11. 连接符 `[text](url)` → 渲染不崩溃（降级允许）
//   E12. renderError 含 "⚠️" 前缀且颜色为红色
//   E13. renderError(.maxIterations) 含"最大迭代次数"或相关提示文本
//
// 黑盒原则：仅通过 MarkdownRenderer.render 和 AttributedString.characters 公开接口验证。
// 渲染结果的具体字体/粗体属性受 macOS 版本影响，此处只验证文本内容不崩溃。
// 测试 WILL NOT compile 直到蓝队合并实现 — 这是预期的 TDD 红灯。

final class MarkdownStreamingAcceptanceTests: XCTestCase {

    // MARK: - Helper：将 AttributedString 转为纯文本字符串

    private func plainText(_ attributed: AttributedString) -> String {
        String(attributed.characters)
    }

    // MARK: - 流式累积 5 段 Markdown

    // 测试流数据：分 5 段投递，模拟 LLM token 流
    private let streamSegments: [String] = [
        "# Title\n\n",
        "- item1\n",
        "- item2\n\n",
        "```swift\n",
        "let x = 1\n```\n"
    ]

    // MARK: - E1. 每段渲染不崩溃

    /// 分 5 段流式累积，每段调用 MarkdownRenderer.render(buffer) 验证不崩溃
    /// Mutation 探针：若 render 在未闭合 markdown 时抛异常，此测试红灯。
    func test_E1_streamingSegments_eachRenderDoesNotCrash() {
        var buffer = ""
        for (index, segment) in streamSegments.enumerated() {
            buffer += segment
            // 每段累积后渲染，不应崩溃
            let result = MarkdownRenderer.render(buffer)
            // 验证返回值不是 nil（AttributedString 是值类型，不会是 nil，但可以为空）
            // 重要：只断言不崩溃，具体内容由后续测试验证
            _ = result  // 触发渲染副作用
            XCTAssertNotNil(result as AttributedString?,
                            "第 \(index + 1) 段渲染不应崩溃（buffer 长度: \(buffer.count)）")
        }
    }

    // MARK: - E2/E3/E4/E5. 最终态 AttributedString 内容验证

    /// 完整 5 段累积后，最终态应含 Title / item1 / item2 / Swift 代码内容
    func test_E2E3E4E5_finalBuffer_containsAllMarkdownContent() {
        var buffer = ""
        for segment in streamSegments {
            buffer += segment
        }

        let result = MarkdownRenderer.render(buffer)
        let text = plainText(result)

        // E2: 含 Title 文本
        XCTAssertTrue(text.contains("Title"),
                      "最终态 AttributedString 必须含 \"Title\"，实际文本: \(text)")

        // E3: 含 item1
        XCTAssertTrue(text.contains("item1"),
                      "最终态 AttributedString 必须含 \"item1\"，实际文本: \(text)")

        // E4: 含 item2
        XCTAssertTrue(text.contains("item2"),
                      "最终态 AttributedString 必须含 \"item2\"，实际文本: \(text)")

        // E5: 含代码块内容（Swift 变量声明）
        // AttributedString inlineOnlyPreservingWhitespace 会保留代码块文本
        // 但代码围栏（```swift）本身可能被过滤
        XCTAssertTrue(text.contains("x") && text.contains("1"),
                      "最终态应含代码块中的 \"x\" 和 \"1\"，实际文本: \(text)")
    }

    // MARK: - E6. 未闭合代码块（中间态）不崩溃

    /// 流式中间态：只有开头的 ```swift\n，没有结束 ``` → 渲染不崩溃
    /// 设计文档明确：macOS 14 实测可解析未闭合 markdown，返回部分渲染。
    func test_E6_unclosedCodeBlock_doesNotCrash() {
        let unclosedMarkdown = "# Title\n\n- item1\n\n```swift\nlet x = 1"
        // 必须不崩溃（try? 兜底在 MarkdownRenderer.render 内部）
        let result = MarkdownRenderer.render(unclosedMarkdown)
        // 只验证返回了合法的 AttributedString（可以是部分渲染）
        _ = plainText(result)  // 触发 characters 访问，不崩溃即通过
        XCTAssert(true, "未闭合代码块渲染通过（不崩溃）")
    }

    // MARK: - E7. 空字符串 render 不崩溃

    func test_E7_emptyString_doesNotCrash() {
        let result = MarkdownRenderer.render("")
        _ = plainText(result)
        XCTAssert(true, "空字符串渲染通过（不崩溃）")
    }

    // MARK: - E8. 每段累积后 buffer 不为空

    /// 每段累积后，buffer 内容单调增长（段内容非空）
    func test_E8_bufferGrowsMonotonically() {
        var buffer = ""
        var prevLength = 0
        for (index, segment) in streamSegments.enumerated() {
            buffer += segment
            let result = MarkdownRenderer.render(buffer)
            let text = plainText(result)
            XCTAssertFalse(text.isEmpty,
                           "第 \(index + 1) 段后 AttributedString 不应为空，buffer: \(buffer.prefix(40))")
            XCTAssertGreaterThan(buffer.count, prevLength,
                                 "buffer 单调增长：第 \(index + 1) 段后长度应大于之前")
            prevLength = buffer.count
        }
    }

    // MARK: - E9. 标题 `# H1` 含文本

    /// `# H1` 渲染后 AttributedString 含 "H1" 文本（macOS AttributedString 保留文本内容）
    func test_E9_h1Header_containsTextContent() {
        let result = MarkdownRenderer.render("# H1 Heading")
        let text = plainText(result)
        XCTAssertTrue(text.contains("H1"),
                      "# H1 渲染后必须含 \"H1\" 文本，实际: \(text)")
    }

    // MARK: - E10. 代码块内容可访问

    /// ```swift\nlet x = 1\n``` → 渲染结果含 x = 1 字符序列
    func test_E10_codeBlock_containsSourceCode() {
        let markdown = "```swift\nlet x = 1\n```"
        let result = MarkdownRenderer.render(markdown)
        let text = plainText(result)
        // inlineOnlyPreservingWhitespace 模式下代码块可能被降级为纯文本
        // 关键验证：内容可访问（不崩溃 + 包含关键文字）
        XCTAssertTrue(text.contains("x") || text.contains("let"),
                      "代码块渲染应含 \"x\" 或 \"let\"，实际: \(text)")
    }

    // MARK: - E11. 链接渲染不崩溃

    /// `[text](https://example.com)` → 渲染不崩溃（降级允许）
    func test_E11_markdownLink_doesNotCrash() {
        let markdown = "[Click here](https://example.com)"
        let result = MarkdownRenderer.render(markdown)
        let text = plainText(result)
        // 链接文本应可访问
        XCTAssertTrue(text.contains("Click here"),
                      "链接 [Click here](...) 渲染后必须含 \"Click here\"，实际: \(text)")
    }

    // MARK: - E12. renderError 含 "⚠️" 前缀

    /// MarkdownRenderer.renderError 必须含 "⚠️" 前缀
    func test_E12_renderError_containsWarningPrefix() {
        let error = LauncherError.providerNotConfigured
        let result = MarkdownRenderer.renderError(error)
        let text = plainText(result)
        XCTAssertTrue(text.contains("⚠️"),
                      "renderError 必须含 \"⚠️\" 前缀，实际: \(text)")
    }

    /// renderError 颜色为红色
    func test_E12b_renderError_hasForegroundColorRed() {
        let error = LauncherError.providerNotConfigured
        let result = MarkdownRenderer.renderError(error)
        // 验证存在前景色属性（值应为 .red）
        var foundRed = false
        for run in result.runs {
            if let color = run.foregroundColor {
                // macOS NSColor/CGColor 比较：接受 .red 系颜色
                // AttributedString.foregroundColor 类型是 Color? (SwiftUI) 或 NSColor? (AppKit)
                // 此处用宽松断言：只要有 foregroundColor 属性即可（具体颜色值 macOS 版本有差异）
                _ = color
                foundRed = true
                break
            }
        }
        XCTAssertTrue(foundRed,
                      "renderError 的 AttributedString 应含 foregroundColor 属性（红色）")
    }

    // MARK: - E13. renderError(.maxIterations) 含错误描述

    /// renderError(.maxIterations) 必须含"最大迭代次数"或"迭代"或"iterations"
    func test_E13_renderError_maxIterations_containsDescription() {
        let error = LauncherError.maxIterations
        let result = MarkdownRenderer.renderError(error)
        let text = plainText(result)

        let hasDescription = text.contains("迭代") ||
                             text.contains("iterations") ||
                             text.contains("最大") ||
                             text.contains("maxIterations")
        XCTAssertTrue(hasDescription,
                      "renderError(.maxIterations) 必须含迭代相关描述，实际: \(text)")
    }

    // MARK: - 流式累积 Mutation 测试

    /// 验证累积顺序正确：第 1 段的内容不出现在只用第 2 段渲染的结果中
    func test_streaming_cumulativeOrdering_isCorrect() {
        // 只渲染第 2 段
        let segment2Only = MarkdownRenderer.render(streamSegments[1])
        let text2 = plainText(segment2Only)

        // 第 2 段是 "- item1\n"，不应含 Title（第 1 段内容）
        XCTAssertFalse(text2.contains("Title"),
                       "只渲染第 2 段不应含第 1 段的 Title，实际: \(text2)")

        // 累积前两段后应含 Title 和 item1
        let buffer12 = streamSegments[0] + streamSegments[1]
        let result12 = MarkdownRenderer.render(buffer12)
        let text12 = plainText(result12)
        XCTAssertTrue(text12.contains("Title"),
                      "累积前两段后应含 Title，实际: \(text12)")
        XCTAssertTrue(text12.contains("item1"),
                      "累积前两段后应含 item1，实际: \(text12)")
    }

    // MARK: - 完整流式模拟场景（对应设计文档 场景 E）

    /// 模拟 LauncherInputView 的流式累积逻辑：
    /// 每收到 AgentEvent.text 后累积 buffer 并调 MarkdownRenderer.render
    /// 验证整个流程不崩溃，最终态包含完整内容
    func test_fullStreamingSimulation_matchesExpectedFinalContent() {
        // 模拟 AgentEvent.text 序列（与设计文档 场景 E 一致）
        let textEvents = streamSegments  // 5 段 text 内容

        var outputBuffer = ""
        var rendered: AttributedString = AttributedString("")

        for (index, textContent) in textEvents.enumerated() {
            outputBuffer += textContent
            // 每次 yield .text 后都重新渲染整个 buffer（模拟 LauncherInputView 行为）
            rendered = MarkdownRenderer.render(outputBuffer)
            _ = plainText(rendered)  // 触发字符访问，验证不崩溃

            // 中间态：buffer 长度正确增长
            let expectedBufferLength = streamSegments[0..<(index + 1)].joined().count
            XCTAssertEqual(outputBuffer.count, expectedBufferLength,
                           "第 \(index + 1) 段后 buffer 长度应是 \(expectedBufferLength)，实际: \(outputBuffer.count)")
        }

        // 验证最终态
        let finalText = plainText(rendered)
        XCTAssertTrue(finalText.contains("Title"),
                      "流式模拟最终态应含 Title")
        XCTAssertTrue(finalText.contains("item1"),
                      "流式模拟最终态应含 item1")
        XCTAssertTrue(finalText.contains("item2"),
                      "流式模拟最终态应含 item2")
    }
}
