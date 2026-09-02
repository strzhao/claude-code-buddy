import XCTest
@testable import BuddyCore
// 注：CLI mirror（CLIPluginManifestCheck）的双绑本欲经 @testable import `buddy-cli` 直读断言
//（场景6.P3），但 Swift 5.9 编译器不支持 import 带连字符的模块名（反引号语法解析失败），
// 此为编译器级限制。mirror 一致性改由 CLI 真实子进程路径（buddy launcher inspect，场景6.P4
// real-process）验收；mirror struct 已去 private（internal），保留该测试路径。

// MARK: - PluginManifestIconTests
//
// 契约 C-ICON-FIELD（state.md ## 契约规约）：
//   - plugin.json `icon` 可选字段（String emoji）。SOURCE OF TRUTH = BuddyCore PluginManifest。
//   - decode 一律 `decodeIfPresent ?? nil`，旧 plugin.json 缺字段不得导致整体 decode 失败。
//   - encode `encodeIfPresent`：icon nil 时不序列化（与 legacy 产物一致）。

@MainActor
final class PluginManifestIconTests: XCTestCase {

    // MARK: - decode

    /// 场景6.P2 [det-machine]：plugin.json 含 icon 字段 → decode 成功且 icon == emoji
    func test_decode_withIcon_readsEmoji() throws {
        let json = """
        {
          "name": "qr",
          "version": "0.2.0",
          "description": "二维码生成器",
          "keywords": ["qr", "二维码"],
          "mode": "command",
          "cmd": "./qr-gen.sh",
          "args": [],
          "icon": "🔗"
        }
        """
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
        XCTAssertEqual(manifest.icon, "🔗",
            "C-ICON-FIELD: 含 icon 字段的 plugin.json decode 后 icon 必须是 emoji 本体")
    }

    /// 场景6.P2 [det-machine]：plugin.json 缺 icon 字段 → 整体 decode 成功（向后兼容）且 icon == nil
    func test_decode_withoutIcon_succeedsAndIconNil() throws {
        let json = """
        {
          "name": "legacy",
          "version": "0.1.0",
          "description": "旧版插件（无 icon 字段）",
          "keywords": ["legacy"],
          "mode": "command",
          "cmd": "./run.sh",
          "args": []
        }
        """
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
        XCTAssertNil(manifest.icon,
            "C-ICON-FIELD: 缺 icon 字段 → icon == nil（decodeIfPresent ?? nil）")
        XCTAssertEqual(manifest.name, "legacy",
            "C-ICON-FIELD: 缺 icon 字段不得导致整体 decode 失败（name 应正常读出）")
    }

    /// icon 为 JSON null → 同缺字段语义（icon == nil，不抛错）
    func test_decode_iconNull_succeedsAndIconNil() throws {
        let json = """
        {
          "name": "null-icon",
          "version": "0.1.0",
          "description": "icon null",
          "keywords": ["n"],
          "mode": "command",
          "cmd": "./run.sh",
          "args": [],
          "icon": null
        }
        """
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
        XCTAssertNil(manifest.icon, "C-ICON-FIELD: icon null → icon == nil")
    }

    // MARK: - encode roundtrip

    /// encode 带 icon → JSON 含 icon 且 roundtrip 保留
    func test_encode_withIcon_roundtrips() throws {
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data("""
        {"name":"qzh","version":"0.1.0","description":"d","keywords":["qzh"],"mode":"command","cmd":"./x","args":[],"icon":"📡"}
        """.utf8))
        let data = try JSONEncoder().encode(manifest)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["icon"] as? String, "📡", "encode 带 icon → JSON 含 icon key")

        let decoded = try JSONDecoder().decode(PluginManifest.self, from: data)
        XCTAssertEqual(decoded.icon, "📡", "encode → decode roundtrip 保留 icon")
    }

    /// encode icon nil → 输出 JSON 不含 icon key（encodeIfPresent，与 legacy 产物一致）
    func test_encode_nilIcon_omitsKey() throws {
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data("""
        {"name":"noicon","version":"0.1.0","description":"d","keywords":["n"],"mode":"command","cmd":"./x","args":[]}
        """.utf8))
        XCTAssertNil(manifest.icon)
        let data = try JSONEncoder().encode(manifest)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(obj["icon"], "C-ICON-FIELD: icon nil 时不序列化 icon key")
    }

    // MARK: - CLI mirror 双绑（场景6.P3）

    /// 场景6.P3 的 BuddyCore 侧基线：SOURCE OF TRUTH decode 行为冻结（icon 读取）。
    /// mirror 侧（CLIPluginManifestCheck）因 import 连字符模块名编译器限制无法在同一
    /// XCTest 内直读断言，由 CLI 真实子进程（buddy launcher inspect）路径验收（场景6.P4）。
    func test_iconDecodeBaseline_sourceOfTruth() throws {
        let json = """
        {"name":"qr","version":"0.2.0","description":"d","keywords":["qr"],"mode":"command","cmd":"./x","args":[],"icon":"🔗"}
        """
        let core = try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
        XCTAssertEqual(core.icon, "🔗")
    }
}
