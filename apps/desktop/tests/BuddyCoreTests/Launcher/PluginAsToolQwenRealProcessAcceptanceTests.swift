import XCTest
@testable import BuddyCore

// MARK: - PluginAsToolQwenRealProcessAcceptanceTests
//
// 红队验收测试（real-process）：打真实本地 qwen（llama.cpp，端口 8001），
// 验证「插件作 LLM tool」端到端——LLM 选对插件 + 提取参数。
//
// 设计文档硬指标：弱模型（本地 qwen3.6-35b）执行成功率。
//
// 验收场景（real-process）：
//   场景1.P2[real] : qr 选中执行 → 以 URL 为参数产图（此处验证传输层：tool_calls.arguments 含 URL）
//   场景2.P1[real] : 无关键词但语义指向 qr → 选 qr ｜ assert tool_calls[0].name == "qr"
//   场景2.P2[det]  : 枚举 desc 注入 → 高正确率 ｜ assert count(qr)/N >= 0.9（N>=10）
//   场景3.P1[real] : 两 URL 插件 + 语义 "缩短" → 选 shorten ｜ negate != qr
//   场景3.P2[real] : 语义 "二维码" → 选 qr ｜ negate != shorten
//   场景9.P1[real]（间接）：prompt 插件仅单轮（此处验证 tool 请求为单轮非流式）
//
// 探针参考：/tmp/buddy_dryrun.py 的请求构造（model qwen3.6-35b，chat_template_kwargs.enable_thinking=false，
//   tools + tool_choice:"auto"，stream:false，temperature:0）。
//
// 铁律：
//   - try-connection 守卫：qwen 不可达时 XCTSkip（本地有 qwen 真跑，CI 无 qwen 跳过）
//   - 可达时强断言、失败必挂（不吞错、不 skip 假装跑）
//   - 真实网络请求，断言 tool_calls[0].function.name + arguments
//
// 关键常量（来自 CLAUDE.md / 探针）：
//   API: http://127.0.0.1:8001/v1/chat/completions
//   MODEL: qwen3.6-35b
//   Authorization: Bearer qwen-local-key
//   chat_template_kwargs.enable_thinking: false（必须关，否则 TTFT 24.5s 且 tool_calls 不稳）

private enum QwenConst {
    static let apiURL = URL(string: "http://127.0.0.1:8001/v1/chat/completions")!
    static let model = "qwen3.6-35b"
    static let apiKey = "qwen-local-key"
    static let healthURL = URL(string: "http://127.0.0.1:8001/v1/models")!
}

// MARK: - Qwen HTTP 客户端（real-process）

/// 调真实 qwen 的 chat/completions，返回原始 JSON dict。
private func callQwenReal(
    userQuery: String,
    tools: [[String: Any]],
    maxTokens: Int = 256,
    timeout: TimeInterval = 120
) async throws -> [String: Any] {
    var body: [String: Any] = [
        "model": QwenConst.model,
        "messages": [
            ["role": "user", "content": userQuery]
        ],
        "max_tokens": maxTokens,
        "stream": false,
        "temperature": 0.0,
        "tools": tools,
        "tool_choice": "auto",
        "chat_template_kwargs": ["enable_thinking": false]
    ]
    // swiftlint:disable:next force_try (测试专用，body 序列化不会失败)
    let bodyData = try! JSONSerialization.data(withJSONObject: body)
    body = [:]  // 释放（仅用 bodyData）

    var request = URLRequest(url: QwenConst.apiURL, timeoutInterval: timeout)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(QwenConst.apiKey)", forHTTPHeaderField: "Authorization")
    request.httpBody = bodyData

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else {
        throw NSError(domain: "QwenReal", code: -1, userInfo: [NSLocalizedDescriptionKey: "non-HTTP response"])
    }
    guard http.statusCode == 200 else {
        let body = String(data: data, encoding: .utf8) ?? "<binary>"
        throw NSError(domain: "QwenReal", code: http.statusCode,
                      userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(body.prefix(300))"])
    }
    guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        throw NSError(domain: "QwenReal", code: -2, userInfo: [NSLocalizedDescriptionKey: "non-JSON response"])
    }
    return json
}

/// 从 qwen 响应提取首个 tool_call 的 (name, arguments_dict, content)。
private func extractFirstToolCall(_ json: [String: Any]) -> (name: String?, args: [String: Any]?, content: String?) {
    guard let choices = json["choices"] as? [[String: Any]],
          let firstChoice = choices.first,
          let message = firstChoice["message"] as? [String: Any] else {
        return (nil, nil, nil)
    }
    let content = message["content"] as? String
    let toolCalls = (message["tool_calls"] as? [[String: Any]]) ?? []
    guard let first = toolCalls.first,
          let function = first["function"] as? [String: Any] else {
        return (nil, nil, content)
    }
    let name = function["name"] as? String
    let argsRaw = function["arguments"] as? String
    var argsDict: [String: Any]? = nil
    if let raw = argsRaw,
       let argsData = raw.data(using: .utf8),
       let parsed = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] {
        argsDict = parsed
    }
    return (name, argsDict, content)
}

