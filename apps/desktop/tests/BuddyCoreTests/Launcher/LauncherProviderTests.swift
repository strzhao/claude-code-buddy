import XCTest
@testable import BuddyCore

// MARK: - MockURLProtocol (Step 5 unit test - 蓝队)
// 注意：红队 LauncherProviderAcceptanceTests 也定义了 MockURLProtocol，
// 但两个文件不应同时编译时冲突。
// 这里用不同名字避免重定义
final class StepFiveMockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data?))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = StepFiveMockURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError:
                NSError(domain: "StepFiveMockURLProtocol", code: -1,
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

// MARK: - AnthropicProviderTests

final class AnthropicProviderTests: XCTestCase {
    private var mockSession: URLSession!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StepFiveMockURLProtocol.self]
        mockSession = URLSession(configuration: config)
        StepFiveMockURLProtocol.requestHandler = nil
    }

    override func tearDown() {
        StepFiveMockURLProtocol.requestHandler = nil
        mockSession = nil
        super.tearDown()
    }

    func test_send_includesXApiKeyHeader() async throws {
        var capturedRequest: URLRequest?
        StepFiveMockURLProtocol.requestHandler = { request in
            capturedRequest = request
            let responseJSON = #"{"content":[{"type":"text","text":"hi"}],"stop_reason":"end_turn"}"#
            let data = responseJSON.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, data)
        }

        let provider = AnthropicProvider(apiKey: "sk-ant-testkey12", session: mockSession)
        _ = try await provider.send(messages: [AgentMessage(role: "user", content: [.text("hi")])], tools: [], model: "claude-sonnet-4-5")

        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "x-api-key"), "sk-ant-testkey12")
    }

    func test_send_includesAnthropicVersionHeader() async throws {
        var capturedRequest: URLRequest?
        StepFiveMockURLProtocol.requestHandler = { request in
            capturedRequest = request
            let responseJSON = #"{"content":[{"type":"text","text":"hi"}],"stop_reason":"end_turn"}"#
            let data = responseJSON.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, data)
        }

        let provider = AnthropicProvider(apiKey: "sk-ant-testkey12", session: mockSession)
        _ = try await provider.send(messages: [], tools: [], model: "claude-sonnet-4-5")

        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
    }

    func test_send_bodyContainsMaxTokens4096() async throws {
        var capturedBodyDict: [String: Any]?
        StepFiveMockURLProtocol.requestHandler = { request in
            // URLProtocol 中 httpBody 可能为 nil，body 在 httpBodyStream 中
            let bodyData: Data?
            if let body = request.httpBody {
                bodyData = body
            } else if let stream = request.httpBodyStream {
                stream.open()
                var data = Data()
                let bufferSize = 4096
                var buffer = [UInt8](repeating: 0, count: bufferSize)
                while stream.hasBytesAvailable {
                    let bytesRead = stream.read(&buffer, maxLength: bufferSize)
                    if bytesRead > 0 {
                        data.append(buffer, count: bytesRead)
                    }
                }
                stream.close()
                bodyData = data
            } else {
                bodyData = nil
            }
            if let bd = bodyData {
                capturedBodyDict = try? JSONSerialization.jsonObject(with: bd) as? [String: Any]
            }
            let responseJSON = #"{"content":[{"type":"text","text":"hi"}],"stop_reason":"end_turn"}"#
            let data = responseJSON.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, data)
        }

        let provider = AnthropicProvider(apiKey: "sk-ant-testkey12", session: mockSession)
        _ = try await provider.send(messages: [AgentMessage(role: "user", content: [.text("test")])], tools: [], model: "m")

        XCTAssertEqual(capturedBodyDict?["max_tokens"] as? Int, 4096)
    }

    func test_send_http401_throwsProviderHTTPError() async {
        StepFiveMockURLProtocol.requestHandler = { request in
            let errorBody = #"{"error":{"type":"authentication_error","message":"invalid x-api-key"}}"#
            let data = errorBody.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, data)
        }

        let provider = AnthropicProvider(apiKey: "sk-ant-testkey12", session: mockSession)
        do {
            _ = try await provider.send(messages: [], tools: [], model: "m")
            XCTFail("Should have thrown")
        } catch LauncherError.providerHTTPError(let code, _) {
            XCTAssertEqual(code, 401)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_send_apiKeyTooShort_throwsInvalidAPIKey_noNetworkCall() async {
        var networkCalled = false
        StepFiveMockURLProtocol.requestHandler = { _ in
            networkCalled = true
            let data = Data()
            let response = HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, data)
        }

        let provider = AnthropicProvider(apiKey: "short", session: mockSession)
        do {
            _ = try await provider.send(messages: [], tools: [], model: "m")
            XCTFail("Should have thrown")
        } catch LauncherError.invalidAPIKey(let reason) {
            XCTAssertEqual(reason, "too short")
            XCTAssertFalse(networkCalled, "API key 验证失败时不应发出网络请求")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_send_200_returnsAgentResponse() async throws {
        StepFiveMockURLProtocol.requestHandler = { request in
            let json = #"{"content":[{"type":"text","text":"Hello world!"}],"stop_reason":"end_turn","usage":{"input_tokens":5,"output_tokens":3}}"#
            let data = json.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, data)
        }

        let provider = AnthropicProvider(apiKey: "sk-ant-testkey12", session: mockSession)
        let resp = try await provider.send(messages: [AgentMessage(role: "user", content: [.text("hi")])], tools: [], model: "claude-sonnet-4-5")

        XCTAssertEqual(resp.stopReason, "end_turn")
        XCTAssertEqual(resp.usage?.inputTokens, 5)
        XCTAssertEqual(resp.usage?.outputTokens, 3)
        if case .text(let text) = resp.content.first {
            XCTAssertEqual(text, "Hello world!")
        } else {
            XCTFail("Expected text content")
        }
    }
}

