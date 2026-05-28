import XCTest
@testable import BuddyCore

// MARK: - PluginManifestModeDiscriminatedUnionAcceptanceTests
//
// 红队验收测试：PluginManifest mode discriminated union 全契约覆盖（12 个场景）
//
// 设计文档引用：
//   .autopilot/runtime/sessions/translate/requirements/20260528-002-manifest-discriminated-uni/state.md
//   .autopilot/project/tasks/002-manifest-discriminated-union.md
//
// 黑盒原则：仅通过公开 Codable API + validate() 验证契约，不依赖内部实现细节。
// 测试 WILL NOT compile 直到蓝队实现完成 — 这是预期的 TDD 红灯。
//
// ⚠️ 铁律：本文件由红队独立编写，未读取蓝队实现代码（PluginManifest.swift 等）。

final class PluginManifestModeDiscriminatedUnionAcceptanceTests: XCTestCase {

    // MARK: - Fixture helpers

    /// 构造合法的公共字段（name/version/description/keywords）
    private func baseFields(name: String = "test-plugin") -> String {
        """
        "name": "\(name)",
        "version": "0.1.0",
        "description": "test plugin",
        "keywords": []
        """
    }

    private func decode(_ json: String) throws -> PluginManifest {
        let data = json.data(using: .utf8)!
        return try JSONDecoder().decode(PluginManifest.self, from: data)
    }

    // MARK: - 场景 1：旧格式向后兼容（无 mode 字段 → stdin case）
    //
    // 契约引用：state.md "决策 2：自定义 Codable decoder" - 缺 mode 字段默认 stdin；
    //           验证方案场景 1；brief 验收标准 3

    func test_backwardCompat_noModeField_decodesAsStdin() throws {
        let json = """
        {
            \(baseFields()),
            "cmd": "./run.sh",
            "args": ["--verbose"],
            "env": {"FOO": "bar"},
            "requiredPath": ["/usr/bin/git"]
        }
        """
        let manifest = try decode(json)

        // 必须 decode 为 stdin case
        guard case .stdin(let cfg) = manifest.modeConfig else {
            return XCTFail("无 mode 字段应默认 decode 为 .stdin，实际: \(manifest.modeConfig)")
        }
        XCTAssertEqual(cfg.cmd, "./run.sh", "cmd 字段必须正确读取")
        XCTAssertEqual(cfg.args, ["--verbose"], "args 字段必须正确读取")
        XCTAssertEqual(cfg.env?["FOO"], "bar", "env 字段必须正确读取")
        XCTAssertEqual(cfg.requiredPath, ["/usr/bin/git"], "requiredPath 字段必须正确读取")
    }

    // MARK: - 场景 2：新 stdin mode 显式声明
    //
    // 契约引用：state.md "决策 5：HelloPlugin/plugin.json 加 mode 字段"；
    //           验证方案场景 2；brief 验收标准 2

    func test_explicitStdinMode_decodesCorrectly() throws {
        let json = """
        {
            \(baseFields()),
            "mode": "stdin",
            "cmd": "./hello.sh",
            "args": []
        }
        """
        let manifest = try decode(json)

        guard case .stdin(let cfg) = manifest.modeConfig else {
            return XCTFail("mode=stdin 应 decode 为 .stdin，实际: \(manifest.modeConfig)")
        }
        XCTAssertEqual(cfg.cmd, "./hello.sh", "cmd 字段必须正确")
        XCTAssertEqual(cfg.args, [], "args 字段必须正确")
    }

    // MARK: - 场景 3：新 prompt mode 解析（maxIterations 默认 1，model 默认 nil）
    //
    // 契约引用：state.md "决策 2：自定义 Codable decoder" - prompt case；
    //           验证方案场景 3；brief 验收标准 4

    func test_promptMode_decodesWithDefaults() throws {
        let json = """
        {
            \(baseFields()),
            "mode": "prompt",
            "systemPrompt": "你是翻译助手"
        }
        """
        let manifest = try decode(json)

        guard case .prompt(let cfg) = manifest.modeConfig else {
            return XCTFail("mode=prompt 应 decode 为 .prompt，实际: \(manifest.modeConfig)")
        }
        XCTAssertEqual(cfg.systemPrompt, "你是翻译助手", "systemPrompt 必须正确")
        XCTAssertEqual(cfg.maxIterations, 1, "maxIterations 缺省时应默认为 1")
        XCTAssertNil(cfg.model, "model 缺省时应默认为 nil")
    }

