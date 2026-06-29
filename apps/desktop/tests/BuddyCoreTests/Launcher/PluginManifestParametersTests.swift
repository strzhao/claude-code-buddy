import XCTest
@testable import BuddyCore

// P1 单测：PluginManifest.parameters 字段（可选 JSON Schema，opt-in 向后兼容）
//
// 契约：
//   C-PARAM-OPTIN：parameters 可选，decodeIfPresent，缺失→nil→回退固定 {query}
//   C-BACKCOMPAT：旧 plugin.json 解码不抛错、不丢插件、parameters==nil
final class PluginManifestParametersTests: XCTestCase {

    // MARK: - 向后兼容（旧 plugin.json 无 parameters 字段）

    /// 旧 plugin.json（无 parameters）解码 → parameters==nil，不崩
    func test_decode_legacyManifestWithoutParameters_parametersIsNil() throws {
        let json = """
        {
          "name": "qr",
          "version": "0.2.0",
          "description": "二维码生成器",
          "keywords": ["qr", "二维码"],
          "mode": "command",
          "cmd": "./qr-gen.sh",
          "args": [],
          "env": null,
          "timeout": 10,
          "requiredPath": ["qrencode"]
        }
        """.data(using: .utf8)!
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: json)
        XCTAssertEqual(manifest.name, "qr")
        XCTAssertNil(manifest.parameters,
                     "旧 plugin.json 无 parameters 字段 → parameters 必须为 nil（向后兼容）")
    }

    /// 旧 plugin.json round-trip 不抛错（encode→decode 稳定）
    func test_decode_legacyManifest_roundTripStable() throws {
        let json = """
        {
          "name": "hello",
          "version": "0.1.0",
          "description": "示例",
          "keywords": ["hello"],
          "mode": "stdin",
          "cmd": "./hello.sh"
        }
        """.data(using: .utf8)!
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: json)
        let reencoded = try JSONEncoder().encode(manifest)
        let manifest2 = try JSONDecoder().decode(PluginManifest.self, from: reencoded)
        XCTAssertEqual(manifest, manifest2,
                       "旧 plugin.json round-trip 必须稳定（C-BACKCOMPAT）")
    }

    // MARK: - 新 plugin.json（含 parameters）

    /// 新 plugin.json（含 parameters）解码 → 字段正确解析
    func test_decode_manifestWithParameters_fieldsCorrect() throws {
        let json = """
        {
          "name": "qr",
          "version": "0.3.0",
          "description": "二维码生成器",
          "keywords": ["qr"],
          "mode": "command",
          "cmd": "./qr-gen.sh",
          "parameters": {
            "type": "object",
            "properties": {
              "content": { "type": "string", "description": "要编码的文本或网址" }
            },
            "required": ["content"]
          }
        }
        """.data(using: .utf8)!
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: json)
        XCTAssertEqual(manifest.name, "qr")
        XCTAssertNotNil(manifest.parameters, "含 parameters 的 plugin.json → parameters 非 nil")

        // 顶层 type == "object"
        let typeValue = manifest.parameters?["type"]?.value as? String
        XCTAssertEqual(typeValue, "object",
                       "parameters['type'] 必须解析为 'object'")

        // properties 含 content 键
        let properties = manifest.parameters?["properties"]?.value as? [String: Any]
        XCTAssertNotNil(properties?["content"],
                        "parameters['properties']['content'] 必须存在")

        // required == ["content"]
        let requiredRaw = manifest.parameters?["required"]?.value
        var requiredStrings: [String] = []
        if let arr = requiredRaw as? [Any] {
            requiredStrings = arr.compactMap { $0 as? String }
        } else if let arr = requiredRaw as? [String] {
            requiredStrings = arr
        }
        XCTAssertEqual(requiredStrings, ["content"],
                       "parameters['required'] 必须解析为 ['content']")
    }

    /// 含 parameters 的 manifest round-trip 稳定（encode→decode 字段一致）
    func test_encode_manifestWithParameters_roundTripStable() throws {
        let json = """
        {
          "name": "qr",
          "version": "0.3.0",
          "description": "二维码生成器",
          "keywords": ["qr"],
          "mode": "command",
          "cmd": "./qr-gen.sh",
          "parameters": {
            "type": "object",
            "properties": { "content": { "type": "string" } },
            "required": ["content"]
          }
        }
        """.data(using: .utf8)!
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: json)
        let reencoded = try JSONEncoder().encode(manifest)
        let manifest2 = try JSONDecoder().decode(PluginManifest.self, from: reencoded)
        XCTAssertEqual(manifest, manifest2,
                       "含 parameters 的 manifest round-trip 必须稳定")
    }

    /// encode 后的 JSON 含 parameters 键（nil 时不序列化）
    func test_encode_parametersNil_notSerialized() throws {
        let manifest = PluginManifest(
            name: "hello",
            version: "0.1.0",
            description: "示例",
            keywords: ["hello"],
            cmd: "./hello.sh"
        )
        let data = try JSONEncoder().encode(manifest)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("\"parameters\""),
                       "parameters==nil 时 encode 不应输出 parameters 键（与 legacy 产物一致）")
    }

    // MARK: - 便利 init（带 parameters 默认参数）

    /// 便利 init 带 parameters 参数 → manifest.parameters 正确存储
    func test_convenienceInit_withParameters_stored() {
        let parameters: [String: AnyCodable] = [
            "type": AnyCodable("object"),
            "properties": AnyCodable([
                "content": ["type": "string"] as [String: String]
            ]),
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
        XCTAssertEqual(manifest.name, "qr")
        XCTAssertNotNil(manifest.parameters)
        let typeValue = manifest.parameters?["type"]?.value as? String
        XCTAssertEqual(typeValue, "object")
    }

    /// 便利 init 不传 parameters → 默认 nil（向后兼容现有 helper 调用）
    func test_convenienceInit_withoutParameters_defaultsNil() {
        let manifest = PluginManifest(
            name: "hello",
            version: "0.1.0",
            description: "示例",
            keywords: ["hello"],
            cmd: "./hello.sh"
        )
        XCTAssertNil(manifest.parameters,
                     "便利 init 不传 parameters → 必须默认 nil（不破坏现有 makeManifest helper）")
    }
}
