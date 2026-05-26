import XCTest
@testable import BuddyCore

// MARK: - PluginManifestAcceptanceTests
//
// 验收测试：PluginManifest Codable 数据契约 + validate 字段校验
//
// 设计文档覆盖点（task 004 输出契约）：
//   A. Codable round-trip：完整 fixture（含所有可选字段）编解码相等
//   B. 最简 fixture：只含 7 个必填字段 + 可选字段均为 null
//   C. validate 5 个反例：每个必须抛 LauncherError.pluginManifestInvalid
//      C1. name 与 dirName 不一致（name="other", dirName="hello-plugin"）
//      C2. cmd 以 "/" 开头（绝对路径）
//      C3. cmd 含 ".."（路径逃逸）
//      C4. timeout 超出 [1, 120]（timeout=200）
//      C5. requiredPath 超 10 个元素
//   D. validate 正例：name=="repo", dirName=="user-repo"（split 后匹配）
//   E. validate 正例：name==dirName（builtin-hello 直接匹配）
//   F. PluginInput Codable：JSON 输出包含 query / sessionId / cwd 三字段
//   G. PluginResult Equatable：相同字段值相等，不同则不等
//   H. PluginManifest.effectiveTimeout 缺省返回 pluginDefaultTimeoutSec(30)
//   I. PluginManifest Equatable 实现（相同内容相等）
//
// 黑盒原则：通过公开结构体 API 和 Codable/Equatable 协议验证契约。
// 测试 WILL NOT compile 直到蓝队合并实现 — 这是预期的 TDD 红灯。

final class PluginManifestAcceptanceTests: XCTestCase {

    // MARK: - Helpers

    private func makeManifest(
        name: String = "test",
        cmd: String = "./test.sh",
        timeout: Int? = 5,
        requiredPath: [String]? = nil,
        env: [String: String]? = nil
    ) -> PluginManifest {
        PluginManifest(
            name: name,
            version: "1.0.0",
            description: "test plugin",
            keywords: ["test"],
            cmd: cmd,
            args: [],
            env: env,
            timeout: timeout,
            requiredPath: requiredPath
        )
    }

    // MARK: - A. Codable round-trip（完整 fixture）

    /// 完整 fixture（含 env / timeout / requiredPath 所有可选字段）编解码后与原值相等。
    /// Mutation 探针：若解码后 name 被静默忽略，XCTAssertEqual 报红。
    func test_pluginManifest_fullFixture_codableRoundTrip() throws {
        let original = PluginManifest(
            name: "my-tool",
            version: "2.1.0",
            description: "A full-featured test plugin",
            keywords: ["tool", "test", "demo"],
            cmd: "./run.sh",
            args: ["--verbose", "--output", "json"],
            env: ["MY_ENV_VAR": "value123", "DEBUG": "1"],
            timeout: 60,
            requiredPath: ["jq", "curl"]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(PluginManifest.self, from: data)

        XCTAssertEqual(decoded.name, "my-tool",
                       "name 字段 round-trip 必须精确相等")
        XCTAssertEqual(decoded.version, "2.1.0",
                       "version 字段 round-trip 必须精确相等")
        XCTAssertEqual(decoded.description, "A full-featured test plugin",
                       "description 字段 round-trip 必须精确相等")
        XCTAssertEqual(decoded.keywords, ["tool", "test", "demo"],
                       "keywords 数组 round-trip 必须精确相等")
        XCTAssertEqual(decoded.cmd, "./run.sh",
                       "cmd 字段 round-trip 必须精确相等")
        XCTAssertEqual(decoded.args, ["--verbose", "--output", "json"],
                       "args 数组 round-trip 必须精确相等")
        XCTAssertEqual(decoded.env, ["MY_ENV_VAR": "value123", "DEBUG": "1"],
                       "env 字典 round-trip 必须精确相等")
        XCTAssertEqual(decoded.timeout, 60,
                       "timeout 字段 round-trip 必须精确相等")
        XCTAssertEqual(decoded.requiredPath, ["jq", "curl"],
                       "requiredPath 数组 round-trip 必须精确相等")
    }

    // MARK: - B. 最简 fixture（只含必填字段，可选字段为 null）

    /// 最简 fixture：env/timeout/requiredPath 均为 nil，JSON 解码后可选字段也为 nil。
    func test_pluginManifest_minimalFixture_codableRoundTrip() throws {
        let jsonStr = """
        {
          "name": "minimal",
          "version": "1.0.0",
          "description": "minimal plugin",
          "keywords": ["min"],
          "cmd": "./min.sh",
          "args": [],
          "env": null,
          "timeout": null,
          "requiredPath": null
        }
        """
        let data = Data(jsonStr.utf8)
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)

        XCTAssertEqual(manifest.name, "minimal",
                       "最简 fixture name 必须精确是 'minimal'")
        XCTAssertEqual(manifest.version, "1.0.0",
                       "最简 fixture version 必须精确是 '1.0.0'")
        XCTAssertEqual(manifest.cmd, "./min.sh",
                       "最简 fixture cmd 必须精确是 './min.sh'")
        XCTAssertEqual(manifest.args, [],
                       "最简 fixture args 必须是空数组")
        XCTAssertNil(manifest.env,
                     "最简 fixture env 必须为 nil")
        XCTAssertNil(manifest.timeout,
                     "最简 fixture timeout 必须为 nil")
        XCTAssertNil(manifest.requiredPath,
                     "最简 fixture requiredPath 必须为 nil")
    }

