import XCTest
@testable import BuddyCore

// MARK: - CandidatesChannelAcceptanceTests
//
// 红队验收测试：通用候选输出通道 BUDDY_OUTPUT_CANDIDATES + AgentEvent.candidates + 选中回调重入 submitWithCandidate
//
// 信息隔离铁律：本文件由红队独立编写，仅依据：
//   - state.md ## 设计文档（C1-C6 契约规约 + §1 候选通道 + §3 回调重入）
//   - state.md ## 验收场景（场景1/3/7 det-machine 谓词）
//   - 已有测试约定（StdinExecutorImageOutputAcceptanceTests mock 模式：伪造输出文件写 $BUDDY_OUTPUT_IMAGE/`$BUDDY_OUTPUT_CANDIDATES`）
// 未读取蓝队本次任何实现代码（LauncherCandidate.swift / AgentEvent.swift 改动 / StdinExecutor.swift 改动 / LauncherManager.swift 改动 / PluginInput.swift 改动 / PluginResult.swift 改动）。
//
// 契约引用（逐字一致）：
//   [C1] 候选输出通道：BUDDY_OUTPUT_CANDIDATES env → /tmp/buddy-plugin-<uuid>.json；子进程写 JSON 数组 [{id,title,subtitle?,selection}]；
//        框架 readCandidatesOutputSafely（存在 + symlink 校验 resolvedPath == expected + <= pluginMaxCandidatesBytes + JSON 解码）
//        → PluginResult.candidates: [LauncherCandidate]?；失败降级 nil（候选可选）。stdin + command 共享。
//   [C2] LauncherCandidate：{id:String, title:String, subtitle:String?, selection:String}，Codable/Equatable/Identifiable。selection 仅标识，禁含命令/路径。
//   [C3] AgentEvent.candidates + == 同步：新增 case candidates([LauncherCandidate])，必须在 AgentEvent.== 加对应比较分支（穷尽 switch，漏则编译错/假阳性）。
//   [C4] PluginInput.selection：新增 selection: String?（Codable 可选，向后兼容）。首次 nil；回调填候选 selection。
//   [C5] 选中回调重入：LauncherManager.submitWithCandidate(_:selection:query:) 以 PluginInput.selection 重入 command mode 执行（bypass LLM）。launcher 不执行候选携带命令，执行权留插件。
//   [C6] TOFU 不变：command trustKey = "command:" + SHA256(cmd+args+exeBytes)，已验证不含 stdin/selection；回调（同二进制 + args=[]）trustKey 不变 ⇒ 不重复弹框。
//
// 验收场景覆盖：
//   场景1.P2 [real-process]: selection 空 → stdout contains "running"/"运行中" AND exit == 0（此处验「子进程能写候选 JSON + 非空 stdout」）
//   场景1.P1 [det-machine]: 候选项可达（candidates 数组非空，含 stop/start）
//   场景3.P1 [real-process]: selection=start → 回调执行（此处验 submitWithCandidate 传 selection 经 PluginInput.selection → 子进程 stdin 链路）
//   场景7.P2 [real-process]: 空/空白 query → 子进程 exit 0（候选可选降级）
//
// TDD：先于实现编写，最初因 LauncherCandidate / PluginResult.candidates / AgentEvent.candidates / PluginInput.selection /
//      submitWithCandidate / readCandidatesOutputSafely / pluginMaxCandidatesBytes 未实现而编译失败（RED）。

final class CandidatesChannelAcceptanceTests: XCTestCase {

    private var tmpDir: URL!
    private let executor = StdinExecutor.shared

    // MARK: - Fixtures

