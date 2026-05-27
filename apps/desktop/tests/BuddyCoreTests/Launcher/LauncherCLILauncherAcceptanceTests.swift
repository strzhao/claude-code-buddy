import XCTest
import CryptoKit
@testable import BuddyCore

// MARK: - LauncherCLILauncherAcceptanceTests
//
// 红队验收测试：buddy launcher add/list/remove/inspect CLI 子命令（task 006 输出契约）
//
// 测试方式：以 subprocess 启动 .build/debug/buddy-cli，使用临时 HOME 隔离 ~/.buddy/
// 避免污染开发者真实 home 目录。HOME 通过 env 重定向到 tempDir，CLI 内 NSHomeDirectory()
// 在 macOS 上会读取 HOME 环境变量（如 HOME 未设置则 fallback 到 getpwuid）。
//
// 设计文档覆盖点（task 006 输出契约）：
//   SC-CLI-01: buddy launcher add <invalid> → exit code 2（manifest 无效）/ 输入 user/repo 格式错误也应非 0
//   SC-CLI-02: buddy launcher add <user/repo> → 已存在时 exit code 3
//   SC-CLI-03: buddy launcher list → 空目录时不 crash，输出可识别
//   SC-CLI-04: buddy launcher remove <name> → 不存在时 exit code 1
//   SC-CLI-05: buddy launcher inspect <name> → 不存在时 exit code 1
//   SC-CLI-06: buddy launcher add 格式校验：参数非 "user/repo" → exit code 2
//   SC-CLI-07: 集成路径：CLI add 一个 fake plugin（用本地 plugin.json 预置目录）→ list 应能找到 + 标记 never_run
//   SC-CLI-08: inspect 输出 JSON 必须含 trust_status 字段（contract）
//
// 注：buddy launcher add <real-github-repo> 测试需要网络，作为 ⚠️ smoke 标注但不强制运行
// 红队选择主要测试可在 CI 离线环境验证的退出码和 schema 契约。

final class LauncherCLILauncherAcceptanceTests: XCTestCase {

    private var tempHome: URL!

    // MARK: - Fixtures

    override func setUp() async throws {
        try await super.setUp()
        tempHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CLITestHome-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let dir = tempHome {
            try? FileManager.default.removeItem(at: dir)
        }
        tempHome = nil
        try await super.tearDown()
    }

