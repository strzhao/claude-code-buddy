import Foundation

/// OpenAI Chat Completions 兼容 Provider（Ollama / Qwen / DeepSeek 等）
/// URL: <baseURL>/chat/completions
/// Header: Authorization: Bearer <key>
/// Note: message content 是 string（不是 [Content] 数组）
final class OpenAICompatibleProvider: LauncherProvider {
    let apiKey: String
    let baseURL: URL
    private let session: URLSession

    init(apiKey: String, baseURL: URL, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.session = session
    }

    func send(messages: [AgentMessage], tools: [AgentTool], model: String) async throws -> AgentResponse {
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
        let oaiMessages = messages.map { msg -> OAIMessage in
            let text = msg.content.compactMap { content -> String? in
                if case .text(let s) = content { return s }
                return nil
            }.joined(separator: "\n")
            return OAIMessage(role: msg.role, content: text)
        }

        let body = OAIRequestBody(model: model, messages: oaiMessages, maxTokens: 4096)
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
}

// MARK: - Request / Response Types

private struct OAIMessage: Codable {
    let role: String
    let content: String?
}

private struct OAIRequestBody: Encodable {
    let model: String
    let messages: [OAIMessage]
    let maxTokens: Int

    private enum CodingKeys: String, CodingKey {
        case model
        case messages
        case maxTokens = "max_tokens"
    }
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
