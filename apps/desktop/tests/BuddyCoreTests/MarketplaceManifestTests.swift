import XCTest
@testable import BuddyCore

/// 蓝队单元测试：覆盖 MarketplaceManifest 各类型 Codable round-trip 与 PluginSourceConfig
/// 4 种形态 happy path。红队 acceptance 测试在 MarketplaceManifestAcceptanceTests 中单独覆盖
/// 端到端语义与错误路径，本文件只测实现细节。
final class MarketplaceManifestTests: XCTestCase {
    private let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return enc
    }()
    private let decoder = JSONDecoder()

    // MARK: - PluginSourceConfig 4 种形态 happy path

    func testPluginSourceConfig_localSubdir_roundTrip() throws {
        let original = PluginSourceConfig.localSubdir(path: "./plugins/translate")
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(PluginSourceConfig.self, from: data)
        XCTAssertEqual(decoded, original)
        // localSubdir 应编码为 JSON 单值字符串（顶层不是对象）。
        // 注意 JSONEncoder 默认会转义 "/"，所以这里直接断言能用 String container 再解出来。
        let asString = try JSONDecoder().decode(String.self, from: data)
        XCTAssertEqual(asString, "./plugins/translate")
    }

    func testPluginSourceConfig_gitSubdir_roundTrip() throws {
        let original = PluginSourceConfig.gitSubdir(
            url: "https://github.com/foo/bar.git",
            path: "plugins/translate",
            ref: "v1.0.0",
            sha: "abc123"
        )
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(PluginSourceConfig.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testPluginSourceConfig_gitURL_withSha_roundTrip() throws {
        let original = PluginSourceConfig.gitURL(url: "https://github.com/foo/bar.git", sha: "abc123")
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(PluginSourceConfig.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testPluginSourceConfig_gitURL_nilSha_roundTrip() throws {
        let original = PluginSourceConfig.gitURL(url: "https://github.com/foo/bar.git", sha: nil)
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(PluginSourceConfig.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testPluginSourceConfig_file_roundTrip() throws {
        let original = PluginSourceConfig.file(path: "/local/abs/path")
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(PluginSourceConfig.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - 各类型 Codable round-trip

    func testMarketplaceOwner_roundTrip() throws {
        let original = MarketplaceOwner(
            name: "stringzhao",
            email: "foo@example.com",
            homepage: "https://example.com"
        )
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(MarketplaceOwner.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testMarketplaceOwner_optionalsNil_roundTrip() throws {
        let original = MarketplaceOwner(name: "stringzhao", email: nil, homepage: nil)
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(MarketplaceOwner.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testMarketplaceAuthor_roundTrip() throws {
        let original = MarketplaceAuthor(name: "alice", email: "a@b.com")
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(MarketplaceAuthor.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testMarketplacePlugin_roundTrip() throws {
        let original = MarketplacePlugin(
            name: "translate",
            description: "中英互译助手",
            version: "0.1.0",
            category: "productivity",
            author: MarketplaceAuthor(name: "stringzhao", email: nil),
            source: .localSubdir(path: "./plugins/translate"),
            homepage: "https://example.com",
            editable: false
        )
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(MarketplacePlugin.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testMarketplaceManifest_roundTrip() throws {
        let original = MarketplaceManifest(
            schemaVersion: 1,
            name: "buddy-official",
            description: "Claude Code Buddy 官方插件目录",
            owner: MarketplaceOwner(name: "stringzhao", email: nil, homepage: nil),
            plugins: [
                MarketplacePlugin(
                    name: "hello",
                    description: "Hello world demo",
                    version: "0.1.0",
                    category: "example",
                    author: MarketplaceAuthor(name: "stringzhao", email: nil),
                    source: .localSubdir(path: "./plugins/hello"),
                    homepage: nil,
                    editable: nil
                )
            ]
        )
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(MarketplaceManifest.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