// MARK: - OpenAICompatibleProviderTests

final class OpenAICompatibleProviderTests: XCTestCase {
    private var mockSession: URLSession!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StepFiveMockURLProtocol.self]
        mockSession = URLSession(configuration: config)
        StepFiveMockURLProtocol.requestHandler = nil
    }

    override func tearDown() {
        StepFiveMockURLProtocol.requestHandler = nil
        mockSession = nil
        super.tearDown()
    }

    private func makeProvider(baseURL: String = "http://localhost:11434/v1") -> OpenAICompatibleProvider {
        return OpenAICompatibleProvider(
            apiKey: "ollama-validkey123",
            baseURL: URL(string: baseURL)!,
            session: mockSession
        )
    }

    func test_send_includesBearerAuthHeader() async throws {
        var capturedRequest: URLRequest?
        StepFiveMockURLProtocol.requestHandler = { request in
            capturedRequest = request
            let json = #"{"choices":[{"message":{"role":"assistant","content":"hi"},"finish_reason":"stop"}]}"#
            let data = json.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, data)
        }

        _ = try await makeProvider().send(messages: [], tools: [], model: "llama3")

        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer ollama-validkey123")
    }

    func test_send_urlContainsChatCompletions() async throws {
        var capturedURL: URL?
        StepFiveMockURLProtocol.requestHandler = { request in
            capturedURL = request.url
            let json = #"{"choices":[{"message":{"role":"assistant","content":"hi"},"finish_reason":"stop"}]}"#
            let data = json.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, data)
        }

        _ = try await makeProvider().send(messages: [], tools: [], model: "llama3")

        XCTAssertTrue(capturedURL?.path.hasSuffix("chat/completions") ?? false)
    }

    func test_send_finishReasonStop_mapsToEndTurn() async throws {
        StepFiveMockURLProtocol.requestHandler = { request in
            let json = #"{"choices":[{"message":{"role":"assistant","content":"OK"},"finish_reason":"stop"}]}"#
            let data = json.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, data)
        }

        let resp = try await makeProvider().send(messages: [], tools: [], model: "m")
        XCTAssertEqual(resp.stopReason, "end_turn")
    }

    func test_send_finishReasonLength_mapsToMaxTokens() async throws {
        StepFiveMockURLProtocol.requestHandler = { request in
            let json = #"{"choices":[{"message":{"role":"assistant","content":"truncated"},"finish_reason":"length"}]}"#
            let data = json.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, data)
        }

        let resp = try await makeProvider().send(messages: [], tools: [], model: "m")
        XCTAssertEqual(resp.stopReason, "max_tokens")
    }

    func test_send_http500_throwsProviderHTTPError() async {
        StepFiveMockURLProtocol.requestHandler = { request in
            let errorBody = "Internal Server Error"
            let data = errorBody.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (response, data)
        }

        do {
            _ = try await makeProvider().send(messages: [], tools: [], model: "m")
            XCTFail("Should have thrown")
        } catch LauncherError.providerHTTPError(let code, _) {
            XCTAssertEqual(code, 500)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_send_errorBody_truncatedTo200Chars() async {
        let longBody = String(repeating: "x", count: 500)
        StepFiveMockURLProtocol.requestHandler = { request in
            let data = longBody.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!
            return (response, data)
        }

        do {
            _ = try await makeProvider().send(messages: [], tools: [], model: "m")
            XCTFail("Should have thrown")
        } catch LauncherError.providerHTTPError(_, let body) {
            XCTAssertLessThanOrEqual(body.count, 200, "错误 body 应截断至 200 字符")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