    // MARK: - 场景 4：unknown mode 报错抛 pluginManifestInvalid
    //
    // 契约引用：state.md "决策 2" - default: throw LauncherError.pluginManifestInvalid("unknown mode: \(mode)")；
    //           验证方案场景 4；brief 验收标准 5

    func test_unknownMode_throwsPluginManifestInvalid() throws {
        let json = """
        {
            \(baseFields()),
            "mode": "agent",
            "cmd": "./run.sh"
        }
        """
        XCTAssertThrowsError(try decode(json)) { error in
            guard case LauncherError.pluginManifestInvalid(let reason) = error else {
                return XCTFail("应抛 LauncherError.pluginManifestInvalid，实际: \(error)")
            }
            XCTAssertTrue(
                reason.lowercased().contains("unknown mode"),
                "错误信息必须含 \"unknown mode\"，实际: \(reason)"
            )
        }
    }

    // MARK: - 场景 5：【最高优先级】prompt mode validate() 跳过 cmd 校验
    //
    // 契约引用：state.md "决策 3：mode-aware validate()" - prompt case 跳过 cmd 校验；
    //           验证方案场景 5（最高优先级）；brief 验收标准 1

    func test_promptMode_validate_doesNotThrowCmdErrors() throws {
        let json = """
        {
            \(baseFields()),
            "mode": "prompt",
            "systemPrompt": "你是助手",
            "maxIterations": 1
        }
        """
        let manifest = try decode(json)

        // prompt mode 无 cmd 字段，validate 不应因缺少 cmd 而抛错
        XCTAssertNoThrow(
            try manifest.validate(againstDirName: "test-plugin"),
            "prompt mode validate() 不应抛 cmd 相关错误（prompt mode 无 cmd 字段）"
        )
    }

    // MARK: - 场景 6a：prompt systemPrompt 空字符串拒绝
    //
    // 契约引用：state.md "决策 3：mode-aware validate()" - 非空校验；
    //           验证方案场景 6；brief 验收标准 6

    func test_promptMode_validate_emptySystemPrompt_throws() throws {
        let json = """
        {
            \(baseFields()),
            "mode": "prompt",
            "systemPrompt": "",
            "maxIterations": 1
        }
        """
        let manifest = try decode(json)

        XCTAssertThrowsError(try manifest.validate(againstDirName: "test-plugin")) { error in
            guard case LauncherError.pluginManifestInvalid(let reason) = error else {
                return XCTFail("应抛 pluginManifestInvalid，实际: \(error)")
            }
            XCTAssertTrue(
                reason.contains("systemPrompt") || reason.contains("不能为空"),
                "错误信息必须含 systemPrompt 或 不能为空 字样，实际: \(reason)"
            )
        }
    }

    // MARK: - 场景 6b：prompt systemPrompt 超过 8192 bytes 拒绝
    //
    // 契约引用：state.md "LauncherConstants: promptMaxSystemPromptBytes = 8192"；
    //           验证方案场景 6；brief 验收标准 6

    func test_promptMode_validate_systemPromptExceeds8KB_throws() throws {
        // 9KB 字符串（ASCII，1 char = 1 byte）
        let nineKB = String(repeating: "a", count: 9 * 1024)
        let json = """
        {
            \(baseFields()),
            "mode": "prompt",
            "systemPrompt": "\(nineKB)",
            "maxIterations": 1
        }
        """
        let manifest = try decode(json)

        XCTAssertThrowsError(try manifest.validate(againstDirName: "test-plugin")) { error in
            guard case LauncherError.pluginManifestInvalid(let reason) = error else {
                return XCTFail("应抛 pluginManifestInvalid，实际: \(error)")
            }
            XCTAssertTrue(
                reason.contains("8192") || reason.contains("超过"),
                "错误信息必须含 8192 或 超过 字样，实际: \(reason)"
            )
        }
    }

    // MARK: - 场景 6c：prompt systemPrompt 恰好 8KB 通过
    //
    // 契约引用：state.md "promptMaxSystemPromptBytes = 8192" 边界值（等于允许）；
    //           验证方案场景 6

