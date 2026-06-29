import XCTest
@testable import BuddyCore

// MARK: - LauncherRouterSelectWithToolsAcceptanceTests
//
// 红队验收测试（黑盒 TDD 红灯）：LauncherRouter.selectWithTools —— 把所有开启插件作 LLM tool，
// provider 返回 tool_calls → 匹配 plugin name → (RouteDecision, extractedQuery)。
//
// 设计文档契约（逐字一致）：
//   C-TOOLCALL-CHANNEL : request.tools 非空 ⟹ 响应 tool_calls 被解析为 .toolUse 不丢弃
//   C-HALLUCINATE      : tool_call.name ∉ plugins.name ⟹ RouteDecision == .directChat
//   C-NO-TOOL-NO-FORGE : plugins==[] ⟹ request.tools==[] 且无 tool_calls
//   C-EXTRACTED-QUERY  : extractedQuery 非空 ⟹ PluginInput.query == extractedQuery
//   错误码              : LauncherError.pluginNotFound(name)
//
// 验收场景（det-machine）：
//   场景1.P1[det] : 输入含 URL "生成二维码" → 选中 qr ｜ assert plugin=="qr"
//   场景1.P3[det] : tool-use 请求 → 关 thinking（在 OpenAICompatibleProvider 文件覆盖，此处覆盖 selectWithTools 侧）
//   场景3.P1[det] : 两 URL 插件 + 语义 "缩短" → 选 shorten ｜ negate != qr
//   场景3.P2[det] : 语义 "二维码" → 选 qr ｜ negate != shorten
//   场景4.P1[det] : 开启插件集空 → 不发 tool ｜ assert tools==[]
//   场景4.P2[det] : 工具集空 → 不伪造 tool_calls
//   场景8.P2[det] : 回灌完成 → 非空回复（间接：selectWithTools 不返回空 decision）
//   场景9.P2[det] : 参数提取 → 填入插件输入（extractedQuery 契约）
//
// 铁律：强断言、失败必挂、Mutation-Survival、黑盒（不读蓝队新实现源码）。
//
// 关键类型（已有，非蓝队新增；蓝队新增 selectWithTools 方法）：
//   LauncherRouter(pluginManager:provider:routerModel:)
//   LauncherRouter.selectWithTools(query:plugins:) async throws -> (RouteDecision, extractedQuery: String?)
//     （设计文档 Part2 新增；红队假设此签名存在）
//   AgentContent.toolUse(id:name:input:[String:AnyCodable])
//   RouteDecision(.directChat / .withPlugin(PluginManifest))

// MARK: - MockSelectWithToolsProvider
//
// 专用于 selectWithTools 测试的 LauncherProvider 桩（捕获 tools 入参，返回造好的 toolUse 响应）。
// 命名加 SelectWithTools 前缀避免与其他测试文件 mock 重名。

private final class MockSelectWithToolsProvider: LauncherProvider {
    /// 预设响应（按调用顺序消费）
    var responses: [Result<AgentResponse, Error>] = []
    /// 捕获每次 send 的 tools 入参（用于断言 request.tools 内容）
    private(set) var capturedTools: [[AgentTool]] = []
    private(set) var capturedMessages: [[AgentMessage]] = []
    private(set) var callCount = 0

    func send(messages: [AgentMessage], tools: [AgentTool], model: String, system: String?) async throws -> AgentResponse {
        capturedMessages.append(messages)
        capturedTools.append(tools)
        guard callCount < responses.count else {
            throw LauncherError.networkFailure(URLError(.unknown))
        }
        let result = responses[callCount]
        callCount += 1
        return try result.get()
    }
}

// MARK: - Helpers

private func makeManifest(
    name: String,
    description: String = "test plugin",
    keywords: [String] = [],
    cmd: String = "./run.sh"
) -> PluginManifest {
    PluginManifest(
        name: name,
        version: "1.0.0",
        description: description,
        keywords: keywords,
        cmd: cmd,
        args: [],
        env: nil,
        timeout: 5,
        requiredPath: nil
    )
}

