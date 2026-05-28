import XCTest
@testable import BuddyCore

// MARK: - 红队验收测试：LauncherProvider system 字段 (Task 001)
//
// 本文件由红队独立编写，基于设计文档 + brief，不读取任何蓝队实现代码。
//
// 契约来源：
//   - .autopilot/project/tasks/001-provider-system-field.md
//   - .autopilot/runtime/sessions/translate/requirements/20260528-001-provider-system-field/state.md
//
// 测试场景覆盖（10 个）：
//   SC-1  send 不传 system → mock provider 行为与 3 参数旧调用一致
//   SC-2  AnthropicProvider system="hi" → HTTP body JSON 含顶层 "system":"hi"
//   SC-3  AnthropicProvider system=nil → body 不含 "system" key
//   SC-4  AnthropicProvider system="" → body 不含 "system" key（空字符串等价 nil）
//   SC-5  OpenAICompatibleProvider system="route" → body messages[0] 为 {role:"system",content:"route"}
//   SC-6  OpenAICompatibleProvider system=nil → body messages 仅含原 user 项
//   SC-7  OpenAICompatibleProvider system="" → body messages 不含 system 项
//   SC-8  LauncherRouter.aiSelect 调用 send 时传入 system 参数 == 期望的 systemPrompt
//   SC-9  LauncherRouter.aiSelect 行为等价性回归（迁移前后相同 query 选相同 plugin）
//   SC-10 Qwen 本地端点真实调用（条件性，不可达时 XCTSkip）
//
// 编译预期：
//   - 蓝队 Step 1 完成（协议签名更新 + mock 同步）后编译通过
//   - 蓝队 Step 1 之前：编译失败（MockRouterSystemProvider.send 参数数量不匹配），这是预期红灯
//
// 注意：LauncherProvider 协议方法在 Swift 5.9 不支持默认参数（见设计文档修正 1），
//       协议层签名为 send(messages:tools:model:system:) 无默认值，
//       concrete impl 可加默认值，但协议引用调用必须显式传 system: 参数。

// MARK: - MockURLProtocolSystem
//
// 专用于本验收测试的 URLProtocol mock（避免与 LauncherProviderAcceptanceTests.MockURLProtocol 冲突）

private final class MockURLProtocolSystem: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data?))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    /// URLSession 内部把 httpBody 转为 httpBodyStream，此处恢复为 httpBody 供断言
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
        guard let handler = MockURLProtocolSystem.requestHandler else {
            client?.urlProtocol(self, didFailWithError:
                NSError(domain: "MockURLProtocolSystem", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "No handler registered"]))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let data = data { client?.urlProtocol(self, didLoad: data) }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// MARK: - MockRouterSystemProvider
//
// 专用于 LauncherRouter 测试的 mock provider（记录 system 参数用于断言）
// 签名必须与蓝队扩展后的 LauncherProvider 协议一致（加 system: String?）

private final class MockRouterSystemProvider: LauncherProvider {
    var response: AgentResponse
    private(set) var capturedMessages: [AgentMessage] = []
    private(set) var capturedSystem: String?
    private(set) var callCount = 0

    init(reply: String) {
        self.response = AgentResponse(
            content: [.text(reply)],
            stopReason: "end_turn",
            usage: nil
        )
    }

    // 蓝队 Step 1 完成后此签名必须匹配 LauncherProvider 协议
    func send(
        messages: [AgentMessage],
        tools: [AgentTool],
        model: String,
        system: String?
    ) async throws -> AgentResponse {
        capturedMessages = messages
        capturedSystem = system
        callCount += 1
        return response
    }
}

// MARK: - Helpers

private func makeSystemTestManifest(name: String, description: String, keywords: [String] = []) -> PluginManifest {
    PluginManifest(
        name: name,
        version: "1.0.0",
        description: description,
        keywords: keywords,
        cmd: "./run.sh",
        args: [],
        env: nil,
        timeout: nil,
        requiredPath: nil
    )
}

private func anthropicSuccessJSON(text: String = "ok") -> Data {
    let json = """
    {
        "content": [{"type": "text", "text": "\(text)"}],
        "stop_reason": "end_turn",
        "usage": {"input_tokens": 5, "output_tokens": 3}
    }
    """
    return json.data(using: .utf8)!
}

