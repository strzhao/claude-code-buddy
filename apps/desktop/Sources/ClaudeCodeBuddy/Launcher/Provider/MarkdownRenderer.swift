import Foundation

/// Markdown 渲染工具：将字符串转为 AttributedString
enum MarkdownRenderer {

    /// 将 Markdown 文本渲染为 AttributedString（支持内联样式）
    static func render(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
    }

    /// 将 LauncherError 渲染为带红色前缀的 AttributedString
    static func renderError(_ error: LauncherError) -> AttributedString {
        var result = AttributedString("⚠️ " + (error.errorDescription ?? "未知错误"))
        result.foregroundColor = .red
        return result
    }
}
