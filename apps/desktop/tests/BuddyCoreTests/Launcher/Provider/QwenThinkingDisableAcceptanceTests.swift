import XCTest
@testable import BuddyCore

// MARK: - QwenThinkingDisableAcceptanceTests
//
// 红队验收测试：P0 — 关闭 Qwen3 thinking
//
// 设计文档契约：
//   当 provider 配置 noThinking: true 时：
//     - 请求体 JSON 必须含 "chat_template_kwargs": {"enable_thinking": false}
//     - 请求体不含 top-level "enable_thinking" 字段
//   当 noThinking: false/nil 时：
//     - 请求体不含 "chat_template_kwargs" 字段（不能是 null）
//     - 请求体不含 top-level "enable_thinking" 字段
//
// 实测背景：Qwen3 默认启用 thinking，导致 24.5s 响应；
//   关闭后降到 1.45s（17×）。唯一有效通道是 chat_template_kwargs.enable_thinking: false。
//
// 测试策略：
//   用 URLProtocol mock 拦截 HTTP 请求体，解析 JSON，做字段级断言。
//   OpenAICompatibleProvider 扩展一个接受 noThinking: Bool 的构造器（或 init 参数）。
//
// NOTE: 蓝队需在 OpenAICompatibleProvider 加入 noThinking 参数支持，
//       本测试在蓝队合并前会编译报错 —— 这是预期的 TDD 红灯。
//       当前用字符串 JSON 解析断言，不依赖新类型。

// MARK: - MockURLProtocol（复用 LauncherProviderAcceptanceTests 中同名类，
//         但两文件不可同时用同一 class name。此处新建局部版本，命名为 QwenMockURLProtocol）

private final class QwenMockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data?))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    /// URLSession 把 httpBody 转为 httpBodyStream 传给 URLProtocol，需手动读回。
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
        guard let handler = QwenMockURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError:
                NSError(domain: "QwenMockURLProtocol", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "No handler registered"]))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let data { client?.urlProtocol(self, didLoad: data) }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// MARK: - QwenThinkingDisableAcceptanceTests

final class QwenThinkingDisableAcceptanceTests: XCTestCase {

    private var mockSession: URLSession!
    private let baseURL = URL(string: "http://localhost:8080/v1")!
    private let apiKey = "dummy-key-1234"

    // MARK: - 成功响应 helper

