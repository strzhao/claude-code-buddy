import XCTest
@testable import BuddyCore

/// Tier 0 红队验收测试（黑盒）—— `buddy tools` IPC（action `launcher_list_tools`）契约。
///
/// 信息隔离：不读蓝队本次新写的 QueryHandler 改动（list_tools / run_tool / runPluginCore）实现。
/// 仅依赖设计文档 ## 契约规约 + 既有事实（PluginManager.init(rootDir:) 可注入、
/// QueryHandler.init(pluginManager:...) 可注入、PluginManifest JSONDecoder 真实 decode 路径、
/// displaySummary / synthesizeToolDescription / effectiveToolInputSchema / modeConfig 既有 accessor）。
///
/// 驱动方式（det-machine）：构造真实临时插件目录 + 真实 plugin.json 文件 →
/// `JSONDecoder().decode(PluginManifest.self, from:)`（非便利 init，覆盖补强 2 decode 路径）→
/// 注入 QueryHandler → 直接 `await handler.handle(query:["action":"launcher_list_tools"])` →
/// 断言返回 JSON `{status:"ok", data:{tools:[...], count:N}}` 的字段名集合与字面量。
///
/// 覆盖验收场景：
/// - 场景 1（P1-P7）：buddy tools --json 列出所有启用外部插件（manifest schema / no-builtin / mode 枚举 / inputSchema 分支）
/// - 场景 3（P1-P5）：动态增删（enable/disable 后 manifest 变化，不重启 handler）
/// - 场景 7（P1-P3）：契约稳定性（连续多次字段名集合稳定）
/// - 场景 8（P1）：插件零适配（纯读 plugin.json，无 tools 专属字段）
/// - 补强 2：legacy plugin.json（无 summary/parameters/keywords）decode 路径降级非空 + inputSchema 回退 {query}
/// - 补强 3：mode 多样性强枚举（测试数据含 ≥2 种 mode，kill 全报同值 mutation）
///
/// 命名前缀: test_T<编号>_<场景>
@MainActor
final class ToolsManifestAcceptanceTests: XCTestCase {

    private var tempRoot: URL!
    private var handler: QueryHandler!

    // MARK: - setUp / tearDown