    func test_promptMode_validate_systemPromptExactly8KB_passes() throws {
        // 恰好 8192 bytes（ASCII）
        let exactly8KB = String(repeating: "a", count: 8192)
        let json = """
        {
            \(baseFields()),
            "mode": "prompt",
            "systemPrompt": "\(exactly8KB)",
            "maxIterations": 1
        }
        """
        let manifest = try decode(json)

        XCTAssertNoThrow(
            try manifest.validate(againstDirName: "test-plugin"),
            "systemPrompt 恰好 8192 bytes 应通过 validate()"
        )
    }

    // MARK: - 场景 7：prompt maxIterations 边界
    //
    // 契约引用：state.md "promptMaxIterations = 10"，范围 [1, 10]；
    //           验证方案场景 7

    func test_promptMode_validate_maxIterationsBoundaries() throws {
        // 0 拒绝
        let manifestZero = try decode("""
        { \(baseFields()), "mode": "prompt", "systemPrompt": "x", "maxIterations": 0 }
        """)
        XCTAssertThrowsError(
            try manifestZero.validate(againstDirName: "test-plugin"),
            "maxIterations=0 应抛错"
        ) { error in
            XCTAssertTrue(error is LauncherError, "应是 LauncherError，实际: \(error)")
        }

        // 11 拒绝
        let manifestEleven = try decode("""
        { \(baseFields()), "mode": "prompt", "systemPrompt": "x", "maxIterations": 11 }
        """)
        XCTAssertThrowsError(
            try manifestEleven.validate(againstDirName: "test-plugin"),
            "maxIterations=11 应抛错"
        ) { error in
            XCTAssertTrue(error is LauncherError, "应是 LauncherError，实际: \(error)")
        }

        // 1 通过
        let manifestOne = try decode("""
        { \(baseFields()), "mode": "prompt", "systemPrompt": "x", "maxIterations": 1 }
        """)
        XCTAssertNoThrow(
            try manifestOne.validate(againstDirName: "test-plugin"),
            "maxIterations=1 应通过"
        )

        // 10 通过
        let manifestTen = try decode("""
        { \(baseFields()), "mode": "prompt", "systemPrompt": "x", "maxIterations": 10 }
        """)
        XCTAssertNoThrow(
            try manifestTen.validate(againstDirName: "test-plugin"),
            "maxIterations=10 应通过"
        )
    }

    // MARK: - 场景 8：stdin validate 行为保留（cmd 绝对路径 / ".." 路径规则不变）
    //
    // 契约引用：state.md "决策 3" - stdin case 校验 cmd 绝对路径/..；
    //           验证方案场景 8；brief 验收标准 7

    func test_stdinMode_validate_cmdAbsolutePath_throws() throws {
        let json = """
        {
            \(baseFields()),
            "mode": "stdin",
            "cmd": "/usr/bin/x"
        }
        """
        let manifest = try decode(json)

        XCTAssertThrowsError(try manifest.validate(againstDirName: "test-plugin")) { error in
            guard case LauncherError.pluginManifestInvalid(let reason) = error else {
                return XCTFail("应抛 pluginManifestInvalid，实际: \(error)")
            }
            XCTAssertTrue(
                reason.contains("绝对路径") || reason.contains("absolute"),
                "错误信息必须含 绝对路径 字样，实际: \(reason)"
            )
        }
    }

    func test_stdinMode_validate_cmdDotDotPath_throws() throws {
        let json = """
        {
            \(baseFields()),
            "mode": "stdin",
            "cmd": "./../escape.sh"
        }
        """
        let manifest = try decode(json)

        XCTAssertThrowsError(try manifest.validate(againstDirName: "test-plugin")) { error in
            guard case LauncherError.pluginManifestInvalid(let reason) = error else {
                return XCTFail("应抛 pluginManifestInvalid，实际: \(error)")
            }
            XCTAssertTrue(
                reason.contains(".."),
                "错误信息必须含 '..'，实际: \(reason)"
            )
        }
    }

    func test_stdinMode_validate_relativeCmdPath_passes() throws {
        let json = """
        {
            \(baseFields()),
            "mode": "stdin",
            "cmd": "./hello.sh"
        }
        """
        let manifest = try decode(json)

        XCTAssertNoThrow(
            try manifest.validate(againstDirName: "test-plugin"),
            "cmd=./hello.sh（合法相对路径）应通过 validate()"
        )
    }

    // MARK: - 场景 9：Encode round-trip（stdin）
    //
    // 契约引用：state.md "决策 2：自定义 encoder - encode 后再 decode 应得相同值"；
    //           验证方案场景 9

