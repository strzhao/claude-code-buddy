import XCTest
@testable import BuddyCore

// MARK: - PluginManifestAgentToolContractAcceptanceTests
//
// 红队验收测试（黑盒 TDD 红灯）：PluginManifest.parameters opt-in + toAgentTool() 重写契约。
//
// 设计文档契约（逐字一致）：
//   C-TOOL-SCHEMA  : AgentTool.inputSchema 顶层 type == "object"
//   C-PARAM-OPTIN  : parameters == nil ⟹ inputSchema.properties 含 "query"
//   C-BACKCOMPAT   : 旧 plugin.json（无 parameters）解码不抛错、parameters == nil
//   场景5.P1[det]  : manifest 声明 parameters → inputSchema.type == "object"
//   场景5.P2[det]  : schema 含声明字段 → properties.keys == manifest.parameters.fields
//   场景5.P3[det]  : 顶层 type:object 不破（BLOCKER-2）
//   场景6.P1[det]  : 未声明 parameters → 回退固定契约 → "query" in properties
//   场景6.P2[det]  : 旧插件执行 → 原始查询填 query → input.query == userInput
//   场景7.P1[det]  : 无新字段旧 manifest → 全部加载 → len(loaded) == len(files)，无 crash
//   场景7.P2[det]  : 旧插件被选 → 进执行路径 → exit == 0
//
// 铁律：
//   - 强断言（XCTAssert*），失败必挂；禁 try/catch 吞错 / skip 假装跑 / 只断言 stable 终态
//   - Mutation-Survival：涉及状态变化的断言能 kill no-op mutation
//   - 黑盒：只调公开 API + 断言；不读蓝队新实现源码
//
// 关键类型（已有，非蓝队新增）：
//   PluginManifest(name:version:description:keywords:cmd:...) 便利 init（stdin mode）
//   PluginManifest.parameters: [String: AnyCodable]? （蓝队要加的可选字段——红队假设存在）
//   PluginManifest.toAgentTool() -> AgentTool
//   AgentTool(name:description:inputSchema:[String:AnyCodable])

// MARK: - Helpers（私有，仅本文件）

