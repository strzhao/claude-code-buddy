import XCTest
@testable import BuddyCore

// MARK: - PluginManifestCommandModeTests
//
// 蓝队单测：PluginManifest 第三 mode —— command（T1）
//
// 契约引用（state.md ## 契约规约）：
//   enum PluginModeConfig { case stdin(StdinConfig); case prompt(PromptConfig); case command(CommandConfig) }
//   struct CommandConfig: Codable, Equatable { cmd, args, env, requiredPath }
//   validate .command 复用 stdin cmd 校验（禁绝对路径 / ..）
//   back-compat accessor cmd/args/env/requiredPath 覆盖 command mode
//
// TDD：本文件先于实现编写，最初编译失败（RED），实现后转 GREEN。

final class PluginManifestCommandModeTests: XCTestCase {

    // MARK: - Helpers

    private func decode(_ json: String) throws -> PluginManifest {
        let data = json.data(using: .utf8)!
        return try JSONDecoder().decode(PluginManifest.self, from: data)
    }

    private func baseFields(name: String = "test-command") -> String {
        """
        "name": "\(name)",
        "version": "0.1.0",
        "description": "command mode 测试",
        "keywords": ["cmd"]
        """
    }

    // MARK: - 场景 1：mode=command decode 成功，字段正确

    func test_commandMode_decode_success_fieldsEqual() throws {
        let json = """
        {
            \(baseFields()),
            "mode": "command",
            "cmd": "./qr-gen",
            "args": ["--level", "M"],
            "env": {"FOO": "bar"},
            "requiredPath": null
        }
        """
        let manifest = try decode(json)

        guard case .command(let cfg) = manifest.modeConfig else {
            return XCTFail("mode=command 应 decode 为 .command，实际: \(manifest.modeConfig)")
        }
        XCTAssertEqual(cfg.cmd, "./qr-gen", "cmd 必须正确")
        XCTAssertEqual(cfg.args, ["--level", "M"], "args 必须正确")
        XCTAssertEqual(cfg.env?["FOO"], "bar", "env 必须正确")
        XCTAssertNil(cfg.requiredPath, "requiredPath 缺省应为 nil")
    }

    // MARK: - 场景 2：command mode args/requiredPath 缺省兼容（旧格式社区插件）

    func test_commandMode_missingArgsAndRequiredPath_defaultsEmpty() throws {
        let json = """
        {
            \(baseFields()),
            "mode": "command",
            "cmd": "./run"
        }
        """
        let manifest = try decode(json)

        guard case .command(let cfg) = manifest.modeConfig else {
            return XCTFail("应 decode 为 .command，实际: \(manifest.modeConfig)")
        }
        XCTAssertEqual(cfg.args, [], "缺 args 字段应默认 []")
        XCTAssertNil(cfg.requiredPath, "缺 requiredPath 字段应默认 nil")
    }

    // MARK: - 场景 3：command mode encode round-trip

    func test_commandMode_encodeRoundTrip_equal() throws {
        let original = try decode("""
        {
            \(baseFields()),
            "mode": "command",
            "cmd": "./qr-gen",
            "args": ["--flag"],
            "env": {"KEY": "val"},
            "timeout": 15
        }
        """)

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PluginManifest.self, from: encoded)

