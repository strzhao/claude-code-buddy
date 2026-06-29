import XCTest
@testable import BuddyCore

// MARK: - OpenAICompatibleProviderToolsChannelAcceptanceTests
//
// 红队验收测试（黑盒 TDD 红灯）：OpenAICompatibleProvider 非流式 send 的 tools 通道。
//
// 设计文档契约（逐字一致）：
//   C-THINKING-OFF    : noThinking == true ⟹ body.chat_template_kwargs.enable_thinking == false
//   C-NO-TOOL-NO-FORGE : tools 为空时 body 不含 tools / tool_choice 字段
//   C-TOOLCALL-CHANNEL : request.tools 非空 ⟹ 响应 tool_calls 被解析为 AgentContent.toolUse 不丢弃
//
// 验收场景（det-machine）：
//   场景1.P3[det] : tool-use 请求 → 关 thinking ｜ assert enable_thinking == false
//   场景4.P1[det] : 开启插件集空 → 不发 tool ｜ assert tools==[] 或不存在
//   场景8.P1[det]（传输层）: 响应 tool_calls 解析为 .toolUse
//
// 铁律：强断言、失败必挂、Mutation-Survival、黑盒（不读蓝队新实现源码）。
//
// 关键类型（已有，非蓝队新增）：
//   OpenAICompatibleProvider(apiKey:baseURL:noThinking:session:) —— init 已有
//   LauncherProvider.send(messages:tools:model:system:) -> AgentResponse
//   AgentTool / AgentContent.toolUse(id:name:input:) / AnyCodable

// MARK: - PluginToolMockURLProtocol（HTTP 拦截，命名隔离避免冲突）

final class PluginToolMockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data?))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = PluginToolMockURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError:
                NSError(domain: "PluginToolMockURLProtocol", code: -1,
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

// MARK: - Helpers

private func makeMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [PluginToolMockURLProtocol.self]
    return URLSession(configuration: config)
}

/// 从 URLRequest 提取 body 为 dict（兼容 httpBody 与 httpBodyStream）
private func bodyDict(of request: URLRequest) -> [String: Any]? {
    var bodyData: Data?
    if let body = request.httpBody {
        bodyData = body
    } else if let stream = request.httpBodyStream {
        stream.open()
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let bytesRead = stream.read(&buffer, maxLength: bufferSize)
            if bytesRead > 0 { data.append(buffer, count: bytesRead) }
        }
        stream.close()
        bodyData = data
    }
    guard let data = bodyData else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

private func makeAgentTool(name: String = "qr", description: String = "gen qr") -> AgentTool {
    AgentTool(
        name: name,
        description: description,
        inputSchema: [
            "type": AnyCodable("object"),
            "properties": AnyCodable([
                "query": ["type": "string"]
            ]),
            "required": AnyCodable(["query"])
        ]
    )
}

private func makeOKResponse(_ bodyJSON: String) -> (HTTPURLResponse, Data) {
    let data = bodyJSON.data(using: .utf8)!
    let response = HTTPURLResponse(
        url: URL(string: "http://localhost:8001/v1/chat/completions")!,
        statusCode: 200, httpVersion: nil, headerFields: nil
    )!
    return (response, data)
}

// MARK: - 场景1.P3[det] + C-THINKING-OFF: tool-use 请求 → 关 thinking

final class OpenAICompatibleProviderThinkingOffAcceptanceTests: XCTestCase {

    private var session: URLSession!

    override func setUp() {
        super.setUp()
        session = makeMockSession()
        PluginToolMockURLProtocol.requestHandler = nil
    }

    override func tearDown() {
        PluginToolMockURLProtocol.requestHandler = nil
        session = nil
        super.tearDown()
    }

