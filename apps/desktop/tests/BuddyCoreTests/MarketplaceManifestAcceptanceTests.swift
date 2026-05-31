import XCTest
@testable import BuddyCore

/// Tier 0 红队验收测试 —— 独立基于设计文档契约，验证 MarketplaceManifest schema 与 bundle seed。
/// 命名前缀: test_AT<编号>_<场景>
final class MarketplaceManifestAcceptanceTests: XCTestCase {

    // MARK: - Helpers

    private func canonicalEncoder() -> JSONEncoder {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return enc
    }

    private func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        let data = Data(json.utf8)
        return try JSONDecoder().decode(type, from: data)
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        try canonicalEncoder().encode(value)
    }

    // MARK: - AT01 localSubdir 简写

    func test_AT01_localSubdirShorthandRoundTrip() throws {
        // AT01: 裸字符串 "./plugins/translate" → .localSubdir → re-encode 回字符串
        let json = "\"./plugins/translate\""
        let decoded = try decode(PluginSourceConfig.self, from: json)
        XCTAssertEqual(decoded, .localSubdir(path: "./plugins/translate"))

        let reEncoded = try encode(decoded)
        let reDecoded = try JSONDecoder().decode(PluginSourceConfig.self, from: reEncoded)
        XCTAssertEqual(reDecoded, decoded)

        // encode 必须输出 JSON 字符串字面量（非对象/数组）—— 容忍 Foundation 默认对 `/` 转义为 `\/`
        let asString = String(data: reEncoded, encoding: .utf8) ?? ""
        XCTAssertTrue(asString.hasPrefix("\"") && asString.hasSuffix("\""),
                      "expected JSON string literal, got: \(asString)")
        XCTAssertFalse(asString.hasPrefix("{"), "must not encode as object")
        // 解析回字符串值后路径必须一致（消除 `\/` 转义干扰）
        let raw = try JSONSerialization.jsonObject(with: reEncoded, options: [.fragmentsAllowed]) as? String
        XCTAssertEqual(raw, "./plugins/translate")
    }

    // MARK: - AT02 gitSubdir

    func test_AT02_gitSubdirRoundTrip() throws {
        // AT02: {"source": "git-subdir", url, path, ref, sha} → .gitSubdir → 字段全等
        let json = """
        {"source":"git-subdir","url":"https://github.com/x/y.git","path":"plugins/z","ref":"v1.0.0","sha":"abc123"}
        """
        let decoded = try decode(PluginSourceConfig.self, from: json)
        XCTAssertEqual(
            decoded,
            .gitSubdir(url: "https://github.com/x/y.git", path: "plugins/z", ref: "v1.0.0", sha: "abc123")
        )

        let reEncoded = try encode(decoded)
        let reDecoded = try JSONDecoder().decode(PluginSourceConfig.self, from: reEncoded)
        XCTAssertEqual(reDecoded, decoded)
    }

    // MARK: - AT03 gitURL with sha

    func test_AT03_gitURLWithShaRoundTrip() throws {
        // AT03: {"source": "url", url, sha} → .gitURL(sha=...) → 字段全等
        let json = """
        {"source":"url","url":"https://github.com/x/y.git","sha":"deadbeef"}
        """
        let decoded = try decode(PluginSourceConfig.self, from: json)
        XCTAssertEqual(decoded, .gitURL(url: "https://github.com/x/y.git", sha: "deadbeef"))

        let reEncoded = try encode(decoded)
        let reDecoded = try JSONDecoder().decode(PluginSourceConfig.self, from: reEncoded)
        XCTAssertEqual(reDecoded, decoded)
    }

    // MARK: - AT04 gitURL 无 sha (sha 可选)

    func test_AT04_gitURLWithoutShaRoundTrip() throws {
        // AT04: {"source": "url", url} → .gitURL(sha=nil) round-trip
        let json = """
        {"source":"url","url":"https://github.com/x/y.git"}
        """
        let decoded = try decode(PluginSourceConfig.self, from: json)
        XCTAssertEqual(decoded, .gitURL(url: "https://github.com/x/y.git", sha: nil))

        let reEncoded = try encode(decoded)
        let reDecoded = try JSONDecoder().decode(PluginSourceConfig.self, from: reEncoded)
        XCTAssertEqual(reDecoded, decoded)

        // 验证 nil sha 在 case 中保留
        if case .gitURL(_, let sha) = reDecoded {
            XCTAssertNil(sha)
        } else {
            XCTFail("expected .gitURL case")
        }
    }

    // MARK: - AT05 file

    func test_AT05_fileRoundTrip() throws {
        // AT05: {"source": "file", "path": "/abs/p"} → .file → 字段全等
        let json = """
        {"source":"file","path":"/abs/p"}
        """
        let decoded = try decode(PluginSourceConfig.self, from: json)
        XCTAssertEqual(decoded, .file(path: "/abs/p"))

        let reEncoded = try encode(decoded)
        let reDecoded = try JSONDecoder().decode(PluginSourceConfig.self, from: reEncoded)
        XCTAssertEqual(reDecoded, decoded)
    }

    // MARK: - AT06 真实 seed marketplace.json 解析

    func test_AT06_seedMarketplaceJSONDecodes() throws {
        // AT06: Bundle.module 读 Marketplace/marketplace.json → decode → 关键字段断言
        guard let url = Bundle.module.url(
            forResource: "marketplace",
            withExtension: "json",
            subdirectory: "Marketplace"
        ) else {
            XCTFail("seed marketplace.json not found in Bundle.module")
            return
        }
        let data = try Data(contentsOf: url)
        let manifest = try JSONDecoder().decode(MarketplaceManifest.self, from: data)

        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.name, "buddy-official")
        XCTAssertEqual(manifest.plugins.count, 2)

        let hello = manifest.plugins.first { $0.name == "hello" }
        XCTAssertNotNil(hello)
        XCTAssertEqual(hello?.source, .localSubdir(path: "./plugins/hello"))

        let translate = manifest.plugins.first { $0.name == "translate" }
        XCTAssertNotNil(translate)
        XCTAssertEqual(translate?.source, .localSubdir(path: "./plugins/translate"))
    }

    // MARK: - AT07 schemaVersion 缺失抛错

    func test_AT07_missingSchemaVersionThrows() throws {
        // AT07: 删除 schemaVersion → decode throw
        let json = """
        {
          "name": "x",
          "owner": {"name": "o"},
          "plugins": [
            {
              "name": "p",
              "description": "d",
              "version": "0.0.1",
              "author": {"name": "a"},
              "source": "./plugins/p"
            }
          ]
        }
        """
        XCTAssertThrowsError(try decode(MarketplaceManifest.self, from: json))
    }

    // MARK: - AT08 source 非法 kind 抛 dataCorrupted

    func test_AT08_unknownSourceKindThrowsDataCorrupted() throws {
        // AT08: {"source": "unknown-xyz"} → throw DecodingError.dataCorrupted
        let json = """
        {"source":"unknown-xyz"}
        """
        XCTAssertThrowsError(try decode(PluginSourceConfig.self, from: json)) { err in
            if case DecodingError.dataCorrupted = err {
                // ok
            } else {
                XCTFail("expected .dataCorrupted, got \(err)")
            }
        }
    }

    // MARK: - AT09 MarketplacePlugin name 缺失抛错

    func test_AT09_pluginMissingNameThrows() throws {
        // AT09: plugin 缺 name → decode throw
        let json = """
        {
          "description": "d",
          "version": "0.0.1",
          "author": {"name": "a"},
          "source": "./plugins/p"
        }
        """
        XCTAssertThrowsError(try decode(MarketplacePlugin.self, from: json))
    }

    // MARK: - AT10 MarketplacePlugin source 缺失抛错

    func test_AT10_pluginMissingSourceThrows() throws {
        // AT10: plugin 缺 source → decode throw
        let json = """
        {
          "name": "p",
          "description": "d",
          "version": "0.0.1",
          "author": {"name": "a"}
        }
        """
        XCTAssertThrowsError(try decode(MarketplacePlugin.self, from: json))
    }

    // MARK: - AT11 Bundle 内 translate plugin.json name == "translate"

    func test_AT11_translatePluginJSONNameMigrated() throws {
        // AT11: Bundle 内 translate plugin.json name 字段已迁移
        guard let url = Bundle.module.url(
            forResource: "plugin",
            withExtension: "json",
            subdirectory: "Marketplace/plugins/translate"
        ) else {
            XCTFail("translate plugin.json not found in Bundle.module")
            return
        }
        let data = try Data(contentsOf: url)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["name"] as? String, "translate")
    }

    // MARK: - AT12 Bundle 内 hello plugin.json name == "hello"

    func test_AT12_helloPluginJSONNameMigrated() throws {
        // AT12: Bundle 内 hello plugin.json name 字段已迁移
        guard let url = Bundle.module.url(
            forResource: "plugin",
            withExtension: "json",
            subdirectory: "Marketplace/plugins/hello"
        ) else {
            XCTFail("hello plugin.json not found in Bundle.module")
            return
        }
        let data = try Data(contentsOf: url)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["name"] as? String, "hello")
    }

    // MARK: - AT13 Equatable 行为

    func test_AT13_equatableBehavior() {
        // AT13: 相同字段 == true；不同 source 类型同 path != false
        let a = MarketplacePlugin(
            name: "p",
            description: "d",
            version: "0.0.1",
            category: nil,
            author: MarketplaceAuthor(name: "a", email: nil),
            source: .localSubdir(path: "/abs/p"),
            homepage: nil,
            editable: nil
        )
        let b = MarketplacePlugin(
            name: "p",
            description: "d",
            version: "0.0.1",
            category: nil,
            author: MarketplaceAuthor(name: "a", email: nil),
            source: .localSubdir(path: "/abs/p"),
            homepage: nil,
            editable: nil
        )
        XCTAssertEqual(a, b)

        // 不同 source case 同 path 应不等
        XCTAssertNotEqual(
            PluginSourceConfig.localSubdir(path: "/abs/p"),
            PluginSourceConfig.file(path: "/abs/p")
        )
    }

    // MARK: - AT14 encode 稳定性

    func test_AT14_encodeIsStable() throws {
        // AT14: 同一实例 encode 两次结果字节一致（影响 trust hash）
        let plugin = MarketplacePlugin(
            name: "translate",
            description: "中英互译助手",
            version: "0.1.0",
            category: "productivity",
            author: MarketplaceAuthor(name: "stringzhao", email: nil),
            source: .gitURL(url: "https://github.com/x/y.git", sha: "abc"),
            homepage: nil,
            editable: nil
        )
        let enc = canonicalEncoder()
        let d1 = try enc.encode(plugin)
        let d2 = try enc.encode(plugin)
        XCTAssertEqual(d1, d2)
    }

    // MARK: - AT15 localSubdir 简写不混淆 file

    func test_AT15_stringFormDecodesAsLocalSubdirNotFile() throws {
        // AT15: 裸字符串 "/abs/path" → .localSubdir（不是 .file）
        let json = "\"/abs/path\""
        let decoded = try decode(PluginSourceConfig.self, from: json)
        XCTAssertEqual(decoded, .localSubdir(path: "/abs/path"))

        if case .file = decoded {
            XCTFail("bare string must not decode as .file")
        }
    }
}