    private func oaiSuccessData() -> Data {
        """
        {
            "choices": [{"message":{"role":"assistant","content":"hello"},"finish_reason":"stop"}],
            "usage": {"prompt_tokens": 5, "completion_tokens": 3}
        }
        """.data(using: .utf8)!
    }

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [QwenMockURLProtocol.self]
        mockSession = URLSession(configuration: config)
        QwenMockURLProtocol.requestHandler = nil
    }

    override func tearDown() {
        QwenMockURLProtocol.requestHandler = nil
        mockSession = nil
        super.tearDown()
    }

    // MARK: - P0-A: noThinking=true 时请求体含 chat_template_kwargs.enable_thinking: false

    /// noThinking=true → JSON body["chat_template_kwargs"]["enable_thinking"] == false
    func test_noThinking_true_bodyContainsChatTemplateKwargs() async throws {
        var capturedBody: Data?
        QwenMockURLProtocol.requestHandler = { request in
            capturedBody = request.httpBody
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
            return (resp, self.oaiSuccessData())
        }

        // 蓝队将 noThinking 作为 OpenAICompatibleProvider 的 init 参数
        // 当 noThinking=true 时构造 provider（参数顺序：apiKey, baseURL, noThinking, session）
        let provider = OpenAICompatibleProvider(
            apiKey: apiKey,
            baseURL: baseURL,
            noThinking: true,
            session: mockSession
        )
        _ = try await provider.send(
            messages: [AgentMessage(role: "user", content: [.text("翻译：hello")])],
            tools: [],
            model: "qwen3:8b"
        )

        let body = try XCTUnwrap(capturedBody, "请求体不应为 nil")
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: body) as? [String: Any],
            "请求体必须是合法 JSON object"
        )

        // 断言含 chat_template_kwargs
        let kwargs = json["chat_template_kwargs"] as? [String: Any]
        XCTAssertNotNil(kwargs,
                        "noThinking=true 时请求体必须含 chat_template_kwargs 字段，实际 JSON keys: \(json.keys.sorted())")

        // 断言 enable_thinking == false
        let enableThinking = kwargs?["enable_thinking"] as? Bool
        XCTAssertEqual(enableThinking, false,
                       "chat_template_kwargs.enable_thinking 必须精确是 false，实际: \(String(describing: enableThinking))")
    }

    // MARK: - P0-B: noThinking=true 时 top-level 不含 enable_thinking 字段

    /// noThinking=true → JSON body 不含 top-level "enable_thinking" 键
    func test_noThinking_true_bodyNotContainsTopLevelEnableThinking() async throws {
        var capturedBody: Data?
        QwenMockURLProtocol.requestHandler = { request in
            capturedBody = request.httpBody
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
            return (resp, self.oaiSuccessData())
        }

        let provider = OpenAICompatibleProvider(
            apiKey: apiKey,
            baseURL: baseURL,
            noThinking: true,
            session: mockSession
        )
        _ = try await provider.send(
            messages: [AgentMessage(role: "user", content: [.text("翻译：hello")])],
            tools: [],
            model: "qwen3:8b"
        )

        let body = try XCTUnwrap(capturedBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])

        // top-level 不含 enable_thinking
        XCTAssertNil(json["enable_thinking"],
                     "top-level 不应含 enable_thinking 字段（唯一有效通道是 chat_template_kwargs 嵌套）")
    }

    // MARK: - P0-C: noThinking=false 时请求体不含 chat_template_kwargs 字段

    /// noThinking=false → JSON body 不含 chat_template_kwargs 键（连 null 也不行）
    func test_noThinking_false_bodyNotContainsChatTemplateKwargs() async throws {
        var capturedBody: Data?
        QwenMockURLProtocol.requestHandler = { request in
            capturedBody = request.httpBody
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
            return (resp, self.oaiSuccessData())
        }

        let provider = OpenAICompatibleProvider(
            apiKey: apiKey,
            baseURL: baseURL,
            noThinking: false,
            session: mockSession
        )
        _ = try await provider.send(
            messages: [AgentMessage(role: "user", content: [.text("hi")])],
            tools: [],
            model: "qwen3:8b"
        )

        let body = try XCTUnwrap(capturedBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])

        // 不含 chat_template_kwargs（不能是 null，也不能是 {}）
        XCTAssertNil(json["chat_template_kwargs"],
                     "noThinking=false 时请求体不能含 chat_template_kwargs 字段（含 null 值也不允许）")
    }

    // MARK: - P0-D: noThinking=false 时 top-level 也不含 enable_thinking

    /// noThinking=false → top-level 也不含 enable_thinking
    func test_noThinking_false_bodyNotContainsTopLevelEnableThinking() async throws {
        var capturedBody: Data?
        QwenMockURLProtocol.requestHandler = { request in
            capturedBody = request.httpBody
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
            return (resp, self.oaiSuccessData())
        }

        let provider = OpenAICompatibleProvider(
            apiKey: apiKey,
            baseURL: baseURL,
            noThinking: false,
            session: mockSession
        )
        _ = try await provider.send(
            messages: [AgentMessage(role: "user", content: [.text("hi")])],
            tools: [],
            model: "qwen3:8b"
        )

        let body = try XCTUnwrap(capturedBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])

        XCTAssertNil(json["enable_thinking"],
                     "noThinking=false 时 top-level 也不应含 enable_thinking")
    }

    // MARK: - P0-E: noThinking 默认（不传该参数）时不含 chat_template_kwargs

    /// 默认构造器（不传 noThinking）→ 保持原有行为，不含 chat_template_kwargs
    func test_noThinking_default_bodyNotContainsChatTemplateKwargs() async throws {
        var capturedBody: Data?
        QwenMockURLProtocol.requestHandler = { request in
            capturedBody = request.httpBody
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
            return (resp, self.oaiSuccessData())
        }

        // 使用原有三参数构造器（不传 noThinking，蓝队需保持向后兼容）
        let provider = OpenAICompatibleProvider(
            apiKey: apiKey,
            baseURL: baseURL,
            session: mockSession
        )
        _ = try await provider.send(
            messages: [AgentMessage(role: "user", content: [.text("hi")])],
            tools: [],
            model: "gpt-4o"
        )

        let body = try XCTUnwrap(capturedBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])

        // 默认行为：不破坏非 Qwen provider
        XCTAssertNil(json["chat_template_kwargs"],
                     "默认构造器（noThinking 未设置）时不应含 chat_template_kwargs，不能破坏 Anthropic/OpenAI 等 provider")
    }

    // MARK: - P0-F: noThinking=true 时其他标准字段仍正常

    /// noThinking=true 时不影响 model、messages 等标准字段
    func test_noThinking_true_doesNotBreakOtherBodyFields() async throws {
        var capturedBody: Data?
        QwenMockURLProtocol.requestHandler = { request in
            capturedBody = request.httpBody
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
            return (resp, self.oaiSuccessData())
        }

        let provider = OpenAICompatibleProvider(
            apiKey: apiKey,
            baseURL: baseURL,
            noThinking: true,
            session: mockSession
        )
        _ = try await provider.send(
            messages: [AgentMessage(role: "user", content: [.text("翻译：hello")])],
            tools: [],
            model: "qwen3:8b"
        )

        let body = try XCTUnwrap(capturedBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])

        // model 字段仍正确
        XCTAssertEqual(json["model"] as? String, "qwen3:8b",
                       "noThinking=true 时 model 字段必须正确传递")

        // messages 字段仍存在
        XCTAssertNotNil(json["messages"] as? [[String: Any]],
                        "noThinking=true 时 messages 字段不能丢失")
    }
}