private func oaiSuccessJSON(text: String = "ok") -> Data {
    let json = """
    {
        "choices": [{
            "message": {"role": "assistant", "content": "\(text)"},
            "finish_reason": "stop"
        }],
        "usage": {"prompt_tokens": 5, "completion_tokens": 3}
    }
    """
    return json.data(using: .utf8)!
}

private func httpOK(url: URL) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
}

// MARK: - SC-1 ~ SC-4: AnthropicProvider system 字段编码测试

final class AnthropicProviderSystemFieldTests: XCTestCase {

    private var mockSession: URLSession!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocolSystem.self]
        mockSession = URLSession(configuration: config)
        MockURLProtocolSystem.requestHandler = nil
    }

    override func tearDown() {
        MockURLProtocolSystem.requestHandler = nil
        mockSession = nil
        super.tearDown()
    }

    private func makeProvider() -> AnthropicProvider {
        AnthropicProvider(apiKey: "sk-ant-test-key-1234", session: mockSession)
    }

    // SC-1: send 不传 system（旧调用风格）行为不变
    // 契约：协议 send 有 4 个参数，显式传 system: nil 等价于旧 3 参数行为
    // 断言：body 不含 "system" key，响应正常解析
    func test_sc1_sendWithSystemNil_behaviorUnchanged() async throws {
        var capturedBody: Data?
        MockURLProtocolSystem.requestHandler = { request in
            capturedBody = request.httpBody
            return (httpOK(url: request.url!), anthropicSuccessJSON())
        }

        let provider = makeProvider()
        let response = try await provider.send(
            messages: [AgentMessage(role: "user", content: [.text("hi")])],
            tools: [],
            model: "claude-sonnet-4-5",
            system: nil  // 旧调用等价
        )

        XCTAssertEqual(response.stopReason, "end_turn",
                       "SC-1: system=nil 时响应必须正常解析，stopReason == end_turn")
        let bodyJSON = try JSONSerialization.jsonObject(with: capturedBody!) as? [String: Any]
        XCTAssertNil(bodyJSON?["system"],
                     "SC-1: system=nil 时 body 不应包含 system 字段")
    }

    // SC-2: AnthropicProvider 传 system="hi" → body 含顶层 "system":"hi"
    // 契约：设计文档 §契约规约 2 + 决策 2（CodingKey = "system" 无下划线）
    // 断言：body JSON 顶层字段 "system" == "hi"
    func test_sc2_anthropicProvider_withSystem_bodyContainsTopLevelSystemField() async throws {
        var capturedBody: Data?
        MockURLProtocolSystem.requestHandler = { request in
            capturedBody = request.httpBody
            return (httpOK(url: request.url!), anthropicSuccessJSON())
        }

        let provider = makeProvider()
        _ = try await provider.send(
            messages: [AgentMessage(role: "user", content: [.text("test")])],
            tools: [],
            model: "claude-sonnet-4-5",
            system: "hi"
        )

        let bodyStr = String(data: capturedBody!, encoding: .utf8) ?? ""
        let bodyJSON = try JSONSerialization.jsonObject(with: capturedBody!) as? [String: Any]
        XCTAssertEqual(bodyJSON?["system"] as? String, "hi",
                       "SC-2: system='hi' 时 body 必须含顶层 system 字段，值为 'hi'")
        // 双重断言：原始字符串检查
        XCTAssertTrue(bodyStr.contains("\"system\""),
                      "SC-2: body 原始字符串必须包含 \"system\" key")
    }

    // SC-3: AnthropicProvider system=nil → body 不含 "system" key
    // 契约：设计文档 决策 2 + Swift Encodable Optional nil 不编码（encodeIfPresent）
    // 断言：body JSON 无 "system" key
    func test_sc3_anthropicProvider_systemNil_bodyNoSystemKey() async throws {
        var capturedBody: Data?
        MockURLProtocolSystem.requestHandler = { request in
            capturedBody = request.httpBody
            return (httpOK(url: request.url!), anthropicSuccessJSON())
        }

        let provider = makeProvider()
        _ = try await provider.send(
            messages: [AgentMessage(role: "user", content: [.text("test")])],
            tools: [],
            model: "claude-sonnet-4-5",
            system: nil
        )

        let bodyStr = String(data: capturedBody!, encoding: .utf8) ?? ""
        XCTAssertFalse(bodyStr.contains("\"system\""),
                       "SC-3: system=nil 时 body 不应包含 system key（Optional nil 不编码）")
    }

    // SC-4: AnthropicProvider system="" → body 不含 "system" key（业务守卫: !system.isEmpty）
    // 契约：设计文档 决策 1 + 决策 2 §if let system = system, !system.isEmpty
    // 断言：body JSON 无 "system" key
    func test_sc4_anthropicProvider_emptySystem_bodyNoSystemKey() async throws {
        var capturedBody: Data?
        MockURLProtocolSystem.requestHandler = { request in
            capturedBody = request.httpBody
            return (httpOK(url: request.url!), anthropicSuccessJSON())
        }

        let provider = makeProvider()
        _ = try await provider.send(
            messages: [AgentMessage(role: "user", content: [.text("test")])],
            tools: [],
            model: "claude-sonnet-4-5",
            system: ""
        )

        let bodyStr = String(data: capturedBody!, encoding: .utf8) ?? ""
        XCTAssertFalse(bodyStr.contains("\"system\""),
                       "SC-4: system='' 应等价于 nil，body 不含 system key")
    }
}

