import Foundation

/// 永远 loop + tool_use 早停（learn-everything v1 76 行 Swift 翻译）
///
/// 算法：
///   while round in 1...maxIterations:
///     resp = provider.send(messages, tools)
///     yield text content (增量)
///     append assistant message
///     if stop_reason != "tool_use": yield .done(reason); break
///     execute tool_use items, yield toolCall/toolResult
///     append tool_result messages (Anthropic 协议放 user 消息的 content 数组)
///   if reached max: yield .error(.maxIterations)
final class LauncherAgent {
    private let provider: LauncherProvider
    private let tools: [AgentTool]
    private let model: String
    private let toolExecutor: (String, [String: AnyCodable]) async throws -> String

    init(
        provider: LauncherProvider,
        tools: [AgentTool],
        model: String,
        toolExecutor: @escaping (String, [String: AnyCodable]) async throws -> String
    ) {
        self.provider = provider
        self.tools = tools
        self.model = model
        self.toolExecutor = toolExecutor
    }

    func run(prompt: String, config: AgentLoopConfig = .default) -> AsyncStream<AgentEvent> {
        AsyncStream { continuation in
            let task = Task { [provider, tools, model, toolExecutor] in
                var messages: [AgentMessage] = [
                    AgentMessage(role: "user", content: [.text(prompt)])
                ]

                for _ in 1...config.maxIterations {
                    // 检查取消
                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }

                    let resp: AgentResponse
                    do {
                        resp = try await provider.send(messages: messages, tools: tools, model: model, system: nil)
                    } catch let err as LauncherError {
                        continuation.yield(.error(err))
                        continuation.finish()
                        return
                    } catch {
                        continuation.yield(.error(.networkFailure(error)))
                        continuation.finish()
                        return
                    }

                    // 增量 yield text content
                    for item in resp.content {
                        if case .text(let s) = item {
                            continuation.yield(.text(s))
                        }
                    }

                    // 追加 assistant message
                    messages.append(AgentMessage(role: "assistant", content: resp.content))

                    if resp.stopReason != "tool_use" {
                        continuation.yield(.done(reason: resp.stopReason))
                        continuation.finish()
                        return
                    }

                    // 执行所有 tool_use → 拼 tool_result
                    var toolResults: [AgentContent] = []
                    for item in resp.content {
                        if case .toolUse(let id, let name, let input) = item {
                            continuation.yield(.toolCall(name: name, input: input))
                            let output: String
                            let isError: Bool
                            do {
                                output = try await toolExecutor(name, input)
                                isError = false
                            } catch {
                                output = "Tool failed: \(error.localizedDescription)"
                                isError = true
                            }
                            continuation.yield(.toolResult(name: name, output: output, isError: isError))
                            toolResults.append(.toolResult(toolUseId: id, content: output, isError: isError))
                        }
                    }
                    // tool_result 在 Anthropic 协议里走 user 消息
                    messages.append(AgentMessage(role: "user", content: toolResults))
                }

                // 达到 max iterations
                continuation.yield(.error(.maxIterations))
                continuation.finish()
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