/// 造一个 toolUse 响应（模拟 LLM 返回 tool_call）。
private func makeToolUseResponse(
    toolName: String,
    input: [String: AnyCodable],
    id: String = "tool-call-1"
) -> AgentResponse {
    AgentResponse(
        content: [.toolUse(id: id, name: toolName, input: input)],
        stopReason: "tool_use",
        usage: nil
    )
}

/// 造一个纯文本响应（模拟 LLM 无 tool_call 兜底）。
private func makeTextResponse(_ text: String) -> AgentResponse {
    AgentResponse(
        content: [.text(text)],
        stopReason: "end_turn",
        usage: nil
    )
}

private func makeRouter(provider: MockSelectWithToolsProvider) -> LauncherRouter {
    let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "SelectWithTools-\(UUID().uuidString)")
    let mgr = PluginManager(rootDir: tmpDir)
    return LauncherRouter(pluginManager: mgr, provider: provider, routerModel: "test-model")
}

// MARK: - 场景1.P1[det]: URL + "生成二维码" → 选中 qr

final class SelectWithToolsScenario1AcceptanceTests: XCTestCase {

    // 场景1.P1[det]：LLM 返回 tool_call(qr, {query:"https://example.com"}) → selectWithTools 选中 qr
    //
    // Mutation 探针：
    //   - 若蓝队 selectWithTools 漏匹配 tool_call.name 到 plugin name，decision != .withPlugin(qr) → 红灯
    //   - 若蓝队把 extractedQuery 设为 nil，断言红灯
    func test_scenario1_P1_urlAndQRQuery_selectsQrPlugin() async throws {
        let provider = MockSelectWithToolsProvider()
        let qr = makeManifest(name: "qr", description: "生成二维码", keywords: ["qr", "二维码"])
        provider.responses = [
            .success(makeToolUseResponse(
                toolName: "qr",
                input: ["query": AnyCodable("https://example.com")]
            ))
        ]
        let router = makeRouter(provider: provider)

        let (decision, extractedQuery) = try await router.selectWithTools(
            query: "生成二维码 https://example.com",
            plugins: [qr]
        )

        // 关键断言：选中 qr
        if case .withPlugin(let m) = decision {
            XCTAssertEqual(m.name, "qr",
                           "场景1.P1: selectWithTools 必须选中 qr 插件（tool_call.name=='qr'），实际: \(m.name)")
        } else {
            XCTFail("场景1.P1: decision 必须是 .withPlugin(qr)，实际: \(decision)")
        }

        // extractedQuery 必须非空且等于 LLM 提取的 URL（不是原始整句）
        XCTAssertEqual(extractedQuery, "https://example.com",
                       "场景1.P1: extractedQuery 必须精确是 LLM 提取的 'https://example.com'，实际: \(extractedQuery ?? "nil")")
        XCTAssertNotEqual(extractedQuery, "生成二维码 https://example.com",
                          "Mutation 探针: extractedQuery 不能是原始整句（必须经 LLM 参数提取）")
    }

    // 场景1.P1 补（C-TOOLCALL-CHANNEL）：send 时 tools 入参包含 qr 插件（不丢弃 tool 通道）
    func test_scenario1_P1_toolsChannelIncludesAllPlugins() async throws {
        let provider = MockSelectWithToolsProvider()
        let qr = makeManifest(name: "qr", description: "生成二维码", keywords: ["qr"])
        let shorten = makeManifest(name: "shorten", description: "缩短网址", keywords: ["shorten"])
        provider.responses = [
            .success(makeToolUseResponse(toolName: "qr", input: ["query": AnyCodable("x")]))
        ]
        let router = makeRouter(provider: provider)

        _ = try await router.selectWithTools(query: "二维码", plugins: [qr, shorten])

        XCTAssertEqual(provider.callCount, 1, "selectWithTools 必须调用 provider.send 恰好 1 次")
        XCTAssertEqual(provider.capturedTools.count, 1, "必须捕获到 1 次 tools 入参")
        let sentTools = provider.capturedTools.first ?? []
        let sentNames = Set(sentTools.map(\.name))
        XCTAssertTrue(sentNames.contains("qr"),
                      "C-TOOLCALL-CHANNEL: send 时 tools 必须包含 qr 插件，实际: \(sentNames)")
        XCTAssertTrue(sentNames.contains("shorten"),
                      "C-TOOLCALL-CHANNEL: send 时 tools 必须包含 shorten 插件（全部开启插件作 tool），实际: \(sentNames)")
    }
}