    func test_stdinManifest_encodeRoundTrip_fieldsEqual() throws {
        let original = try decode("""
        {
            \(baseFields()),
            "mode": "stdin",
            "cmd": "./run.sh",
            "args": ["--flag"],
            "env": {"KEY": "val"},
            "requiredPath": null,
            "timeout": 15
        }
        """)

        let encoder = JSONEncoder()
        let encoded = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(PluginManifest.self, from: encoded)

        XCTAssertEqual(original, decoded, "stdin manifest encode→decode 应得相同值（Equatable）")
    }

    // MARK: - 场景 10：Encode round-trip（prompt）
    //
    // 契约引用：state.md "决策 2：encoder 严格按 mode 分支"；
    //           验证方案场景 10

    func test_promptManifest_encodeRoundTrip_fieldsEqual() throws {
        let original = try decode("""
        {
            \(baseFields()),
            "mode": "prompt",
            "systemPrompt": "你是中英互译助手",
            "maxIterations": 3,
            "model": "qwen2.5:7b"
        }
        """)

        let encoder = JSONEncoder()
        let encoded = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(PluginManifest.self, from: encoded)

        XCTAssertEqual(original, decoded, "prompt manifest encode→decode 应得相同值（Equatable）")
    }

    // MARK: - 场景 11：Back-compat accessor（stdin 返回正确值，prompt 返回空值兜底）
    //
    // 契约引用：state.md "决策 4：向后兼容 accessors"；
    //           验证方案场景 11

    func test_backCompatAccessors_stdinManifest_returnsCorrectValues() throws {
        let json = """
        {
            \(baseFields()),
            "mode": "stdin",
            "cmd": "./run.sh",
            "args": ["--arg1"],
            "env": {"A": "1"},
            "requiredPath": ["/usr/bin/git"]
        }
        """
        let manifest = try decode(json)

        XCTAssertEqual(manifest.cmd, "./run.sh", "stdin manifest .cmd 应返回正确值")
        XCTAssertEqual(manifest.args, ["--arg1"], "stdin manifest .args 应返回正确值")
        XCTAssertEqual(manifest.env?["A"], "1", "stdin manifest .env 应返回正确值")
        XCTAssertEqual(manifest.requiredPath, ["/usr/bin/git"], "stdin manifest .requiredPath 应返回正确值")
        XCTAssertNotNil(manifest.stdinConfig, "stdin manifest .stdinConfig 应非 nil")
        XCTAssertNil(manifest.promptConfig, "stdin manifest .promptConfig 应为 nil")
    }

    func test_backCompatAccessors_promptManifest_returnsEmptyFallbacks() throws {
        let json = """
        {
            \(baseFields()),
            "mode": "prompt",
            "systemPrompt": "x",
            "maxIterations": 1
        }
        """
        let manifest = try decode(json)

        XCTAssertEqual(manifest.cmd, "", "prompt manifest .cmd 应返回空字符串（back-compat 兜底）")
        XCTAssertEqual(manifest.args, [], "prompt manifest .args 应返回空数组（back-compat 兜底）")
        XCTAssertNil(manifest.env, "prompt manifest .env 应返回 nil（back-compat 兜底）")
        XCTAssertNil(manifest.requiredPath, "prompt manifest .requiredPath 应返回 nil（back-compat 兜底）")
        XCTAssertNil(manifest.stdinConfig, "prompt manifest .stdinConfig 应为 nil")
        XCTAssertNotNil(manifest.promptConfig, "prompt manifest .promptConfig 应非 nil")
    }

    // MARK: - 场景 12：stdin JSON 缺 args 字段兼容（旧格式社区插件兼容）
    //
    // 契约引用：state.md "plan-reviewer 建议 3：StdinConfig.args decodeIfPresent ?? []"；
    //           验证方案场景 12；state.md 变更日志"新增红队场景 12"

    func test_stdinMode_missingArgsField_decodesSuccessfully() throws {
        let json = """
        {
            \(baseFields()),
            "mode": "stdin",
            "cmd": "./run.sh"
        }
        """
        // 不应抛 DecodingError（args 字段缺失）
        let manifest = try decode(json)

        guard case .stdin(let cfg) = manifest.modeConfig else {
            return XCTFail("应 decode 为 .stdin，实际: \(manifest.modeConfig)")
        }
        XCTAssertEqual(cfg.args, [], "缺失 args 字段时应默认为空数组 []")
    }
}
