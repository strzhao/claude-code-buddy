import Foundation

/// Token 用量统计
struct AgentUsage: Codable, Equatable {
    let inputTokens: Int
    let outputTokens: Int

    private enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
    }
}

/// Provider 返回的完整响应
struct AgentResponse: Codable, Equatable {
    let content: [AgentContent]
    let stopReason: String  // "end_turn" | "tool_use" | "max_tokens" | "stop_sequence"
    let usage: AgentUsage?

    private enum CodingKeys: String, CodingKey {
        case content
        case stopReason = "stop_reason"
        case usage
    }
}
