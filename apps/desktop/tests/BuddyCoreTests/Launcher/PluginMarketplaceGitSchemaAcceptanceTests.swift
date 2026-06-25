import XCTest
@testable import BuddyCore

// MARK: - PluginMarketplaceGitSchemaAcceptanceTests
//
// 红队验收测试（社区插件 git 化，2026-06-24）
//
// 覆盖契约：C1（marketplace.json schema 对齐）+ B3（缺必填字段 decode 失败）+ C1 summary 字段语义
// 覆盖谓词：B3 / C1 的 schema 校验部分
//
// 红队红线：不读 MarketplaceManifest 实现，仅依据 state.md 设计文档的 marketplace.json
// schema 样例（顶层 schemaVersion/name/owner，每个 plugin 必填 name/description/version/author/source，
// **不含 summary**）黑盒断言。
//
// 契约逐字（C1）：
//   - 顶层必填：schemaVersion / name / owner
//   - 每个 plugin 必填：name / description / version / author / source
//   - **不含 summary**（summary 是 plugin.json 字段，不在 marketplace.json）
//   - source=gitSubdir 不填 sha 仅 ref

final class PluginMarketplaceGitSchemaAcceptanceTests: XCTestCase {

    private func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    /// 完整合法的 monorepo marketplace.json（对齐设计文档样例，3 个官方插件）
    private func validMonorepoJSON() -> String {
        """
        {
          "schemaVersion": 1,
          "name": "buddy-official",
          "description": "Claude Code Buddy 官方插件目录",
          "owner": {"name": "stringzhao", "homepage": "https://github.com/stringzhao"},
          "plugins": [
            {"name":"hello","version":"0.1.0","description":"演示插件协议的入门示例","category":"example","author":{"name":"stringzhao"},"source":{"source":"git-subdir","url":"https://github.com/stringzhao/buddy-official-plugins","path":"plugins/hello","ref":"main"}},
            {"name":"qr","version":"0.1.0","description":"生成二维码图片并复制到剪贴板","category":"utility","author":{"name":"stringzhao"},"source":{"source":"git-subdir","url":"https://github.com/stringzhao/buddy-official-plugins","path":"plugins/qr","ref":"main"}},
            {"name":"qzh","version":"0.1.0","description":"查询并开关 QzhddrSrv 监控服务","category":"utility","author":{"name":"stringzhao"},"source":{"source":"git-subdir","url":"https://github.com/stringzhao/buddy-official-plugins","path":"plugins/qzh","ref":"main"}}
          ]
        }
        """
    }

    // MARK: - B3/C1: 完整合法 marketplace.json 能 decode

    /// 基线：设计文档样例的完整 marketplace.json 必须 decode 成功，3 个官方插件齐全。
    func test_C1_validMonorepoManifest_decodesWithThreePlugins() throws {
        let manifest = try decode(MarketplaceManifest.self, from: validMonorepoJSON())

        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.name, "buddy-official")
        XCTAssertEqual(manifest.plugins.count, 3, "monorepo 含 hello/qr/qzh 三个官方插件")

        let names = manifest.plugins.map(\.name).sorted()
        XCTAssertEqual(names, ["hello", "qr", "qzh"], "三个官方插件 name 必须齐全")