// MARK: - 场景3[det]: 两 URL 插件语义消歧（shorten vs qr）

final class SelectWithToolsScenario3AcceptanceTests: XCTestCase {

    // 场景3.P1[det]：语义 "缩短" → LLM 返回 tool_call(shorten) → 选中 shorten，negate != qr
    //
    // Mutation 探针：若蓝队 selectWithTools 总是返回第一个 plugin，shorten 不在第一位 → 红灯。
    func test_scenario3_P1_semanticShorten_selectsShorten_notQr() async throws {
        let provider = MockSelectWithToolsProvider()
        let qr = makeManifest(name: "qr", description: "生成二维码", keywords: ["qr"])
        let shorten = makeManifest(name: "shorten", description: "缩短网址", keywords: ["shorten", "短链"])
        // qr 排在前面——验证 selectWithTools 不是无脑取第一个
        provider.responses = [
            .success(makeToolUseResponse(
                toolName: "shorten",
                input: ["url": AnyCodable("https://example.com")]
            ))
        ]
        let router = makeRouter(provider: provider)

        let (decision, _) = try await router.selectWithTools(
            query: "缩短这个网址 https://example.com",
            plugins: [qr, shorten]
        )

        if case .withPlugin(let m) = decision {
            XCTAssertEqual(m.name, "shorten",
                           "场景3.P1: 语义'缩短' + tool_call(shorten) 必须选中 shorten，实际: \(m.name)")
            XCTAssertNotEqual(m.name, "qr",
                              "场景3.P1 negate: 选中的不能是 qr（语义消歧）")
        } else {
            XCTFail("场景3.P1: decision 必须是 .withPlugin(shorten)，实际: \(decision)")
        }
    }

    // 场景3.P2[det]：语义 "二维码" → LLM 返回 tool_call(qr) → 选中 qr，negate != shorten
    func test_scenario3_P2_semanticQR_selectsQr_notShorten() async throws {
        let provider = MockSelectWithToolsProvider()
        let qr = makeManifest(name: "qr", description: "生成二维码", keywords: ["qr", "二维码"])
        let shorten = makeManifest(name: "shorten", description: "缩短网址", keywords: ["shorten"])
        provider.responses = [
            .success(makeToolUseResponse(
                toolName: "qr",
                input: ["query": AnyCodable("https://example.com")]
            ))
        ]
        let router = makeRouter(provider: provider)

        let (decision, _) = try await router.selectWithTools(
            query: "把这个网址生成二维码 https://example.com",
            plugins: [qr, shorten]
        )

        if case .withPlugin(let m) = decision {
            XCTAssertEqual(m.name, "qr",
                           "场景3.P2: 语义'二维码' + tool_call(qr) 必须选中 qr，实际: \(m.name)")
            XCTAssertNotEqual(m.name, "shorten",
                              "场景3.P2 negate: 选中的不能是 shorten")
        } else {
            XCTFail("场景3.P2: decision 必须是 .withPlugin(qr)，实际: \(decision)")
        }
    }
}

// MARK: - 场景4[det] + C-NO-TOOL-NO-FORGE: 开启插件集空 → 不发 tool / 不伪造

final class SelectWithToolsScenario4AcceptanceTests: XCTestCase {