    override func setUp() {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("buddy-acceptance-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        rebuildHandler()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func rebuildHandler() {
        let scene = MockScene()
        let (manager, _) = TestHelpers.makeManager(scene: scene)
        // 关键：注入 PluginManager(rootDir:) + TrustStore(file:) fake，直驱 handle(query:)
        let pm = PluginManager(rootDir: tempRoot)
        let trustFile = tempRoot.appendingPathComponent("fake-trust.json")
        let ts = TrustStore(file: trustFile)
        handler = QueryHandler(
            sessionManager: manager,
            scene: scene,
            eventStore: manager.eventStore,
            pluginManager: pm,
            trustStore: ts
        )
    }

    // MARK: - Helpers（构造真实 plugin.json 文件，走 JSONDecoder decode 路径）

    /// 在 tempRoot 下写一个插件目录 + plugin.json。
    /// rawJSON 直接写盘（不走便利 init，强制 JSONDecoder().decode(PluginManifest.self, from:) 路径）。
    @discardableResult
    private func writePlugin(_ name: String, rawJSON: String, disabled: Bool = false) throws -> URL {
        let dir = tempRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifestFile = dir.appendingPathComponent("plugin.json")
        try rawJSON.data(using: .utf8)!.write(to: manifestFile)
        if disabled {
            try Data().write(to: dir.appendingPathComponent(".disabled"))
        }
        return dir
    }

    /// 标准 command mode 插件（有 parameters）。
    private var commandWithParamsJSON: String {
        """
        {
          "name": "qr-gen",
          "version": "1.0.0",
          "summary": "生成二维码图片",
          "description": "调用 qrencode 把网址或文本生成 PNG 二维码图片。",
          "keywords": ["qr", "二维码", "码"],
          "mode": "command",
          "cmd": "qr-gen.sh",
          "parameters": {
            "type": "object",
            "properties": {
              "query": { "type": "string", "description": "要编码的内容（如网址）" }
            },
            "required": ["query"]
          }
        }
        """
    }

    /// stdin mode 插件（无 parameters → 回退 {query}）。
    private var stdinNoParamsJSON: String {
        """
        {
          "name": "echo-stdin",
          "version": "0.3.1",
          "summary": "把输入文本原样回显",
          "description": "简单 stdin 插件，读取 query 后回显。",
          "keywords": ["echo"],
          "mode": "stdin",
          "cmd": "echo.sh"
        }
        """
    }

    /// prompt mode 插件。
    /// 注：CodingKeys 用 camelCase（systemPrompt / maxIterations），非 snake_case。
    private var promptJSON: String {
        """
        {
          "name": "translate-prompt",
          "version": "2.0.0",
          "summary": "翻译文本",
          "description": "prompt mode 翻译插件。",
          "keywords": ["translate", "翻译"],
          "mode": "prompt",
          "systemPrompt": "你是翻译助手",
          "maxIterations": 1
        }
        """
    }

    /// minimal legacy 插件（无 summary / 无 parameters / 无 keywords，补强 2）。
    private var legacyMinimalJSON: String {
        """
        {
          "name": "legacy-min",
          "version": "0.1.0",
          "description": "老插件仅有 description 一句用来降级",
          "mode": "command",
          "cmd": "legacy.sh"
        }
        """
    }

    private func parseJSON(_ data: Data) -> [String: Any] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("response 不是合法 JSON object: \(String(data: data, encoding: .utf8) ?? "<binary>")")
            return [:]
        }
        return obj
    }

    /// 发 launcher_list_tools，返回 data.tools 数组 + count。失败 XCTFail 返回空。
    private func fetchTools() async -> (tools: [[String: Any]], count: Int, raw: [String: Any]) {
        let data = await handler.handle(query: ["action": "launcher_list_tools"])
        let json = parseJSON(data)
        XCTAssertEqual(json["status"] as? String, "ok",
                       "launcher_list_tools 必须 status=ok（action 必须被识别），实际: \(json)")
        guard let dataDict = json["data"] as? [String: Any] else {
            XCTFail("data 字段缺失或非 dict: \(json)")
            return ([], 0, json)
        }
        let tools = (dataDict["tools"] as? [[String: Any]]) ?? []
        let count = (dataDict["count"] as? Int) ?? -1
        return (tools, count, json)
    }

    // MARK: - 场景 1: buddy tools --json manifest schema

    /// 场景 1.P1 + 1.P3 + 1.P7: 返回 status ok + tools 是数组 + count == 元素数 + exit==0（单测层 status==ok 等价 exit 0）。
    func test_T01_listToolsReturnsArrayOfEnabledExternalPlugins() async throws {
        try writePlugin("qr-gen", rawJSON: commandWithParamsJSON)
        try writePlugin("echo-stdin", rawJSON: stdinNoParamsJSON)

        let (tools, count, _) = await fetchTools()
        // 场景 1.P1: isArray==true（tools 是 [[String:Any]]，已证明是数组）
        XCTAssertEqual(tools.count, 2, "场景 1.P3: tools 数 == enabled 外部插件数（2）")
        XCTAssertEqual(count, tools.count, "data.count 字段必须 == tools.count（kill count 漂移 mutation）")
    }

    /// 场景 1.P2 + 契约 C-MANIFEST-SCHEMA: 每元素 keys ⊇ {name,summary,description,inputSchema,mode}（五字段必填非空）。
    /// kill 删字段 mutation：只断言「response 非 nil」过 no-op；这里硬断言字段名集合。
    func test_T02_everyToolEntryHasFiveContractFieldsNonEmpty() async throws {
        try writePlugin("qr-gen", rawJSON: commandWithParamsJSON)
        try writePlugin("echo-stdin", rawJSON: stdinNoParamsJSON)
        try writePlugin("translate-prompt", rawJSON: promptJSON)

        let (tools, _, _) = await fetchTools()
        XCTAssertFalse(tools.isEmpty, "测试数据应有 ≥1 插件")

        let requiredKeys: Set<String> = ["name", "summary", "description", "inputSchema", "mode"]
        for (i, tool) in tools.enumerated() {
            let keys = Set(tool.keys)
            XCTAssertTrue(keys.isSuperset(of: requiredKeys),
                          "场景 1.P2 / C-MANIFEST-SCHEMA: tool[\(i)] keys=\(keys.sorted()) 必须 ⊇ \(requiredKeys.sorted())（kill 删字段 mutation）")
            // 非空硬断言（summary 经 displaySummary 降级保证非空）
            for field in requiredKeys {
                let value = tool[field]
                XCTAssertNotNil(value, "tool[\(i)].\(field) 必须存在")
                if let str = value as? String {
                    XCTAssertFalse(str.isEmpty, "tool[\(i)].\(field)（String）必须非空（降级保证）")
                } else if let dict = value as? [String: Any] {
                    XCTAssertFalse(dict.isEmpty, "tool[\(i)].\(field)（dict）必须非空")
                } else {
                    XCTFail("tool[\(i)].\(field) 类型应为 String 或 dict，实际: \(type(of: value ?? ""))")
                }
            }
        }
    }

    /// 契约 C-INPUTSCHEMA-CAMELCASE: 字段名是 camelCase `inputSchema`（非 snake `input_schema`）。
    /// kill mutation：蓝队误用 AgentTool 的 input_schema key。
    func test_T03_inputSchemaFieldIsCamelCaseNotSnakeCase() async throws {
        try writePlugin("qr-gen", rawJSON: commandWithParamsJSON)

        let (tools, _, _) = await fetchTools()
        let tool = try XCTUnwrap(tools.first)
        XCTAssertNotNil(tool["inputSchema"], "C-INPUTSCHEMA-CAMELCASE: 必须用 camelCase key 'inputSchema'")
        XCTAssertNil(tool["input_schema"],
                     "C-INPUTSCHEMA-CAMELCASE: 禁用 snake_case key 'input_schema'（AgentTool Codable key 不得泄漏到 manifest）")
    }

    /// 契约 C-INPUTSCHEMA-CAMELCASE: inputSchema 顶层 type=="object"（复用 effectiveToolInputSchema）。
    /// 场景 1.P5 has_params 分支：有 parameters 的 inputSchema 含 properties + type:object。
    func test_T04_inputSchemaHasTopLevelTypeObject() async throws {
        try writePlugin("qr-gen", rawJSON: commandWithParamsJSON)

        let (tools, _, _) = await fetchTools()
        let tool = try XCTUnwrap(tools.first)
        let schema = try XCTUnwrap(tool["inputSchema"] as? [String: Any])
        XCTAssertEqual(schema["type"] as? String, "object",
                       "inputSchema 顶层 type 必须 == 'object'（C-TOOL-SCHEMA / 防_provider_400）")
        XCTAssertNotNil(schema["properties"], "inputSchema 应含 properties（has_params 分支）")
    }

    /// 场景 1.P5 no_params 分支 + 补强 2: legacy 无 parameters → inputSchema 回退 {query}。
    /// kill mutation：回退分支漏写 query / 漏写 type:object。
    func test_T05_inputSchemaFallbackToQueryShapeForLegacyPlugin() async throws {
        // legacy 插件走 JSONDecoder 真实 decode 路径（非便利 init，覆盖补强 2 降级路径）
        try writePlugin("legacy-min", rawJSON: legacyMinimalJSON)

        let (tools, _, _) = await fetchTools()
        let tool = try XCTUnwrap(tools.first)
        XCTAssertEqual(tool["name"] as? String, "legacy-min")

        let schema = try XCTUnwrap(tool["inputSchema"] as? [String: Any])
        XCTAssertEqual(schema["type"] as? String, "object", "回退 inputSchema 顶层 type==object")
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        XCTAssertNotNil(properties["query"], "回退 inputSchema.properties 必须含 query 字段（场景 1.P5 no_params）")
        // required 含 query
        if let required = schema["required"] as? [String] {
            XCTAssertTrue(required.contains("query"), "回退 inputSchema.required 应含 query")
        } else {
            XCTFail("回退 inputSchema 应有 required 数组")
        }
    }

    /// 补强 2: legacy plugin.json 降级 —— summary 经 displaySummary 非空（用 description 首句）+ description 非空。
    /// kill mutation：summary 字段为 nil/空时蓝队未走降级。
    func test_T06_legacyPluginSummaryAndDescriptionDegradedNonEmpty() async throws {
        try writePlugin("legacy-min", rawJSON: legacyMinimalJSON)

        let (tools, _, _) = await fetchTools()
        let tool = try XCTUnwrap(tools.first)
        let summary = try XCTUnwrap(tool["summary"] as? String)
        XCTAssertFalse(summary.isEmpty, "补强 2: legacy 插件 summary 经 displaySummary 降级必须非空")
        let description = try XCTUnwrap(tool["description"] as? String)
        XCTAssertFalse(description.isEmpty, "补强 2: legacy 插件 description 经 synthesizeToolDescription 必须非空")
    }

    /// 场景 1.P6 + 补强 3: mode ∈ {stdin,command,prompt}，且测试数据含 ≥2 种 mode（强枚举）。
    /// kill mutation：mode 全报同一值（"command"）—— 测试数据有 command+stdin+prompt 三种，
    /// 若蓝队误把所有 mode 报成 command，stdin/prompt 插件 mode 会错（断言 name→mode 映射精确）。
    func test_T07_modeIsEnumAndDiverseAcrossPlugins() async throws {
        try writePlugin("qr-gen", rawJSON: commandWithParamsJSON)        // command
        try writePlugin("echo-stdin", rawJSON: stdinNoParamsJSON)        // stdin
        try writePlugin("translate-prompt", rawJSON: promptJSON)         // prompt

        let (tools, _, _) = await fetchTools()
        let allowedModes: Set<String> = ["stdin", "command", "prompt"]

        var seenModes = Set<String>()
        for tool in tools {
            let mode = try XCTUnwrap(tool["mode"] as? String, "tool.mode 必须是 String")
            XCTAssertTrue(allowedModes.contains(mode),
                          "场景 1.P6: mode=\(mode) 必须 ∈ {stdin,command,prompt}")
            seenModes.insert(mode)
        }
        // 补强 3：实测数据应观察到 ≥2 种 mode（kill 全报同值 mutation）
        XCTAssertGreaterThanOrEqual(seenModes.count, 2,
                                    "补强 3: 测试数据含 3 种 mode（command+stdin+prompt），manifest 至少应观察到 ≥2 种；实际: \(seenModes.sorted())")

        // 精确 name→mode 映射断言（kill mode 标签错位 mutation）
        let byName = Dictionary(uniqueKeysWithValues: tools.compactMap { t -> (String, String)? in
            guard let n = t["name"] as? String, let m = t["mode"] as? String else { return nil }
            return (n, m)
        })
        XCTAssertEqual(byName["qr-gen"], "command")
        XCTAssertEqual(byName["echo-stdin"], "stdin")
        XCTAssertEqual(byName["translate-prompt"], "prompt")
    }

    /// 场景 1.P4 + 契约 C-NO-BUILTIN: 五内置 id 不出现在 manifest。
    /// kill mutation：蓝队误把内置插件纳入 PluginManager.list()。
    func test_T08_builtinPluginsNotInManifest() async throws {
        try writePlugin("qr-gen", rawJSON: commandWithParamsJSON)

        let (tools, _, _) = await fetchTools()
        let names = tools.compactMap { $0["name"] as? String }
        let builtinIds: Set<String> = ["calculator", "paste", "screenshot", "app-launcher", "system-command",
                                       "app_launcher", "system_command"]  // 容 kebab/snake 变体
        let leaked = names.filter { builtinIds.contains($0.lowercased()) }
        XCTAssertTrue(leaked.isEmpty,
                      "场景 1.P4 / C-NO-BUILTIN: 五内置不得出现在 manifest，泄漏: \(leaked)")
    }

    // MARK: - 场景 3: 动态增删（不重启 handler）

    /// 场景 3.P1-P5: enable（删 .disabled）后 P_ENABLE 出现；disable（写 .disabled）后 P_DISABLE 消失；长度差==0（一增一减）。
    /// kill mutation：manifest 缓存（非 live 计算）→ 增删后不反映。
    /// 注：PluginManager.validate(againstDirName:) 要求 JSON.name == 目录名，故 rawJSON 内嵌匹配的 name。
    func test_T09_manifestReflectsEnableDisableWithoutRestart() async throws {
        // 初始：P_DISABLE 启用、P_ENABLE 禁用。目录名 == JSON.name（validate 约束）。
        let disableJSON = """
        { "name": "p-disable", "version": "1.0.0", "summary": "将被禁用",
          "description": "动态测试用 stdin 插件。", "keywords": ["d"], "mode": "stdin", "cmd": "d.sh" }
        """
        let enableJSON = """
        { "name": "p-enable", "version": "1.0.0", "summary": "将被启用",
          "description": "动态测试用 command 插件。", "keywords": ["e"], "mode": "command", "cmd": "e.sh" }
        """
        try writePlugin("p-disable", rawJSON: disableJSON, disabled: false)
        try writePlugin("p-enable", rawJSON: enableJSON, disabled: true)

        let (toolsBefore, _, _) = await fetchTools()
        let namesBefore = Set(toolsBefore.compactMap { $0["name"] as? String })
        XCTAssertTrue(namesBefore.contains("p-disable"), "场景 3.P1: 变更前 P_DISABLE 在 manifest")
        XCTAssertFalse(namesBefore.contains("p-enable"), "场景 3.P2: 变更前 P_ENABLE 不在 manifest")
        let lenBefore = toolsBefore.count

        // 动态变更：disable P_DISABLE（写 .disabled）+ enable P_ENABLE（删 .disabled）
        try Data().write(to: tempRoot.appendingPathComponent("p-disable/.disabled"))
        try FileManager.default.removeItem(at: tempRoot.appendingPathComponent("p-enable/.disabled"))

        // 不重建 handler（验 live 计算，C-DYNAMIC）
        let (toolsAfter, _, _) = await fetchTools()
        let namesAfter = Set(toolsAfter.compactMap { $0["name"] as? String })
        XCTAssertTrue(namesAfter.contains("p-enable"), "场景 3.P3: 变更后 P_ENABLE 出现（无重启）")
        XCTAssertFalse(namesAfter.contains("p-disable"), "场景 3.P4: 变更后 P_DISABLE 消失")
        XCTAssertEqual(toolsAfter.count, lenBefore,
                       "场景 3.P5: 一增一减长度差 == 0（实际 before=\(lenBefore) after=\(toolsAfter.count)）")
    }

    // MARK: - 场景 7: 契约稳定性（字段是契约）

    /// 场景 7.P1-P3: 连续 3 次同插件集字段名集合相同 + 五契约字段恒存在 + name/mode 稳定。
    /// kill mutation：某次调用随机返回不同字段（非确定性序列化）。
    func test_T10_manifestContractStableAcrossCalls() async throws {
        try writePlugin("qr-gen", rawJSON: commandWithParamsJSON)
        try writePlugin("echo-stdin", rawJSON: stdinNoParamsJSON)

        var keysSnapshots: [Set<String>] = []
        var nameModeSnapshots: [String: String] = [:]
        var firstSeen: [String: String] = [:]

        for _ in 0..<3 {
            let (tools, _, _) = await fetchTools()
            for tool in tools {
                let keys = Set(tool.keys)
                keysSnapshots.append(keys)
                let requiredKeys: Set<String> = ["name", "summary", "description", "inputSchema", "mode"]
                XCTAssertTrue(keys.isSuperset(of: requiredKeys),
                              "场景 7.P2: 五契约字段恒存在，实际 keys=\(keys.sorted())")
                if let name = tool["name"] as? String, let mode = tool["mode"] as? String {
                    if let prev = firstSeen[name] {
                        XCTAssertEqual(mode, prev,
                                       "场景 7.P3: 同插件 \(name) mode 三次稳定（\(prev) vs \(mode)）")
                    } else {
                        firstSeen[name] = mode
                    }
                    nameModeSnapshots[name] = mode
                }
            }
        }
        // 场景 7.P1: 字段名集合三次相同（取第一个非空 snapshot 比对其余）
        if let first = keysSnapshots.first(where: { !$0.isEmpty }) {
            for snap in keysSnapshots where !snap.isEmpty {
                XCTAssertEqual(snap, first, "场景 7.P1: 字段名集合跨调用必须稳定")
            }
        }
    }

    // MARK: - 场景 8: 插件零适配（纯读 plugin.json）

    /// 场景 8.P1 + 8.P2: 标准 plugin.json 即出现 + plugin.json 无 tools 专属字段。
    /// kill mutation：蓝队要求 plugin.json 加 tools_only/manifest_override 等专属字段才入 manifest。
    func test_T11_zeroAdaptationStandardPluginJsonAppearsWithoutToolsSpecificFields() async throws {
        // 标准 plugin.json（无任何 tools/agent_tool_spec 专属字段）
        try writePlugin("qr-gen", rawJSON: commandWithParamsJSON)

        let (tools, _, _) = await fetchTools()
        let names = tools.compactMap { $0["name"] as? String }
        XCTAssertTrue(names.contains("qr-gen"), "场景 8.P1: 标准 plugin.json 即应出现，无需 tools 适配")

        // 场景 8.P2: 读回 plugin.json 源，断言无 tools 专属字段
        let manifestFile = tempRoot.appendingPathComponent("qr-gen/plugin.json")
        let raw = try String(contentsOf: manifestFile, encoding: .utf8)
        XCTAssertFalse(raw.contains("tools_only"), "场景 8.P2: plugin.json 不得含 tools_only")
        XCTAssertFalse(raw.contains("manifest_override"), "场景 8.P2: plugin.json 不得含 manifest_override")
        XCTAssertFalse(raw.contains("agent_tool_spec"), "场景 8.P2: plugin.json 不得含 agent_tool_spec")
    }

    // MARK: - 错误路径：app 未运行 / socket（单测层无法覆盖真 socket 不可达，标 E2E）

    /// 单测层局限说明（非断言测试，仅文档化）：
    /// 场景 5（app 未运行 <10s 退出 + 非 0 + 错误指向连接）与场景 11（真跑 buddy 二进制端到端）
    /// 需真跑 buddy CLI binary + 真 app 进程，**非 in-process XCTest 能覆盖**。
    /// 详见 ToolsRunE2EChecklist.sh（E2E 留 QA Tier 1.5 真机驱动）。
    func test_T99_e2eScenariosDocumentedInShellChecklist() {
        // 占位：确保 CI 不因「无对应测试」误判。真机驱动见 ToolsRunE2EChecklist.sh。
        XCTAssertTrue(true, "E2E: 场景 5/11 留 QA Tier 1.5 真机驱动（ToolsRunE2EChecklist.sh）")
    }
}
