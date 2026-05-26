import XCTest
import Security
import CryptoKit
@testable import BuddyCore

// MARK: - MockURLProtocol
//
// URLProtocol mock，用于拦截 URLSession 请求，不发出真实网络请求。
// 每个测试用例设置 requestHandler 然后通过注入了 MockURLProtocol 的 session 构造 Provider。

final class MockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data?))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    /// URLSession 内部把 httpBody 转为 httpBodyStream 再传给 URLProtocol，导致 request.httpBody 永远是 nil。
    /// 这里把 stream 内容读回 httpBody，让上层断言 `request.httpBody` 不再 nil。
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        guard request.httpBody == nil, let stream = request.httpBodyStream else { return request }
        var mutable = request
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read > 0 { data.append(buffer, count: read) } else { break }
        }
        mutable.httpBody = data
        return mutable
    }

    override func startLoading() {
        guard let handler = MockURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError:
                NSError(domain: "MockURLProtocol", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "No handler registered"]))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let data = data {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// MARK: - LauncherProviderAcceptanceTests
//
// 验收测试：LauncherProvider 协议形态 + 错误抛出契约（URLProtocol mock）
//
// 设计文档覆盖点（task 002 输出契约）：
//   A. AnthropicProvider.send 发送的 request 含 x-api-key header
//   B. AnthropicProvider.send 发送的 request 含 anthropic-version: 2023-06-01
//   C. request body 含 "max_tokens":4096
//   D. HTTP 4xx → 抛 LauncherError.providerHTTPError(code, body)，body 长度 ≤ 200
//   E. HTTP 5xx → 抛 LauncherError.providerHTTPError(500, ...)
//   F. 非法 JSON 响应 → 抛 LauncherError.networkFailure 或 DecodingError
//   G. API key 长度 < 8 → 抛 LauncherError.invalidAPIKey（不发网络请求）
//   H. OpenAICompatibleProvider 发送的 request 含 Authorization: Bearer <key>
//   I. OpenAICompatibleProvider URL path 含 /chat/completions
//   J. OAI 响应 finish_reason:"stop" → AgentResponse.stopReason == "end_turn"
//   K. OAI 响应 finish_reason:"length" → AgentResponse.stopReason == "max_tokens"
//   L. AnthropicProvider 正常 200 响应 → 返回 AgentResponse（内容正确）
//
// CONTRACT_AMBIGUOUS 注记：
//   AnthropicProvider(apiKey:session:) 和 OpenAICompatibleProvider(apiKey:baseURL:session:)
//   设计文档草图已明确包含 session 参数，红队据此编写测试。
//   若蓝队没有暴露 session 注入，此测试编译失败，视为接口契约违反。
//
// 测试 WILL NOT compile 直到蓝队合并实现 — 这是预期的 TDD 红灯。

final class LauncherProviderAcceptanceTests: XCTestCase {

    private var mockSession: URLSession!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        mockSession = URLSession(configuration: config)
        MockURLProtocol.requestHandler = nil
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        mockSession = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeAnthropicProvider(apiKey: String = "sk-ant-valid-key-1234") -> AnthropicProvider {
        return AnthropicProvider(apiKey: apiKey, session: mockSession)
    }

    private func makeOAIProvider(
        apiKey: String = "ollama-valid-key-123",
        baseURL: URL = URL(string: "http://localhost:11434/v1")!
    ) -> OpenAICompatibleProvider {
        return OpenAICompatibleProvider(apiKey: apiKey, baseURL: baseURL, session: mockSession)
    }

    private func anthropicSuccessResponse(text: String = "Hello!") -> Data {
        let json = """
        {
            "content": [{"type": "text", "text": "\(text)"}],
            "stop_reason": "end_turn",
            "usage": {"input_tokens": 10, "output_tokens": 5}
        }
        """
        return json.data(using: .utf8)!
    }

    private func oaiSuccessResponse(text: String = "Hi there!", finishReason: String = "stop") -> Data {
        let json = """
        {
            "choices": [{
                "message": {"role": "assistant", "content": "\(text)"},
                "finish_reason": "\(finishReason)"
            }],
            "usage": {"prompt_tokens": 5, "completion_tokens": 8}
        }
        """
        return json.data(using: .utf8)!
    }

    private func httpResponse(url: URL, statusCode: Int) -> HTTPURLResponse {
        return HTTPURLResponse(url: url, statusCode: statusCode,
                               httpVersion: nil, headerFields: nil)!
    }

    // MARK: - A. AnthropicProvider x-api-key header

    /// AnthropicProvider.send 发送的 request 必须含 x-api-key header，值等于 apiKey
    func test_anthropic_send_hasXApiKeyHeader() async throws {
        var capturedRequest: URLRequest?
        MockURLProtocol.requestHandler = { request in
            capturedRequest = request
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
            return (resp, self.anthropicSuccessResponse())
        }

        let provider = makeAnthropicProvider(apiKey: "sk-ant-valid-key-1234")
        _ = try await provider.send(
            messages: [AgentMessage(role: "user", content: [.text("hi")])],
            tools: [],
            model: "claude-sonnet-4-5"
        )

        let xApiKey = capturedRequest?.value(forHTTPHeaderField: "x-api-key")
        XCTAssertEqual(xApiKey, "sk-ant-valid-key-1234",
                       "request 必须含 x-api-key header，值等于 apiKey")
    }

    // MARK: - B. anthropic-version header

    /// AnthropicProvider.send 发送的 request 必须含 anthropic-version: 2023-06-01
    func test_anthropic_send_hasVersionHeader() async throws {
        var capturedRequest: URLRequest?
        MockURLProtocol.requestHandler = { request in
            capturedRequest = request
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
            return (resp, self.anthropicSuccessResponse())
        }

        let provider = makeAnthropicProvider()
        _ = try await provider.send(
            messages: [AgentMessage(role: "user", content: [.text("hi")])],
            tools: [], model: "claude-sonnet-4-5"
        )

        let version = capturedRequest?.value(forHTTPHeaderField: "anthropic-version")
        XCTAssertEqual(version, "2023-06-01",
                       "request 必须含 anthropic-version: 2023-06-01 header")
    }

    // MARK: - C. request body 含 max_tokens:4096

    /// AnthropicProvider.send 的 request body 必须含 "max_tokens":4096
    func test_anthropic_send_bodyContainsMaxTokens4096() async throws {
        var capturedBody: Data?
        MockURLProtocol.requestHandler = { request in
            capturedBody = request.httpBody
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
            return (resp, self.anthropicSuccessResponse())
        }

        let provider = makeAnthropicProvider()
        _ = try await provider.send(
            messages: [AgentMessage(role: "user", content: [.text("hi")])],
            tools: [], model: "claude-sonnet-4-5"
        )

        let bodyJSON = try JSONSerialization.jsonObject(with: capturedBody!) as? [String: Any]
        XCTAssertEqual(bodyJSON?["max_tokens"] as? Int, 4096,
                       "request body 必须含 max_tokens == 4096")
    }

    /// request body 含 messages 数组
    func test_anthropic_send_bodyContainsMessages() async throws {
        var capturedBody: Data?
        MockURLProtocol.requestHandler = { request in
            capturedBody = request.httpBody
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
            return (resp, self.anthropicSuccessResponse())
        }

        let provider = makeAnthropicProvider()
        _ = try await provider.send(
            messages: [AgentMessage(role: "user", content: [.text("test message")])],
            tools: [], model: "claude-sonnet-4-5"
        )

        let bodyJSON = try JSONSerialization.jsonObject(with: capturedBody!) as? [String: Any]
        let messages = bodyJSON?["messages"] as? [[String: Any]]
        XCTAssertEqual(messages?.count, 1, "request body 必须含 1 条 message")
        XCTAssertEqual(messages?.first?["role"] as? String, "user",
                       "message role 必须是 \"user\"")
    }

    // MARK: - D. HTTP 4xx → 抛 providerHTTPError

    /// HTTP 401 → 抛 LauncherError.providerHTTPError(401, ...)
    func test_anthropic_send_http401_throwsProviderHTTPError() async {
        MockURLProtocol.requestHandler = { request in
            let resp = HTTPURLResponse(url: request.url!, statusCode: 401,
                                       httpVersion: nil, headerFields: nil)!
            let body = "{\"error\":\"unauthorized\"}".data(using: .utf8)!
            return (resp, body)
        }

        let provider = makeAnthropicProvider()
        do {
            _ = try await provider.send(
                messages: [AgentMessage(role: "user", content: [.text("hi")])],
                tools: [], model: "claude-sonnet-4-5"
            )
            XCTFail("HTTP 401 必须抛 LauncherError.providerHTTPError")
        } catch LauncherError.providerHTTPError(let code, let body) {
            XCTAssertEqual(code, 401,
                           "错误码必须精确是 401")
            XCTAssertTrue(body.count <= 200,
                          "body 片段长度必须 ≤ 200 字节")
        } catch {
            XCTFail("期望 LauncherError.providerHTTPError，实际抛: \(error)")
        }
    }

    /// HTTP 403 → 抛 providerHTTPError(403, ...)，body 长度 ≤ 200
    func test_anthropic_send_http403_bodyTruncatedTo200() async {
        let longBody = String(repeating: "x", count: 500)
        MockURLProtocol.requestHandler = { request in
            let resp = HTTPURLResponse(url: request.url!, statusCode: 403,
                                       httpVersion: nil, headerFields: nil)!
            return (resp, longBody.data(using: .utf8)!)
        }

        let provider = makeAnthropicProvider()
        do {
            _ = try await provider.send(
                messages: [AgentMessage(role: "user", content: [.text("hi")])],
                tools: [], model: "claude-sonnet-4-5"
            )
            XCTFail("HTTP 403 必须抛 providerHTTPError")
        } catch LauncherError.providerHTTPError(let code, let body) {
            XCTAssertEqual(code, 403)
            XCTAssertEqual(body.count, 200,
                           "500 字节的 body 必须被截断到 200 字节")
        } catch {
            XCTFail("期望 LauncherError.providerHTTPError，实际: \(error)")
        }
    }

    // MARK: - E. HTTP 5xx → 抛 providerHTTPError(500, ...)

    func test_anthropic_send_http500_throwsProviderHTTPError() async {
        MockURLProtocol.requestHandler = { request in
            let resp = HTTPURLResponse(url: request.url!, statusCode: 500,
                                       httpVersion: nil, headerFields: nil)!
            return (resp, "internal server error".data(using: .utf8)!)
        }

        let provider = makeAnthropicProvider()
        do {
            _ = try await provider.send(
                messages: [AgentMessage(role: "user", content: [.text("hi")])],
                tools: [], model: "claude-sonnet-4-5"
            )
            XCTFail("HTTP 500 必须抛 providerHTTPError")
        } catch LauncherError.providerHTTPError(let code, _) {
            XCTAssertEqual(code, 500,
                           "错误码必须精确是 500")
        } catch {
            XCTFail("期望 LauncherError.providerHTTPError，实际: \(error)")
        }
    }

    // MARK: - F. 非法 JSON 响应 → 抛 networkFailure 或 DecodingError

    /// HTTP 200 但 body 是非法 JSON → 抛错（不静默忽略）
    func test_anthropic_send_invalidJSONResponse_throws() async {
        MockURLProtocol.requestHandler = { request in
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
            return (resp, "not json at all".data(using: .utf8)!)
        }

        let provider = makeAnthropicProvider()
        do {
            _ = try await provider.send(
                messages: [AgentMessage(role: "user", content: [.text("hi")])],
                tools: [], model: "claude-sonnet-4-5"
            )
            XCTFail("非法 JSON 响应必须抛错")
        } catch {
            // 接受 LauncherError.networkFailure 或 DecodingError
            let isExpected = (error is LauncherError) || (error is DecodingError)
            XCTAssertTrue(isExpected,
                          "非法 JSON 必须抛 LauncherError.networkFailure 或 DecodingError，实际: \(error)")
        }
    }

    // MARK: - G. API key 长度 < 8 → 抛 invalidAPIKey（不发网络请求）

    /// API key 只有 7 个字符 → 抛 LauncherError.invalidAPIKey，不发网络请求
    func test_anthropic_send_shortAPIKey_throwsInvalidAPIKey() async {
        var networkRequestMade = false
        MockURLProtocol.requestHandler = { _ in
            networkRequestMade = true
            let resp = HTTPURLResponse(url: URL(string: "https://api.anthropic.com")!,
                                       statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, self.anthropicSuccessResponse())
        }

        let provider = AnthropicProvider(apiKey: "1234567", session: mockSession)  // 7 chars < 8
        do {
            _ = try await provider.send(
                messages: [AgentMessage(role: "user", content: [.text("hi")])],
                tools: [], model: "claude-sonnet-4-5"
            )
            XCTFail("API key 长度 < 8 必须抛 LauncherError.invalidAPIKey")
        } catch LauncherError.invalidAPIKey(let reason) {
            XCTAssertFalse(networkRequestMade,
                           "API key 校验失败时不应发送网络请求")
            XCTAssertFalse(reason.isEmpty,
                           "invalidAPIKey 关联的 reason 字符串不应为空")
        } catch {
            XCTFail("期望 LauncherError.invalidAPIKey，实际: \(error)")
        }
    }

    /// 空 API key → 抛 LauncherError.invalidAPIKey
    func test_anthropic_send_emptyAPIKey_throwsInvalidAPIKey() async {
        let provider = AnthropicProvider(apiKey: "", session: mockSession)
        do {
            _ = try await provider.send(
                messages: [AgentMessage(role: "user", content: [.text("hi")])],
                tools: [], model: "claude-sonnet-4-5"
            )
            XCTFail("空 API key 必须抛 LauncherError.invalidAPIKey")
        } catch LauncherError.invalidAPIKey {
            // 预期
        } catch {
            XCTFail("期望 LauncherError.invalidAPIKey，实际: \(error)")
        }
    }

    // MARK: - H. OpenAICompatibleProvider Authorization header

    /// OpenAICompatibleProvider.send 必须含 Authorization: Bearer <key>
    func test_oai_send_hasAuthorizationBearerHeader() async throws {
        var capturedRequest: URLRequest?
        MockURLProtocol.requestHandler = { request in
            capturedRequest = request
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
            return (resp, self.oaiSuccessResponse())
        }

        let provider = makeOAIProvider(apiKey: "ollama-valid-key-123")
        _ = try await provider.send(
            messages: [AgentMessage(role: "user", content: [.text("hi")])],
            tools: [], model: "qwen2.5:7b"
        )

        let auth = capturedRequest?.value(forHTTPHeaderField: "Authorization")
        XCTAssertEqual(auth, "Bearer ollama-valid-key-123",
                       "OpenAI 兼容 provider 必须含 Authorization: Bearer <apiKey>")
    }

    // MARK: - I. OpenAI URL path 含 /chat/completions

    /// OpenAICompatibleProvider 请求 URL 必须含 /chat/completions 路径
    func test_oai_send_urlContainsChatCompletions() async throws {
        var capturedURL: URL?
        MockURLProtocol.requestHandler = { request in
            capturedURL = request.url
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
            return (resp, self.oaiSuccessResponse())
        }

        let baseURL = URL(string: "http://localhost:11434/v1")!
        let provider = makeOAIProvider(baseURL: baseURL)
        _ = try await provider.send(
            messages: [AgentMessage(role: "user", content: [.text("hi")])],
            tools: [], model: "qwen2.5:7b"
        )

        XCTAssertNotNil(capturedURL?.path,
                        "请求 URL 不应为 nil")
        XCTAssertTrue(capturedURL?.path.contains("chat/completions") == true,
                      "请求 URL path 必须含 /chat/completions，实际: \(capturedURL?.path ?? "nil")")
    }

    // MARK: - J. OAI finish_reason:"stop" → stopReason == "end_turn"

    /// OpenAI finish_reason:"stop" 必须映射为 AgentResponse.stopReason == "end_turn"
    func test_oai_finishReasonStop_mapsToEndTurn() async throws {
        MockURLProtocol.requestHandler = { request in
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
            return (resp, self.oaiSuccessResponse(finishReason: "stop"))
        }

        let provider = makeOAIProvider()
        let response = try await provider.send(
            messages: [AgentMessage(role: "user", content: [.text("hi")])],
            tools: [], model: "qwen2.5:7b"
        )

        XCTAssertEqual(response.stopReason, "end_turn",
                       "OAI finish_reason:\"stop\" 必须映射为 AgentResponse.stopReason == \"end_turn\"")
    }

    // MARK: - K. OAI finish_reason:"length" → stopReason == "max_tokens"

    /// OpenAI finish_reason:"length" 必须映射为 AgentResponse.stopReason == "max_tokens"
    func test_oai_finishReasonLength_mapsToMaxTokens() async throws {
        MockURLProtocol.requestHandler = { request in
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
            return (resp, self.oaiSuccessResponse(finishReason: "length"))
        }

        let provider = makeOAIProvider()
        let response = try await provider.send(
            messages: [AgentMessage(role: "user", content: [.text("hi")])],
            tools: [], model: "qwen2.5:7b"
        )

        XCTAssertEqual(response.stopReason, "max_tokens",
                       "OAI finish_reason:\"length\" 必须映射为 \"max_tokens\"")
    }

    /// OpenAI finish_reason:"tool_calls" 必须映射为 "tool_use"
    func test_oai_finishReasonToolCalls_mapsToToolUse() async throws {
        MockURLProtocol.requestHandler = { request in
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
            return (resp, self.oaiSuccessResponse(finishReason: "tool_calls"))
        }

        let provider = makeOAIProvider()
        let response = try await provider.send(
            messages: [AgentMessage(role: "user", content: [.text("hi")])],
            tools: [], model: "qwen2.5:7b"
        )

        XCTAssertEqual(response.stopReason, "tool_use",
                       "OAI finish_reason:\"tool_calls\" 必须映射为 \"tool_use\"")
    }

    // MARK: - L. AnthropicProvider 正常 200 响应 → 返回正确 AgentResponse

    /// HTTP 200 + 有效 Anthropic JSON → 返回 AgentResponse，content 含 text
    func test_anthropic_send_http200_returnsAgentResponse() async throws {
        MockURLProtocol.requestHandler = { request in
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
            return (resp, self.anthropicSuccessResponse(text: "Hello from Anthropic!"))
        }

        let provider = makeAnthropicProvider()
        let response = try await provider.send(
            messages: [AgentMessage(role: "user", content: [.text("hi")])],
            tools: [], model: "claude-sonnet-4-5"
        )

        XCTAssertEqual(response.stopReason, "end_turn",
                       "成功响应 stopReason 必须是 \"end_turn\"")
        if case .text(let t) = response.content.first {
            XCTAssertEqual(t, "Hello from Anthropic!",
                           "content text 必须精确还原")
        } else {
            XCTFail("response.content[0] 必须是 .text case")
        }
    }

    /// AnthropicProvider request 使用 POST 方法
    func test_anthropic_send_usesPostMethod() async throws {
        var capturedMethod: String?
        MockURLProtocol.requestHandler = { request in
            capturedMethod = request.httpMethod
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
            return (resp, self.anthropicSuccessResponse())
        }

        let provider = makeAnthropicProvider()
        _ = try await provider.send(
            messages: [AgentMessage(role: "user", content: [.text("hi")])],
            tools: [], model: "claude-sonnet-4-5"
        )

        XCTAssertEqual(capturedMethod, "POST",
                       "Anthropic 请求必须使用 POST method")
    }

    /// OAI provider request 使用 POST 方法
    func test_oai_send_usesPostMethod() async throws {
        var capturedMethod: String?
        MockURLProtocol.requestHandler = { request in
            capturedMethod = request.httpMethod
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
            return (resp, self.oaiSuccessResponse())
        }

        let provider = makeOAIProvider()
        _ = try await provider.send(
            messages: [AgentMessage(role: "user", content: [.text("hi")])],
            tools: [], model: "qwen2.5:7b"
        )

        XCTAssertEqual(capturedMethod, "POST",
                       "OAI 请求必须使用 POST method")
    }

    // MARK: - OAI API key 校验（与 Anthropic 一致）

    /// OAI API key 长度 < 8 → 抛 LauncherError.invalidAPIKey
    func test_oai_send_shortAPIKey_throwsInvalidAPIKey() async {
        let provider = OpenAICompatibleProvider(
            apiKey: "short",  // 5 chars < 8
            baseURL: URL(string: "http://localhost:11434/v1")!,
            session: mockSession
        )
        do {
            _ = try await provider.send(
                messages: [AgentMessage(role: "user", content: [.text("hi")])],
                tools: [], model: "qwen2.5:7b"
            )
            XCTFail("OAI short API key 必须抛 LauncherError.invalidAPIKey")
        } catch LauncherError.invalidAPIKey {
            // 预期
        } catch {
            XCTFail("期望 LauncherError.invalidAPIKey，实际: \(error)")
        }
    }
}