// MARK: - SC-5 ~ SC-7: OpenAICompatibleProvider system 字段 prepend 测试

final class OpenAICompatibleProviderSystemFieldTests: XCTestCase {

    private var mockSession: URLSession!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocolSystem.self]
        mockSession = URLSession(configuration: config)
        MockURLProtocolSystem.requestHandler = nil
    }

    override func tearDown() {
        MockURLProtocolSystem.requestHandler = nil
        mockSession = nil
        super.tearDown()
    }

    private func makeProvider() -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(
            apiKey: "qwen-local-key",
            baseURL: URL(string: "http://localhost:11434/v1")!,
            session: mockSession
        )
    }

    // SC-5: OpenAICompatibleProvider system="route" + messages=[user("q")]
    //       → body messages[0] == {role:"system",content:"route"}，user 项在 index 1
    // 契约：设计文档 决策 3 + 修正 3（content 是 String，不是 [ContentBlock]）
    // 断言：messages[0].role=="system"，messages[0].content=="route"，messages[1].role=="user"
    func test_sc5_oaiProvider_withSystem_prependsSystemMessageAtIndex0() async throws {
        var capturedBody: Data?
        MockURLProtocolSystem.requestHandler = { request in
            capturedBody = request.httpBody
            return (httpOK(url: request.url!), oaiSuccessJSON())
        }

        let provider = makeProvider()
        _ = try await provider.send(
            messages: [AgentMessage(role: "user", content: [.text("q")])],
            tools: [],
            model: "qwen3.6-35b",
            system: "route"
        )

        let bodyJSON = try JSONSerialization.jsonObject(with: capturedBody!) as? [String: Any]
        let messages = bodyJSON?["messages"] as? [[String: Any]]
        XCTAssertNotNil(messages, "SC-5: body 必须含 messages 数组")
        XCTAssertGreaterThanOrEqual(messages?.count ?? 0, 2,
                                    "SC-5: prepend system 后 messages 总数 >= 2")
        XCTAssertEqual(messages?[0]["role"] as? String, "system",
                       "SC-5: messages[0].role 必须 == 'system'")
        XCTAssertEqual(messages?[0]["content"] as? String, "route",
                       "SC-5: messages[0].content 必须 == 'route'（字符串，非数组）")
        XCTAssertEqual(messages?[1]["role"] as? String, "user",
                       "SC-5: 原 user 项必须保留在 index 1")
    }

    // SC-6: OpenAICompatibleProvider system=nil → body messages 仅含原 user 项
    // 契约：设计文档 决策 3 §if let system = system, !system.isEmpty
    // 断言：messages.count == 1，messages[0].role == "user"
    func test_sc6_oaiProvider_systemNil_messagesUnchanged() async throws {
        var capturedBody: Data?
        MockURLProtocolSystem.requestHandler = { request in
            capturedBody = request.httpBody
            return (httpOK(url: request.url!), oaiSuccessJSON())
        }

        let provider = makeProvider()
        _ = try await provider.send(
            messages: [AgentMessage(role: "user", content: [.text("q")])],
            tools: [],
            model: "qwen3.6-35b",
            system: nil
        )

        let bodyJSON = try JSONSerialization.jsonObject(with: capturedBody!) as? [String: Any]
        let messages = bodyJSON?["messages"] as? [[String: Any]]
        XCTAssertEqual(messages?.count, 1,
                       "SC-6: system=nil 时 messages 不应被改变（仍为 1 条）")
        XCTAssertEqual(messages?[0]["role"] as? String, "user",
                       "SC-6: 唯一 message 的 role 应为 'user'")
    }

    // SC-7: OpenAICompatibleProvider system="" → body messages 不含 system 项
    // 契约：设计文档 决策 3 §!system.isEmpty 守卫
    // 断言：messages 不含 role=="system" 的项
    func test_sc7_oaiProvider_emptySystem_noSystemMessage() async throws {
        var capturedBody: Data?
        MockURLProtocolSystem.requestHandler = { request in
            capturedBody = request.httpBody
            return (httpOK(url: request.url!), oaiSuccessJSON())
        }

        let provider = makeProvider()
        _ = try await provider.send(
            messages: [AgentMessage(role: "user", content: [.text("q")])],
            tools: [],
            model: "qwen3.6-35b",
            system: ""
        )

        let bodyJSON = try JSONSerialization.jsonObject(with: capturedBody!) as? [String: Any]
        let messages = bodyJSON?["messages"] as? [[String: Any]]
        let hasSystemMsg = messages?.contains { $0["role"] as? String == "system" } ?? false
        XCTAssertFalse(hasSystemMsg,
                       "SC-7: system='' 时 messages 不应包含 role=='system' 的项")
    }
}