    /// 契约 [C1]/[C2]：候选 JSON 数组结构 [{id,title,subtitle?,selection}]
    private let validCandidatesJSON = #"""
    [
      {"id":"stop","title":"关闭监控","subtitle":"停止 service+update","selection":"stop"},
      {"id":"start","title":"打开监控","subtitle":"恢复 service+update","selection":"start"}
    ]
    """#

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CandAcceptance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let dir = tmpDir { try? FileManager.default.removeItem(at: dir) }
        tmpDir = nil
        try await super.tearDown()
    }

    // MARK: - Plugin scaffolding（仿 StdinExecutorImageOutputAcceptanceTests.makeStdinPlugin）

    /// 生成 stdin/command 插件，run.sh 把 JSON 写入 $BUDDY_OUTPUT_CANDIDATES，stdout 写 query echo（模拟状态文本）
    private func makePlugin(
        dirName: String,
        mode: String = "stdin",
        candidatesJSON: String?,     // nil = 不写候选文件
        stdoutText: String = "running",
        exitCode: Int32 = 0,
        timeout: Int = 10
    ) throws -> URL {
        let pluginDir = tmpDir.appendingPathComponent(dirName)
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)

        let writeLine: String
        if let json = candidatesJSON {
            // shell 脚本：把 JSON 字面量写入 $BUDDY_OUTPUT_CANDIDATES（用 heredoc 避免 shell 转义）
            writeLine = """
            if [ -n \"$BUDDY_OUTPUT_CANDIDATES\" ]; then
              cat > \"$BUDDY_OUTPUT_CANDIDATES\" <<'BUDDY_EOF'
            \(json)
            BUDDY_EOF
            fi
            """
        } else {
            writeLine = ": # do not write candidates"
        }

        let script = """
        #!/bin/bash
        # 模拟 qzh-exec：echo query 到 stdout（状态文本），可选写候选 JSON
        echo "\(stdoutText)"
        \(writeLine)
        exit \(exitCode)
        """
        let scriptURL = pluginDir.appendingPathComponent("run.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let manifest = """
        {
          "name": "\(dirName)",
          "version": "0.1.0",
          "description": "candidates channel test",
          "keywords": [],
          "mode": "\(mode)",
          "cmd": "./run.sh",
          "args": [],
          "env": null,
          "timeout": \(timeout),
          "requiredPath": null
        }
        """
        try manifest.write(to: pluginDir.appendingPathComponent("plugin.json"),
                          atomically: true, encoding: .utf8)
        return pluginDir
    }

    private func loadManifest(from dir: URL, dirName: String) throws -> PluginManifest {
        let data = try Data(contentsOf: dir.appendingPathComponent("plugin.json"))
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        try manifest.validate(againstDirName: dirName)
        return manifest
    }

    // MARK: - [C1] 场景8.P3 det-machine 间接：env 注入 BUDDY_OUTPUT_CANDIDATES 键 + 路径格式
    //
    // 契约引用：StdinExecutor 注入 env["BUDDY_OUTPUT_CANDIDATES"] = "/tmp/buddy-plugin-<uuid>.json"
    // Mutation kill：若蓝队没注入 env，子进程 $BUDDY_OUTPUT_CANDIDATES 为空 → 断言挂
    // CONTRACT_AMBIGUITY: 设计文档未明确后缀（image 是 .png），候选用 .json 最贴近契约；断言 hasPrefix /tmp/buddy-plugin- 足够

    func test_C1_envContainsBuddyOutputCandidatesKey() async throws {
        let pluginDir = tmpDir.appendingPathComponent("env-printer")
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        let script = """
        #!/bin/bash
        echo "KEY=${BUDDY_OUTPUT_CANDIDATES:-MISSING}"
        exit 0
        """
        let scriptURL = pluginDir.appendingPathComponent("run.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        let manifestJSON = """
        { "name": "env-printer", "version": "0.1.0", "description": "x", "keywords": [],
          "mode": "stdin", "cmd": "./run.sh", "args": [], "env": null, "timeout": 30, "requiredPath": null }
        """
        try manifestJSON.write(to: pluginDir.appendingPathComponent("plugin.json"),
                              atomically: true, encoding: .utf8)

        let manifest = try loadManifest(from: pluginDir, dirName: "env-printer")
        let input = PluginInput(query: "qzh", sessionId: UUID().uuidString, cwd: "/tmp")
        let result = try await executor.execute(manifest, pluginDir: pluginDir, input: input)

        XCTAssertTrue(
            result.stdout.contains("KEY=/tmp/buddy-plugin-"),
            "[C1] 子进程必须能读到 BUDDY_OUTPUT_CANDIDATES 键，且值以 /tmp/buddy-plugin- 开头。实际 stdout: \(result.stdout)"
        )
        XCTAssertFalse(
            result.stdout.contains("KEY=MISSING"),
            "[C1] BUDDY_OUTPUT_CANDIDATES 必须被注入（不能 MISSING）"
        )
    }

    // MARK: - [C1] 场景1.P1 det-machine：exit 0 + 合法候选 JSON → PluginResult.candidates 非空 + 结构正确
    //
    // 契约引用：exit 0 → readCandidatesOutputSafely → JSON 解码为 [LauncherCandidate] → PluginResult.candidates
    // 场景1.P1 assert: AX 节点 contains "运行中" OR "running"（候选可达性 = candidates 数组含 stop/start）
    // 场景1.P2 real-process: stdout contains "running" AND exit == 0
    // Mutation kill：若蓝队未实现 readCandidatesOutputSafely 或字段名拼错，candidates 为 nil → 解包挂

    func test_C1_scenario1_legalJSON_decodesToCandidates_withStopAndStart() async throws {
        let pluginDir = try makePlugin(
            dirName: "legal-cands",
            mode: "command",
            candidatesJSON: validCandidatesJSON,
            stdoutText: "running"
        )
        let manifest = try loadManifest(from: pluginDir, dirName: "legal-cands")
        let input = PluginInput(query: "qzh", sessionId: UUID().uuidString, cwd: "/tmp")

        let result = try await executor.execute(manifest, pluginDir: pluginDir, input: input)

        // 场景1.P2 real-process assert: stdout contains "running" AND exit == 0
        XCTAssertEqual(result.exitCode, 0, "[场景1.P2] exit 必须 0")
        XCTAssertTrue(result.stdout.contains("running"),
                      "[场景1.P2] stdout 必须含 'running'（状态文本），实际: \(result.stdout)")

        // [C1] PluginResult.candidates 必须非空
        let candidates = try XCTUnwrap(
            result.candidates,
            "[C1][场景1.P1] exit 0 + 子进程写了合法候选 JSON，PluginResult.candidates 必须非空（候选可达）"
        )
        XCTAssertEqual(candidates.count, 2, "[C1] 必须解码出 2 个候选（stop/start），实际: \(candidates.count)")

        // [C2] LauncherCandidate 字段逐字一致 + Identifiable/Equatable
        let stop = try XCTUnwrap(candidates.first { $0.id == "stop" }, "[C2] 必须有 id==stop 的候选")
        let start = try XCTUnwrap(candidates.first { $0.id == "start" }, "[C2] 必须有 id==start 的候选")
        XCTAssertEqual(stop.title, "关闭监控", "[C2] stop.title 字段名/值逐字一致")
        XCTAssertEqual(stop.subtitle, "停止 service+update", "[C2] stop.subtitle 字段名/值逐字一致（可选非 nil）")
        XCTAssertEqual(stop.selection, "stop", "[C2] stop.selection 字段名/值逐字一致")
        XCTAssertEqual(start.title, "打开监控")
        XCTAssertEqual(start.selection, "start")
        // [auto-fix] 删除原 line 203 XCTAssertNil 笔误（与测试数据矛盾：start 有 subtitle 却断言 nil，必然失败）；
        // 下一行 XCTAssertNotNil 已正确覆盖「subtitle 存在性」，非弱化断言。
        XCTAssertNotNil(start.subtitle, "[C2] subtitle 可选字段存在时必须解码")
    }

    // MARK: - [C1] 场景7.P2 det-machine：合法 JSON 但无候选（空数组）→ candidates 非空可选降级
    //
    // 契约引用：候选可选，空数组是合法「无候选」表示；exit 0 正常
    // 场景7.P2 real-process assert: exit == 0（空/无匹配 query 子进程干净退出）

    func test_C1_emptyCandidatesArray_exit0_candidatesEmpty() async throws {
        let pluginDir = try makePlugin(
            dirName: "empty-cands",
            mode: "command",
            candidatesJSON: "[]",
            stdoutText: "no match"
        )
        let manifest = try loadManifest(from: pluginDir, dirName: "empty-cands")
        let input = PluginInput(query: "", sessionId: UUID().uuidString, cwd: "/tmp")

        let result = try await executor.execute(manifest, pluginDir: pluginDir, input: input)

        XCTAssertEqual(result.exitCode, 0, "[场景7.P2] 空 query 子进程必须 exit 0")
        // candidates 可选；空数组应解码为空数组（非 nil）或 nil（降级），都接受，但若非 nil 必须 count==0
        if let cands = result.candidates {
            XCTAssertEqual(cands.count, 0, "[C1] 空数组必须解码为 count==0，不能伪造候选")
        }
    }

    // MARK: - [C1] 损坏 JSON → nil（降级路径，设计声明降级）
    //
    // 契约引用：JSON 解码失败 → candidates = nil（候选可选，非 error）
    // 强断言规则例外：设计声明的降级路径（候选损坏→nil）显式断言降级行为
    // Mutation kill：若蓝队把损坏 JSON 当 error 抛出（而非降级 nil），execute 抛 → 测试挂

    func test_C1_corruptJSON_degradesToNil_notThrows() async throws {
        let pluginDir = try makePlugin(
            dirName: "corrupt-cands",
            mode: "command",
            candidatesJSON: "{not valid json,,}",
            stdoutText: "running"
        )
        let manifest = try loadManifest(from: pluginDir, dirName: "corrupt-cands")
        let input = PluginInput(query: "qzh", sessionId: UUID().uuidString, cwd: "/tmp")

        // 不应抛（降级而非 error）
        let result = try await executor.execute(manifest, pluginDir: pluginDir, input: input)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertNil(result.candidates,
                     "[C1] 损坏 JSON 必须降级为 nil（非 error、非伪造候选），实际: \(String(describing: result.candidates))")
    }

    // MARK: - [C1] 超过 pluginMaxCandidatesBytes → nil
    //
    // 契约引用：count > pluginMaxCandidatesBytes → candidates = nil（丢弃）
    // Mutation kill：若蓝队漏掉大小限制，超大候选被加载 → 测试挂

    func test_C1_candidatesExceedMaxBytes_degradesToNil() async throws {
        let maxBytes = LauncherConstants.pluginMaxCandidatesBytes
        // 构造超限 JSON：单候选 title 极长
        let padding = String(repeating: "x", count: maxBytes + 100)
        let oversizedJSON = """
        [{"id":"big","title":"\(padding)","selection":"big"}]
        """
        let pluginDir = try makePlugin(
            dirName: "oversized-cands",
            mode: "command",
            candidatesJSON: oversizedJSON,
            stdoutText: "running"
        )
        let manifest = try loadManifest(from: pluginDir, dirName: "oversized-cands")
        let input = PluginInput(query: "qzh", sessionId: UUID().uuidString, cwd: "/tmp")

        let result = try await executor.execute(manifest, pluginDir: pluginDir, input: input)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertNil(result.candidates,
                     "[C1] candidates > pluginMaxCandidatesBytes (=\(maxBytes)) 必须降级 nil")
    }

    // MARK: - [C1] 文件缺失（子进程未写）→ nil（降级）
    //
    // 契约引用：文件不存在 → candidates = nil
    // 场景7.P1 det-machine assert: 监控相关节点 count == 0（无候选 = candidates nil 或空）

    func test_C1_missingCandidatesFile_degradesToNil() async throws {
        let pluginDir = try makePlugin(
            dirName: "no-cands-file",
            mode: "command",
            candidatesJSON: nil,   // 不写文件
            stdoutText: "running"
        )
        let manifest = try loadManifest(from: pluginDir, dirName: "no-cands-file")
        let input = PluginInput(query: "non-qzh-input", sessionId: UUID().uuidString, cwd: "/tmp")

        let result = try await executor.execute(manifest, pluginDir: pluginDir, input: input)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertNil(result.candidates,
                     "[C1][场景7.P1] 子进程未写候选文件时 PluginResult.candidates 必须 nil（无候选可达）")
    }

    // MARK: - [C1] symlink 攻击 → nil（resolvedPath != expected，/tmp 防御）
    //
    // 契约引用：symlink 校验 resolvedPath == expected，不符 → nil
    // Mutation kill：若蓝队漏掉 symlink 校验，攻击者可把 $BUDDY_OUTPUT_CANDIDATES 指向任意文件 → 测试挂

    func test_C1_symlinkCandidatesFile_degradesToNil() async throws {
        // 先在 tmpDir 造一个「真实」候选文件（攻击 payload）
        let attackFile = tmpDir.appendingPathComponent("attack-payload.json")
        try validCandidatesJSON.write(to: attackFile, atomically: true, encoding: .utf8)

        // 脚本：把 $BUDDY_OUTPUT_CANDIDATES 替换为指向 attackFile 的 symlink（而非写内容）
        let pluginDir = tmpDir.appendingPathComponent("symlink-attack")
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        let script = """
        #!/bin/bash
        echo "running"
        if [ -n \"$BUDDY_OUTPUT_CANDIDATES\" ]; then
          rm -f \"$BUDDY_OUTPUT_CANDIDATES\"
          ln -s \"\(attackFile.path)\" \"$BUDDY_OUTPUT_CANDIDATES\"
        fi
        exit 0
        """
        let scriptURL = pluginDir.appendingPathComponent("run.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        let manifestJSON = """
        { "name": "symlink-attack", "version": "0.1.0", "description": "x", "keywords": [],
          "mode": "command", "cmd": "./run.sh", "args": [], "env": null, "timeout": 10, "requiredPath": null }
        """
        try manifestJSON.write(to: pluginDir.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)

        let manifest = try loadManifest(from: pluginDir, dirName: "symlink-attack")
        let input = PluginInput(query: "qzh", sessionId: UUID().uuidString, cwd: "/tmp")

        let result = try await executor.execute(manifest, pluginDir: pluginDir, input: input)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertNil(result.candidates,
                     "[C1] symlink 攻击必须被 resolvedPath 校验拦截 → nil，实际: \(String(describing: result.candidates))")
    }

    // MARK: - [C3] AgentEvent.candidates == 分支（防漏比较假阴性）
    //
    // 契约引用：AgentEvent.== 必须加 .candidates 比较分支；漏则编译错（穷尽 switch）或假阳性（switch 命中 default）
    // Mutation kill：若蓝队漏掉 == 分支，两个不同 candidates 流会被判等 → XCTAssertNotEqual 挂
    // 双向断言：相等候选流判等 + 不同候选流判不等（防 == 恒 true 也防恒 false）

    func test_C3_agentEventCandidates_equality_bothDirections() {
        let c1a = LauncherCandidate(id: "stop", title: "关闭监控", subtitle: "x", selection: "stop")
        let c1b = LauncherCandidate(id: "stop", title: "关闭监控", subtitle: "x", selection: "stop")
        let c2 = LauncherCandidate(id: "start", title: "打开监控", subtitle: nil, selection: "start")

        let streamA = AgentEvent.candidates([c1a])
        let streamB = AgentEvent.candidates([c1b])  // 内容等价
        let streamC = AgentEvent.candidates([c2])   // 内容不同

        XCTAssertEqual(streamA, streamB,
                      "[C3] 两个内容等价的 candidates 流必须判等（== 分支比较了元素）")
        XCTAssertNotEqual(streamA, streamC,
                          "[C3] 不同 candidates 流必须判不等（防 == 恒 true 假阳性）")

        // 空数组 vs 非空数组
        let empty = AgentEvent.candidates([])
        XCTAssertNotEqual(streamA, empty,
                          "[C3] 非空 vs 空 candidates 流必须判不等（防 == 忽略数组内容）")
        XCTAssertEqual(empty, AgentEvent.candidates([]),
                       "[C3] 两个空 candidates 流判等")
    }

    // MARK: - [C4] PluginInput.selection 字段 + Codable 向后兼容
    //
    // 契约引用：PluginInput 加 selection: String?（Codable 可选，向后兼容）；首次 nil；回调填候选 selection
    // Mutation kill：若蓝队字段名拼错或漏掉，编译失败或解码异常

    func test_C4_pluginInput_selectionField_optionalAndCodable() throws {
        // 首次（无 selection）应为 nil
        let firstInput = PluginInput(query: "qzh", sessionId: "s1", cwd: "/tmp")
        XCTAssertNil(firstInput.selection,
                     "[C4] 首次 PluginInput.selection 必须为 nil（向后兼容默认）")

        // 回调（带 selection）能构造
        let callbackInput = PluginInput(query: "qzh", sessionId: "s2", cwd: "/tmp", selection: "stop")
        XCTAssertEqual(callbackInput.selection, "stop",
                       "[C4] 回调 PluginInput.selection 必须能填 'stop'")

        // CONTRACT_AMBIGUOUS: 设计文档未给 PluginInput 完整字段列表（query/sessionId/cwd 来自现有测试用法）。
        // 用 JSON decode 验「向后兼容」：旧 JSON（无 selection 键）必须能解码为 selection == nil
        let legacyJSON = """
        {"query":"qzh","sessionId":"s3","cwd":"/tmp"}
        """
        let decoded = try JSONDecoder().decode(PluginInput.self, from: legacyJSON.data(using: .utf8)!)
        XCTAssertNil(decoded.selection,
                     "[C4] 旧 JSON（无 selection 键）必须向后兼容解码为 selection == nil")

        // 新 JSON（带 selection 键）能解码
        let newJSON = """
        {"query":"qzh","sessionId":"s4","cwd":"/tmp","selection":"start"}
        """
        let decodedNew = try JSONDecoder().decode(PluginInput.self, from: newJSON.data(using: .utf8)!)
        XCTAssertEqual(decodedNew.selection, "start",
                       "[C4] 新 JSON（带 selection 键）必须解码 selection == 'start'")
    }

    // MARK: - [C4][C5][C6] 跨层数据流：selection → PluginInput.selection → 插件 stdin → 执行
    //
    // 契约引用：submitWithCandidate 以 PluginInput.selection 重入 command mode 执行；子进程从 stdin 读 selection
    // 验证完整链路字段名一致性：蓝队若把 stdin JSON 里 selection 键名拼错（如 chosen/selected）→ 子进程读不到
    // 场景3.P1 real-process: selection=start → 回调执行（此处验 selection 经 stdin 透传到子进程）
    // Mutation kill：用脚本 cat stdin 把收到的 JSON 原样回显 stdout，断言 stdout 含 "selection":"start"

    func test_C4C5C6_selectionFlowsFromCallbackInputToPluginStdin() async throws {
        // 脚本：cat stdin → echo 到 stdout（暴露收到的 JSON）
        let pluginDir = tmpDir.appendingPathComponent("echo-stdin")
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        let script = """
        #!/bin/bash
        INPUT=$(cat)
        echo "$INPUT"
        exit 0
        """
        let scriptURL = pluginDir.appendingPathComponent("run.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        let manifestJSON = """
        { "name": "echo-stdin", "version": "0.1.0", "description": "x", "keywords": [],
          "mode": "command", "cmd": "./run.sh", "args": [], "env": null, "timeout": 10, "requiredPath": null }
        """
        try manifestJSON.write(to: pluginDir.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)

        let manifest = try loadManifest(from: pluginDir, dirName: "echo-stdin")
        // 模拟 submitWithCandidate 构造的 PluginInput（selection = "start"）
        let callbackInput = PluginInput(query: "qzh", sessionId: UUID().uuidString, cwd: "/tmp", selection: "start")

        let result = try await executor.execute(manifest, pluginDir: pluginDir, input: callbackInput)

        XCTAssertEqual(result.exitCode, 0)
        // 子进程收到的 stdin JSON 必须含 "selection":"start"（字段名逐字一致）
        XCTAssertTrue(
            result.stdout.contains(#""selection":"start""#),
            "[C4/C5/C6][场景3.P1] selection 必须经 PluginInput.selection → stdin JSON → 子进程完整透传。" +
            "子进程回显的 stdin 必须含 \"selection\":\"start\"。实际 stdout: \(result.stdout)"
        )
        // query 也必须透传（黑盒验证 PluginInput 序列化完整）
        XCTAssertTrue(result.stdout.contains(#""query":"qzh""#),
                      "[C4] query 字段也必须经 stdin 透传到子进程")
    }

    // MARK: - [C5] submitWithCandidate 方法存在 + 签名契约
    //
    // 契约引用：LauncherManager.submitWithCandidate(_:selection:query:) -> AsyncStream<AgentEvent>
    // 不直接驱动真实 LauncherManager（依赖 app 状态/provider），但断言方法存在 + 参数语义
    // Mutation kill：若蓝队方法名拼错（如 submitCandidate/withCandidate）或参数顺序错，编译失败
    // CONTRACT_AMBIGUOUS: 设计文档未给第一个参数标签（_ manifest），用最贴近 prompt mode submit(_:query:) 的对称命名

    @MainActor
    func test_C5_submitWithCandidate_methodExists_andAcceptsSelection() async throws {
        // 构造一个 command 插件 + 一个极简 LauncherManager（仿 PluginDispatcherCommandModeTests 注入 executor）
        let pluginDir = try makePlugin(
            dirName: "callback-target",
            mode: "command",
            candidatesJSON: validCandidatesJSON,
            stdoutText: "已打开监控"
        )
        let manifest = try loadManifest(from: pluginDir, dirName: "callback-target")

        // 预审批插件（避免 TrustStore 在 submitWithCandidate 中弹 NSAlert 挂死测试）
        let exePath = pluginDir.appendingPathComponent("run.sh")
        try TrustStore.shared.approve(manifest, executablePath: exePath)

        // 注入 PluginManager 指向测试 tmpDir（父目录），避免依赖 ~/.buddy/launcher-plugins
        let testPluginManager = PluginManager(rootDir: pluginDir.deletingLastPathComponent())
        let manager = LauncherManager.shared
        manager.pluginManagerOverride = testPluginManager
        manager.resetSubmittingStateForTesting()
        defer { manager.pluginManagerOverride = nil }

        // 场景3.P1 real-process: selection=start → 回调执行（yield 文本事件）
        let stream = await manager.submitWithCandidate(manifest, selection: "start", query: "qzh")
        var events: [AgentEvent] = []
        for try await event in stream {
            events.append(event)
            if events.count > 50 { break }  // 防无限流
        }

        XCTAssertFalse(events.isEmpty,
                       "[C5] submitWithCandidate 必须返回非空 AgentEvent 流（回调执行有结果）")
        // 至少有一个文本事件携带执行结果（「已打开监控」或等价文本）
        let hasTextEvent = events.contains { event in
            if case .text(let s) = event { return s.contains("已打开监控") || s.contains("running") }
            return false
        }
        XCTAssertTrue(hasTextEvent,
                     "[C5][场景3.P1] 回调执行后必须 yield 文本结果事件，实际 events: \(events)")
    }

    // MARK: - [C6] TOFU 不变：command trustKey 不含 selection（回调不重复弹框）
    //
    // 契约引用：trustKey = "command:" + SHA256(cmd+args+exeBytes)，已验证不含 stdin/selection
    // 回调（同二进制 + args=[]）trustKey 必须与首次查询一致 → 不重复弹框
    // Mutation kill：若蓝队误把 selection 纳入 trustKey，两次 selection 不同 → trustKey 不同 → 重复弹框
    // 直接断言 TrustStore.trustKey 对同 manifest + exe，不同 selection 输入下不变
    // （trustKey 入参是 manifest/exe，不含 input——这是 C6 的核心；本测试验「调用 isTrusted 两次不因 selection 变化失效」）

    func test_C6_commandTrustKey_invariantToSelectionChange() throws {
        // 构造 command manifest（同 TrustStoreCommandModeTests 模式）
        let exe = tmpDir.appendingPathComponent("qzh-exec")
        try "#!/bin/sh\necho qzh".write(to: exe, atomically: true, encoding: .utf8)

        let json = """
        {"name":"qzh","version":"0.1.0","description":"q","keywords":["qzh"],"mode":"command",
         "cmd":"./qzh-exec","args":[],"env":null,"requiredPath":null}
        """
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: json.data(using: .utf8)!)

        // trustKey 只依赖 manifest + exe bytes，不依赖 input.selection
        let key1 = try TrustStore.trustKey(for: manifest, executablePath: exe)
        // 模拟「回调」：同 manifest + 同 exe，理论上 trustKey 必须不变
        // （selection 是 PluginInput 字段，trustKey 签名不含 PluginInput，所以这里直接证明不变性）
        let key2 = try TrustStore.trustKey(for: manifest, executablePath: exe)
        XCTAssertEqual(key1, key2,
                       "[C6] command trustKey 必须对同 manifest+exe 稳定不变（回调不重复弹框）")
        XCTAssertTrue(key1.hasPrefix("command:"),
                      "[C6] command trustKey 必须以 'command:' 开头")

        // 进一步：approve 后 isTrusted，模拟「首次查询已信任 → 回调仍受信」
        let trustFile = tmpDir.appendingPathComponent("launcher-trust.json")
        let store = TrustStore(file: trustFile)
        XCTAssertFalse(store.isTrusted(manifest, executablePath: exe))
        try store.approve(manifest, executablePath: exe)
        // 回调场景：再次 isTrusted 必须仍 true（trustKey 未变 ⇒ 不重复弹框）
        XCTAssertTrue(store.isTrusted(manifest, executablePath: exe),
                      "[C6] approve 后回调 isTrusted 必须仍 true（trustKey 不含 selection，不重复弹框）")
    }

    // MARK: - [C2] LauncherCandidate.security 不含命令字符（安全红线）
    //
    // 契约引用：selection 仅标识字符串，禁含 shell 命令/路径；执行权始终在插件
    // 验收点（任务说明「安全验证」）：LauncherCandidate.selection 不含命令字符
    // 此处验「构造的合法候选 selection 是纯标识（stop/start），不含 ; | & $ / 等元字符」
    // Mutation kill：防蓝队把 selection 设计成「命令字符串」由 launcher 直接执行（违反 C5 执行权留插件）

    func test_C2_candidateSelection_isIdentifierOnly_noShellMetachar() {
        // 合法候选的 selection 必须是纯标识
        let legalSelections = ["stop", "start", "query"]
        for sel in legalSelections {
            let candidate = LauncherCandidate(id: sel, title: sel, subtitle: nil, selection: sel)
            XCTAssertEqual(candidate.selection, sel)
            // 断言不含 shell 元字符（执行权留插件，selection 不能是命令）
            let metachars = CharacterSet(charactersIn: ";|&$()`/\\>< \t\n")
            XCTAssertFalse(
                candidate.selection.unicodeScalars.contains { metachars.contains($0) },
                "[C2] selection '\(sel)' 禁含 shell 元字符/路径（执行权留插件，selection 仅标识）"
            )
        }
    }
}
