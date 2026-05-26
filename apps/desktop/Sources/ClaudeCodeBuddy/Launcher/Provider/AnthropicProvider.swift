import Foundation

/// Anthropic Messages API 实现
/// URL: https://api.anthropic.com/v1/messages
/// Headers: x-api-key + anthropic-version: 2023-06-01
final class AnthropicProvider: LauncherProvider {
    private let apiKey: String
    private let session: URLSession

    init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    func send(messages: [AgentMessage], tools: [AgentTool], model: String) async throws -> AgentResponse {
        guard apiKey.count >= LauncherConstants.minAPIKeyLength else {
            throw LauncherError.invalidAPIKey("too short")
        }

        // swiftlint:disable:next force_unwrapping
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = LauncherConstants.httpTimeoutSec

        let body = AnthropicRequestBody(
            model: model,
            maxTokens: 4096,
            messages: messages,
            tools: tools.isEmpty ? nil : tools
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

        return try JSONDecoder().decode(AgentResponse.self, from: data)
    }
}

// MARK: - Request Body

private struct AnthropicRequestBody: Encodable {
    let model: String
    let maxTokens: Int
    let messages: [AgentMessage]
    let tools: [AgentTool]?

    private enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case messages
        case tools
    }
}