        // 所有 source 都是 gitSubdir 且不填 sha（C1/C1.1）
        for plugin in manifest.plugins {
            guard case .gitSubdir(let url, let path, let ref, let sha) = plugin.source else {
                return XCTFail("\(plugin.name) source 必须为 gitSubdir（C1 monorepo）")
            }
            XCTAssertTrue(url.contains("buddy-official-plugins"),
                          "\(plugin.name) url 必须指向 monorepo")
            XCTAssertTrue(path.hasPrefix("plugins/"),
                          "\(plugin.name) path 必须为 plugins/<name>")
            XCTAssertEqual(ref, "main", "\(plugin.name) ref 必须为 main")
            XCTAssertNil(sha, "\(plugin.name) gitSubdir 不填 sha（C1.1）")
        }
    }

    // MARK: - B3: plugin 缺 description → decode 失败

    /// 契约 C1：每个 plugin 必填 description。缺则 decode 失败。
    func test_B3_pluginMissingDescription_decodeFails() throws {
        let json = """
        {
          "schemaVersion": 1,
          "name": "buddy-official",
          "owner": {"name": "stringzhao"},
          "plugins": [
            {"name":"hello","version":"0.1.0","author":{"name":"x"},"source":"./plugins/hello"}
          ]
        }
        """
        XCTAssertThrowsError(try decode(MarketplaceManifest.self, from: json),
                             "plugin 缺 description 必须 decode 失败（C1 必填）")
    }

    // MARK: - B3: plugin 缺 author → decode 失败

    /// 契约 C1：每个 plugin 必填 author。缺则 decode 失败。
    func test_B3_pluginMissingAuthor_decodeFails() throws {
        let json = """
        {
          "schemaVersion": 1,
          "name": "buddy-official",
          "owner": {"name": "stringzhao"},
          "plugins": [
            {"name":"hello","version":"0.1.0","description":"d","source":"./plugins/hello"}
          ]
        }
        """
        XCTAssertThrowsError(try decode(MarketplaceManifest.self, from: json),
                             "plugin 缺 author 必须 decode 失败（C1 必填）")
    }

    // MARK: - B3: plugin 缺 version → decode 失败

    /// 契约 C1：每个 plugin 必填 version。缺则 decode 失败。
    func test_B3_pluginMissingVersion_decodeFails() throws {
        let json = """
        {
          "schemaVersion": 1,
          "name": "buddy-official",
          "owner": {"name": "stringzhao"},
          "plugins": [
            {"name":"hello","description":"d","author":{"name":"x"},"source":"./plugins/hello"}
          ]
        }
        """
        XCTAssertThrowsError(try decode(MarketplaceManifest.self, from: json),
                             "plugin 缺 version 必须 decode 失败（C1 必填）")
    }

    // MARK: - B3: plugin 缺 name → decode 失败

    /// 契约 C1：每个 plugin 必填 name。缺则 decode 失败。
    func test_B3_pluginMissingName_decodeFails() throws {
        let json = """
        {
          "schemaVersion": 1,
          "name": "buddy-official",
          "owner": {"name": "stringzhao"},
          "plugins": [
            {"description":"d","version":"0.1.0","author":{"name":"x"},"source":"./plugins/hello"}
          ]
        }
        """
        XCTAssertThrowsError(try decode(MarketplaceManifest.self, from: json),
                             "plugin 缺 name 必须 decode 失败（C1 必填）")
    }

    // MARK: - B3: plugin 缺 source → decode 失败

    /// 契约 C1：每个 plugin 必填 source。缺则 decode 失败。
    func test_B3_pluginMissingSource_decodeFails() throws {
        let json = """
        {
          "schemaVersion": 1,
          "name": "buddy-official",
          "owner": {"name": "stringzhao"},
          "plugins": [
            {"name":"hello","description":"d","version":"0.1.0","author":{"name":"x"}}
          ]
        }
        """
        XCTAssertThrowsError(try decode(MarketplaceManifest.self, from: json),
                             "plugin 缺 source 必须 decode 失败（C1 必填）")
    }

    // MARK: - B3: 顶层缺 schemaVersion → decode 失败

    /// 契约 C1：顶层必填 schemaVersion。缺则 decode 失败。
    func test_B3_topLevelMissingSchemaVersion_decodeFails() throws {
        let json = """
        {
          "name": "buddy-official",
          "owner": {"name": "stringzhao"},
          "plugins": []
        }
        """
        XCTAssertThrowsError(try decode(MarketplaceManifest.self, from: json),
                             "顶层缺 schemaVersion 必须 decode 失败（C1 必填）")
    }

    // MARK: - B3: 顶层缺 owner → decode 失败

    /// 契约 C1：顶层必填 owner。缺则 decode 失败。
    func test_B3_topLevelMissingOwner_decodeFails() throws {
        let json = """
        {
          "schemaVersion": 1,
          "name": "buddy-official",
          "plugins": []
        }
        """
        XCTAssertThrowsError(try decode(MarketplaceManifest.self, from: json),
                             "顶层缺 owner 必须 decode 失败（C1 必填）")
    }

    // MARK: - B3: 顶层缺 name → decode 失败

    /// 契约 C1：顶层必填 name。缺则 decode 失败。
    func test_B3_topLevelMissingName_decodeFails() throws {
        let json = """
        {
          "schemaVersion": 1,
          "owner": {"name": "stringzhao"},
          "plugins": []
        }
        """
        XCTAssertThrowsError(try decode(MarketplaceManifest.self, from: json),
                             "顶层缺 name 必须 decode 失败（C1 必填）")
    }

    // MARK: - C1: marketplace.json 含 summary 字段时 decode 不报错（多余字段被忽略）

    /// 契约 C1：marketplace.json **不含 summary**（summary 是 plugin.json 字段）。
    /// 但若误传了 summary，Codable 默认应忽略未知键，**不报错**（宽容多余字段）。
    /// 此测试守护「summary 不在 marketplace.json schema」的同时，确认 decode 不因多余字段崩溃。
    func test_C1_marketplaceJSON_withExtraSummaryField_decodesWithoutError() throws {
        let json = """
        {
          "schemaVersion": 1,
          "name": "buddy-official",
          "owner": {"name": "stringzhao"},
          "plugins": [
            {"name":"hello","version":"0.1.0","description":"d","author":{"name":"x"},"source":"./plugins/hello","summary":"多余字段不应导致 decode 失败"}
          ]
        }
        """
        // 多余的 summary 字段应被 Codable 忽略，decode 成功
        let manifest = try decode(MarketplaceManifest.self, from: json)
        XCTAssertEqual(manifest.plugins.count, 1)
        XCTAssertEqual(manifest.plugins.first?.name, "hello")

        // 关键：MarketplacePlugin 的 summary 不应被填充（marketplace.json 无此字段语义）
        // 注：若 MarketplacePlugin 类型本身无 summary 属性，此断言通过类型系统保证；
        // 若有，则应为 nil（marketplace.json 不该携带，但携带了也不崩）。
    }

    // MARK: - C1: MarketplacePlugin schema 不含 summary 字段（类型契约）

    /// 契约 C1：MarketplacePlugin 的 schema **不含 summary**。
    /// 本测试通过构造合法 MarketplacePlugin 实例（不传 summary），验证类型本身不强制 summary。
    /// summary 是 plugin.json（PluginManifest）的字段，不是 marketplace.json（MarketplacePlugin）的。
    func test_C1_marketplacePlugin_initWithoutSummary_succeeds() {
        // MarketplacePlugin 构造不含 summary 参数（C1：summary 在 plugin.json 不在 marketplace.json）
        let plugin = MarketplacePlugin(
            name: "schema-test",
            description: "测试 schema",
            version: "0.1.0",
            category: nil,
            author: MarketplaceAuthor(name: "tester", email: nil),
            source: .gitSubdir(
                url: "https://github.com/stringzhao/buddy-official-plugins",
                path: "plugins/hello",
                ref: "main",
                sha: nil
            ),
            homepage: nil,
            editable: nil
        )
        XCTAssertEqual(plugin.name, "schema-test")
        XCTAssertEqual(plugin.version, "0.1.0")
        XCTAssertEqual(plugin.description, "测试 schema")
    }
}