    // 场景4.P1[det] + C-NO-TOOL-NO-FORGE：plugins==[] ⟹ send 时 request.tools==[]
    //
    // Mutation 探针：若蓝队 plugins 为空时仍注入 tool（如残留固定 query tool），sentTools 非空 → 红灯。
    func test_scenario4_P1_emptyPlugins_sendsEmptyTools() async throws {
        let provider = MockSelectWithToolsProvider()
        provider.responses = [.success(makeTextResponse("闲聊回复"))]
        let router = makeRouter(provider: provider)

        _ = try await router.selectWithTools(query: "你好", plugins: [])

        XCTAssertEqual(provider.callCount, 1, "即使 plugins 为空也必须调 send（文本兜底路径）")
        let sentTools = provider.capturedTools.first ?? []
        XCTAssertTrue(sentTools.isEmpty,
                      "场景4.P1 / C-NO-TOOL-NO-FORGE: plugins==[] 时 send 的 tools 必须为空，实际: \(sentTools.map(\.name))")
    }

    // 场景4.P2[det] + C-NO-TOOL-NO-FORGE：plugins==[] ⟹ 不伪造 tool_calls → decision == .directChat
    //
    // Mutation 探针：若蓝队 selectWithTools 在无 tool_call 时伪造一个 plugin 决策，
    //   decision != .directChat → 红灯。
    func test_scenario4_P2_emptyPlugins_noForgedToolCall_directChat() async throws {
        let provider = MockSelectWithToolsProvider()
        // LLM 返回纯文本（无 tool_call）
        provider.responses = [.success(makeTextResponse("你好，有什么可以帮你？"))]
        let router = makeRouter(provider: provider)

        let (decision, extractedQuery) = try await router.selectWithTools(query: "你好", plugins: [])

        XCTAssertEqual(decision, .directChat,
                       "场景4.P2 / C-NO-TOOL-NO-FORGE: plugins==[] 且无 tool_call 时必须返回 .directChat（不伪造），实际: \(decision)")
        XCTAssertNil(extractedQuery,
                     "场景4.P2: directChat 时 extractedQuery 必须为 nil，实际: \(extractedQuery ?? "non-nil")")
    }

    // 场景4.P2 补（C-NO-TOOL-NO-FORGE 强化）：有 plugins 但 LLM 返回纯文本（无 tool_call）→ 也必须 directChat
    //
    // 文本兜底路径可能本地匹配或再调 LLM（设计文档允许两种实现），故多准备一个响应容错二次调用；
    // 核心断言聚焦「最终 decision == .directChat」（契约结果，不依赖调用次数）。
    func test_scenario4_P2_pluginsPresent_butNoToolCall_directChat() async throws {
        let provider = MockSelectWithToolsProvider()
        let qr = makeManifest(name: "qr", description: "生成二维码", keywords: ["qr"])
        // 准备多个纯文本响应（容错文本兜底的二次调用；文本里不含 plugin name → 不会误匹配）
        provider.responses = [
            .success(makeTextResponse("这个问题我直接回答，不需要工具")),
            .success(makeTextResponse("NONE")),
            .success(makeTextResponse("NONE"))
        ]
        let router = makeRouter(provider: provider)

        let (decision, _) = try await router.selectWithTools(query: "解释一下量子力学", plugins: [qr])

        XCTAssertEqual(decision, .directChat,
                       "有 plugins 但 LLM 无 tool_call 时必须文本兜底 .directChat，实际: \(decision)")
    }
}

// MARK: - C-HALLUCINATE: tool_call.name 不在 plugins 中 → directChat

final class SelectWithToolsHallucinateAcceptanceTests: XCTestCase {

    // C-HALLUCINATE + 场景4 边界：LLM 返回的 tool_call.name 不在 plugins 列表中 → .directChat（幻觉防护）
    //
    // Mutation 探针：若蓝队 selectWithTools 不校验 tool_call.name 是否在 plugins 中（直接信任 LLM），
    //   decision 会变成某个伪造的 plugin 或崩溃 → 断言红灯。
    func test_C_HALLUCINATE_toolCallNameNotInPlugins_returnsDirectChat() async throws {
        let provider = MockSelectWithToolsProvider()
        let qr = makeManifest(name: "qr", description: "生成二维码", keywords: ["qr"])
        // LLM 幻觉：返回一个不存在的 plugin name
        provider.responses = [
            .success(makeToolUseResponse(
                toolName: "nonexistent_plugin_xyz",
                input: ["query": AnyCodable("anything")]
            ))
        ]
        let router = makeRouter(provider: provider)

        let (decision, _) = try await router.selectWithTools(query: "某查询", plugins: [qr])

        XCTAssertEqual(decision, .directChat,
                       "C-HALLUCINATE: tool_call.name('nonexistent_plugin_xyz') 不在 plugins 中时必须返回 .directChat，实际: \(decision)")
    }

