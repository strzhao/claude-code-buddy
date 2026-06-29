import XCTest
@testable import BuddyCore

// P3.0 + P5 单测：OpenAICompatibleProvider 非流式 send 补 tools 通道 + thinking 验证
//
// 契约：
//   C-TOOLCALL-CHANNEL：非流式 send 在 tools 非空时发 tools+tool_choice:"auto"，响应 tool_calls 解析为 .toolUse 不丢弃
//   C-NO-TOOL-NO-FORGE：tools 空 → 不发 tool_choice
//   C-THINKING-OFF：noThinking=true → body.chat_template_kwargs.enable_thinking==false
//   arguments 空串/畸形 JSON → soft-fail（input=空 dict）不 throw
final class OpenAICompatibleProviderToolCallTests: XCTestCase {
    private var mockSession: URLSession!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ToolCallMockURLProtocol.self]
        mockSession = URLSession(configuration: config)
        ToolCallMockURLProtocol.requestHandler = nil
    }

    override func tearDown() {
        ToolCallMockURLProtocol.requestHandler = nil
        mockSession = nil
        super.tearDown()
    }

    private func makeProvider(noThinking: Bool = false) -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(
            apiKey: "qwen-validkey12345",
            baseURL: URL(string: "http://127.0.0.1:8001/v1")!,
            noThinking: noThinking,
            session: mockSession
        )
    }

    /// 捕获请求 body（URLProtocol httpBody 可能在 stream 里）
    private func captureBody(_ request: URLRequest) -> [String: Any]? {
        var bodyData: Data?
        if let body = request.httpBody {
            bodyData = body
        } else if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: 4096)
                if read > 0 { data.append(buffer, count: read) }
            }
            stream.close()
            bodyData = data
        }
        guard let bd = bodyData else { return nil }
        return try? JSONSerialization.jsonObject(with: bd) as? [String: Any]
    }

    // MARK: - tools 非空 → 发 tools + tool_choice:"auto"

    /// tools 非空时 body 必须含 tools 数组 + tool_choice=="auto"
    func test_send_nonEmptyTools_bodyIncludesToolsAndToolChoiceAuto() async throws {
        var capturedBody: [String: Any]?
        ToolCallMockURLProtocol.requestHandler = { request in
            capturedBody = self.captureBody(request)
            let json = #"{"choices":[{"message":{"role":"assistant","content":"hi"},"finish_reason":"stop"}]}"#
            let data = json.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, data)
        }

        let tool = AgentTool(
            name: "qr",
            description: "生成二维码",
            inputSchema: ["type": AnyCodable("object"), "properties": AnyCodable(["query": ["type": "string"]]), "required": AnyCodable(["query"])]
        )
        _ = try await makeProvider().send(messages: [.init(role: "user", content: [.text("二维码")])], tools: [tool], model: "qwen3.6-35b")

        XCTAssertNotNil(capturedBody?["tools"], "tools 非空时 body 必须含 tools 字段")
        XCTAssertEqual(capturedBody?["tool_choice"] as? String, "auto",
                       "tools 非空时 tool_choice 必须是 'auto'")
        let toolsArr = capturedBody?["tools"] as? [[String: Any]]
        XCTAssertEqual(toolsArr?.first?["type"] as? String, "function",
                       "tools 必须是 OpenAI function 格式 {type:function,...}")
    }

    // MARK: - tools 空 → 不发 tool_choice

    /// tools 空时 body 不应含 tool_choice（C-NO-TOOL-NO-FORGE）
    func test_send_emptyTools_bodyOmitsToolChoice() async throws {
        var capturedBody: [String: Any]?
        ToolCallMockURLProtocol.requestHandler = { request in
            capturedBody = self.captureBody(request)
            let json = #"{"choices":[{"message":{"role":"assistant","content":"hi"},"finish_reason":"stop"}]}"#
            let data = json.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, data)
        }

        _ = try await makeProvider().send(messages: [], tools: [], model: "m")

        XCTAssertNil(capturedBody?["tool_choice"],
                     "tools 空时 body 不应含 tool_choice 字段（C-NO-TOOL-NO-FORGE）")
        XCTAssertNil(capturedBody?["tools"],
                     "tools 空时 body 不应含 tools 字段")
    }

    // MARK: - 响应 tool_calls → 解析为 .toolUse

    /// 响应 message.tool_calls 含合法 arguments → content 含 .toolUse(id,name,input==解析 args)
    func test_send_responseToolCalls_parsedAsToolUse() async throws {
        ToolCallMockURLProtocol.requestHandler = { request in
            // OpenAI 非流式 tool_calls 格式：message.tool_calls[{id, type:"function", function:{name, arguments(JSON 字符串)}}]
            let json = """
            {
              "choices": [{
                "message": {
                  "role": "assistant",
                  "content": null,
                  "tool_calls": [
                    {
                      "id": "call_abc123",
                      "type": "function",
                      "function": {
                        "name": "qr",
                        "arguments": "{\\"query\\": \\"https://example.com\\"}"
                      }
                    }
                  ]
                },
                "finish_reason": "tool_calls"
              }]
            }
            """
            let data = json.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, data)
        }

        let resp = try await makeProvider().send(messages: [], tools: [], model: "m")

        // 找到 .toolUse
        let toolUse = resp.content.first { c in
            if case .toolUse = c { return true }
            return false
        }
        guard case .toolUse(let id, let name, let input)? = toolUse else {
            XCTFail("响应 tool_calls 必须被解析为 .toolUse，实际 content: \(resp.content)")
            return
        }
        XCTAssertEqual(id, "call_abc123", "toolUse.id 必须是 tool_call.id 'call_abc123'")
        XCTAssertEqual(name, "qr", "toolUse.name 必须是 function.name 'qr'")
        XCTAssertEqual(input["query"]?.value as? String, "https://example.com",
                       "toolUse.input.query 必须是 arguments JSON 解析后的值")
        XCTAssertEqual(resp.stopReason, "tool_use",
                       "finish_reason=='tool_calls' → stopReason=='tool_use'")
    }

    /// 响应同时含 content + tool_calls → .text 与 .toolUse 并存不丢弃
    func test_send_responseWithTextAndToolCalls_bothPreserved() async throws {
        ToolCallMockURLProtocol.requestHandler = { request in
            let json = """
            {
              "choices": [{
                "message": {
                  "role": "assistant",
                  "content": "我来帮你生成二维码",
                  "tool_calls": [
                    {
                      "id": "call_1",
                      "type": "function",
                      "function": {"name": "qr", "arguments": "{\\"query\\": \\"https://x.com\\"}"}
                    }
                  ]
                },
                "finish_reason": "tool_calls"
              }]
            }
            """
            let data = json.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, data)
        }

        let resp = try await makeProvider().send(messages: [], tools: [], model: "m")
        let hasText = resp.content.contains { c in
            if case .text(let t) = c { return t == "我来帮你生成二维码" }
            return false
        }
        let hasToolUse = resp.content.contains { c in
            if case .toolUse(_, let n, _) = c { return n == "qr" }
            return false
        }
        XCTAssertTrue(hasText, "响应含 content 时 .text 必须保留")
        XCTAssertTrue(hasToolUse, "响应含 tool_calls 时 .toolUse 必须保留（不丢弃）")
    }

    /// 无 tool_calls → 仅 .text（回归，不引入空 toolUse）
    func test_send_responseNoToolCalls_onlyText() async throws {
        ToolCallMockURLProtocol.requestHandler = { request in
            let json = #"{"choices":[{"message":{"role":"assistant","content":"plain"},"finish_reason":"stop"}]}"#
            let data = json.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, data)
        }
        let resp = try await makeProvider().send(messages: [], tools: [], model: "m")
        let hasToolUse = resp.content.contains { c in
            if case .toolUse = c { return true }
            return false
        }
        XCTAssertFalse(hasToolUse, "无 tool_calls 时 content 不应含 .toolUse")
    }

    // MARK: - arguments 畸形 → soft-fail

    /// arguments 空串 → soft-fail（input=空 dict）不 throw
    func test_send_responseToolCalls_emptyArguments_softFailEmptyDict() async throws {
        ToolCallMockURLProtocol.requestHandler = { request in
            let json = """
            {"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"c1","type":"function","function":{"name":"qr","arguments":""}}]},"finish_reason":"tool_calls"}]}
            """
            let data = json.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, data)
        }
        let resp = try await makeProvider().send(messages: [], tools: [], model: "m")
        let toolUse = resp.content.first { c in
            if case .toolUse = c { return true }
            return false
        }
        guard case .toolUse(_, let name, let input)? = toolUse else {
            XCTFail("arguments 空串也应解析出 .toolUse（soft-fail 不丢弃整个 tool_call）")
            return
        }
        XCTAssertEqual(name, "qr")
        XCTAssertTrue(input.isEmpty, "arguments 空串 → input 必须是空 dict（soft-fail），实际: \(input)")
    }

    /// arguments 畸形 JSON → soft-fail（input=空 dict）不 throw
    func test_send_responseToolCalls_malformedArguments_softFailEmptyDict() async throws {
        ToolCallMockURLProtocol.requestHandler = { request in
            let json = """
            {"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"c1","type":"function","function":{"name":"qr","arguments":"not-valid-json{{{"}}]},"finish_reason":"tool_calls"}]}
            """
            let data = json.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, data)
        }
        let resp = try await makeProvider().send(messages: [], tools: [], model: "m")
        let toolUse = resp.content.first { c in
            if case .toolUse = c { return true }
            return false
        }
        guard case .toolUse(_, let name, let input)? = toolUse else {
            XCTFail("arguments 畸形 JSON 也应解析出 .toolUse（soft-fail，不 throw 不丢弃）")
            return
        }
        XCTAssertEqual(name, "qr")
        XCTAssertTrue(input.isEmpty, "arguments 畸形 JSON → input 必须是空 dict（soft-fail），实际: \(input)")
    }

    // MARK: - C-THINKING-OFF

    /// noThinking=true → body.chat_template_kwargs.enable_thinking==false
    func test_send_noThinkingTrue_bodyIncludesEnableThinkingFalse() async throws {
        var capturedBody: [String: Any]?
        ToolCallMockURLProtocol.requestHandler = { request in
            capturedBody = self.captureBody(request)
            let json = #"{"choices":[{"message":{"role":"assistant","content":"hi"},"finish_reason":"stop"}]}"#
            let data = json.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, data)
        }

        _ = try await makeProvider(noThinking: true).send(messages: [], tools: [], model: "qwen3.6-35b")

        let kwargs = capturedBody?["chat_template_kwargs"] as? [String: Any]
        XCTAssertEqual(kwargs?["enable_thinking"] as? Bool, false,
                       "C-THINKING-OFF: noThinking=true 时 body.chat_template_kwargs.enable_thinking 必须是 false")
    }

    /// noThinking=false（默认）→ body 不含 chat_template_kwargs（不注入无关字段）
    func test_send_noThinkingFalse_bodyOmitsChatTemplateKwargs() async throws {
        var capturedBody: [String: Any]?
        ToolCallMockURLProtocol.requestHandler = { request in
            capturedBody = self.captureBody(request)
            let json = #"{"choices":[{"message":{"role":"assistant","content":"hi"},"finish_reason":"stop"}]}"#
            let data = json.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, data)
        }

        _ = try await makeProvider(noThinking: false).send(messages: [], tools: [], model: "m")

        XCTAssertNil(capturedBody?["chat_template_kwargs"],
                     "noThinking=false 时 body 不应含 chat_template_kwargs（不注入无关字段）")
    }
}

// MARK: - MockURLProtocol（专用，避免与 StepFiveMockURLProtocol 冲突）

private final class ToolCallMockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data?))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = ToolCallMockURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError:
                NSError(domain: "ToolCallMockURLProtocol", code: -1,
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