    // 场景1.P3[det] + C-THINKING-OFF：noThinking==true + tools 非空 → body.chat_template_kwargs.enable_thinking==false
    //
    // Mutation 探针：
    //   - 若蓝队漏写 enable_thinking（noThinking=true 时），enable_thinking 为 nil → 红灯
    //   - 若蓝队写成 true，断言红灯
    func test_scenario1_P3_noThinkingTrue_enablesThinkingFalseInBody() async throws {
        var capturedBody: [String: Any]?
        PluginToolMockURLProtocol.requestHandler = { request in
            capturedBody = bodyDict(of: request)
            return makeOKResponse(#"{"choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}"#)
        }

        let provider = OpenAICompatibleProvider(
            apiKey: "qwen-local-key",
            baseURL: URL(string: "http://localhost:8001/v1")!,
            noThinking: true,
            session: session
        )
        _ = try await provider.send(
            messages: [AgentMessage(role: "user", content: [.text("生成二维码 https://example.com")])],
            tools: [makeAgentTool()],
            model: "qwen3.6-35b"
        )

        // chat_template_kwargs 必须存在
        let chatTemplateKwargs = capturedBody?["chat_template_kwargs"] as? [String: Any]
        XCTAssertNotNil(chatTemplateKwargs,
                       "C-THINKING-OFF: body 必须含 chat_template_kwargs 字段（noThinking=true 时），实际 body keys: \(capturedBody?.keys.sorted() ?? [])")

        let enableThinking = chatTemplateKwargs?["enable_thinking"] as? Bool
        XCTAssertEqual(enableThinking, false,
                       "场景1.P3 / C-THINKING-OFF: chat_template_kwargs.enable_thinking 必须精确是 false，实际: \(enableThinking ?? true)")
    }

    // C-THINKING-OFF 补（边界）：noThinking==false（默认）→ enable_thinking 不为 false（可为 true 或缺省，但不能是 false）
    //
    // 设计文档：只有 noThinking==true 通道生效关 thinking。noThinking==false 时不应强制 enable_thinking==false。
    func test_C_THINKING_OFF_noThinkingFalse_doesNotForceFalse() async throws {
        var capturedBody: [String: Any]?
        PluginToolMockURLProtocol.requestHandler = { request in
            capturedBody = bodyDict(of: request)
            return makeOKResponse(#"{"choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}"#)
        }

        let provider = OpenAICompatibleProvider(
            apiKey: "qwen-local-key",
            baseURL: URL(string: "http://localhost:8001/v1")!,
            noThinking: false,
            session: session
        )
        _ = try await provider.send(
            messages: [AgentMessage(role: "user", content: [.text("hi")])],
            tools: [],
            model: "qwen3.6-35b"
        )

        let chatTemplateKwargs = capturedBody?["chat_template_kwargs"] as? [String: Any]
        let enableThinking = chatTemplateKwargs?["enable_thinking"] as? Bool
        // noThinking=false 时，enable_thinking 不能是 false（可为 true 或 nil）
        XCTAssertFalse(enableThinking == false,
                       "C-THINKING-OFF: noThinking==false 时不应强制 enable_thinking==false（关 thinking 只在 noThinking=true 时生效），实际: \(enableThinking ?? true)")
    }
}

// MARK: - 场景4.P1[det] + C-NO-TOOL-NO-FORGE: tools 为空 → body 不含 tools/tool_choice

final class OpenAICompatibleProviderNoToolNoForgeAcceptanceTests: XCTestCase {

    private var session: URLSession!

    override func setUp() {
        super.setUp()
        session = makeMockSession()
        PluginToolMockURLProtocol.requestHandler = nil
    }

    override func tearDown() {
        PluginToolMockURLProtocol.requestHandler = nil
        session = nil
        super.tearDown()
    }

    // 场景4.P1[det] + C-NO-TOOL-NO-FORGE：send 时 tools==[] → body 不含 "tools" 键（或为空数组），不含 "tool_choice"
    //
    // Mutation 探针：若蓝队 tools 为空时仍注入 tools/tool_choice（如残留固定 query tool），
    //   bodyHasTools 断言红灯。
    func test_scenario4_P1_emptyTools_bodyHasNoToolsOrToolChoice() async throws {
        var capturedBody: [String: Any]?
        PluginToolMockURLProtocol.requestHandler = { request in
            capturedBody = bodyDict(of: request)
            return makeOKResponse(#"{"choices":[{"message":{"role":"assistant","content":"闲聊"},"finish_reason":"stop"}]}"#)
        }

        let provider = OpenAICompatibleProvider(
            apiKey: "qwen-local-key",
            baseURL: URL(string: "http://localhost:8001/v1")!,
            session: session
        )
        _ = try await provider.send(
            messages: [AgentMessage(role: "user", content: [.text("你好")])],
            tools: [],
            model: "qwen3.6-35b"
        )

        let body = capturedBody ?? [:]
        // tools 必须不存在或为空数组
        let toolsValue = body["tools"]
        let toolsIsEmpty: Bool
        if toolsValue == nil {
            toolsIsEmpty = true
        } else if let arr = toolsValue as? [Any] {
            toolsIsEmpty = arr.isEmpty
        } else {
            toolsIsEmpty = false
        }
        XCTAssertTrue(toolsIsEmpty,
                      "场景4.P1 / C-NO-TOOL-NO-FORGE: tools==[] 时 body.tools 必须不存在或为空数组，实际: \(String(describing: toolsValue))")

        // tool_choice 必须不存在（无 tools 时不发 tool_choice）
        XCTAssertNil(body["tool_choice"],
                     "场景4.P1: tools==[] 时 body 不应含 tool_choice，实际 body keys: \(body.keys.sorted())")
    }
}

// MARK: - 场景8.P1[det] + C-TOOLCALL-CHANNEL: 响应 tool_calls 解析为 .toolUse

final class OpenAICompatibleProviderToolCallParseAcceptanceTests: XCTestCase {

    private var session: URLSession!

    override func setUp() {
        super.setUp()
        session = makeMockSession()
        PluginToolMockURLProtocol.requestHandler = nil
    }

    override func tearDown() {
        PluginToolMockURLProtocol.requestHandler = nil
        session = nil
        super.tearDown()
    }

    // C-TOOLCALL-CHANNEL：send 时 tools 非空 + 响应含 tool_calls → 解析为 AgentContent.toolUse 不丢弃
    //
    // Mutation 探针：
    //   - 若蓝队 send 丢弃 tool_calls（只解析 content 文本），response 无 .toolUse → 红灯
    //   - 若蓝队漏解析 input（只取 name），input 为空 → 红灯
    func test_C_TOOLCALL_CHANNEL_responseToolCalls_parsedAsToolUse() async throws {
        PluginToolMockURLProtocol.requestHandler = { _ in
            // OpenAI 格式响应：tool_calls 在 message.tool_calls 数组中
            let json = """
            {
              "choices": [{
                "message": {
                  "role": "assistant",
                  "content": null,
                  "tool_calls": [{
                    "id": "call_abc123",
                    "type": "function",
                    "function": {
                      "name": "qr",
                      "arguments": "{\\"query\\": \\"https://example.com\\"}"
                    }
                  }]
                },
                "finish_reason": "tool_calls"
              }]
            }
            """
            return makeOKResponse(json)
        }

        let provider = OpenAICompatibleProvider(
            apiKey: "qwen-local-key",
            baseURL: URL(string: "http://localhost:8001/v1")!,
            session: session
        )
        let response = try await provider.send(
            messages: [AgentMessage(role: "user", content: [.text("生成二维码 https://example.com")])],
            tools: [makeAgentTool()],
            model: "qwen3.6-35b"
        )

        // 必须有一个 .toolUse 内容（不丢弃）
        let toolUseContents = response.content.filter { c in
            if case .toolUse = c { return true }; return false
        }
        XCTAssertEqual(toolUseContents.count, 1,
                       "C-TOOLCALL-CHANNEL: 响应含 1 个 tool_calls 必须解析为恰好 1 个 .toolUse，实际: \(toolUseContents.count)")

        // 解构验证：name + input.query 双重校验
        if case .toolUse(let id, let name, let input) = toolUseContents.first {
            XCTAssertEqual(name, "qr",
                           "C-TOOLCALL-CHANNEL: toolUse.name 必须精确是 'qr'，实际: \(name)")
            XCTAssertEqual(id, "call_abc123",
                           "toolUse.id 必须保留响应中的 tool_call.id，实际: \(id)")
            let queryValue = input["query"]?.value as? String
            XCTAssertEqual(queryValue, "https://example.com",
                           "C-TOOLCALL-CHANNEL: toolUse.input.query 必须精确是 'https://example.com'（从 arguments JSON 解析），实际: \(queryValue ?? "nil")")
        } else {
            XCTFail("C-TOOLCALL-CHANNEL: toolUseContents.first 必须是 .toolUse")
        }
    }

    // C-TOOLCALL-CHANNEL 补（场景8.P1 stdin 回灌前置）：tool_calls 解析出的 input 必须能转成 PluginInput
    //   （stdin 插件 stdout 回灌路径前置——tool 结果能回灌说明 toolUse.input 通道完整）
    func test_C_TOOLCALL_CHANNEL_parsedInputFillsPluginInput() async throws {
        PluginToolMockURLProtocol.requestHandler = { _ in
            let json = """
            {
              "choices": [{
                "message": {
                  "role": "assistant",
                  "tool_calls": [{
                    "id": "call_1",
                    "type": "function",
                    "function": {
                      "name": "qr",
                      "arguments": "{\\"query\\": \\"https://github.com\\"}"
                    }
                  }]
                },
                "finish_reason": "tool_calls"
              }]
            }
            """
            return makeOKResponse(json)
        }

        let provider = OpenAICompatibleProvider(
            apiKey: "qwen-local-key",
            baseURL: URL(string: "http://localhost:8001/v1")!,
            session: session
        )
        let response = try await provider.send(
            messages: [AgentMessage(role: "user", content: [.text("qr")])],
            tools: [makeAgentTool()],
            model: "qwen3.6-35b"
        )

        guard case .toolUse(_, _, let input)? = response.content.first(where: { if case .toolUse = $0 { return true }; return false }) else {
            XCTFail("必须解析出 toolUse")
            return
        }
        // 场景8.P1 前置：解析出的 input.query 能填入 PluginInput（stdin 回灌链路完整）
        let queryValue = input["query"]?.value as? String
        XCTAssertEqual(queryValue, "https://github.com")
        let pluginInput = PluginInput(query: queryValue ?? "", sessionId: "test-session", cwd: "/tmp")
        XCTAssertEqual(pluginInput.query, "https://github.com",
                       "场景8.P1 前置: toolUse.input.query 必须能填入 PluginInput.query（stdin 回灌链路完整）")
    }

    // 场景4.P1 补：send 时 tools 非空 → body.tools 必须包含该 tool（OpenAI function 格式）
    //
    // Mutation 探针：若蓝队 send 漏发 tools 字段（即使入参非空），bodyHasTools 红灯。
    func test_scenario4_P1_supplement_nonEmptyTools_bodyContainsTools() async throws {
        var capturedBody: [String: Any]?
        PluginToolMockURLProtocol.requestHandler = { request in
            capturedBody = bodyDict(of: request)
            return makeOKResponse(#"{"choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}"#)
        }

        let provider = OpenAICompatibleProvider(
            apiKey: "qwen-local-key",
            baseURL: URL(string: "http://localhost:8001/v1")!,
            session: session
        )
        let tool = makeAgentTool(name: "qr", description: "生成二维码")
        _ = try await provider.send(
            messages: [AgentMessage(role: "user", content: [.text("qr")])],
            tools: [tool],
            model: "qwen3.6-35b"
        )

        let body = capturedBody ?? [:]
        let toolsValue = body["tools"]
        XCTAssertNotNil(toolsValue,
                       "send 时 tools 非空 → body.tools 必须存在（发送给 LLM），实际 body keys: \(body.keys.sorted())")

        // tool_choice 必须存在且为 "auto"（设计文档：tools 非空时 tool_choice:"auto"）
        let toolChoice = body["tool_choice"]
        XCTAssertEqual(toolChoice as? String, "auto",
                       "tools 非空时 body.tool_choice 必须是 'auto'，实际: \(String(describing: toolChoice))")

        // tools 数组里第一个 function name 必须是 qr
        if let toolsArr = toolsValue as? [[String: Any]],
           let firstTool = toolsArr.first,
           let function = firstTool["function"] as? [String: Any] {
            XCTAssertEqual(function["name"] as? String, "qr",
                           "body.tools[0].function.name 必须是 'qr'，实际: \(function["name"] ?? "nil")")
        } else {
            XCTFail("body.tools 必须是 [[String:Any]] 且首元素含 function 字段，实际: \(String(describing: toolsValue))")
        }
    }
}