/// 健康检查：qwen 是否可达（2s 超时）。不可达返回 false（测试方决定 skip 还是 fail）。
private func qwenReachable() async -> Bool {
    var request = URLRequest(url: QwenConst.healthURL, timeoutInterval: 2.0)
    request.setValue("Bearer \(QwenConst.apiKey)", forHTTPHeaderField: "Authorization")
    do {
        let (_, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 200 {
            return true
        }
        return false
    } catch {
        return false
    }
}

// MARK: - 工具定义（仿照 /tmp/buddy_dryrun.py 的枚举 desc 模板）

/// qr 工具：生成二维码（固定 {query} 契约 + 枚举 desc）
private func qrTool() -> [String: Any] {
    [
        "type": "function",
        "function": [
            "name": "qr",
            "description": "生成二维码图片。当用户想把一段文本、网址或链接变成可扫描的二维码图片时使用。"
                + "query 字段只填要编码的内容本身，不要填整句话。"
                + "例：「生成二维码 https://x」→ query 填 https://x。"
                + "不要用于：翻译、计算、聊天、缩短网址。",
            "parameters": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "要编码成二维码的内容（URL/文本）"]
                ],
                "required": ["query"]
            ]
        ] as [String: Any]
    ] as [String: Any]
}

/// shorten 工具：缩短网址（结构化参数，与 qr 形成语义对照）
private func shortenTool() -> [String: Any] {
    [
        "type": "function",
        "function": [
            "name": "shorten",
            "description": "缩短网址。当用户想把一个长网址/链接变短时使用。"
                + "例：「缩短这个网址 https://x」→ url 填 https://x。"
                + "不要用于：生成二维码、翻译、聊天。",
            "parameters": [
                "type": "object",
                "properties": [
                    "url": ["type": "string", "description": "要缩短的长网址"]
                ],
                "required": ["url"]
            ]
        ] as [String: Any]
    ] as [String: Any]
}

// MARK: - 场景2.P1[real] + 场景3[real]: 语义选插件

final class PluginAsToolQwenSemanticAcceptanceTests: XCTestCase {

    // 场景2.P1[real]：无关键词（query 不含 "qr"/"二维码" 字面）但语义指向 qr → LLM 选 qr
    //
    // query 选「把这个链接做成能扫码的图」—— 不含 qr 字面，靠语义。
    // 断言：tool_calls[0].function.name == "qr"。
    func test_scenario2_P1_semanticQR_noLiteralKeyword_selectsQr() async throws {
        let reachable = await qwenReachable()
        try XCTSkipUnless(reachable, "qwen 不可达（本地 llama.cpp 未运行），跳过 real-process 测试")

        let json = try await callQwenReal(
            userQuery: "帮我把 https://example.com 这个链接做成能扫码的图片",
            tools: [qrTool()]
        )
        let (name, args, _) = extractFirstToolCall(json)

        XCTAssertEqual(name, "qr",
                       "场景2.P1[real]: 语义指向二维码（无字面关键词）时 qwen 必须选 qr 工具，实际: \(name ?? "nil")")

        // 参数提取：query 必须是 URL，不是整句
        let queryArg = args?["query"] as? String
        XCTAssertEqual(queryArg, "https://example.com",
                       "场景2.P1[real]: qr.query 必须提取为 'https://example.com'（非整句），实际: \(queryArg ?? "nil")")
    }

    // 场景3.P1[real]：两 URL 插件 + 语义 "缩短" → 选 shorten（negate != qr）
    //
    // 关键：qr 和 shorten 都处理 URL，LLM 必须按语义消歧选 shorten。
    func test_scenario3_P1_semanticShorten_twoUrlPlugins_selectsShorten() async throws {
        let reachable = await qwenReachable()
        try XCTSkipUnless(reachable, "qwen 不可达，跳过 real-process 测试")

        let json = try await callQwenReal(
            userQuery: "缩短这个网址 https://example.com/very/long/path?query=1",
            tools: [qrTool(), shortenTool()]
        )
        let (name, args, _) = extractFirstToolCall(json)

        XCTAssertEqual(name, "shorten",
                       "场景3.P1[real]: 语义'缩短'+两 URL 插件时 qwen 必须选 shorten，实际: \(name ?? "nil")")
        XCTAssertNotEqual(name, "qr",
                          "场景3.P1[real] negate: 选中的不能是 qr（语义消歧）")

        let urlArg = args?["url"] as? String
        XCTAssertEqual(urlArg, "https://example.com/very/long/path?query=1",
                       "场景3.P1[real]: shorten.url 必须提取为完整长 URL，实际: \(urlArg ?? "nil")")
    }

