import XCTest
@testable import BuddyCore

/// 统一 CLI hub（AI 能力暴露）单元测试 —— 蓝队 T4。
///
/// 覆盖契约（信息隔离：不读 QueryHandler list_tools/run_tool 实现，仅调 action + 断言返回结构）：
/// - C-MANIFEST-SCHEMA：launcher_list_tools → {tools:[{name,summary,description,inputSchema,mode}], count}
/// - C-INPUTSCHEMA-CAMELCASE：inputSchema 用 camelCase key（非 input_schema）；顶层 type:object
/// - C-NO-BUILTIN：manifest 仅含外部插件（PluginManager.list() 范围）
/// - C-DYNAMIC：list 每次 live 计算自 PluginManager.list()
/// - C-RUN-RESPONSE / C-TOFU-NOBYPASS：launcher_run_tool action 识别 + name 解析 + TOFU seam
/// - C-DEBUG-ISOLATION：launcher_debug_run_plugin 契约不变（瘦序列化字段）
///
/// 局限（与 LauncherRunCLIAcceptanceTests 一致）：单元层无 mock dispatcher（final class，无协议 seam），
/// 成功路径 + 富字段（image/candidates）正确性由 QA Tier 1.5 真机端到端覆盖。
/// 本文件守护「action 被识别 + manifest 字段齐全 + camelCase key + error 语义 + TOFU/execute 签名存在」。
@MainActor
final class CLIHubQueryHandlerTests: XCTestCase {

    private var manager: SessionManager!
    private var scene: MockScene!
    private var tmpPluginsDir: URL!
    private var handler: QueryHandler!

