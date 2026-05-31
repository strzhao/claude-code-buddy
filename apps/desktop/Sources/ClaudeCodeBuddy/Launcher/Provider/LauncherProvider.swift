import Foundation

/// 流式 chunk 枚举（P1 SSE）
enum ProviderChunk: Equatable {
    case text(String)
    /// render-only meta tool 调用：模型声明一个按钮（不立即执行）。
    /// 在流结束（[DONE]）时由 provider 把累积的 tool_calls 解析后逐个 emit。
    case action(LauncherActionButton)
    case done(reason: String?)
}

/// Provider 协议：发送 messages → 返回 AgentResponse
protocol LauncherProvider {
    func send(messages: [AgentMessage], tools: [AgentTool], model: String, system: String?) async throws -> AgentResponse

    /// 流式版本：返回 AsyncThrowingStream<ProviderChunk, Error>
    /// 默认实现：调 send → 包成单 chunk emit + done，保证 anthropic / mock provider 免改
    func sendStream(messages: [AgentMessage], tools: [AgentTool], model: String, system: String?) async throws -> AsyncThrowingStream<ProviderChunk, Error>
}

// MARK: - 默认实现（fallback：非流式 provider 自动兼容）
extension LauncherProvider {
    /// 便利重载：system 默认 nil（供测试和无 system 场景调用）
    func sendStream(
        messages: [AgentMessage],
        tools: [AgentTool],
        model: String
    ) async throws -> AsyncThrowingStream<ProviderChunk, Error> {
        return try await sendStream(messages: messages, tools: tools, model: model, system: nil)
    }

    func sendStream(
        messages: [AgentMessage],
        tools: [AgentTool],
        model: String,
        system: String?
    ) async throws -> AsyncThrowingStream<ProviderChunk, Error> {
        let response = try await send(messages: messages, tools: tools, model: model, system: system)
        let text = response.content.compactMap { c -> String? in
            if case .text(let s) = c { return s }
            return nil
        }.joined()
        let stopReason = response.stopReason
        return AsyncThrowingStream { continuation in
            if !text.isEmpty {
                continuation.yield(.text(text))
            }
            continuation.yield(.done(reason: stopReason))
            continuation.finish()
        }
    }
}
