import Foundation

/// Markdown 渲染工具：将字符串转为 AttributedString
enum MarkdownRenderer {

    /// 将 Markdown 文本渲染为 AttributedString（支持内联样式 + block 预处理）
    ///
    /// AttributedString `.inlineOnly*` 模式不消化 block 级语法（`### heading` / `- list`），
    /// 会把 `### ` 当字面显示。这里先把 block 语法转成视觉等价的 inline 再 parse。
    static func render(_ markdown: String) -> AttributedString {
        let preprocessed = preprocessBlockMarkdown(stripLeakedActionTags(markdown))
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

    /// 剥离模型偶发泄漏到正文里的 `<action .../>` 工具标签。
    ///
    /// 按钮能力只走 tool_calls 通道（attach_action meta tool）。但本地 qwen 等弱模型
    /// 偶尔不发起 function call，转而把动作写成 XML 标签塞进正文 —— 这些纯属噪声，
    /// 渲染前一律清掉，绝不解析成按钮（文本驱动按钮太不稳定，已彻底废弃）。
    static func stripLeakedActionTags(_ raw: String) -> String {
        var text = raw
        // 1) 成对标签 <action ...>泄漏的按钮文本</action> —— 连同中间内容整段删
        text = text.replacingOccurrences(
            of: #"<action\b[^>]*>.*?</action>"#, with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        // 2) 自闭合 <action .../>
        text = text.replacingOccurrences(
            of: #"<action\b[^>]*/>"#, with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        // 3) 落单的开/闭标签 <action ...> 或 </action>（未配对、非自闭合）
        text = text.replacingOccurrences(
            of: #"</?action\b[^>]*>"#, with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        // 4) 流式中途尚未闭合的尾巴：`<action ...`（无收尾 `>`）截到结尾，避免边打字边闪
        if let r = text.range(of: #"<action\b[^>]*$"#, options: [.regularExpression, .caseInsensitive]) {
            text.removeSubrange(r)
        }
        // 5) 删标签后残留的纯列表标记空行（如 `*   ` / `- ` / `1. ` / `•`）整行去掉
        text = text
            .components(separatedBy: "\n")
            .filter { $0.range(of: #"^\s*([-*•]|\d+\.)\s*$"#, options: .regularExpression) == nil }
            .joined(separator: "\n")
        // 6) 行尾空白 + 连续空行收敛
        text = text.replacingOccurrences(of: #"[ \t]+(?=\n)"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return text
    }

    /// 将 LauncherError 渲染为带红色前缀的 AttributedString
    static func renderError(_ error: LauncherError) -> AttributedString {
        var result = AttributedString("⚠️ " + (error.errorDescription ?? "未知错误"))
        result.foregroundColor = .red
        return result
    }
}
