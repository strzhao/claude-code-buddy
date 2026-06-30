import Foundation

extension PluginManifest {
    /// 转换为 LLM tool 定义。
    ///
    /// **P2 重写**：
    /// - description：用 `synthesizeToolDescription()`（枚举模板，弱模型锚点匹配）。
    /// - inputSchema：优先用 manifest.parameters（强制顶层 type:object，防 provider 400），
    ///   缺失→回退固定 {query} 契约（properties 含 query + required==["query"]）。
    ///
    /// **关键契约（BLOCKER-2 / C-TOOL-SCHEMA）**：inputSchema 必须含顶层 "type":"object"，
    /// 无论走 parameters 还是固定 {query} 分支。
    func toAgentTool() -> AgentTool {
        AgentTool(
            name: name,
            description: synthesizeToolDescription(),
            inputSchema: effectiveToolInputSchema()
        )
    }

    /// 计算 tool inputSchema：优先 parameters（强制 type:object），否则固定 {query}。
    func effectiveToolInputSchema() -> [String: AnyCodable] {
        if let parameters = parameters {
            // 复制 parameters 并强制顶层 type:object（防作者漏写或写错导致 provider 400）
            var schema = parameters
            schema["type"] = AnyCodable("object")
            return schema
        }
        // 回退固定 {query} 契约（C-PARAM-OPTIN）
        return [
            "type": AnyCodable("object"),
            "properties": AnyCodable([
                "query": ["type": "string", "description": "要处理的内容本身（如网址、文本），不要填整句话"] as [String: String]
            ]),
            "required": AnyCodable(["query"])
        ]
    }
}