    // C-HALLUCINATE 补：幻觉名大小写敏感（不应用模糊匹配兜底）
    func test_C_HALLUCINATE_caseSensitiveNameMatch() async throws {
        let provider = MockSelectWithToolsProvider()
        let qr = makeManifest(name: "qr", description: "生成二维码", keywords: ["qr"])
        // LLM 返回大写 QR，但 plugin name 是小写 qr
        provider.responses = [
            .success(makeToolUseResponse(toolName: "QR", input: ["query": AnyCodable("x")]))
        ]
        let router = makeRouter(provider: provider)

        let (decision, _) = try await router.selectWithTools(query: "QR", plugins: [qr])

        // 严格：'QR' != 'qr'（大小写敏感）→ directChat。
        // （若蓝队做大小写不敏感匹配，此测试会失败——红队要求精确匹配，防误路由）
        XCTAssertEqual(decision, .directChat,
                       "C-HALLUCINATE: tool_call.name('QR') 与 plugin name('qr') 大小写不同必须视为幻觉 → directChat，实际: \(decision)")
    }
}

// MARK: - 场景9.P2[det] + C-EXTRACTED-QUERY: 参数提取 → extractedQuery 填插件输入

final class SelectWithToolsExtractedQueryAcceptanceTests: XCTestCase {

    // 场景9.P2[det] + C-EXTRACTED-QUERY：extractedQuery 非空 ⟹ 后续 PluginInput.query == extractedQuery
    //
    // 这里验证 selectWithTools 返回的 extractedQuery 精确等于 LLM tool_call.input 中的参数值。
    // （实际 PluginInput.query == extractedQuery 的填入由 LauncherManager.submit 完成，此处验证契约源头）
    func test_scenario9_P2_extractedQueryMatchesToolCallInput() async throws {
        let provider = MockSelectWithToolsProvider()
        let qr = makeManifest(name: "qr", description: "生成二维码", keywords: ["qr"])
        let extractedURL = "https://github.com/strzhao/buddy-official-plugins"
        provider.responses = [
            .success(makeToolUseResponse(
                toolName: "qr",
                input: ["query": AnyCodable(extractedURL)]
            ))
        ]
        let router = makeRouter(provider: provider)

        let (decision, extractedQuery) = try await router.selectWithTools(
            query: "帮我把 \(extractedURL) 生成二维码",
            plugins: [qr]
        )

        if case .withPlugin(let m) = decision {
            XCTAssertEqual(m.name, "qr")
        } else {
            XCTFail("expected .withPlugin(qr)")
        }

        // C-EXTRACTED-QUERY：extractedQuery 必须精确等于 LLM 提取的 URL
        XCTAssertEqual(extractedQuery, extractedURL,
                       "场景9.P2 / C-EXTRACTED-QUERY: extractedQuery 必须精确等于 tool_call.input.query 的值，实际: \(extractedQuery ?? "nil")")
    }

    // 场景9.P2 补（C-EXTRACTED-QUERY 反向）：extractedQuery 非空时 PluginInput(query: extractedQuery) 构造后保留原值
    //   （这是 LauncherManager.submit 用 extractedQuery 填插件输入的基础语义）
    func test_scenario9_P2_extractedQueryFillsPluginInputQueryExactly() async throws {
        let provider = MockSelectWithToolsProvider()
        let qr = makeManifest(name: "qr", description: "生成二维码", keywords: ["qr"])
        provider.responses = [
            .success(makeToolUseResponse(
                toolName: "qr",
                input: ["query": AnyCodable("https://example.com/path?x=1")]
            ))
        ]
        let router = makeRouter(provider: provider)

        let (_, extractedQuery) = try await router.selectWithTools(query: "生成二维码", plugins: [qr])

        guard let eq = extractedQuery else {
            XCTFail("extractedQuery 不能为 nil（LLM 返回了 tool_call）")
            return
        }
        // 模拟 LauncherManager.submit 用 extractedQuery 填插件输入
        let pluginInput = PluginInput(query: eq, sessionId: "test-session", cwd: "/tmp")
        XCTAssertEqual(pluginInput.query, "https://example.com/path?x=1",
                       "C-EXTRACTED-QUERY: extractedQuery 填入 PluginInput.query 后必须保留精确值（含 query string）")
    }
}