// MARK: - SC-8 ~ SC-9: LauncherRouter system 参数迁移测试

final class LauncherRouterSystemMigrationTests: XCTestCase {

    // SC-8: LauncherRouter.aiSelect 调用 send 时 system 参数 == 完整 systemPrompt 字符串
    //       且 messages 内容为纯 user query（不含 router 指令前缀 hack）
    // 契约：设计文档 §契约规约 4 + 决策 4（迁移 combinedPrompt hack）
    // 断言：capturedSystem != nil && 含 "You are a router"；messages[0].content 不含 systemPrompt 前缀
    func test_sc8_launcherRouter_aiSelect_usesSystemParameter() async throws {
        let translate = makeSystemTestManifest(
            name: "translate",
            description: "Translate text",
            keywords: ["translation"]
        )
        let mockProvider = MockRouterSystemProvider(reply: "translate")
        let router = LauncherRouter(
            pluginManager: PluginManager(rootDir: URL(fileURLWithPath: "/nonexistent")),
            provider: mockProvider,
            routerModel: "test-model"
        )

        _ = try await router.aiSelect(query: "translate this text", candidates: [translate])

        // 验证 system 参数非空且包含 router 指令
        let capturedSystem = mockProvider.capturedSystem
        XCTAssertNotNil(capturedSystem,
                        "SC-8: LauncherRouter.aiSelect 必须通过 system 参数传递 router 指令（不再是 user message 前缀）")
        XCTAssertTrue(capturedSystem?.contains("You are a router") ?? false,
                      "SC-8: system 参数必须包含 'You are a router' 指令文本")

        // 验证 messages 仅含纯 query，不含 router 指令前缀
        let firstMessage = mockProvider.capturedMessages.first
        XCTAssertNotNil(firstMessage, "SC-8: provider.send 必须被调用（messages 非空）")
        if case .text(let text) = firstMessage?.content.first {
            XCTAssertFalse(text.contains("You are a router"),
                           "SC-8: user message 不应包含 router 指令前缀（hack 已迁移到 system 参数）")
        }
    }