        XCTAssertEqual(original, decoded, "command manifest encode→decode 应相等")
    }

    // MARK: - 场景 4：command mode validate 复用 stdin cmd 校验（绝对路径拒绝）

    func test_commandMode_validate_absolutePath_throws() throws {
        let manifest = try decode("""
        {
            \(baseFields()),
            "mode": "command",
            "cmd": "/usr/bin/evil"
        }
        """)
        XCTAssertThrowsError(try manifest.validate(againstDirName: "test-command")) { error in
            guard case LauncherError.pluginManifestInvalid(let reason) = error else {
                return XCTFail("应抛 pluginManifestInvalid，实际: \(error)")
            }
            XCTAssertTrue(reason.contains("绝对路径") || reason.contains("absolute"),
                          "应含绝对路径字样: \(reason)")
        }
    }

    // MARK: - 场景 5：command mode validate 复用 stdin cmd 校验（.. 路径拒绝）

    func test_commandMode_validate_dotDot_throws() throws {
        let manifest = try decode("""
        {
            \(baseFields()),
            "mode": "command",
            "cmd": "./../escape.sh"
        }
        """)
        XCTAssertThrowsError(try manifest.validate(againstDirName: "test-command")) { error in
            guard case LauncherError.pluginManifestInvalid(let reason) = error else {
                return XCTFail("应抛 pluginManifestInvalid，实际: \(error)")
            }
            XCTAssertTrue(reason.contains(".."), "应含 '..': \(reason)")
        }
    }

    // MARK: - 场景 6：command mode validate 合法相对路径通过

    func test_commandMode_validate_relativeCmdPath_passes() throws {
        let manifest = try decode("""
        {
            \(baseFields()),
            "mode": "command",
            "cmd": "./qr-gen"
        }
        """)
        XCTAssertNoThrow(try manifest.validate(againstDirName: "test-command"),
                         "合法相对 cmd 应通过 validate()")
    }

    // MARK: - 场景 7：command mode validate requiredPath 上限复用

    func test_commandMode_validate_requiredPathTooMany_throws() throws {
        let paths = (0...10).map { "bin\($0)" }  // 11 个
        let pathsJSON = "[" + paths.map { "\"\($0)\"" }.joined(separator: ",") + "]"
        let manifest = try decode("""
        {
            \(baseFields()),
            "mode": "command",
            "cmd": "./run",
            "requiredPath": \(pathsJSON)
        }
        """)
        XCTAssertThrowsError(try manifest.validate(againstDirName: "test-command")) { error in
            guard case LauncherError.pluginManifestInvalid(let reason) = error else {
                return XCTFail("应抛 pluginManifestInvalid，实际: \(error)")
            }
            XCTAssertTrue(reason.contains("11") || reason.contains("requiredPath"),
                          "应含 11 或 requiredPath: \(reason)")
        }
    }

    // MARK: - 场景 8：back-compat accessor 覆盖 command mode

    func test_commandMode_backCompatAccessors_returnCommandValues() throws {
        let manifest = try decode("""
        {
            \(baseFields()),
            "mode": "command",
            "cmd": "./qr-gen",
            "args": ["--x"],
            "env": {"A": "1"},
            "requiredPath": ["/usr/bin/git"]
        }
        """)
        XCTAssertEqual(manifest.cmd, "./qr-gen", "back-compat .cmd 应返回 command 的值")
        XCTAssertEqual(manifest.args, ["--x"], "back-compat .args 应返回 command 的值")
        XCTAssertEqual(manifest.env?["A"], "1", "back-compat .env 应返回 command 的值")
        XCTAssertEqual(manifest.requiredPath, ["/usr/bin/git"], "back-compat .requiredPath 应返回 command 的值")
        XCTAssertNil(manifest.stdinConfig, "command manifest .stdinConfig 应为 nil")
        XCTAssertNil(manifest.promptConfig, "command manifest .promptConfig 应为 nil")
        XCTAssertNotNil(manifest.commandConfig, "command manifest .commandConfig 应非 nil")
    }

    // MARK: - 场景 9：stdin/prompt mode 的 commandConfig 应为 nil（不串扰）

    func test_stdinMode_commandConfig_isNil() throws {
        let manifest = try decode("""
        {
            \(baseFields()),
            "mode": "stdin",
            "cmd": "./run.sh"
        }
        """)
        XCTAssertNil(manifest.commandConfig, "stdin mode .commandConfig 应为 nil")
        XCTAssertNotNil(manifest.stdinConfig, "stdin mode .stdinConfig 应非 nil")
    }
}