    // MARK: - C1. validate 反例：name 与 dirName 不一致

    /// name="other" 但 dirName="hello-plugin"（split 后末段为 "plugin"）→ 必须抛 pluginManifestInvalid。
    func test_validate_nameDirectoryMismatch_throwsManifestInvalid() throws {
        let manifest = makeManifest(name: "other")

        XCTAssertThrowsError(
            try manifest.validate(againstDirName: "hello-plugin"),
            "name 与 dirName 不一致时必须抛 LauncherError.pluginManifestInvalid"
        ) { error in
            guard case LauncherError.pluginManifestInvalid(let reason) = error else {
                XCTFail("错误类型必须是 LauncherError.pluginManifestInvalid，实际: \(error)")
                return
            }
            XCTAssertFalse(reason.isEmpty,
                           "pluginManifestInvalid 关联值 reason 不应为空字符串")
        }
    }

    // MARK: - C2. validate 反例：cmd 以 "/" 开头（绝对路径）

    /// cmd="/usr/bin/cat" 时必须抛 pluginManifestInvalid。
    func test_validate_cmdAbsolutePath_throwsManifestInvalid() throws {
        let manifest = makeManifest(name: "test", cmd: "/usr/bin/cat")

        XCTAssertThrowsError(
            try manifest.validate(againstDirName: "test"),
            "cmd 以 '/' 开头时必须抛 LauncherError.pluginManifestInvalid"
        ) { error in
            guard case LauncherError.pluginManifestInvalid = error else {
                XCTFail("错误类型必须是 LauncherError.pluginManifestInvalid，实际: \(error)")
                return
            }
        }
    }

    // MARK: - C3. validate 反例：cmd 含 ".."（路径逃逸）

    /// cmd="../escape.sh" 时必须抛 pluginManifestInvalid。
    func test_validate_cmdContainsDotDot_throwsManifestInvalid() throws {
        let manifest = makeManifest(name: "test", cmd: "../escape.sh")

        XCTAssertThrowsError(
            try manifest.validate(againstDirName: "test"),
            "cmd 含 '..' 时必须抛 LauncherError.pluginManifestInvalid"
        ) { error in
            guard case LauncherError.pluginManifestInvalid = error else {
                XCTFail("错误类型必须是 LauncherError.pluginManifestInvalid，实际: \(error)")
                return
            }
        }
    }

    // MARK: - C3b. validate 反例：cmd 含 "/.."（内嵌逃逸）

    /// cmd="subdir/../escape.sh" 时必须抛 pluginManifestInvalid。
    func test_validate_cmdContainsEmbeddedDotDot_throwsManifestInvalid() throws {
        let manifest = makeManifest(name: "test", cmd: "subdir/../escape.sh")

        XCTAssertThrowsError(
            try manifest.validate(againstDirName: "test"),
            "cmd 含 '/..' 时必须抛 LauncherError.pluginManifestInvalid"
        ) { error in
            guard case LauncherError.pluginManifestInvalid = error else {
                XCTFail("错误类型必须是 LauncherError.pluginManifestInvalid，实际: \(error)")
                return
            }
        }
    }

    // MARK: - C4. validate 反例：timeout 超出 [1, 120]

    /// timeout=200 时必须抛 pluginManifestInvalid（上限 120）。
    func test_validate_timeoutExceedsMax_throwsManifestInvalid() throws {
        let manifest = makeManifest(name: "test", timeout: 200)

        XCTAssertThrowsError(
            try manifest.validate(againstDirName: "test"),
            "timeout=200 超出上限 120 时必须抛 LauncherError.pluginManifestInvalid"
        ) { error in
            guard case LauncherError.pluginManifestInvalid(let reason) = error else {
                XCTFail("错误类型必须是 LauncherError.pluginManifestInvalid，实际: \(error)")
                return
            }
            // reason 应包含数值信息（200 或 120），便于调试
            let hasNumericInfo = reason.contains("200") || reason.contains("120")
            XCTAssertTrue(hasNumericInfo,
                          "pluginManifestInvalid reason 应含 timeout 数值信息，实际: \(reason)")
        }
    }