// MARK: - C-TOOLCALL-CHANNEL: 响应 tool_calls 被解析为 .toolUse 不丢弃

final class SelectWithToolsToolCallChannelAcceptanceTests: XCTestCase {

    // C-TOOLCALL-CHANNEL：provider 返回 .toolUse 响应（tool_calls 已被 provider 解析），
    //   selectWithTools 必须消费它并路由到对应 plugin（不丢弃）。
    //
    // Mutation 探针：若蓝队 selectWithTools 忽略 .toolUse 内容（只看文本），decision 会变 directChat → 红灯。
    func test_C_TOOLCALL_CHANNEL_responseToolUseRoutedToPlugin() async throws {
        let provider = MockSelectWithToolsProvider()
        let qr = makeManifest(name: "qr", description: "生成二维码", keywords: ["qr"])
        provider.responses = [
            .success(AgentResponse(
                content: [
                    .text("我来帮你生成二维码"),
                    .toolUse(id: "tool-1", name: "qr", input: ["query": AnyCodable("https://x.com")])
                ],
                stopReason: "tool_use",
                usage: nil
            ))
        ]
        let router = makeRouter(provider: provider)

        let (decision, extractedQuery) = try await router.selectWithTools(
            query: "生成二维码 https://x.com",
            plugins: [qr]
        )

        // 即使 content 里混了 text，selectWithTools 必须识别出 toolUse 并路由
        if case .withPlugin(let m) = decision {
            XCTAssertEqual(m.name, "qr",
                           "C-TOOLCALL-CHANNEL: 响应含 .toolUse(qr) 必须路由到 qr 插件（不丢弃），实际: \(m.name)")
        } else {
            XCTFail("C-TOOLCALL-CHANNEL: 响应含 toolUse 时 decision 必须是 .withPlugin，实际: \(decision)")
        }
        XCTAssertEqual(extractedQuery, "https://x.com",
                       "C-TOOLCALL-CHANNEL: toolUse 的 input.query 必须被提取为 extractedQuery")
    }

    // C-TOOLCALL-CHANNEL 补：多个 tool_call 时取第一个（LLM 应只调一个，但需定义行为）
    func test_C_TOOLCALL_CHANNEL_multipleToolCalls_picksFirst() async throws {
        let provider = MockSelectWithToolsProvider()
        let qr = makeManifest(name: "qr", description: "二维码", keywords: ["qr"])
        let shorten = makeManifest(name: "shorten", description: "短链", keywords: ["shorten"])
        provider.responses = [
            .success(AgentResponse(
                content: [
                    .toolUse(id: "tool-1", name: "qr", input: ["query": AnyCodable("first")]),
                    .toolUse(id: "tool-2", name: "shorten", input: ["url": AnyCodable("second")])
                ],
                stopReason: "tool_use",
                usage: nil
            ))
        ]
        let router = makeRouter(provider: provider)

        let (decision, extractedQuery) = try await router.selectWithTools(
            query: "多 tool 测试",
            plugins: [qr, shorten]
        )

        // 取第一个 tool_call（qr）
        if case .withPlugin(let m) = decision {
            XCTAssertEqual(m.name, "qr",
                           "多 tool_call 时应取第一个（qr），实际: \(m.name)")
        } else {
            XCTFail("多 tool_call 也必须有 decision，实际: \(decision)")
        }
        XCTAssertEqual(extractedQuery, "first",
                       "extractedQuery 应取第一个 tool_call 的参数")
    }
}