    /// 找 buddy-cli 二进制路径（test 在 .build/debug 下运行，CLI 也编译到这里）
    private func cliBinary() throws -> URL {
        let testBundle = Bundle(for: type(of: self))
        // 测试可执行文件位于 .build/debug/BuddyCorePackageTests.xctest/Contents/MacOS/...
        // 上溯到 .build/debug
        var dir = testBundle.bundleURL.deletingLastPathComponent()
        while dir.lastPathComponent != "debug" && dir.path != "/" {
            dir = dir.deletingLastPathComponent()
        }
        guard dir.lastPathComponent == "debug" else {
            throw XCTSkip("无法定位 .build/debug 目录")
        }
        let binary = dir.appendingPathComponent("buddy-cli")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw XCTSkip("buddy-cli 二进制未找到: \(binary.path)。先运行 `swift build`")
        }
        return binary
    }

    /// 以临时 HOME 启动 buddy-cli，返回 (stdout, stderr, exitCode)
    @discardableResult
    private func runCLI(_ args: [String]) throws -> (stdout: String, stderr: String, exitCode: Int32) {
        let binary = try cliBinary()
        let process = Process()
        process.executableURL = binary
        process.arguments = args

        // 隔离 HOME：所有 ~/.buddy/* 都落在 tempHome 下
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = tempHome.path
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // 30s timeout（git clone 可能慢，但本测试不调外网；nominal subcommand < 1s）
        let timeoutWork = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeoutWork)
        process.waitUntilExit()
        timeoutWork.cancel()

        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        return (
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? "",
            exitCode: process.terminationStatus
        )
    }

    /// 预置一个 fake plugin 目录（绕过 git clone，直接写文件验证 list/inspect/remove）
    private func seedFakePlugin(userRepo: String,
                                manifestName: String,
                                version: String = "0.1.0",
                                description: String = "fake plugin") throws -> URL {
        let pluginDir = tempHome
            .appendingPathComponent(".buddy/launcher-plugins")
            .appendingPathComponent(userRepo.replacingOccurrences(of: "/", with: "-"))
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        let manifestJSON = """
        {
          "name": "\(manifestName)",
          "version": "\(version)",
          "description": "\(description)",
          "keywords": ["fake"],
          "cmd": "./run.sh",
          "args": []
        }
        """
        try manifestJSON.write(to: pluginDir.appendingPathComponent("plugin.json"),
                               atomically: true, encoding: .utf8)
        try "#!/bin/sh\necho fake".write(to: pluginDir.appendingPathComponent("run.sh"),
                                        atomically: true, encoding: .utf8)
        return pluginDir
    }

    // MARK: - SC-CLI-01 / SC-CLI-06: add 格式校验

    func test_SC_CLI_01_add_invalidFormat_exitCode2() throws {
        let result = try runCLI(["launcher", "add", "not-a-valid-format"])
        XCTAssertEqual(result.exitCode, 2,
                       "无效 user/repo 格式必须 exit 2，实际 \(result.exitCode); stderr: \(result.stderr)")
    }

    func test_SC_CLI_06_add_emptyArg_exitCode2() throws {
        let result = try runCLI(["launcher", "add"])
        XCTAssertNotEqual(result.exitCode, 0,
                          "缺少 user/repo 参数必须非 0 退出; stderr: \(result.stderr)")
    }

    // MARK: - SC-CLI-02: add 已存在 exit code 3

    func test_SC_CLI_02_add_alreadyInstalled_exitCode3() throws {
        // 预置已存在的 plugin 目录
        _ = try seedFakePlugin(userRepo: "alice/existing-plugin", manifestName: "existing-plugin")

        let result = try runCLI(["launcher", "add", "alice/existing-plugin"])
        XCTAssertEqual(result.exitCode, 3,
                       "已存在 plugin add 必须 exit 3，实际 \(result.exitCode); stderr: \(result.stderr)")
    }

    // MARK: - SC-CLI-03: list 空目录不 crash

    func test_SC_CLI_03_list_emptyDir_exitsZero() throws {
        let result = try runCLI(["launcher", "list"])
        XCTAssertEqual(result.exitCode, 0,
                       "list 空目录必须 exit 0，实际 \(result.exitCode); stderr: \(result.stderr)")
    }

    // MARK: - SC-CLI-04: remove 不存在 exit code 1

    func test_SC_CLI_04_remove_notFound_exitCode1() throws {
        let result = try runCLI(["launcher", "remove", "nonexistent-plugin"])
        XCTAssertEqual(result.exitCode, 1,
                       "remove 不存在 plugin 必须 exit 1，实际 \(result.exitCode); stderr: \(result.stderr)")
    }

    // MARK: - SC-CLI-05: inspect 不存在 exit code 1

    func test_SC_CLI_05_inspect_notFound_exitCode1() throws {
        let result = try runCLI(["launcher", "inspect", "nonexistent-plugin"])
        XCTAssertEqual(result.exitCode, 1,
                       "inspect 不存在 plugin 必须 exit 1，实际 \(result.exitCode); stderr: \(result.stderr)")
    }

    // MARK: - SC-CLI-07: 集成路径 fake plugin → list 显示 never_run

    func test_SC_CLI_07_seededPlugin_listShows_neverRun() throws {
        _ = try seedFakePlugin(userRepo: "bob/seeded-plugin", manifestName: "seeded-plugin")

        let result = try runCLI(["launcher", "list"])
        XCTAssertEqual(result.exitCode, 0, "list 必须 exit 0; stderr: \(result.stderr)")
        XCTAssertTrue(result.stdout.contains("seeded-plugin"),
                      "list 输出必须含 plugin name 'seeded-plugin'，实际: \(result.stdout)")
        XCTAssertTrue(result.stdout.contains("never_run"),
                      "从未运行的 plugin 必须显示 'never_run' 状态，实际: \(result.stdout)")
    }

    // MARK: - SC-CLI-08: inspect 输出 JSON schema

    func test_SC_CLI_08_inspect_outputsValidJSON_withTrustStatus() throws {
        _ = try seedFakePlugin(userRepo: "carol/inspect-plugin",
                               manifestName: "inspect-plugin",
                               version: "2.0.0",
                               description: "inspect test plugin")

        let result = try runCLI(["launcher", "inspect", "inspect-plugin"])
        XCTAssertEqual(result.exitCode, 0,
                       "inspect 必须 exit 0; stderr: \(result.stderr)")

        // 输出必须是合法 JSON 且含必要字段
        guard let data = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("inspect 输出必须是合法 JSON object，实际: \(result.stdout)")
            return
        }
        XCTAssertEqual(json["name"] as? String, "inspect-plugin")
        XCTAssertEqual(json["version"] as? String, "2.0.0")
        XCTAssertEqual(json["description"] as? String, "inspect test plugin")
        XCTAssertNotNil(json["trust_status"], "inspect 输出必须含 trust_status 字段（契约）")
        XCTAssertNotNil(json["install_path"], "inspect 输出必须含 install_path 字段（契约）")

        // trust_status 必须是三个合法值之一
        let allowedStatuses = Set(["trusted", "untrusted", "never_run"])
        guard let status = json["trust_status"] as? String else {
            XCTFail("trust_status 必须是 String")
            return
        }
        XCTAssertTrue(allowedStatuses.contains(status),
                      "trust_status 必须是 trusted/untrusted/never_run，实际: \(status)")
    }

    // MARK: - SC-CLI-09: remove 后 list 不再包含该 plugin

    func test_SC_CLI_09_remove_then_listNotContains() throws {
        _ = try seedFakePlugin(userRepo: "dave/to-remove", manifestName: "to-remove")

        // 验证存在
        var listResult = try runCLI(["launcher", "list"])
        XCTAssertTrue(listResult.stdout.contains("to-remove"),
                      "remove 前 list 必须含 to-remove")

        // remove
        let removeResult = try runCLI(["launcher", "remove", "to-remove"])
        XCTAssertEqual(removeResult.exitCode, 0,
                       "remove 必须 exit 0; stderr: \(removeResult.stderr)")

        // 再次 list 必须不含
        listResult = try runCLI(["launcher", "list"])
        XCTAssertFalse(listResult.stdout.contains("to-remove"),
                       "remove 后 list 必须不含 to-remove，实际: \(listResult.stdout)")
    }
}
