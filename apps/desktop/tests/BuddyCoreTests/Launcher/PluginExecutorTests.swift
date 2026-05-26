import XCTest
@testable import BuddyCore

/// 蓝队单测：PluginExecutor 5 个场景（在 tmpDir 用 fixture shell 脚本）
final class PluginExecutorTests: XCTestCase {

    private var tmpDir: URL!
    private let executor = PluginExecutor.shared

    override func setUp() {
        super.setUp()
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PluginExecutorTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    // MARK: - 场景 1：正例（echo markdown）

    func test_execute_success_echoMarkdown() async throws {
        let pluginDir = try makeScriptPlugin(
            dirName: "test-echo",
            manifestName: "echo",
            script: """
            #!/bin/bash
            echo "## Hello, world!"
            exit 0
            """
        )
        let manifest = try loadManifest(from: pluginDir, dirName: "test-echo")
        let input = PluginInput(query: "world", sessionId: UUID().uuidString, cwd: "/tmp")

        let result = try await executor.execute(manifest, pluginDir: pluginDir, input: input)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("## Hello, world!"), "stdout: \(result.stdout)")
        XCTAssertFalse(result.stdoutTruncated)
        XCTAssertGreaterThan(result.durationMs, 0)
    }

    // MARK: - 场景 2：超时（timeout=1）

    func test_execute_timeout() async throws {
        let pluginDir = try makeScriptPlugin(
            dirName: "test-timeout",
            manifestName: "timeout",
            script: """
            #!/bin/bash
            sleep 10
            exit 0
            """,
            timeout: 1
        )
        let manifest = try loadManifest(from: pluginDir, dirName: "test-timeout")
        let input = PluginInput(query: "x", sessionId: UUID().uuidString, cwd: "/tmp")

        do {
            _ = try await executor.execute(manifest, pluginDir: pluginDir, input: input)
            XCTFail("应抛 pluginTimeout")
        } catch LauncherError.pluginTimeout(let sec) {
            XCTAssertEqual(sec, 1)
        } catch {
            XCTFail("意外错误: \(error)")
        }
    }

    // MARK: - 场景 3：exit code 非 0 → pluginCrash

    func test_execute_nonZeroExitCode() async throws {
        let pluginDir = try makeScriptPlugin(
            dirName: "test-crash",
            manifestName: "crash",
            script: """
            #!/bin/bash
            echo "bad input" >&2
            exit 2
            """
        )
        let manifest = try loadManifest(from: pluginDir, dirName: "test-crash")
        let input = PluginInput(query: "x", sessionId: UUID().uuidString, cwd: "/tmp")

        do {
            _ = try await executor.execute(manifest, pluginDir: pluginDir, input: input)
            XCTFail("应抛 pluginCrash")
        } catch LauncherError.pluginCrash(let code, let stderr) {
            XCTAssertEqual(code, 2)
            XCTAssertTrue(stderr.contains("bad input"), "stderr: \(stderr)")
        } catch {
            XCTFail("意外错误: \(error)")
        }
    }

    // MARK: - 场景 4：依赖缺失 → pluginMissingDependency

    func test_execute_missingDependency() async throws {
        let pluginDir = try makeScriptPlugin(
            dirName: "test-dep",
            manifestName: "dep",
            script: """
            #!/bin/bash
            echo "should not run"
            """,
            requiredPath: ["nonexistent-binary-zzz-definitely-not-on-system"]
        )
        let manifest = try loadManifest(from: pluginDir, dirName: "test-dep")
        let input = PluginInput(query: "x", sessionId: UUID().uuidString, cwd: "/tmp")

        do {
            _ = try await executor.execute(manifest, pluginDir: pluginDir, input: input)
            XCTFail("应抛 pluginMissingDependency")
        } catch LauncherError.pluginMissingDependency(let bin) {
            XCTAssertEqual(bin, "nonexistent-binary-zzz-definitely-not-on-system")
        } catch {
            XCTFail("意外错误: \(error)")
        }
    }

    // MARK: - 场景 5：stdout 超过 1 MiB 截断

    func test_execute_stdoutTruncated() async throws {
        // 输出 2 MiB 以上（超过 1 MiB 限制）
        let pluginDir = try makeScriptPlugin(
            dirName: "test-truncate",
            manifestName: "truncate",
            script: """
            #!/bin/bash
            python3 -c "print('A' * (1024 * 1024 + 100))"
            exit 0
            """,
            timeout: 30
        )
        let manifest = try loadManifest(from: pluginDir, dirName: "test-truncate")
        let input = PluginInput(query: "x", sessionId: UUID().uuidString, cwd: "/tmp")

        let result = try await executor.execute(manifest, pluginDir: pluginDir, input: input)
        XCTAssertTrue(result.stdoutTruncated, "stdout 应被截断")
        XCTAssertTrue(result.stdout.hasSuffix("[...output truncated]"), "末尾应有截断标记")
        // stdout 长度 ≤ 1MiB + 截断标记长度
        XCTAssertLessThanOrEqual(
            result.stdout.utf8.count,
            LauncherConstants.pluginMaxStdoutBytes + 100
        )
    }

    // MARK: - Helpers

    private func makeScriptPlugin(
        dirName: String,
        manifestName: String,
        script: String,
        timeout: Int = 10,
        requiredPath: [String]? = nil
    ) throws -> URL {
        let pluginDir = tmpDir.appendingPathComponent(dirName)
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)

        // 写 hello.sh
        let scriptURL = pluginDir.appendingPathComponent("run.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )

        // 写 plugin.json
        let requiredPathJSON: String
        if let rp = requiredPath {
            requiredPathJSON = "[" + rp.map { "\"\($0)\"" }.joined(separator: ",") + "]"
        } else {
            requiredPathJSON = "null"
        }
        let manifestJSON = """
        {
          "name": "\(manifestName)",
          "version": "0.1.0",
          "description": "test",
          "keywords": [],
          "cmd": "./run.sh",
          "args": [],
          "env": null,
          "timeout": \(timeout),
          "requiredPath": \(requiredPathJSON)
        }
        """
        try manifestJSON.write(
            to: pluginDir.appendingPathComponent("plugin.json"),
            atomically: true, encoding: .utf8
        )
        return pluginDir
    }

    private func loadManifest(from pluginDir: URL, dirName: String) throws -> PluginManifest {
        let data = try Data(contentsOf: pluginDir.appendingPathComponent("plugin.json"))
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        try manifest.validate(againstDirName: dirName)
        return manifest
    }
}
