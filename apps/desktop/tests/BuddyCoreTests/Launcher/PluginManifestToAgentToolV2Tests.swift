import XCTest
@testable import BuddyCore

// P2 单测：toAgentTool() 重写 — 合成枚举 description + inputSchema 优先 parameters
//
// 契约：
//   C-TOOL-SCHEMA：inputSchema 顶层 type:"object"（无论 parameters 还是固定 query）
//   C-PARAM-OPTIN：parameters 缺失→nil→回退固定 {query}（properties 含 "query"）
//   描述合成：从 summary/description/keywords 合成枚举模板，含触发词
final class PluginManifestToAgentToolV2Tests: XCTestCase {

    // MARK: - 无 parameters → 回退固定 {query} 契约（qr 真实 manifest 形态）

    /// qr 无 parameters → inputSchema 回退固定 {query}，properties 含 query，required==["query"]
    func test_qrManifestWithoutParameters_fallsBackToFixedQuerySchema() {
        let manifest = makeQrManifest(parameters: nil)
        let tool = manifest.toAgentTool()

        // 顶层 type:object
        let typeValue = tool.inputSchema["type"]?.value as? String
        XCTAssertEqual(typeValue, "object",
                       "C-TOOL-SCHEMA：inputSchema 顶层 type 必须是 'object'")

        // properties 含 query
        let properties = tool.inputSchema["properties"]?.value as? [String: Any]
        XCTAssertNotNil(properties?["query"],
                        "无 parameters → 回退固定 {query}，properties 必须含 'query'")

        // required == ["query"]
        let requiredStrings = extractRequiredStrings(tool.inputSchema["required"]?.value)
        XCTAssertEqual(requiredStrings, ["query"],
                       "无 parameters → required 必须是 ['query']")
    }

    // MARK: - 含 parameters → inputSchema 用 parameters（强制 type:object）

    /// qr 含 parameters(content 字段) → inputSchema 用 parameters，properties 含 content 非 query
    func test_qrManifestWithParameters_usesParametersSchema() {
        let manifest = makeQrManifest(parameters: qrParameters())
        let tool = manifest.toAgentTool()

        let typeValue = tool.inputSchema["type"]?.value as? String
        XCTAssertEqual(typeValue, "object",
                       "含 parameters 时顶层 type 仍必须是 'object'")

        let properties = tool.inputSchema["properties"]?.value as? [String: Any]
        XCTAssertNotNil(properties?["content"],
                        "含 parameters → properties 必须含 parameters 声明的 'content' 字段")

        // required 来自 parameters
        let requiredStrings = extractRequiredStrings(tool.inputSchema["required"]?.value)
        XCTAssertEqual(requiredStrings, ["content"],
                       "含 parameters → required 必须来自 parameters 声明")
    }

    /// parameters 顶层 type 非 object 时强制覆盖为 object（防 provider 400）
    func test_parametersTopLevelTypeNotObject_forcedToObject() {
        // 故意构造 parameters 顶层 type:"string"（非法），toAgentTool 必须强制改 object
        let parameters: [String: AnyCodable] = [
            "type": AnyCodable("string"),
            "properties": AnyCodable(["content": ["type": "string"] as [String: String]]),
            "required": AnyCodable(["content"])
        ]
        let manifest = PluginManifest(
            name: "qr",
            version: "0.3.0",
            description: "二维码生成器",
            keywords: ["qr"],
            cmd: "./qr-gen.sh",
            parameters: parameters
        )
        let tool = manifest.toAgentTool()
        let typeValue = tool.inputSchema["type"]?.value as? String
        XCTAssertEqual(typeValue, "object",
                       "BLOCKER：即使 parameters.type 非 object，toAgentTool 必须强制顶层 type=='object'")
    }

    // MARK: - description 合成（枚举模板）