    // 场景3.P2[real]：两 URL 插件 + 语义 "二维码" → 选 qr（negate != shorten）
    func test_scenario3_P2_semanticQR_twoUrlPlugins_selectsQr() async throws {
        let reachable = await qwenReachable()
        try XCTSkipUnless(reachable, "qwen 不可达，跳过 real-process 测试")

        let json = try await callQwenReal(
            userQuery: "把这个网址 https://example.com/very/long/path 生成二维码",
            tools: [qrTool(), shortenTool()]
        )
        let (name, args, _) = extractFirstToolCall(json)

        XCTAssertEqual(name, "qr",
                       "场景3.P2[real]: 语义'二维码'+两 URL 插件时 qwen 必须选 qr，实际: \(name ?? "nil")")
        XCTAssertNotEqual(name, "shorten",
                          "场景3.P2[real] negate: 选中的不能是 shorten")

        let queryArg = args?["query"] as? String
        XCTAssertEqual(queryArg, "https://example.com/very/long/path",
                       "场景3.P2[real]: qr.query 必须提取为完整 URL，实际: \(queryArg ?? "nil")")
    }
}

// MARK: - 场景1.P2[real]: qr 选中 → 参数为 URL（产图前置）

final class PluginAsToolQwenQrExecutionAcceptanceTests: XCTestCase {

    // 场景1.P2[real]：输入含 URL "生成二维码" → qwen 选 qr 且 query 为 URL（产图前置契约）
    //
    // 注意：完整产图需 qr-gen.sh + qrencode，此处只验证「LLM 选对插件 + 提取 URL 参数」这一前置环节
    // （真实产图在 E2E 测试覆盖，这里验证 LLM 决策正确性）。
    // negate：参数 != 原始整句。
    func test_scenario1_P2_urlQuery_qrSelectedWithUrlArgument() async throws {
        let reachable = await qwenReachable()
        try XCTSkipUnless(reachable, "qwen 不可达，跳过 real-process 测试")

        let json = try await callQwenReal(
            userQuery: "生成二维码 https://github.com/strzhao/buddy-official-plugins",
            tools: [qrTool()]
        )
        let (name, args, _) = extractFirstToolCall(json)

        XCTAssertEqual(name, "qr",
                       "场景1.P2[real]: '生成二维码 + URL' 必须选 qr，实际: \(name ?? "nil")")

        let queryArg = args?["query"] as? String
        XCTAssertEqual(queryArg, "https://github.com/strzhao/buddy-official-plugins",
                       "场景1.P2[real]: qr.query 必须是完整 URL（产图前置），实际: \(queryArg ?? "nil")")
        // negate：参数不能是原始整句（LLM 必须做参数提取，不是整句透传）
        XCTAssertNotEqual(queryArg, "生成二维码 https://github.com/strzhao/buddy-official-plugins",
                          "场景1.P2[real] negate: query 不能是原始整句（必须提取出 URL）")
    }
}

// MARK: - 场景2.P2[det-style real]: 枚举 desc 注入 → 高正确率（count(qr)/N >= 0.9, N>=10）

final class PluginAsToolQwenAccuracyAcceptanceTests: XCTestCase {

    // 场景2.P2：枚举 desc 注入 → 多样化输入下 qr 选中率 >= 0.9（N=10）
    //
    // 设计文档硬指标：弱模型执行成功率。用 10 个语义指向 qr 但表达不同的 query，
    // 断言 qr 选中次数 / 10 >= 0.9。
    //
    // 注意：这是 real-process 统计断言——qwen 必须可达才跑，否则 skip。
    func test_scenario2_P2_enumeratedDesc_highAccuracy_rateAboveThreshold() async throws {
        let reachable = await qwenReachable()
        try XCTSkipUnless(reachable, "qwen 不可达，跳过 real-process 测试")

        // 10 个语义指向 qr 的多样化 query（都不直接含 "qr" 命令字，靠语义）
        let queries = [
            "把这个链接做成能扫码的图 https://a.com",
            "我要一张能扫出 https://b.com 的图片",
            "帮我生成 https://c.com 的扫码图",
            "https://d.com 做成二维码",
            "给我一个 https://e.com 的二维码图片",
            "把 https://f.com 编码成可扫描的图形",
            "扫描能打开 https://g.com 的图怎么生成",
            "我要 https://h.com 的二维条码",
            "帮弄一个网址 https://i.com 的扫码码",
            "这个网址 https://j.com 弄成那种扫一扫的图"
        ]
        let N = queries.count
        XCTAssertEqual(N, 10, "场景2.P2: 样本量必须 >= 10（设计文档约束）")

        var qrSelectedCount = 0
        for query in queries {
            do {
                let json = try await callQwenReal(userQuery: query, tools: [qrTool()], maxTokens: 128)
                let (name, _, _) = extractFirstToolCall(json)
                if name == "qr" { qrSelectedCount += 1 }
            } catch {
                // 单个请求失败不立刻 fail，但记录（网络抖动容错）；最终用选中率断言
                continue
            }
        }

        let rate = Double(qrSelectedCount) / Double(N)
        XCTAssertGreaterThanOrEqual(
            rate, 0.9,
            "场景2.P2: 枚举 desc 注入后 qr 选中率必须 >= 0.9（\(qrSelectedCount)/\(N) = \(rate)），硬指标未达"
        )
    }
}

