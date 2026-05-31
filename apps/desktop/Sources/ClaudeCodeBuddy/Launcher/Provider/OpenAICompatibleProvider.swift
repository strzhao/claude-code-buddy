import Foundation

/// OpenAI Chat Completions 兼容 Provider（Ollama / Qwen / DeepSeek 等）
/// URL: <baseURL>/chat/completions
/// Header: Authorization: Bearer <key>
/// Note: message content 是 string（不是 [Content] 数组）
final class OpenAICompatibleProvider: LauncherProvider {
    let apiKey: String
    let baseURL: URL
    private let session: URLSession
    /// noThinking=true 时注入 chat_template_kwargs.enable_thinking:false
    /// 实测结论：top-level enable_thinking 无效（41.9s），只有 chat_template_kwargs 通道生效（1.45s，17× 加速）
    private let chatTemplateKwargs: ChatTemplateKwargs?

    init(apiKey: String, baseURL: URL, noThinking: Bool = false, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.session = session
        self.chatTemplateKwargs = noThinking ? ChatTemplateKwargs(enableThinking: false) : nil
    }

    func send(messages: [AgentMessage], tools: [AgentTool], model: String, system: String? = nil) async throws -> AgentResponse {
        guard apiKey.count >= LauncherConstants.minAPIKeyLength else {
            throw LauncherError.invalidAPIKey("too short")
        }

        let url = baseURL.appendingPathComponent("chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = LauncherConstants.httpTimeoutSec

        // OpenAI 兼容协议：messages content 是 string（仅 MVP text 内容，tool_calls 留 task 003）
        var oaiMessages = messages.map { msg -> OAIMessage in
            let text = msg.content.compactMap { content -> String? in
                if case .text(let s) = content { return s }
                return nil
            }.joined(separator: "\n")
            return OAIMessage(role: msg.role, content: text)
        }
        if let system = system, !system.isEmpty {
            oaiMessages.insert(OAIMessage(role: "system", content: system), at: 0)
        }

        let body = OAIRequestBody(
            model: model,
            messages: oaiMessages,
            maxTokens: 4096,
            chatTemplateKwargs: chatTemplateKwargs
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LauncherError.networkFailure(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LauncherError.networkFailure(URLError(.badServerResponse))
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let bodySnippet = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw LauncherError.providerHTTPError(httpResponse.statusCode, bodySnippet)
        }

        // 解析 OpenAI 响应，转换为 AgentResponse
        let oaiResp = try JSONDecoder().decode(OAIResponse.self, from: data)
        let choice = oaiResp.choices.first
        let text = choice?.message.content ?? ""

        // finish_reason 映射
        let stopReason: String = {
            switch choice?.finishReason {
            case "stop": return "end_turn"
            case "length": return "max_tokens"
            case "tool_calls": return "tool_use"
            default: return choice?.finishReason ?? "end_turn"
            }
        }()

        let usage = oaiResp.usage.map { u in
            AgentUsage(inputTokens: u.promptTokens, outputTokens: u.completionTokens)
        }

        return AgentResponse(content: [.text(text)], stopReason: stopReason, usage: usage)
    }

    // MARK: - P1 SSE 流式

    func sendStream(
        messages: [AgentMessage],
        tools: [AgentTool],
        model: String,
        system: String? = nil
    ) async throws -> AsyncThrowingStream<ProviderChunk, Error> {
        guard apiKey.count >= LauncherConstants.minAPIKeyLength else {
            throw LauncherError.invalidAPIKey("too short")
        }

        let url = baseURL.appendingPathComponent("chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = LauncherConstants.httpTimeoutSec

        var oaiMessages = messages.map { msg -> OAIMessage in
            let text = msg.content.compactMap { content -> String? in
                if case .text(let s) = content { return s }
                return nil
            }.joined(separator: "\n")
            return OAIMessage(role: msg.role, content: text)
        }
        if let system = system, !system.isEmpty {
            oaiMessages.insert(OAIMessage(role: "system", content: system), at: 0)
        }

        let body = OAIRequestBodyStream(
            model: model,
            messages: oaiMessages,
            maxTokens: 4096,
            stream: true,
            chatTemplateKwargs: chatTemplateKwargs
        )
        request.httpBody = try JSONEncoder().encode(body)

        // 先获取 (bytes, response) 检查 HTTP 状态
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw LauncherError.networkFailure(error)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LauncherError.networkFailure(URLError(.badServerResponse))
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            // 读取前 200 字节作为错误提示
            var errorData = Data()
            for try await byte in bytes {
                errorData.append(byte)
                if errorData.count >= 200 { break }
            }
            let bodySnippet = String(data: errorData, encoding: .utf8) ?? ""
            throw LauncherError.providerHTTPError(httpResponse.statusCode, bodySnippet)
        }

        return Self.parseSSELines(bytes.lines)
    }

    /// SSE 行级 parser（纯函数化）：接受任意 `AsyncSequence<String>` 行序列，输出 ProviderChunk 流
    /// 抽出便于测试（避免 URLSession.AsyncBytes 的 mock 困境）
    static func parseSSELines<S: AsyncSequence & Sendable>(
        _ lines: S
    ) -> AsyncThrowingStream<ProviderChunk, Error> where S.Element == String {
        let decoder = JSONDecoder()
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in lines {
                        guard !line.isEmpty else { continue }
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        if payload == "[DONE]" {
                            continuation.yield(.done(reason: "stop"))
                            continuation.finish()
                            return
                        }
                        guard let data = payload.data(using: .utf8) else { continue }
                        guard let chunk = try? decoder.decode(OAIStreamChunk.self, from: data) else { continue }
                        if let content = chunk.choices.first?.delta.content, !content.isEmpty {
                            continuation.yield(.text(content))
                        }
                    }
                    // 流自然结束（未收到 [DONE]）
                    continuation.yield(.done(reason: "stop"))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: LauncherError.networkFailure(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Request / Response Types

private struct OAIMessage: Codable {
    let role: String
    let content: String?
}

/// Qwen3 thinking 控制通道（chat_template_kwargs.enable_thinking）
/// 实测：top-level enable_thinking 无效，必须走 chat_template_kwargs
struct ChatTemplateKwargs: Codable {
    let enableThinking: Bool?

    private enum CodingKeys: String, CodingKey {
        case enableThinking = "enable_thinking"
    }
}

private struct OAIRequestBody: Encodable {
    let model: String
    let messages: [OAIMessage]
    let maxTokens: Int
    /// noThinking=true 时注入，nil 时不序列化（encodeIfPresent 跳过 nil）
    let chatTemplateKwargs: ChatTemplateKwargs?

    private enum CodingKeys: String, CodingKey {
        case model
        case messages
        case maxTokens = "max_tokens"
        case chatTemplateKwargs = "chat_template_kwargs"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(messages, forKey: .messages)
        try container.encode(maxTokens, forKey: .maxTokens)
        try container.encodeIfPresent(chatTemplateKwargs, forKey: .chatTemplateKwargs)
    }
}

/// 流式请求体（含 stream: true）
private struct OAIRequestBodyStream: Encodable {
    let model: String
    let messages: [OAIMessage]
    let maxTokens: Int
    let stream: Bool
    let chatTemplateKwargs: ChatTemplateKwargs?

    private enum CodingKeys: String, CodingKey {
        case model
        case messages
        case maxTokens = "max_tokens"
        case stream
        case chatTemplateKwargs = "chat_template_kwargs"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(messages, forKey: .messages)
        try container.encode(maxTokens, forKey: .maxTokens)
        try container.encode(stream, forKey: .stream)
        try container.encodeIfPresent(chatTemplateKwargs, forKey: .chatTemplateKwargs)
    }
}

/// SSE stream chunk: data.choices[0].delta.content
private struct OAIStreamChunk: Decodable {
    let choices: [OAIStreamChoice]
}

private struct OAIStreamChoice: Decodable {
    let delta: OAIDelta
}

private struct OAIDelta: Decodable {
    let content: String?
}

private struct OAIResponseChoice: Decodable {
    let message: OAIMessage
    let finishReason: String?

    private enum CodingKeys: String, CodingKey {
        case message
        case finishReason = "finish_reason"
    }
}

private struct OAIResponseUsage: Decodable {
    let promptTokens: Int
    let completionTokens: Int

    private enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
    }
}

private struct OAIResponse: Decodable {
    let choices: [OAIResponseChoice]
    let usage: OAIResponseUsage?
}
