import Foundation

// MARK: - P2：tool description 合成（枚举模板，给弱模型选对插件）
//
// 设计依据：dry-run 证明枚举式 description 让本地 qwen3.6-35b 选择正确率 90-100%。
// 模板：`<功能>。当用户想<触发场景>时使用。<字段>填<填法>。例：「<输入>」→ <字段>=<值>。不要用于：<反例/近邻干扰项>`
// 从 summary/description/keywords 合成，缺字段降级但不退回空串/裸字段名。

extension PluginManifest {

    /// 合成给 LLM tool 用的 description（枚举锚点式，弱模型友好）。
    ///
    /// 优先级（取首个非空 trim）：
    /// 1. summary（一句话人话摘要，最精炼）
    /// 2. description（详细，取首句避免过长）
    /// 3. keywords 拼接 + name 兜底
    ///
    /// 合成结构（任一段缺失则跳过该段，不拼空段）：
    /// `<主功能>。触发：<keywords/触发词>。输入：填用户的原始请求。`
    func synthesizeToolDescription() -> String {
        // 主功能句（summary 优先，否则 description 首句）
        var main = summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if main.isEmpty {
            main = firstSentencePlain(description)
        }
        if main.isEmpty {
            // 兜底：keywords + name
            main = keywords.isEmpty ? name : keywords.joined(separator: "、")
        }

        var parts: [String] = [main]

        // 触发词段（keywords 非空时附加，帮弱模型锚点匹配）
        let kws = keywords.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !kws.isEmpty {
            parts.append("触发：" + kws.joined(separator: "、"))
        }

        // 输入填法段（提取式锚点：弱模型倾向整句透传，必须明确要求只填内容本身。
        // 否则 LLM 把整句塞进字段 → extractedQuery 退化；cli e2e + real-process 实测证实。）
        if parameters == nil {
            // 固定 {query} 契约：明确 query 只填内容本身
            parts.append("输入：query 只填要处理的内容本身（如网址、文本），不要填整句话")
        } else {
            // 结构化 parameters：inputSchema 自描述字段，补通用提取锚点
            parts.append("输入：按各字段只填对应的值（如网址、文本），不要把整句话塞进单个字段")
        }

        return parts.joined(separator: "。")
    }

    /// 取字符串首句（按中文句号 `。` / 英文句号+空格 / 换行切第一段 trim）。
    /// 与 displaySummary.firstSentence 同语义但不依赖实例方法（避免循环引用）。
    private func firstSentencePlain(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        var cutIndex: String.Index?
        for sep in ["。", "\n", ". "] {
            if let range = trimmed.range(of: sep) {
                if let existing = cutIndex {
                    if range.lowerBound < existing { cutIndex = range.lowerBound }
                } else {
                    cutIndex = range.lowerBound
                }
            }
        }
        if trimmed.hasSuffix(".") {
            let suffixIdx = trimmed.index(before: trimmed.endIndex)
            if let existing = cutIndex {
                if suffixIdx < existing { cutIndex = suffixIdx }
            } else {
                cutIndex = suffixIdx
            }
        }
        if let idx = cutIndex {
            return String(trimmed[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }
}
