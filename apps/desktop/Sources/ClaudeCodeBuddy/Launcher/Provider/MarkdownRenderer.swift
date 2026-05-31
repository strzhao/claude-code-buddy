import Foundation

/// Markdown 渲染工具：将字符串转为 AttributedString
enum MarkdownRenderer {

    /// 将 Markdown 文本渲染为 AttributedString（支持内联样式 + block 预处理）
    ///
    /// AttributedString `.inlineOnly*` 模式不消化 block 级语法（`### heading` / `- list`），
    /// 会把 `### ` 当字面显示。这里先把 block 语法转成视觉等价的 inline 再 parse。
    static func render(_ markdown: String) -> AttributedString {
        let preprocessed = preprocessBlockMarkdown(markdown)
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: preprocessed, options: options)) ?? AttributedString(preprocessed)
    }

    /// 行级预处理：把 block markdown 转成 inline 友好形式
    /// - `### text` (任意 #) → `**text**`
    /// - `- text` / `* text` → `• text`（保留前导缩进）
    /// - `1. text` → 不动（数字列表本身视觉 OK）
    /// - `---` 分割线 → 空行 + `─────` 等长划线（避免显示字面 `---`）
    private static func preprocessBlockMarkdown(_ raw: String) -> String {
        raw.components(separatedBy: "\n").map { line -> String in
            // ATX heading: ### / ## / # ... → **content**
            if let m = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                let content = String(line[m.upperBound...]).trimmingCharacters(in: .whitespaces)
                return "**\(content)**"
            }
            // 无序列表: - foo / * foo → • foo（保留缩进）
            if let m = line.range(of: #"^(\s*)[-*]\s+"#, options: .regularExpression) {
                let prefix = String(line[m.lowerBound..<m.upperBound])
                let indent = prefix.prefix { $0.isWhitespace }
                let content = String(line[m.upperBound...])
                return "\(indent)• \(content)"
            }
            // 分割线: --- / *** → ─────
            if line.range(of: #"^\s*(-{3,}|\*{3,})\s*$"#, options: .regularExpression) != nil {
                return "─────"
            }
            return line
        }.joined(separator: "\n")
    }

    /// 将 LauncherError 渲染为带红色前缀的 AttributedString
    static func renderError(_ error: LauncherError) -> AttributedString {
        var result = AttributedString("⚠️ " + (error.errorDescription ?? "未知错误"))
        result.foregroundColor = .red
        return result
    }
}