    /// qr description 合成含触发词（二维码/url/网址 等）
    func test_qrDescription_synthesizedContainsTriggerWords() {
        let manifest = makeQrManifest(parameters: nil)
        let tool = manifest.toAgentTool()
        // 合成 description 必须含触发词（来自 summary/description/keywords）
        let lowercased = tool.description.lowercased()
        let containsTrigger = lowercased.contains("二维码") || lowercased.contains("qr") || lowercased.contains("qrcode")
        XCTAssertTrue(containsTrigger,
                      "合成 description 必须含触发词（二维码/qr/qrcode），实际: \(tool.description)")
    }

    /// qzh description 合成含触发词（监控/qzh）
    func test_qzhDescription_synthesizedContainsTriggerWords() {
        let manifest = makeQzhManifest()
        let tool = manifest.toAgentTool()
        let lowercased = tool.description.lowercased()
        let containsTrigger = lowercased.contains("监控") || lowercased.contains("qzh")
        XCTAssertTrue(containsTrigger,
                      "qzh 合成 description 必须含触发词，实际: \(tool.description)")
    }

    /// hello description 合成非空（即使最简插件也要有可用 description）
    func test_helloDescription_synthesizedNonEmpty() {
        let manifest = makeHelloManifest()
        let tool = manifest.toAgentTool()
        XCTAssertFalse(tool.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "hello 合成 description 必须非空（禁退回空串）")
    }

    /// description 不再硬编码 "用户原始查询"（旧 stub 标记，合成后应消失或被替换）
    func test_description_notLegacyStubQueryOnly() {
        let manifest = makeQrManifest(parameters: nil)
        let tool = manifest.toAgentTool()
        // 旧 stub 的 properties.query.description == "用户原始查询"；合成后顶层 description 不应仅是这串
        XCTAssertNotEqual(tool.description, "用户原始查询",
                          "description 不应停留在旧 stub 硬编码值")
    }

    // MARK: - 不同 manifest 产生不同 description（mutation 探针）

    func test_differentManifests_produceDifferentDescriptions() {
        let qr = makeQrManifest(parameters: nil)
        let qzh = makeQzhManifest()
        XCTAssertNotEqual(qr.toAgentTool().description, qzh.toAgentTool().description,
                          "不同 manifest 合成的 description 必须不同")
    }

    // MARK: - Helpers

    private func makeQrManifest(parameters: [String: AnyCodable]?) -> PluginManifest {
        PluginManifest(
            name: "qr",
            version: "0.2.0",
            description: "把输入的文本或网址变成一张二维码图片，点击可复制到剪贴板。适合把链接快速转移到手机扫描。",
            keywords: ["qr", "qrcode", "二维码", "码"],
            cmd: "./qr-gen.sh",
            summary: "二维码生成器：输入文本或网址生成可扫码图片",
            parameters: parameters
        )
    }

    private func makeQzhManifest() -> PluginManifest {
        PluginManifest(
            name: "qzh",
            version: "0.1.0",
            description: "查看后台监控服务的运行状态，需要时一键关闭或重新打开。",
            keywords: ["qzh", "qzhddr", "监控"],
            cmd: "./qzh-exec",
            summary: "监控服务开关：一键查询并启停后台监控服务"
        )
    }

    private func makeHelloManifest() -> PluginManifest {
        PluginManifest(
            name: "hello",
            version: "0.1.0",
            description: "内置入门示例插件，把你的输入原样回显成一句问候。",
            keywords: ["hello", "demo", "示例", "问候"],
            cmd: "./hello.sh",
            summary: "问候示例：输入任意内容回显一句问候"
        )
    }

    private func qrParameters() -> [String: AnyCodable] {
        [
            "type": AnyCodable("object"),
            "properties": AnyCodable([
                "content": ["type": "string", "description": "要编码的文本或网址"] as [String: String]
            ]),
            "required": AnyCodable(["content"])
        ]
    }

    private func extractRequiredStrings(_ raw: Any?) -> [String] {
        if let arr = raw as? [Any] { return arr.compactMap { $0 as? String } }
        if let arr = raw as? [String] { return arr }
        return []
    }
}
