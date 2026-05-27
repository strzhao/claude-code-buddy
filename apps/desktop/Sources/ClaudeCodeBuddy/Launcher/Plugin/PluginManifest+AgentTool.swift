import Foundation

extension PluginManifest {
    /// **关键契约（BLOCKER-2）**：inputSchema 必须含顶层 "type":"object"，否则 Anthropic API 返回 400
    /// 参考 LauncherManager.swift:126-134 echo stub 的完整 inputSchema 格式。
    func toAgentTool() -> AgentTool {
        AgentTool(
            name: name,
            description: description,
            inputSchema: [
                "type": AnyCodable("object"),          // ⚠️ 顶层 type 必填
                "properties": AnyCodable([
                    "query": ["type": "string", "description": "用户原始查询"] as [String: String]
                ]),
                "required": AnyCodable(["query"])
            ]
        )
    }
}