    /// timeout=0 时必须抛 pluginManifestInvalid（下限 1）。
    func test_validate_timeoutBelowMin_throwsManifestInvalid() throws {
        let manifest = makeManifest(name: "test", timeout: 0)

        XCTAssertThrowsError(
            try manifest.validate(againstDirName: "test"),
            "timeout=0 低于下限 1 时必须抛 LauncherError.pluginManifestInvalid"
        ) { error in
            guard case LauncherError.pluginManifestInvalid = error else {
                XCTFail("错误类型必须是 LauncherError.pluginManifestInvalid，实际: \(error)")
                return
            }
        }
    }

    // MARK: - C5. validate 反例：requiredPath 超 10 个元素

    /// requiredPath 含 11 个元素时必须抛 pluginManifestInvalid。
    func test_validate_requiredPathExceedsLimit_throwsManifestInvalid() throws {
        let manifest = makeManifest(
            name: "test",
            requiredPath: Array(repeating: "x", count: 11)
        )

        XCTAssertThrowsError(
            try manifest.validate(againstDirName: "test"),
            "requiredPath 含 11 个元素（超 10 上限）时必须抛 LauncherError.pluginManifestInvalid"
        ) { error in
            guard case LauncherError.pluginManifestInvalid(let reason) = error else {
                XCTFail("错误类型必须是 LauncherError.pluginManifestInvalid，实际: \(error)")
                return
            }
            // reason 应包含数量信息
            let hasCountInfo = reason.contains("11") || reason.contains("10")
            XCTAssertTrue(hasCountInfo,
                          "pluginManifestInvalid reason 应含数量信息，实际: \(reason)")
        }
    }

    // MARK: - D. validate 正例：name=="repo", dirName=="user-repo"（split 后匹配）

    /// name="repo", dirName="user-repo" → split("-").last == "repo" → validate 不抛错。
    func test_validate_nameMathchesDirNameLastSegment_succeeds() throws {
        let manifest = makeManifest(name: "repo")

        // 不应抛错
        XCTAssertNoThrow(
            try manifest.validate(againstDirName: "user-repo"),
            "name='repo' 与 dirName='user-repo' split 后末段匹配，validate 不应抛错"
        )
    }

    // MARK: - E. validate 正例：name==dirName（builtin-hello 直接匹配）

    /// name="builtin-hello", dirName="builtin-hello" → 完全匹配 → validate 不抛错。
    func test_validate_nameEqualsDirectoryName_succeeds() throws {
        let manifest = makeManifest(name: "builtin-hello")

        XCTAssertNoThrow(
            try manifest.validate(againstDirName: "builtin-hello"),
            "name 与 dirName 完全相同时，validate 不应抛错"
        )
    }

    // MARK: - F. PluginInput Codable：JSON 含 query / sessionId / cwd 三字段

    /// PluginInput 编码后 JSON 必须含 "query" / "sessionId" / "cwd" 三个顶层 key。
    func test_pluginInput_codable_containsRequiredFields() throws {
        let input = PluginInput(
            query: "hello world",
            sessionId: "550e8400-e29b-41d4-a716-446655440000",
            cwd: "/Users/test/project"
        )

        let data = try JSONEncoder().encode(input)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertNotNil(json, "PluginInput 必须编码为有效 JSON 对象")
        let decoded = try XCTUnwrap(json, "JSON 解析不应返回 nil")

        XCTAssertEqual(decoded["query"] as? String, "hello world",
                       "JSON 中 'query' 字段必须精确是 'hello world'")
        XCTAssertEqual(decoded["sessionId"] as? String, "550e8400-e29b-41d4-a716-446655440000",
                       "JSON 中 'sessionId' 字段必须精确是原始 UUID")
        XCTAssertEqual(decoded["cwd"] as? String, "/Users/test/project",
                       "JSON 中 'cwd' 字段必须精确是 '/Users/test/project'")
    }

    /// PluginInput JSON 字段数精确是 3（不多不少）。
    func test_pluginInput_codable_exactlyThreeFields() throws {
        let input = PluginInput(
            query: "q",
            sessionId: "abc",
            cwd: "/tmp"
        )

        let data = try JSONEncoder().encode(input)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let decoded = try XCTUnwrap(json)

        XCTAssertEqual(decoded.count, 3,
                       "PluginInput JSON 必须精确含 3 个字段（query/sessionId/cwd），实际: \(decoded.keys.sorted())")
    }

    // MARK: - G. PluginResult Equatable

