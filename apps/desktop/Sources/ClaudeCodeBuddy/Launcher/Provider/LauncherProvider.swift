import Foundation

/// Provider 协议：发送 messages → 返回 AgentResponse
protocol LauncherProvider {
    func send(messages: [AgentMessage], tools: [AgentTool], model: String) async throws -> AgentResponse
}
