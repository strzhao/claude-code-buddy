import XCTest
@testable import BuddyCore

// MARK: - CandidateCallbackTests
//
// 蓝队单测：选中回调重入（C4-C6）
//
// 契约引用（state.md ## 契约规约）：
//   C4：PluginInput.selection（Codable 可选，向后兼容）
//   C5：LauncherManager.submitWithCandidate(_:selection:query:)（command 重入，带 selection）
//   C6：command trustKey = "command:" + SHA256(cmd+args+exeBytes)，不含 stdin/selection
//       ⇒ 回调同二进制同 args，trustKey 不变，不重复弹框
//
// TDD：先于实现编写（实现已完成，此处为回归守护）。
// 参考 PluginDispatcherCommandModeTests mock 模式。

final class CandidateCallbackTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CandidateCallback-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    // MARK: - C4: PluginInput.selection 向后兼容

    func test_pluginInput_defaultSelectionNil_preservesOldCallSites() {
        // 现有调用点 PluginInput(query:sessionId:cwd:) 不传 selection → 默认 nil（向后兼容）
        let input = PluginInput(query: "qzh", sessionId: "s1", cwd: "/tmp")
        XCTAssertNil(input.selection, "selection 默认 nil，旧调用点无需改动")
    }

    func test_pluginInput_explicitSelection_carriesValue() {
        let input = PluginInput(query: "qzh", sessionId: "s1", cwd: "/tmp", selection: "stop")
        XCTAssertEqual(input.selection, "stop")
    }

    func test_pluginInput_codable_decodesOldJSONWithoutSelection() throws {
        // 老 JSON（无 selection 键）解码不崩（C4 向后兼容）
        let oldJSON = """
        {"query":"qzh","sessionId":"s1","cwd":"/tmp"}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(PluginInput.self, from: oldJSON)
        XCTAssertEqual(decoded.query, "qzh")
        XCTAssertNil(decoded.selection, "老 JSON 无 selection 键应解码为 nil")
    }

    func test_pluginInput_codable_encodesNilSelection_omitsKey() throws {
        // selection=nil 编码时省略键（向后兼容老插件读取）
        let input = PluginInput(query: "qzh", sessionId: "s1", cwd: "/tmp")
        let data = try JSONEncoder().encode(input)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertFalse(json.contains("\"selection\""), "nil selection 应省略键：\(json)")
    }

    func test_pluginInput_codable_roundtripWithSelection() throws {
        let input = PluginInput(query: "qzh", sessionId: "s1", cwd: "/tmp", selection: "start")
        let data = try JSONEncoder().encode(input)
        let decoded = try JSONDecoder().decode(PluginInput.self, from: data)
        XCTAssertEqual(decoded, input, "往返解码应保持相等（含 selection）")
    }

    // MARK: - C5: submitWithCandidate selection 透传到插件

    func test_submitWithCandidate_selectionPassedToPlugin_viaStdinExecutor() async throws {
        // 插件读 stdin selection → 回显到 stdout，验证 selection 正确透传
        let pluginDir = try makeCommandPlugin(
            dirName: "cb-echo",
            script: """
            #!/bin/bash
            input=$(cat)
            sel=$(echo "$input" | jq -r '.selection // "none"')
            echo "selection=$sel"
            exit 0
            """
        )
        let manifest = try loadManifest(from: pluginDir, dirName: "cb-echo")
        // 直接用 StdinExecutor 验证 selection 透传（绕过 LauncherManager 的 MainActor）
        let input = PluginInput(query: "qzh", sessionId: UUID().uuidString, cwd: "/tmp", selection: "stop")
        let result = try await StdinExecutor().execute(manifest, pluginDir: pluginDir, input: input)
        XCTAssertTrue(result.stdout.contains("selection=stop"), "selection 应透传到插件：\(result.stdout)")
    }

    // MARK: - C5: command 分支 yield .candidates（经 PluginDispatcher 贯通）

    func test_commandMode_yieldsCandidatesInPluginResult() async throws {
        let pluginDir = try makeCommandPlugin(
            dirName: "cb-cand",
            script: """
            #!/bin/bash
            printf '%s' '[{"id":"stop","title":"关闭","selection":"stop"}]' > "$BUDDY_OUTPUT_CANDIDATES"
            echo "status: running"
            exit 0
            """
        )
        let manifest = try loadManifest(from: pluginDir, dirName: "cb-cand")
        let input = PluginInput(query: "qzh", sessionId: UUID().uuidString, cwd: "/tmp")

        // 经 PluginDispatcher（command mode 转发 stdinExecutor）
        let dispatcher = PluginDispatcher(stdinExecutor: StdinExecutor())
        let result = try await dispatcher.execute(manifest, pluginDir: pluginDir, input: input)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertNotNil(result.candidates, "command mode 经 dispatcher 应产候选")
        XCTAssertEqual(result.candidates?.count, 1)
        XCTAssertEqual(result.candidates?[0].selection, "stop")
    }

    // MARK: - C6: trustKey 不含 selection（回调不重复弹框）

    func test_trustKey_commandMode_identicalForSameBinaryAndArgs_regardlessOfSelection() throws {
        // 同二进制 + 同 args → trustKey 相同（不管 selection 如何，因为 trustKey 不含 stdin/selection）
        let pluginDir = try makeCommandPlugin(
            dirName: "cb-trust",
            script: """
            #!/bin/bash
            exit 0
            """
        )
        let manifest = try loadManifest(from: pluginDir, dirName: "cb-trust")
        let execPath = pluginDir.appendingPathComponent("run.sh")

        let key1 = try TrustStore.trustKey(for: manifest, executablePath: execPath)
        // trustKey 是静态算的（基于 cmd/args/exe bytes），与运行时 selection 无关。
        // 这里验证：同 manifest 同 execPath 两次计算结果一致（C6 回调 trustKey 不变的前提）。
        let key2 = try TrustStore.trustKey(for: manifest, executablePath: execPath)
        XCTAssertEqual(key1, key2, "同二进制同 args trustKey 必须稳定（回调不重复弹框前提）")
        XCTAssertTrue(key1.hasPrefix("command:"), "command mode trustKey 应带 command: 前缀")
        XCTAssertFalse(key1.contains("selection"), "trustKey 不应含 selection 字样（C6）")
    }

    // MARK: - C5: submitWithCandidate 非 command mode 拒绝

    @MainActor
    func test_submitWithCandidate_nonCommandMode_returnsErrorStream() async throws {
        // stdin/prompt mode 回调不在本次范围（设计文档「不做」），应返回错误流而非崩溃
        let stdinManifest = try makeStdinManifest()
        let manager = LauncherManager.shared
        let stream = await manager.submitWithCandidate(stdinManifest, selection: "x", query: "q")
        var hasError = false
        for await event in stream {
            if case .error = event { hasError = true }
        }
        XCTAssertTrue(hasError, "非 command mode 调 submitWithCandidate 应返回错误流")
    }

    // MARK: - Helpers

    private func makeCommandPlugin(dirName: String, script: String, timeout: Int = 10) throws -> URL {
        let pluginDir = tmpDir.appendingPathComponent(dirName)
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        let scriptURL = pluginDir.appendingPathComponent("run.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        let manifestJSON = """
        {
          "name": "\(dirName)",
          "version": "0.1.0",
          "description": "callback test",
          "keywords": [],
          "mode": "command",
          "cmd": "./run.sh",
          "args": [],
          "env": null,
          "timeout": \(timeout),
          "requiredPath": null
        }
        """
        try manifestJSON.write(to: pluginDir.appendingPathComponent("plugin.json"),
                               atomically: true, encoding: .utf8)
        return pluginDir
    }

    private func makeStdinManifest() throws -> PluginManifest {
        let json = """
        {
          "name": "stdin-test",
          "version": "0.1.0",
          "description": "stdin mode",
          "keywords": [],
          "mode": "stdin",
          "cmd": "./run.sh",
          "args": [],
          "env": null,
          "timeout": 10,
          "requiredPath": null
        }
        """.data(using: .utf8)!
        return try JSONDecoder().decode(PluginManifest.self, from: json)
    }

    private func loadManifest(from pluginDir: URL, dirName: String) throws -> PluginManifest {
        let data = try Data(contentsOf: pluginDir.appendingPathComponent("plugin.json"))
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        try manifest.validate(againstDirName: dirName)
        return manifest
    }
}