private func makeStdinManifest(
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

/// 把 [String: AnyCodable] 当作 JSON Schema dict 读取（AnyCodable.value 解包）。
private func schemaDict(_ schema: [String: AnyCodable]) -> [String: Any] {
    var out: [String: Any] = [:]
    for (k, v) in schema {
        if let d = v.value as? [String: Any] {
            out[k] = d
        } else {
            out[k] = v.value
        }
    }
    return out
}

/// 从 plugin.json 文本解码 PluginManifest（黑盒：经 Codable 公开路径）。
private func decodeManifest(_ json: String) throws -> PluginManifest {
    let data = json.data(using: .utf8)!
    return try JSONDecoder().decode(PluginManifest.self, from: data)
}

// MARK: - 场景5: manifest 声明 parameters → 生成合法 JSON Schema

final class PluginManifestParametersSchemaAcceptanceTests: XCTestCase {

    // 场景5.P1[det] + C-TOOL-SCHEMA：声明 parameters 的 manifest，toAgentTool().inputSchema 顶层 type=="object"
    //
    // Mutation 探针：若蓝队漏写顶层 type 或写成 "string"，typeValue 断言红灯。
    func test_scenario5_P1_declaredParameters_topLevelTypeIsObject() throws {
        // 声明一个结构化参数的 manifest（如 shorten: 一个 url 字段）
        let json = """
        {
          "name": "shorten",
          "version": "1.0.0",
          "description": "缩短网址",
          "keywords": ["shorten", "短链"],
          "cmd": "./shorten.sh",
          "args": [],
          "timeout": 5,
          "parameters": {
            "type": "object",
            "properties": {
              "url": { "type": "string", "description": "要缩短的长网址" }
            },
            "required": ["url"]
          }
        }
        """
        let manifest = try decodeManifest(json)

        // 契约：parameters 字段存在且被解码（蓝队必须加这个可选字段）
        XCTAssertNotNil(manifest.parameters,
                       "C-PARAM-OPTIN: 声明 parameters 的 plugin.json 必须解码到 manifest.parameters（非 nil）")

        let tool = manifest.toAgentTool()
        let schema = schemaDict(tool.inputSchema)
        let typeValue = schema["type"] as? String

        XCTAssertEqual(typeValue, "object",
                       "C-TOOL-SCHEMA / 场景5.P1: inputSchema 顶层 type 必须精确是 'object'，实际: \(typeValue ?? "nil")")
    }

    // 场景5.P2[det]：schema 含声明的字段（properties.keys 包含 manifest 声明的字段名）
    //
    // Mutation 探针：若蓝队 toAgentTool 漏带 parameters 的 properties（回退固定 query），
    //   urlKey 为 nil → 断言红灯。
    func test_scenario5_P2_declaredParameters_propertiesContainDeclaredFields() throws {
        let json = """
        {
          "name": "shorten",
          "version": "1.0.0",
          "description": "缩短网址",
          "keywords": ["shorten"],
          "cmd": "./shorten.sh",
          "parameters": {
            "type": "object",
            "properties": {
              "url": { "type": "string" }
            },
            "required": ["url"]
          }
        }
        """
        let manifest = try decodeManifest(json)
        let tool = manifest.toAgentTool()

        let propertiesRaw = tool.inputSchema["properties"]?.value
        let propertiesDict = propertiesRaw as? [String: Any]
        XCTAssertNotNil(propertiesDict,
                       "inputSchema['properties'] 必须存在且是 dict，实际: \(String(describing: propertiesRaw))")

        // 声明的字段 "url" 必须出现在 properties 中
        XCTAssertNotNil(propertiesDict?["url"],
                       "场景5.P2: 声明 parameters.properties.url 必须出现在 inputSchema.properties 中，实际 keys: \(propertiesDict?.keys.sorted() ?? [])")
    }

    // 场景5.P3[det] + C-TOOL-SCHEMA（BLOCKER-2）：即使声明了复杂 parameters，
    //   最终 tool.inputSchema 顶层 type 仍是 "object"（不能因为 parameters 内部结构破坏顶层契约）
    //
    // Mutation 探针：若蓝队把 parameters 整体当 inputSchema（漏包顶层 type:object 外壳），
    //   typeValue 会变成 nil 或非 object → 红灯。
    func test_scenario5_P3_complexParameters_topLevelTypeStillObject() throws {
        let json = """
        {
          "name": "qr",
          "version": "1.0.0",
          "description": "生成二维码",
          "keywords": ["qr", "二维码"],
          "cmd": "./qr-gen.sh",
          "parameters": {
            "type": "object",
            "properties": {
              "content": { "type": "string" },
              "size": { "type": "integer" }
            },
            "required": ["content"]
          }
        }
        """
        let manifest = try decodeManifest(json)
        let tool = manifest.toAgentTool()
        let schema = schemaDict(tool.inputSchema)

        let typeValue = schema["type"] as? String
        XCTAssertEqual(typeValue, "object",
                       "场景5.P3 / BLOCKER-2: 复杂 parameters 下 inputSchema 顶层 type 必须仍是 'object'，实际: \(typeValue ?? "nil")")
    }
}

// MARK: - 场景6: 未声明 parameters → 回退固定 {query} 契约

final class PluginManifestFallbackQueryAcceptanceTests: XCTestCase {

    // 场景6.P1[det] + C-PARAM-OPTIN：未声明 parameters 的 manifest，inputSchema.properties 必须含 "query"
    //
    // Mutation 探针：若蓝队 parameters==nil 时不回退固定 query（如返回空 properties），
    //   queryKey 为 nil → 红灯。
    func test_scenario6_P1_noParameters_fallsBackToQueryProperty() throws {
        let manifest = makeStdinManifest(
            name: "legacy-plugin",
            description: "legacy without parameters",
            keywords: ["legacy"]
        )

        // 契约：未声明 parameters → manifest.parameters == nil
        XCTAssertNil(manifest.parameters,
                    "C-PARAM-OPTIN: 未声明 parameters 的 manifest，parameters 必须为 nil")

        let tool = manifest.toAgentTool()
        let propertiesRaw = tool.inputSchema["properties"]?.value
        let propertiesDict = propertiesRaw as? [String: Any]
        XCTAssertNotNil(propertiesDict,
                       "inputSchema['properties'] 必须存在（即使无 parameters 也要回退固定 query）")
        XCTAssertNotNil(propertiesDict?["query"],
                       "场景6.P1 / C-PARAM-OPTIN: parameters==nil 时 inputSchema.properties 必须含 'query' 键，实际 keys: \(propertiesDict?.keys.sorted() ?? [])")
    }

    // 场景6.P1 补：回退契约的 query 字段 type 必须是 "string"（结构合法）
    func test_scenario6_P1_fallbackQueryTypeIsString() {
        let manifest = makeStdinManifest(name: "no-params", description: "x")
        let tool = manifest.toAgentTool()

        let propertiesDict = tool.inputSchema["properties"]?.value as? [String: Any]
        let queryDef = propertiesDict?["query"] as? [String: Any]
        let queryType = queryDef?["type"] as? String
        XCTAssertEqual(queryType, "string",
                       "回退契约 properties['query']['type'] 必须是 'string'，实际: \(String(describing: queryType))")
    }

    // 场景6.P2[det] + C-EXTRACTED-QUERY（间接）：未声明 parameters 的旧插件，
    //   执行时 query 字段填用户原始输入（PluginInput.query == userInput）
    //
    // 这里验证回退契约的 required == ["query"]，确保旧插件仍走 query 入参。
    func test_scenario6_P2_legacyPlugin_fallbackRequiredIsQuery() {
        let manifest = makeStdinManifest(name: "legacy", description: "old plugin")
        let tool = manifest.toAgentTool()

        let requiredRaw = tool.inputSchema["required"]?.value
        var requiredStrings: [String] = []
        if let arr = requiredRaw as? [Any] {
            requiredStrings = arr.compactMap { $0 as? String }
        } else if let arr = requiredRaw as? [String] {
            requiredStrings = arr
        }
        XCTAssertEqual(requiredStrings, ["query"],
                       "场景6.P2: 回退契约 required 必须精确是 [\"query\"]（旧插件仍走 query 入参），实际: \(requiredStrings)")
    }

    // 场景6.P2 补（C-EXTRACTED-QUERY 直接验证）：PluginInput(query:) 构造后 query 字段保留原值
    //   （extractedQuery 非空 ⟹ PluginInput.query == extractedQuery 的基础语义）
    func test_scenario6_P2_pluginInputQueryHoldsExactValue() {
        let userInput = "生成二维码 https://example.com"
        let input = PluginInput(query: userInput, sessionId: "test-session", cwd: "/tmp")

        XCTAssertEqual(input.query, userInput,
                       "C-EXTRACTED-QUERY: PluginInput.query 必须精确等于构造时传入的值（旧插件 query 通路），实际: \(input.query)")
        XCTAssertNotEqual(input.query, "生成二维码",
                          "Mutation 探针: query 不应被截断或改写为部分值")
    }
}

// MARK: - 场景7: 旧 plugin.json 向后兼容（无 parameters 字段不破坏加载）

final class PluginManifestBackCompatAcceptanceTests: XCTestCase {

    // 场景7.P1[det] + C-BACKCOMPAT：无 parameters 字段的旧 plugin.json 解码不抛错
    //
    // Mutation 探针：若蓝队把 parameters 声明成非可选（required），旧 JSON 解码会抛 KeyNotFound → 红灯。
    func test_scenario7_P1_legacyPluginJsonWithoutParameters_decodesWithoutThrow() throws {
        let legacyJson = """
        {
          "name": "legacy-v0",
          "version": "0.1.0",
          "description": "旧插件，无 parameters 字段",
          "keywords": ["legacy"],
          "cmd": "./run.sh",
          "args": [],
          "env": null,
          "timeout": 5,
          "requiredPath": null
        }
        """
        // 关键：解码不抛错（try 经 throws 传播，抛错则测试失败）
        let manifest = try decodeManifest(legacyJson)

        XCTAssertEqual(manifest.name, "legacy-v0",
                       "C-BACKCOMPAT: 旧 plugin.json 必须能正常解码（name 字段正确）")
        XCTAssertNil(manifest.parameters,
                    "C-BACKCOMPAT: 旧 plugin.json（无 parameters）解码后 manifest.parameters 必须为 nil")
    }

    // 场景7.P1 补（len(loaded)==len(files)）：多个旧 manifest 全部加载成功，无 crash / 无 fatal
    func test_scenario7_P1_multipleLegacyManifests_allDecode() throws {
        let legacyJsons = [
            """
            {"name":"a","version":"1.0.0","description":"plugin a","keywords":[],"cmd":"./a.sh"}
            """,
            """
            {"name":"b","version":"1.0.0","description":"plugin b","keywords":["b"],"cmd":"./b.sh","args":["--x"]}
            """,
            """
            {"name":"c","version":"2.0.0","description":"plugin c","keywords":[],"cmd":"./c.sh","timeout":10}
            """
        ]
        var loaded: [PluginManifest] = []
        for json in legacyJsons {
            // 任一解码抛错 → try 传播 → 测试失败（不吞错）
            let m = try decodeManifest(json)
            loaded.append(m)
        }
        XCTAssertEqual(loaded.count, legacyJsons.count,
                       "场景7.P1: 所有旧 manifest 必须全部加载成功，期望 \(legacyJsons.count) 个，实际 \(loaded.count)")
    }

    // 场景7.P2[det]：旧插件（无 parameters）被选中后能进执行路径——
    //   验证 toAgentTool() 不抛错且返回合法 AgentTool（执行路径前置条件）。
    //
    // Mutation 探针：若蓝队 toAgentTool 在 parameters==nil 时崩溃或返回空 tool，
    //   name 断言或 inputSchema 非空断言红灯。
    func test_scenario7_P2_legacyPluginSelected_toAgentToolProducesValidTool() throws {
        let legacyJson = """
        {
          "name": "legacy-exec",
          "version": "1.0.0",
          "description": "legacy plugin to be selected",
          "keywords": ["legacy"],
          "cmd": "./run.sh"
        }
        """
        let manifest = try decodeManifest(legacyJson)
        XCTAssertNil(manifest.parameters, "旧插件 parameters 必须为 nil")

        // 选中后转 tool（执行路径前置）——必须不崩、返回非空 tool
        let tool = manifest.toAgentTool()
        XCTAssertEqual(tool.name, "legacy-exec",
                       "场景7.P2: 旧插件转 tool 后 name 必须精确等于 manifest.name")
        XCTAssertFalse(tool.inputSchema.isEmpty,
                      "场景7.P2: 旧插件 tool.inputSchema 不能为空（回退固定 query 契约必须填充）")

        // 回退契约：顶层 type:object + properties.query 存在（双重保险）
        let schema = schemaDict(tool.inputSchema)
        XCTAssertEqual(schema["type"] as? String, "object",
                       "场景7.P2: 旧插件 tool 顶层 type 必须是 object")
        let props = schema["properties"] as? [String: Any]
        XCTAssertNotNil(props?["query"],
                       "场景7.P2: 旧插件 tool.properties 必须含 query（回退契约）")
    }
}

// MARK: - 跨场景补充：toAgentTool description 合成（枚举模板）

final class PluginManifestAgentToolDescriptionAcceptanceTests: XCTestCase {

    // 设计文档 Part1：toAgentTool 的 description 从 summary/description/keywords 合成枚举模板。
    // 这里验证 description 非空且包含 manifest 的核心信息（不依赖具体模板格式，只验证信息密度）。
    //
    // Mutation 探针：若蓝队 description 返回空字符串，isEmpty 断言红灯。
    func test_toAgentTool_descriptionIsNonEmptyAndContainsName() {
        let manifest = makeStdinManifest(
            name: "qr",
            description: "生成二维码图片",
            keywords: ["qr", "二维码"]
        )
        let tool = manifest.toAgentTool()

        XCTAssertFalse(tool.description.isEmpty,
                       "toAgentTool().description 不能为空（必须从 summary/description/keywords 合成）")
        XCTAssertTrue(tool.description.contains("qr") || tool.description.contains("二维码") || tool.description.contains("二维码图片"),
                      "description 必须包含 manifest 的核心信息（name/keywords/description 之一），实际: \(tool.description)")
    }

    // 设计文档：不同 manifest 合成不同 description（mutation 探针——防止 description 写死常量）
    func test_toAgentTool_descriptionDiffersForDifferentManifests() {
        let m1 = makeStdinManifest(name: "qr", description: "生成二维码", keywords: ["qr"])
        let m2 = makeStdinManifest(name: "shorten", description: "缩短网址", keywords: ["shorten"])
        let t1 = m1.toAgentTool()
        let t2 = m2.toAgentTool()

        XCTAssertNotEqual(t1.description, t2.description,
                          "不同 manifest 合成的 description 必须不同（防止 description 写死常量）")
    }
}