    override func setUp() {
        super.setUp()
        scene = MockScene()
        let (m, _) = TestHelpers.makeManager(scene: scene)
        manager = m
        tmpPluginsDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CLIHubQHTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpPluginsDir, withIntermediateDirectories: true)
        // 注入指向 tmpDir 的 PluginManager（不依赖 ~/.buddy/launcher-plugins）
        let pluginManager = PluginManager(rootDir: tmpPluginsDir)
        handler = QueryHandler(
            sessionManager: manager,
            scene: scene,
            eventStore: manager.eventStore,
            pluginManager: pluginManager
        )
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpPluginsDir)
        super.tearDown()
    }

    // MARK: - Helpers

    private func parseJSON(_ data: Data) -> [String: Any] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("response 不是合法 JSON object: \(String(data: data, encoding: .utf8) ?? "<binary>")")
            return [:]
        }
        return obj
    }

    /// 写一个 plugin.json 到 tmpPluginsDir/<dirName>/plugin.json
    @discardableResult
    private func writePlugin(dirName: String, json: String) throws -> URL {
        let pluginDir = tmpPluginsDir.appendingPathComponent(dirName)
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        try json.write(to: pluginDir.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
        return pluginDir
    }

    /// 带 parameters（结构化 schema）的 command mode 插件
    private var structuredCommandPluginJSON: String {
        """
        {
          "name": "qr",
          "version": "0.1.0",
          "description": "生成二维码。",
          "summary": "把网址或文本生成二维码图片",
          "keywords": ["qr", "二维码", "码"],
          "mode": "command",
          "cmd": "qr-gen.sh",
          "args": [],
          "parameters": {
            "type": "object",
            "properties": {
              "query": { "type": "string", "description": "要编码的网址或文本" }
            },
            "required": ["query"]
          }
        }
        """
    }

    /// 无 parameters（回退 {query}）+ 无 summary（降级 description 首句）的 stdin mode 插件
    private var legacyStdinPluginJSON: String {
        """
        {
          "name": "echo",
          "version": "0.1.0",
          "description": "回显输入内容。第二句不会被 summary 取到。",
          "keywords": ["echo"],
          "mode": "stdin",
          "cmd": "run.sh"
        }
        """
    }

    /// 极简 legacy plugin.json（无 summary/parameters/keywords/timeout/env，仅 name/version/mode/cmd/keywords）
    /// 补强 2：走 JSONDecoder 真实 decode 路径验证降级（非便利 init）
    private var minimalLegacyPluginJSON: String {
        """
        {
          "name": "mini",
          "version": "0.0.1",
          "description": "minimal legacy plugin",
          "mode": "command",
          "cmd": "do.sh",
          "keywords": ["mini"]
        }
        """
    }

    // MARK: - D1 launcher_list_tools（C-MANIFEST-SCHEMA / C-INPUTSCHEMA-CAMELCASE / C-NO-BUILTIN / C-DYNAMIC）

    /// C-MANIFEST-SCHEMA：action 被识别，返回 {status:ok, data:{tools:[...], count:N}}
    func test_listTools_returnsToolsArrayAndCount() async throws {
        try writePlugin(dirName: "qr", json: structuredCommandPluginJSON)
        try writePlugin(dirName: "echo", json: legacyStdinPluginJSON)

        let data = await handler.handle(query: ["action": "launcher_list_tools"])
        let json = parseJSON(data)
        XCTAssertEqual(json["status"] as? String, "ok")

        let dataDict = json["data"] as? [String: Any]
        XCTAssertNotNil(dataDict)
        let tools = dataDict?["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.count, 2)
        XCTAssertEqual(dataDict?["count"] as? Int, 2)
    }

    /// C-MANIFEST-SCHEMA：每个 tool 条目含五契约字段 {name,summary,description,inputSchema,mode}
    /// 场景 1.P2 守护。
    func test_listTools_eachToolHasAllFiveContractFields() async throws {
        try writePlugin(dirName: "qr", json: structuredCommandPluginJSON)

        let data = await handler.handle(query: ["action": "launcher_list_tools"])
        let json = parseJSON(data)
        let tools = (json["data"] as? [String: Any])?["tools"] as? [[String: Any]]
        let tool = try XCTUnwrap(tools?.first)

        let keys = Set(tool.keys)
        XCTAssertTrue(keys.contains("name"), "缺 name")
        XCTAssertTrue(keys.contains("summary"), "缺 summary")
        XCTAssertTrue(keys.contains("description"), "缺 description")
        XCTAssertTrue(keys.contains("inputSchema"), "缺 inputSchema（camelCase）")
        XCTAssertTrue(keys.contains("mode"), "缺 mode")
    }

    /// C-INPUTSCHEMA-CAMELCASE：inputSchema 用 camelCase key（非 snake_case `input_schema`）。
    /// 关键防回归：禁用 AgentTool Codable 的 `input_schema` snake key。
    func test_listTools_inputSchemaUsesCamelCaseKey() async throws {
        try writePlugin(dirName: "qr", json: structuredCommandPluginJSON)

        let data = await handler.handle(query: ["action": "launcher_list_tools"])
        let json = parseJSON(data)
        let tool = try XCTUnwrap(((json["data"] as? [String: Any])?["tools"] as? [[String: Any]])?.first)

        // 必须是 camelCase `inputSchema`，不能是 snake `input_schema`
        XCTAssertNotNil(tool["inputSchema"], "inputSchema 必须存在（camelCase）")
        XCTAssertNil(tool["input_schema"], "input_schema（snake_case）不得出现 —— 违反 C-INPUTSCHEMA-CAMELCASE")
    }

    /// C-INPUTSCHEMA-CAMELCASE：inputSchema 顶层必含 `"type":"object"`
    /// （复用 effectiveToolInputSchema，防 provider 400）。
    func test_listTools_inputSchemaTopLevelTypeIsObject() async throws {
        try writePlugin(dirName: "qr", json: structuredCommandPluginJSON)

        let data = await handler.handle(query: ["action": "launcher_list_tools"])
        let json = parseJSON(data)
        let tool = try XCTUnwrap(((json["data"] as? [String: Any])?["tools"] as? [[String: Any]])?.first)
        let schema = try XCTUnwrap(tool["inputSchema"] as? [String: Any])

        XCTAssertEqual(schema["type"] as? String, "object", "inputSchema 顶层 type 必须是 object")
    }

    /// C-INPUTSCHEMA-CAMELCASE + 场景 1.P5：有 parameters 的 inputSchema 含 properties；
    /// 无 parameters 的回退 {query} 形态（含 query property + required）。
    func test_listTools_inputSchemaBranchStructuredVsFallback() async throws {
        try writePlugin(dirName: "qr", json: structuredCommandPluginJSON)       // 有 parameters
        try writePlugin(dirName: "echo", json: legacyStdinPluginJSON)          // 无 parameters

        let data = await handler.handle(query: ["action": "launcher_list_tools"])
        let json = parseJSON(data)
        let tools = ((json["data"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
        let byName = Dictionary(uniqueKeysWithValues: tools.compactMap { t -> (String, [String: Any])? in
            guard let n = t["name"] as? String else { return nil }
            return (n, t)
        })

        // 有 parameters：含 properties
        let qrSchema = try XCTUnwrap(byName["qr"]?["inputSchema"] as? [String: Any])
        XCTAssertNotNil(qrSchema["properties"], "qr 有 parameters 时 inputSchema 应含 properties")

        // 无 parameters：回退 {query}，含 query property + required==["query"]
        let echoSchema = try XCTUnwrap(byName["echo"]?["inputSchema"] as? [String: Any])
        XCTAssertEqual(echoSchema["type"] as? String, "object")
        let props = try XCTUnwrap(echoSchema["properties"] as? [String: Any])
        XCTAssertNotNil(props["query"], "无 parameters 时回退 schema 必须含 query property")
        XCTAssertEqual(echoSchema["required"] as? [String], ["query"])
    }

    /// C-NO-BUILTIN：manifest 仅含外部插件（PluginManager.list() 范围）。
    /// 场景 1.P4 守护：Calculator/Paste/Screenshot/AppLauncher/SystemCommand 不得出现。
    func test_listTools_excludesBuiltinPlugins() async throws {
        try writePlugin(dirName: "qr", json: structuredCommandPluginJSON)

        let data = await handler.handle(query: ["action": "launcher_list_tools"])
        let json = parseJSON(data)
        let tools = ((json["data"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
        let names = tools.compactMap { $0["name"] as? String }

        let builtinNames: Set<String> = ["calculator", "paste", "screenshot", "app-launcher", "system-command"]
        let leaked = names.filter { builtinNames.contains($0.lowercased()) }
        XCTAssertTrue(leaked.isEmpty, "内置插件不得出现在 manifest（C-NO-BUILTIN），泄露: \(leaked)")
    }

    /// C-DYNAMIC + 场景 3：list 每次 live 计算自 PluginManager.list()。
    /// 第一次 list（空）→ 写插件 → 第二次 list（含）。
    func test_listTools_dynamicReflectsPluginChangesWithoutRestart() async throws {
        // 初始：空
        var data = await handler.handle(query: ["action": "launcher_list_tools"])
        var json = parseJSON(data)
        var tools = ((json["data"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
        XCTAssertEqual(tools.count, 0, "初始应无插件")

        // 写入插件
        try writePlugin(dirName: "qr", json: structuredCommandPluginJSON)

        // 再次 list：插件出现（无需重启 / 无缓存）
        data = await handler.handle(query: ["action": "launcher_list_tools"])
        json = parseJSON(data)
        tools = ((json["data"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools.first?["name"] as? String, "qr")
    }

    /// 场景 1.P6：mode ∈ {stdin,command,prompt}
    func test_listTools_modeInAllowedSet() async throws {
        try writePlugin(dirName: "qr", json: structuredCommandPluginJSON)    // command
        try writePlugin(dirName: "echo", json: legacyStdinPluginJSON)       // stdin

        let data = await handler.handle(query: ["action": "launcher_list_tools"])
        let json = parseJSON(data)
        let tools = ((json["data"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
        let allowed: Set<String> = ["stdin", "command", "prompt"]
        for tool in tools {
            let mode = try XCTUnwrap(tool["mode"] as? String)
            XCTAssertTrue(allowed.contains(mode), "mode 必须在 {stdin,command,prompt}，实际: \(mode)")
        }
    }

    /// C1 降级：无 summary 的插件 summary 取 description 首句（非空）。
    /// legacyStdinPluginJSON 无 summary → summary 应是 description 首句。
    func test_listTools_summaryDegradesToDescriptionFirstSentence() async throws {
        try writePlugin(dirName: "echo", json: legacyStdinPluginJSON)

        let data = await handler.handle(query: ["action": "launcher_list_tools"])
        let json = parseJSON(data)
        let tool = try XCTUnwrap(((json["data"] as? [String: Any])?["tools"] as? [[String: Any]])?.first)
        let summary = try XCTUnwrap(tool["summary"] as? String)
        XCTAssertFalse(summary.isEmpty, "summary 必须非空（经 displaySummary 降级保证）")
        XCTAssertEqual(summary, "回显输入内容", "无 summary 时应取 description 首句")
    }

    // MARK: - 补强 2：legacy plugin.json 真实 decode 降级

    /// 补强 2：极简 legacy plugin.json（无 summary/parameters/keywords/timeout/env）经真实
    /// JSONDecoder decode（非便利 init）后，manifest 字段降级非空 + inputSchema 回退 {query}。
    /// 覆盖 `[2026-06-24] red-team-helper-masked-backward-compat`：便利 init 与 init(from:) 路径不同。
    func test_legacyMinimalPluginJSONDecodesAndDegrades() throws {
        // 真实 decode 路径（PluginManager.list() 内部即此路径）
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(minimalLegacyPluginJSON.utf8))

        XCTAssertEqual(manifest.name, "mini")
        XCTAssertEqual(manifest.summary, nil, "legacy 无 summary 字段，decode 后应为 nil")
        XCTAssertEqual(manifest.keywords, ["mini"])
        XCTAssertEqual(manifest.parameters, nil, "legacy 无 parameters，decode 后应为 nil")
        // mode 正确解析为 command
        if case .command(let cfg) = manifest.modeConfig {
            XCTAssertEqual(cfg.cmd, "do.sh")
        } else {
            XCTFail("mode 应为 command，实际: \(manifest.modeConfig)")
        }

        // 降级保证：displaySummary 非空（取 description 或 name）
        XCTAssertFalse(manifest.displaySummary.isEmpty)

        // inputSchema 回退 {query}：顶层 type:object + 含 query property + required==["query"]
        let schema = manifest.effectiveToolInputSchema()
        XCTAssertEqual(schema["type"] as? AnyCodable, AnyCodable("object"))
        let props = (schema["properties"]?.value as? [String: Any]) ?? [:]
        XCTAssertNotNil(props["query"])
        XCTAssertEqual(schema["required"] as? AnyCodable, AnyCodable(["query"]))
    }

    /// 补强 2 + 场景 8（插件零适配）：极简 legacy 插件出现在 manifest，五字段齐全非空。
    func test_listTools_includesMinimalLegacyPluginWithDegrades() async throws {
        try writePlugin(dirName: "mini", json: minimalLegacyPluginJSON)

        let data = await handler.handle(query: ["action": "launcher_list_tools"])
        let json = parseJSON(data)
        let tool = try XCTUnwrap(((json["data"] as? [String: Any])?["tools"] as? [[String: Any]])?.first)

        XCTAssertEqual(tool["name"] as? String, "mini")
        // summary 降级到 description（"minimal legacy plugin"）
        let summary = try XCTUnwrap(tool["summary"] as? String)
        XCTAssertFalse(summary.isEmpty)
        // inputSchema 回退 {query}：顶层 type:object
        let schema = try XCTUnwrap(tool["inputSchema"] as? [String: Any])
        XCTAssertEqual(schema["type"] as? String, "object")
        XCTAssertNotNil((schema["properties"] as? [String: Any])?["query"])
        // mode 派生为 command
        XCTAssertEqual(tool["mode"] as? String, "command")
    }

    // MARK: - D2 launcher_run_tool（C-RUN-RESPONSE / C-TOFU-NOBYPASS）

    /// C-RUN-RESPONSE：action 被识别 + name 解析（缺 name → error，证明分支存在）。
    func test_runToolActionRecognizedAndRejectsMissingName() async {
        let data = await handler.handle(query: ["action": "launcher_run_tool", "input": "x"])
        let json = parseJSON(data)
        XCTAssertEqual(json["status"] as? String, "error")
        let message = (json["message"] as? String) ?? ""
        XCTAssertTrue(message.lowercased().contains("missing") || message.contains("name"),
                      "缺 name 必须 error（证明 run_tool 分支存在且校验入参），实际: \(message)")
    }

    /// 场景 10：run 不存在的插件 → status error + message 含 not found/不存在/找不到。
    func test_runToolNonexistentReturnsNotFoundError() async {
        let data = await handler.handle(query: [
            "action": "launcher_run_tool",
            "name": "does-not-exist-xyz-99999",
            "input": "{}",
        ])
        let json = parseJSON(data)
        XCTAssertEqual(json["status"] as? String, "error")
        let message = (json["message"] as? String) ?? ""
        let indicatesNotFound = message.lowercased().contains("not found")
            || message.contains("不存在") || message.contains("找不到")
        XCTAssertTrue(indicatesNotFound, "error message 必须提示未找到，实际: \(message)")
    }

    // MARK: - C-TOFU-NOBYPASS + C-DEBUG-ISOLATION：架构存在性硬约束

    /// C-TOFU-NOBYPASS：TrustStore.checkAndPrompt 签名必须存在且 async -> Bool。
    /// runPluginCore 的硬依赖（签名缺失则编译失败，TOFU 不可能绕过）。
    /// 与 LauncherRunCLIAcceptanceTests.test_AT04 同款架构约束模式。
    func test_trustStoreCheckAndPromptSignatureExists() async {
        let method: (PluginManifest, URL) async -> Bool = { plugin, exe in
            await TrustStore.shared.checkAndPrompt(plugin, executablePath: exe)
        }
        _ = method
        // 被测方法存在即契约成立（无需实跑，避免弹 NSAlert）
    }

    /// C-RUN-RESPONSE：PluginDispatcher.execute 签名必须存在（runPluginCore 的硬依赖）。
    func test_pluginDispatcherExecuteSignatureExists() async {
        let method: (PluginManifest, URL, PluginInput) async throws -> PluginResult = { plugin, dir, input in
            try await PluginDispatcher.shared.execute(plugin, pluginDir: dir, input: input)
        }
        _ = method
    }

    /// C-DEBUG-ISOLATION：launcher_debug_run_plugin 契约不变（瘦序列化字段）。
    /// 回归守护：重构 runPluginCore 后，debug run 仍报 missing name（action 识别）。
    func test_debugRunPluginContractUnchangedRejectsMissingName() async {
        let data = await handler.handle(query: ["action": "launcher_debug_run_plugin", "input": "x"])
        let json = parseJSON(data)
        XCTAssertEqual(json["status"] as? String, "error")
        // debug run 缺 name 报 missing 'name'（与重构前一致）
        let message = (json["message"] as? String) ?? ""
        XCTAssertTrue(message.lowercased().contains("missing") || message.contains("name"),
                      "debug run 缺 name 必须 error（契约不变），实际: \(message)")
    }
}
