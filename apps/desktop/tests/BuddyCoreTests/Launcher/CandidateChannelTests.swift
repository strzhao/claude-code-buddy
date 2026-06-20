import XCTest
@testable import BuddyCore

// MARK: - CandidateChannelTests
//
// 蓝队单测：候选输出通道（C1-C3）
//
// 契约引用（state.md ## 契约规约）：
//   C1：BUDDY_OUTPUT_CANDIDATES env 注入 + readCandidatesOutputSafely（存在/symlink/超限/JSON 校验）
//       → PluginResult.candidates；失败降级 nil
//   C2：LauncherCandidate {id,title,subtitle?,selection} Codable/Equatable/Identifiable
//   C3：AgentEvent.candidates case + == 分支同步
//
// TDD：先于实现编写（实现已完成，此处为回归守护 + 边界值断言）。
// 参考 PluginDispatcherCommandModeTests mock 模式（伪造 JSON 写 $BUDDY_OUTPUT_CANDIDATES）。

final class CandidateChannelTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CandidateChannel-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    // MARK: - C2: LauncherCandidate 值类型

    func test_launcherCandidate_codable_decodesFullFields() throws {
        let json = """
        [{"id":"stop","title":"关闭监控","subtitle":"停止 service","selection":"stop"}]
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode([LauncherCandidate].self, from: json)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].id, "stop")
        XCTAssertEqual(decoded[0].title, "关闭监控")
        XCTAssertEqual(decoded[0].subtitle, "停止 service")
        XCTAssertEqual(decoded[0].selection, "stop")
    }

    func test_launcherCandidate_codable_subtitleOptional_decodesWithoutSubtitle() throws {
        // subtitle 缺失 → nil（C2 可选字段）
        let json = """
        [{"id":"x","title":"T","selection":"sel"}]
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode([LauncherCandidate].self, from: json)
        XCTAssertNil(decoded[0].subtitle)
    }

    func test_launcherCandidate_codable_missingSelection_throws() throws {
        // 缺必需字段 selection → 解码失败（C2 边界：selection 必需）
        let json = """
        [{"id":"x","title":"T"}]
        """.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode([LauncherCandidate].self, from: json))
    }

    func test_launcherCandidate_equatable_comparesAllFields() {
        let a = LauncherCandidate(id: "stop", title: "关闭", subtitle: "s", selection: "stop")
        let b = LauncherCandidate(id: "stop", title: "关闭", subtitle: "s", selection: "stop")
        let c = LauncherCandidate(id: "start", title: "关闭", subtitle: "s", selection: "stop")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c, "id 不同应不等")
    }

    // MARK: - C3: AgentEvent.candidates + == 同步

    func test_agentEvent_candidates_caseExists_andYields() {
        let candidates = [
            LauncherCandidate(id: "stop", title: "关闭", subtitle: nil, selection: "stop"),
            LauncherCandidate(id: "start", title: "打开", subtitle: nil, selection: "start"),
        ]
        let event = AgentEvent.candidates(candidates)
        // if-case 判别（不依赖 ==）
        if case .candidates(let got) = event {
            XCTAssertEqual(got, candidates)
        } else {
            XCTFail("event 应为 .candidates")
        }
    }

    func test_agentEvent_candidates_equatableEqualCandidatesEqual() {
        // C3 核心：== 分支已加，两相等候选数组 → 事件相等（防假阴性）
        let c1 = [LauncherCandidate(id: "a", title: "A", subtitle: nil, selection: "x")]
        XCTAssertEqual(AgentEvent.candidates(c1), AgentEvent.candidates(c1))
    }

    func test_agentEvent_candidates_equatableDifferentCandidatesNotEqual() {
        // C3 核心：候选不同 → 事件不等（防漏比导致假阳性）
        let c1 = [LauncherCandidate(id: "a", title: "A", subtitle: nil, selection: "x")]
        let c2 = [LauncherCandidate(id: "b", title: "A", subtitle: nil, selection: "x")]
        XCTAssertNotEqual(AgentEvent.candidates(c1), AgentEvent.candidates(c2))
    }

    func test_agentEvent_candidates_notEqualToOtherCases() {
        // 跨 case 不等（default:false 守护）
        let c = [LauncherCandidate(id: "a", title: "A", subtitle: nil, selection: "x")]
        XCTAssertNotEqual(AgentEvent.candidates(c), AgentEvent.text("a"))
        XCTAssertNotEqual(AgentEvent.candidates(c), AgentEvent.image(Data([0x89])))
        XCTAssertNotEqual(AgentEvent.candidates(c), AgentEvent.done(reason: "end_turn"))
    }

    // MARK: - C1: 候选通道贯通（通过 StdinExecutor 端到端）

    func test_candidatesChannel_validJSON_decodesIntoPluginResult() async throws {
        // 子进程写合法候选 JSON → PluginResult.candidates 非空
        let pluginDir = try makeCommandPlugin(
            dirName: "cmd-cand-valid",
            script: """
            #!/bin/bash
            printf '%s' '[{"id":"stop","title":"关闭监控","subtitle":"停止 service","selection":"stop"},{"id":"start","title":"打开监控","subtitle":null,"selection":"start"}]' > "$BUDDY_OUTPUT_CANDIDATES"
            exit 0
            """
        )
        let manifest = try loadManifest(from: pluginDir, dirName: "cmd-cand-valid")
        let input = PluginInput(query: "x", sessionId: UUID().uuidString, cwd: "/tmp")

        let executor = StdinExecutor()
        let result = try await executor.execute(manifest, pluginDir: pluginDir, input: input)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertNotNil(result.candidates, "合法候选 JSON 应解码非空")
        XCTAssertEqual(result.candidates?.count, 2)
        XCTAssertEqual(result.candidates?[0].id, "stop")
        XCTAssertEqual(result.candidates?[1].subtitle, nil, "subtitle:null 应回填 nil")
    }

    func test_candidatesChannel_noFile_returnsNilNotError() async throws {
        // 子进程不写候选文件 → candidates = nil（降级，exit 0 不报错）
        let pluginDir = try makeCommandPlugin(
            dirName: "cmd-cand-none",
            script: """
            #!/bin/bash
            echo "just text"
            exit 0
            """
        )
        let manifest = try loadManifest(from: pluginDir, dirName: "cmd-cand-none")
        let input = PluginInput(query: "x", sessionId: UUID().uuidString, cwd: "/tmp")

        let result = try await StdinExecutor().execute(manifest, pluginDir: pluginDir, input: input)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertNil(result.candidates, "无候选文件应降级 nil，非 error")
    }

    func test_candidatesChannel_corruptJSON_returnsNil() async throws {
        // 损坏 JSON（非合法 JSON）→ candidates = nil
        let pluginDir = try makeCommandPlugin(
            dirName: "cmd-cand-corrupt",
            script: """
            #!/bin/bash
            printf '%s' 'not-a-json-array' > "$BUDDY_OUTPUT_CANDIDATES"
            exit 0
            """
        )
        let manifest = try loadManifest(from: pluginDir, dirName: "cmd-cand-corrupt")
        let input = PluginInput(query: "x", sessionId: UUID().uuidString, cwd: "/tmp")

        let result = try await StdinExecutor().execute(manifest, pluginDir: pluginDir, input: input)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertNil(result.candidates, "损坏 JSON 应降级 nil")
    }

    func test_candidatesChannel_missingField_returnsNil() async throws {
        // JSON 合法但缺必需字段 selection → 解码失败 → nil
        let pluginDir = try makeCommandPlugin(
            dirName: "cmd-cand-missing",
            script: """
            #!/bin/bash
            printf '%s' '[{"id":"x","title":"T"}]' > "$BUDDY_OUTPUT_CANDIDATES"
            exit 0
            """
        )
        let manifest = try loadManifest(from: pluginDir, dirName: "cmd-cand-missing")
        let input = PluginInput(query: "x", sessionId: UUID().uuidString, cwd: "/tmp")

        let result = try await StdinExecutor().execute(manifest, pluginDir: pluginDir, input: input)
        XCTAssertNil(result.candidates, "缺必需字段应解码失败降级 nil")
    }

    func test_candidatesChannel_oversized_returnsNil() async throws {
        // 超限（> 64 KiB）→ candidates = nil
        let pluginDir = try makeCommandPlugin(
            dirName: "cmd-cand-big",
            script: """
            #!/bin/bash
            # 生成 ~100KiB 的合法候选 JSON（title 字段塞长串）
            python3 -c 'import json; print(json.dumps([{"id":"x","title":"A"*100000,"selection":"x"}]))' > "$BUDDY_OUTPUT_CANDIDATES"
            exit 0
            """
        )
        let manifest = try loadManifest(from: pluginDir, dirName: "cmd-cand-big")
        let input = PluginInput(query: "x", sessionId: UUID().uuidString, cwd: "/tmp")

        let result = try await StdinExecutor().execute(manifest, pluginDir: pluginDir, input: input)
        XCTAssertNil(result.candidates, "超 64KiB 应丢弃为 nil")
    }

    // MARK: - 资源清理（defer 删临时文件）

    func test_candidatesChannel_tempFileCleanedUpAfterExecute() async throws {
        // 执行后临时候选文件应被 defer 删除（防累积）
        let pluginDir = try makeCommandPlugin(
            dirName: "cmd-cand-cleanup",
            script: """
            #!/bin/bash
            printf '%s' '[{"id":"x","title":"T","selection":"x"}]' > "$BUDDY_OUTPUT_CANDIDATES"
            echo "$BUDDY_OUTPUT_CANDIDATES"
            exit 0
            """
        )
        let manifest = try loadManifest(from: pluginDir, dirName: "cmd-cand-cleanup")
        let input = PluginInput(query: "x", sessionId: UUID().uuidString, cwd: "/tmp")

        let result = try await StdinExecutor().execute(manifest, pluginDir: pluginDir, input: input)
        let candidatesPath = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidatesPath),
                       "defer 应删除临时候选文件：\(candidatesPath)")
    }

    // MARK: - Helpers

    private func makeCommandPlugin(
        dirName: String,
        script: String,
        timeout: Int = 10
    ) throws -> URL {
        let pluginDir = tmpDir.appendingPathComponent(dirName)
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)

        let scriptURL = pluginDir.appendingPathComponent("run.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let manifestJSON = """
        {
          "name": "\(dirName)",
          "version": "0.1.0",
          "description": "candidate channel test",
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

    private func loadManifest(from pluginDir: URL, dirName: String) throws -> PluginManifest {
        let data = try Data(contentsOf: pluginDir.appendingPathComponent("plugin.json"))
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        try manifest.validate(againstDirName: dirName)
        return manifest
    }
}