    /// 相同字段值的 PluginResult 必须 Equatable 相等。
    func test_pluginResult_equatable_sameValues_areEqual() {
        let result1 = PluginResult(
            stdout: "## Hello",
            stderr: "",
            exitCode: 0,
            durationMs: 42,
            stdoutTruncated: false
        )
        let result2 = PluginResult(
            stdout: "## Hello",
            stderr: "",
            exitCode: 0,
            durationMs: 42,
            stdoutTruncated: false
        )

        XCTAssertEqual(result1, result2,
                       "内容相同的 PluginResult 必须 Equatable 相等")
    }

    /// exitCode 不同则 PluginResult 不等（Mutation 探针）。
    func test_pluginResult_equatable_differentExitCode_notEqual() {
        let result1 = PluginResult(
            stdout: "output",
            stderr: "",
            exitCode: 0,
            durationMs: 10,
            stdoutTruncated: false
        )
        let result2 = PluginResult(
            stdout: "output",
            stderr: "",
            exitCode: 1,
            durationMs: 10,
            stdoutTruncated: false
        )

        XCTAssertNotEqual(result1, result2,
                          "exitCode 不同时 PluginResult 不应相等（Mutation 探针）")
    }

    /// stdoutTruncated 不同则 PluginResult 不等（Mutation 探针）。
    func test_pluginResult_equatable_differentTruncatedFlag_notEqual() {
        let result1 = PluginResult(
            stdout: "output",
            stderr: "",
            exitCode: 0,
            durationMs: 10,
            stdoutTruncated: false
        )
        let result2 = PluginResult(
            stdout: "output",
            stderr: "",
            exitCode: 0,
            durationMs: 10,
            stdoutTruncated: true
        )

        XCTAssertNotEqual(result1, result2,
                          "stdoutTruncated 不同时 PluginResult 不应相等（Mutation 探针）")
    }

    // MARK: - H. PluginManifest.effectiveTimeout 缺省值

    /// timeout=nil 时 effectiveTimeout 必须精确返回 30（pluginDefaultTimeoutSec）。
    func test_pluginManifest_effectiveTimeout_nilTimeout_returnsDefault30() {
        let manifest = makeManifest(timeout: nil)

        XCTAssertEqual(manifest.effectiveTimeout, 30,
                       "timeout=nil 时 effectiveTimeout 必须精确是 30（pluginDefaultTimeoutSec）")
    }

    /// timeout=45 时 effectiveTimeout 必须精确返回 45。
    func test_pluginManifest_effectiveTimeout_explicitTimeout_returnsExplicitValue() {
        let manifest = makeManifest(timeout: 45)

        XCTAssertEqual(manifest.effectiveTimeout, 45,
                       "timeout=45 时 effectiveTimeout 必须精确是 45")
    }

    // MARK: - I. PluginManifest Equatable

    /// 内容相同的 PluginManifest 必须 Equatable 相等。
    func test_pluginManifest_equatable_sameContent_equal() {
        let m1 = makeManifest(name: "foo", cmd: "./foo.sh", timeout: 10)
        let m2 = makeManifest(name: "foo", cmd: "./foo.sh", timeout: 10)

        XCTAssertEqual(m1, m2,
                       "内容相同的 PluginManifest 必须 Equatable 相等")
    }

    /// name 不同则 PluginManifest 不等（Mutation 探针）。
    func test_pluginManifest_equatable_differentName_notEqual() {
        let m1 = makeManifest(name: "foo")
        let m2 = makeManifest(name: "bar")

        XCTAssertNotEqual(m1, m2,
                          "name 不同时 PluginManifest 不应相等")
    }

    // MARK: - validate 边界：timeout=1 和 timeout=120 均合法

    /// timeout=1（下限）必须通过 validate。
    func test_validate_timeoutAtMin_succeeds() throws {
        let manifest = makeManifest(name: "test", timeout: 1)

        XCTAssertNoThrow(
            try manifest.validate(againstDirName: "test"),
            "timeout=1（下限）必须通过 validate"
        )
    }

    /// timeout=120（上限）必须通过 validate。
    func test_validate_timeoutAtMax_succeeds() throws {
        let manifest = makeManifest(name: "test", timeout: 120)

        XCTAssertNoThrow(
            try manifest.validate(againstDirName: "test"),
            "timeout=120（上限）必须通过 validate"
        )
    }

    /// requiredPath 恰好 10 个元素（边界上限）必须通过 validate。
    func test_validate_requiredPathAtLimit_succeeds() throws {
        let manifest = makeManifest(
            name: "test",
            requiredPath: Array(repeating: "x", count: 10)
        )

        XCTAssertNoThrow(
            try manifest.validate(againstDirName: "test"),
            "requiredPath 恰好 10 个元素时必须通过 validate"
        )
    }
}