    // SC-9: LauncherRouter.aiSelect 行为等价性回归
    //       迁移 hack 后，相同 query + 候选列表，router 选择结果与 hack 时期等价
    // 契约：brief §验收标准 Tier 1.5 §router 路由行为不变
    // 断言：mock 返回 "translate" → RouteDecision == .withPlugin(translate manifest)
    func test_sc9_launcherRouter_aiSelect_behaviorEquivalenceAfterMigration() async throws {
        let translate = makeSystemTestManifest(
            name: "translate",
            description: "Translate text",
            keywords: ["translation"]
        )
        let mockProvider = MockRouterSystemProvider(reply: "translate")
        let router = LauncherRouter(
            pluginManager: PluginManager(rootDir: URL(fileURLWithPath: "/nonexistent")),
            provider: mockProvider,
            routerModel: "test-model"
        )

        let decision = try await router.aiSelect(query: "translate this text", candidates: [translate])

        // 行为等价性：迁移前后 mock 返回 "translate" 时选择结果必须一致
        XCTAssertEqual(decision, .withPlugin(translate),
                       "SC-9: 行为等价性回归——system 迁移后 AI 选 'translate' 时决策仍为 .withPlugin(translate)")
    }

    // SC-9b: Router NONE 行为等价性
    // 断言：mock 返回 "NONE" → RouteDecision == .directChat
    func test_sc9b_launcherRouter_aiSelect_noneDecision_behaviorEquivalence() async throws {
        let translate = makeSystemTestManifest(
            name: "translate",
            description: "Translate text",
            keywords: ["translation"]
        )
        let mockProvider = MockRouterSystemProvider(reply: "NONE")
        let router = LauncherRouter(
            pluginManager: PluginManager(rootDir: URL(fileURLWithPath: "/nonexistent")),
            provider: mockProvider,
            routerModel: "test-model"
        )

        let decision = try await router.aiSelect(query: "calculate 1+1", candidates: [translate])

        XCTAssertEqual(decision, .directChat,
                       "SC-9b: NONE 行为等价性——system 迁移后 AI 返回 NONE 时决策仍为 .directChat")
    }
}

// MARK: - SC-10: Qwen 本地端点真实调用（条件性）

final class QwenLocalEndpointSystemFieldTests: XCTestCase {

    // SC-10: 真实 POST 到 http://127.0.0.1:8001/v1，含 system message
    // 条件性：端点不可达时自动 XCTSkip（非强制场景）
    // 契约：brief §验收标准 Tier 1.5 SC-7 + 设计文档 §验证方案场景 6
    // 断言：HTTP 200 + 响应内容非空（system="请用中文回答" 应引导中文回复）
    func test_sc10_qwenLocalEndpoint_withSystemMessage_returns200() async throws {
        let baseURL = URL(string: "http://127.0.0.1:8001/v1")!

        // 检查端点可达性（超时 2 秒快速失败）
        let reachable = await isEndpointReachable(url: URL(string: "http://127.0.0.1:8001/v1/models")!)
        guard reachable else {
            throw XCTSkip("SC-10: Qwen 本地端点 http://127.0.0.1:8001/v1 不可达，跳过真实调用测试")
        }

        let provider = OpenAICompatibleProvider(
            apiKey: "qwen-local-key",
            baseURL: baseURL,
            session: URLSession.shared
        )

        let response = try await provider.send(
            messages: [AgentMessage(role: "user", content: [.text("hello")])],
            tools: [],
            model: "qwen3.6-35b",
            system: "请用中文回答"
        )

        XCTAssertFalse(response.content.isEmpty,
                       "SC-10: 真实 Qwen 端点返回内容不应为空")
        XCTAssertEqual(response.stopReason, "end_turn",
                       "SC-10: 真实调用 stopReason 应为 end_turn")

        // 验证响应包含中文字符（Unicode 检测）
        if case .text(let text) = response.content.first {
            let hasChinese = text.unicodeScalars.contains { scalar in
                (0x4E00...0x9FFF).contains(scalar.value) ||
                (0x3400...0x4DBF).contains(scalar.value)
            }
            // system="请用中文回答" 应引导中文回复（容差：允许混合语言）
            // 仅记录实际结果，不强制失败（语言随机性）
            if !hasChinese {
                XCTFail("SC-10: 期望响应含中文字符，实际为：\(text.prefix(100))")
            }
        }
    }

    // 快速检查端点可达性（2 秒超时）
    private func isEndpointReachable(url: URL) async -> Bool {
        do {
            var request = URLRequest(url: url, timeoutInterval: 2.0)
            request.httpMethod = "GET"
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode != nil
        } catch {
            return false
        }
    }
}