// MARK: - PluginAsToolRealSynthDescAcceptanceTests
//
// 红队验收测试（real-process）：用真实 PluginManifest.toAgentTool() 合成的 tool desc
// （synthesizeToolDescription + effectiveToolInputSchema）打真实 qwen，覆盖参数提取稳定性。
//
// 缺口（cli e2e 暴露）：本文件其他场景用硬编码 tool desc（qrTool/shortenTool 强锚点"只填内容本身"），
// 规避了 synthesizeToolDescription 合成的真实 desc。`buddy launcher debug route` 实跑发现：
// 真实 synthesize desc 的「输入：填用户的原始请求」+ query 字段 description「用户原始查询」让 qwen
// 整句透传，extractedQuery 退化。此场景补这条缺口——真实 toAgentTool() 输出 + 真实 qwen。
//
// 铁律：qwenReachable 守卫（不可达 skip）；可达时强断言 extractedQuery==URL（非整句）。

final class PluginAsToolRealSynthDescAcceptanceTests: XCTestCase {

    // 真实 toAgentTool()（synthesizeToolDescription + effectiveToolInputSchema）合成 desc + 真实 qwen
    // → query 字段必须提取内容本身（URL），不能整句透传。
    func test_realSynthDesc_extractsContentNotFullSentence() async throws {
        let reachable = await qwenReachable()
        try XCTSkipUnless(reachable, "qwen 不可达（本地 llama.cpp 未运行），跳过 real-process 测试")

        // 真实 qr manifest（command mode，固定 {query} 契约，parameters nil）—— 复刻 marketplace/qr
        let qr = PluginManifest(
            name: "qr",
            version: "1.0.0",
            description: "把输入的文本或网址变成一张二维码图片，点击可复制到剪贴板。",
            summary: "二维码生成器：输入文本或网址生成可扫码图片",
            keywords: ["qr", "二维码", "码"],
            timeout: 10,
            modeConfig: .command(CommandConfig(
                cmd: "./qr-gen.sh", args: [], env: nil, requiredPath: ["qrencode", "jq"], deps: []
            )),
            parameters: nil
        )

        // 真实 provider（与 app 生产路径同构：OpenAICompatibleProvider + noThinking）
        let provider = OpenAICompatibleProvider(
            apiKey: QwenConst.apiKey,
            baseURL: URL(string: "http://127.0.0.1:8001/v1")!,  // provider 拼 <baseURL>/chat/completions
            noThinking: true
        )
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "RealSynth-\(UUID().uuidString)")
        let router = LauncherRouter(
            pluginManager: PluginManager(rootDir: tmpDir),
            provider: provider,
            routerModel: QwenConst.model
        )

        // 多样化 query（含场景1「生成二维码 URL」——cli e2e 暴露的整句透传失败用例）
        let cases: [(query: String, expectURL: String)] = [
            ("生成二维码 https://example.com", "https://example.com"),
            ("把这个网址生成二维码 https://buddy.example.org/path", "https://buddy.example.org/path"),
            ("帮我做一张 https://test.io/x/y 的二维码", "https://test.io/x/y"),
        ]

        for (query, expectURL) in cases {
            let (decision, extractedQuery) = try await router.selectWithTools(query: query, plugins: [qr])

            if case .withPlugin(let m) = decision {
                XCTAssertEqual(m.name, "qr", "query=\"\(query)\": 应选 qr 插件")
            } else {
                XCTFail("query=\"\(query)\": decision 应是 .withPlugin(qr)，实际 \(decision)")
            }

            XCTAssertEqual(extractedQuery, expectURL,
                           "query=\"\(query)\": 真实 synthesize desc 下 extractedQuery 必须是 URL，实际: \(extractedQuery ?? "nil")")
            XCTAssertNotEqual(extractedQuery, query,
                              "query=\"\(query)\": extractedQuery 不能整句透传（必须提取内容本身）")
        }
    }
}
