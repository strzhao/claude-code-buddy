import XCTest
@testable import BuddyCore

// MARK: - SnipFrameworkExtensionsTests
//
// 蓝队单测：T0 框架扩展（snip 插件需求驱动）
//   扩展 A（command autoCopy）：CommandConfig.autoCopyToClipboard
//
// 契约引用（state.md ## 契约规约）：
//   C3 autoCopy（扩展 A）：command mode + autoCopyToClipboard:true → 框架代写剪贴板
//
// 注：扩展 B（rawToolInput 透传）已随 snip-mgr LLM 路线退场移除（T5 / C8 清理），
//     相关场景 8-13 已删除，本文件仅保留扩展 A 场景 1-7。

final class SnipFrameworkExtensionsTests: XCTestCase {

    // MARK: - 扩展 A：CommandConfig.autoCopyToClipboard

    private func decode(_ json: String) throws -> PluginManifest {
        let data = json.data(using: .utf8)!
        return try JSONDecoder().decode(PluginManifest.self, from: data)
    }

    private func baseFields(name: String = "test-snip") -> String {
        """
        "name": "\(name)",
        "version": "0.1.0",
        "description": "snip test",
        "keywords": ["snip"]
        """
    }

    // 场景 1：command mode 声明 autoCopyToClipboard:true → decode 正确
    func test_commandMode_autoCopyTrue_decode_success() throws {
        let json = """
        {
            \(baseFields()),
            "mode": "command",
            "cmd": "./snip.sh",
            "autoCopyToClipboard": true
        }
        """
        let manifest = try decode(json)
        guard case .command(let cfg) = manifest.modeConfig else {
            return XCTFail("应 decode 为 .command")
        }
        XCTAssertTrue(cfg.autoCopyToClipboard, "autoCopyToClipboard 应为 true")
        XCTAssertTrue(manifest.autoCopyToClipboard, "便利属性应返回 true")
    }

    // 场景 2：command mode 缺 autoCopyToClipboard 字段（旧 plugin.json）→ 默认 false（向后兼容）
    func test_commandMode_missingAutoCopy_defaultsFalse() throws {
        let json = """
        {
            \(baseFields()),
            "mode": "command",
            "cmd": "./snip.sh"
        }
        """
        let manifest = try decode(json)
        guard case .command(let cfg) = manifest.modeConfig else {
            return XCTFail("应 decode 为 .command")
        }
        XCTAssertFalse(cfg.autoCopyToClipboard, "缺字段应默认 false（向后兼容）")
        XCTAssertFalse(manifest.autoCopyToClipboard, "便利属性应返回 false")
    }

    // 场景 3：command mode autoCopy=false 显式 → 正确
    func test_commandMode_autoCopyFalse_explicit() throws {
        let json = """
        {
            \(baseFields()),
            "mode": "command",
            "cmd": "./snip.sh",
            "autoCopyToClipboard": false
        }
        """
        let manifest = try decode(json)
        XCTAssertFalse(manifest.autoCopyToClipboard, "显式 false 应返回 false")
    }

    // 场景 4：command mode round-trip（encode→decode 相等，含 autoCopy=true）
    func test_commandMode_autoCopyTrue_roundTrip() throws {
        let original = try decode("""
        {
            \(baseFields()),
            "mode": "command",
            "cmd": "./snip.sh",
            "autoCopyToClipboard": true
        }
        """)
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PluginManifest.self, from: encoded)
        XCTAssertEqual(original, decoded, "含 autoCopy=true 的 command manifest round-trip 应相等")
    }

    // 场景 5：autoCopy=false 时 encode 不输出该字段（保持与 legacy 产物一致）
    func test_commandMode_autoCopyFalse_encodeOmitsField() throws {
        let manifest = try decode("""
        {
            \(baseFields()),
            "mode": "command",
            "cmd": "./snip.sh"
        }
        """)
        let encoded = try JSONEncoder().encode(manifest)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(json.contains("\"autoCopyToClipboard\""),
                       "autoCopy=false 时不应 encode 该字段（保持与 legacy 产物一致）: \(json)")
    }

    // 场景 6：stdin mode 的 autoCopyToClipboard 便利属性返回 false（不串扰）
    func test_stdinMode_autoCopy_returnsFalse() throws {
        let manifest = try decode("""
        {
            \(baseFields()),
            "mode": "stdin",
            "cmd": "./run.sh"
        }
        """)
        XCTAssertFalse(manifest.autoCopyToClipboard, "stdin mode autoCopy 应为 false")
    }

    // 场景 7：prompt mode 的 autoCopyToClipboard 便利属性仍正确（不破坏现有）
    func test_promptMode_autoCopy_returnsDeclared() throws {
        let manifest = try decode("""
        {
            \(baseFields()),
            "mode": "prompt",
            "systemPrompt": "you are helpful",
            "autoCopyToClipboard": true
        }
        """)
        XCTAssertTrue(manifest.autoCopyToClipboard, "prompt mode autoCopy 应返回声明值 true")
    }
}
