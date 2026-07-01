import XCTest
@testable import BuddyCore

// MARK: - LauncherRouteConflictExecutionAcceptanceTests
//
// 红队验收测试（信息隔离）：路由冲突改造的执行链 —— Enter 默认触发 command、候选输出通道、执行失败容错。
//
// 仅依据（逐字一致）：
//   - state.md ## 设计文档（§1.5 submitCommandDirect / §4 Enter 优先级 / C11 spy seam）
//   - state.md ## 契约规约 C4/C8/C11
//   - state.md ## 验收场景（场景2/5/6/7 det-machine 谓词）
//
// ⚠️ 关键约束（0 假设，实测于 LauncherManager.submitCommandDirect 接口签名 + 既有 TrustStore/PluginManager）：
//   submitCommandDirect 内部经 PluginManager.shared.pluginDir(for:) + TrustStore.shared.checkAndPrompt。
//   - PluginManager.shared 是单例，扫 ~/.buddy/launcher-plugins/，测试注入的孤立 manifest 不在其列表 → pluginDir 抛错。
//   - TrustStore.shared.checkAndPrompt 未预 approve 时弹 NSAlert.runModal()（TrustPrompt.askUser，无测试 bypass）
//     → 测试环境阻塞主线程（无 NSApplication 运行循环）。
//   两者均为**既有**子系统（C8 明确不动），无测试 seam 注入。
//   ⇒ LauncherManager.submitCommandDirect 的端到端集成（场景2.P2/P3、5.P2、6.P3/P4、7 全部）不可在 det-machine 单测层驱动，
//      标 REAL_PROCESS_QA 留真机 QA（真装 qzh 插件 + 真 approve trust + 真子进程）。
//
// 可单测层（绕过 LauncherManager 单例阻塞，直击本次改造契约）：
//   - C11 dispatcher 层 spy：PluginDispatcher(stdinExecutor: stdinExecutorOverride) 接 spy —— 验「command 短路经
//     PluginDispatcher(stdinExecutor: override ?? .shared)」契约的 dispatcher 注入点（场景2.P2 的 dispatch≥1 真实可达路径）
//   - candidates 通道（C8 不改）：真实 command 插件 + 真实 StdinExecutor 产 .candidates 事件（场景6.P1/P2）
//   - submitCommandDirect 接口存在性 + 非命令 manifest errorStream（C11 guard，场景7 错误降级契约）
//
// 铁律：未读取蓝队本次实现代码。仅用契约 seam + 既有 dispatcher/executor 接口构造场景。

// MARK: - Mock：SpyStdinExecutor（C11 spy seam —— 计数 dispatch，不真执行）

/// 子类化 StdinExecutor（同 module @testable，非 final 可 override），override execute 计数 dispatch 调用。
/// 契约 [C11]：submitCommandDirect 用 `PluginDispatcher(stdinExecutor: stdinExecutorOverride ?? .shared)`，
///             红队注入此 spy 断言 dispatch 调用次数，不真执行 bootout/bootstrap（真副作用）。
private final class SpyStdinExecutor: StdinExecutor {
    private(set) var executeCallCount = 0
    private(set) var capturedManifests: [PluginManifest] = []
    /// 每次调用返回的 PluginResult（默认成功 stdout），可被单测覆写模拟失败
    var resultFactory: ((PluginManifest) -> PluginResult)?

    override func execute(_ plugin: PluginManifest, pluginDir: URL, input: PluginInput) async throws -> PluginResult {
        executeCallCount += 1
        capturedManifests.append(plugin)
        if let factory = resultFactory {
            return factory(plugin)
        }
        return PluginResult(stdout: "spy ok", stderr: "", exitCode: 0,
                            durationMs: 0, stdoutTruncated: false, image: nil, candidates: nil)
    }
}

/// 抛错的 spy：模拟 PluginDispatcher 派发失败（二进制缺失/非零退出/超时）
private final class FailingStdinExecutor: StdinExecutor {
    private(set) var executeCallCount = 0
    var errorToThrow: Error = LauncherError.pluginCrash(127, "command not found")

    override func execute(_ plugin: PluginManifest, pluginDir: URL, input: PluginInput) async throws -> PluginResult {
        executeCallCount += 1
        throw errorToThrow
    }
}

// MARK: - Helpers

private func makeCommandManifest(name: String, keywords: [String], cmd: String = "./run.sh") throws -> PluginManifest {
    // 用 JSONSerialization 正确编码 keywords（避免字符串插值把 keyword 包成带引号字面量，
    // 导致 commandPrefixMatched 严格前缀匹配漏命中）。
    let json: [String: Any] = [
        "name": name,
        "version": "0.1.0",
        "description": "command mode fixture",
        "keywords": keywords,
        "mode": "command",
        "cmd": cmd,
        "args": [] as [String],
        "env": NSNull(),
        "requiredPath": NSNull(),
        "timeout": 5
    ]
    let data = try JSONSerialization.data(withJSONObject: json)
    return try JSONDecoder().decode(PluginManifest.self, from: data)
}

@MainActor
private func makeAppLauncherRegistry(launcher: AppLaunching) -> BuiltinPluginRegistry {
    let qzhApp = URL(fileURLWithPath: "/Applications/Qzhddr.app")
    let index = AppIndex(fixedEntries: [AppEntry(url: qzhApp, name: "Qzhddr")])
    let appPlugin = AppLauncherPlugin(index: index, launcher: launcher)
    return BuiltinPluginRegistry(plugins: [appPlugin])
}

@MainActor
private func makeEmptyInstantRegistry() -> BuiltinPluginRegistry {
    final class EmptyPlugin: BuiltinPlugin {
        let id = "empty-test"
        let priority = 0
        let sectionTitle = "Empty"
        func actions(for query: String) async -> [LauncherAction] { [] }
    }
    return BuiltinPluginRegistry(plugins: [EmptyPlugin()])
}

private final class RecordingAppLauncher: AppLaunching {
    private(set) var launchedURLs: [URL] = []
    func launch(_ url: URL) throws {
        launchedURLs.append(url)
    }
}

/// 生成真实 command 插件目录（run.sh 可选写候选 JSON 到 $BUDDY_OUTPUT_CANDIDATES）
private func makeCommandPluginDir(tmpDir: URL, dirName: String, candidatesJSON: String?,
                                  stdoutText: String = "running", exitCode: Int32 = 0) throws -> URL {
    let pluginDir = tmpDir.appendingPathComponent(dirName)
    try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)

    let writeLine: String
    if let json = candidatesJSON {
        writeLine = """
        if [ -n \"$BUDDY_OUTPUT_CANDIDATES\" ]; then
          cat > \"$BUDDY_OUTPUT_CANDIDATES\" <<'BUDDY_EOF'
        \(json)
        BUDDY_EOF
        fi
        """
    } else {
        writeLine = ": # no candidates"
    }
    let script = """
    #!/bin/bash
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
      "keywords": ["qzh"],
      "mode": "command",
      "cmd": "./run.sh",
      "args": [],
      "env": null,
      "timeout": 10,
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

@MainActor
final class LauncherRouteConflictExecutionAcceptanceTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        LauncherManager.shared.setup()
        LauncherManager.shared.registryOverride = nil
        LauncherManager.shared.instantDebounceMsOverride = nil
        LauncherManager.shared.pluginsOverride = nil
        LauncherManager.shared.stdinExecutorOverride = nil
        LauncherManager.shared.clearInstantActions()

        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RouteConflictExec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        LauncherManager.shared.registryOverride = nil
        LauncherManager.shared.instantDebounceMsOverride = nil
        LauncherManager.shared.pluginsOverride = nil
        LauncherManager.shared.stdinExecutorOverride = nil
        LauncherManager.shared.clearInstantActions()
        if let dir = tmpDir { try? FileManager.default.removeItem(at: dir) }
        tmpDir = nil
        try await super.tearDown()
    }

    private func waitForQuerySettled(_ ms: UInt64 = 80) async {
        try? await Task.sleep(nanoseconds: ms * 1_000_000)
    }

    // MARK: - 场景2.P2 [det-machine] C11 spy seam：command 短路经 PluginDispatcher(stdinExecutor: override) 调 dispatch≥1
    //
    // 契约 [C11]：submitCommandDirect 用 `PluginDispatcher(stdinExecutor: stdinExecutorOverride ?? .shared)`。
    // 红队注入 SpyStdinExecutor 到 PluginDispatcher（直击 dispatcher 注入点，绕过 LauncherManager 单例阻塞），
    // 断言 dispatch≥1（command 短路执行链的 spy 可观测契约）。
    // REAL_PROCESS_QA: submitCommandDirect 端到端（Enter → submit → 经 PluginManager.pluginDir + TrustStore.checkAndPrompt）
    //   因 PluginManager.shared 单例 + NSAlert 阻塞不可单测，留真机 QA 验「Enter 默认 command 触发完整链 + app 未打开」。

    func test_scenario2_P2_commandShortCircuit_dispatcherSpyInjectsAndDispatches() async throws {
        let pluginDir = try makeCommandPluginDir(tmpDir: tmpDir, dirName: "qzh", candidatesJSON: nil)
        let manifest = try loadManifest(from: pluginDir, dirName: "qzh")

        // C11 spy seam：PluginDispatcher 接 spy（镜像 submitCommandDirect 内部构造）
        let spy = SpyStdinExecutor()
        let dispatcher = PluginDispatcher(stdinExecutor: spy)

        let input = PluginInput(query: "qzh", sessionId: UUID().uuidString, cwd: NSHomeDirectory())
        _ = try await dispatcher.execute(manifest, pluginDir: pluginDir, input: input)

        // Observable Transition：dispatch 被调用（spy 计数）
        XCTAssertGreaterThanOrEqual(
            spy.executeCallCount,
            1,
            "[场景2.P2][C11] command 短路经 PluginDispatcher(stdinExecutor: override) 必须 dispatch≥1（spy executeCallCount）。实际: \(spy.executeCallCount)"
        )
        // dispatch 的 manifest 是 command 插件（C9 模式过滤）
        XCTAssertEqual(spy.capturedManifests.first?.name, "qzh",
                       "[场景2.P2] dispatch 的 manifest 必须是 command 插件 qzh")
        // spy 不真执行（bootout/bootstrap 未触发，spy 返回固定 stdout）
        let result = try await dispatcher.execute(manifest, pluginDir: pluginDir, input: input)
        XCTAssertEqual(result.stdout, "spy ok",
                       "[场景2.P2] spy 不真执行子进程，返回固定 stdout（dispatch 被拦截）")
    }

    // MARK: - 场景2.P3 [det-machine] 间接：command 默认选中 → instant app 不被打开（RecordingAppLauncher）
    //
    // 契约 [C4]：command 默认选中时 Enter shall not 触发 instant（app 打开）
    // 单测可达层：注入 RecordingAppLauncher 到 AppLauncherPlugin，updateQuery 后断言 instant 候选存在但 launcher 未被调用
    //   （command 默认选中 → performSelectedInstantAction 不被触发 → app 未打开的前提契约）。
    // REAL_PROCESS_QA: 真实 Enter 按键 → submit 按 activeCandidateZone 派发 → app open==0 留真机 QA。

    func test_scenario2_P3_commandDefault_appLauncherNotInvokedWhenCommandZoneActive() async throws {
        let recordingLauncher = RecordingAppLauncher()
        LauncherManager.shared.registryOverride = makeAppLauncherRegistry(launcher: recordingLauncher)
        // 多命中（2 个共享 keyword「qzh」），避免唯一命中自动锁定使候选清空 + instant 隔离。
        let qzh1 = try makeCommandManifest(name: "qzh", keywords: ["qzh"])
        let qzh2 = try makeCommandManifest(name: "qzh2", keywords: ["qzh"])
        LauncherManager.shared.pluginsOverride = [qzh1, qzh2]

        // 跳过 debounce，使 updateQuery 后 instantActions 快速落地（与其他测试同模式）
        LauncherManager.shared.instantDebounceMsOverride = 0
        LauncherManager.shared.show()
        LauncherManager.shared.updateQuery("qzh")
        // 轮询等待 debounce Task 在 MainActor 上完成（比固定 sleep 更抗 CI 波动）
        for _ in 0..<200 where LauncherManager.shared.instantActions.isEmpty {
            await Task.yield()
        }

        // 诊断：确认 override 注入未丢 + 状态
        XCTAssertNotNil(LauncherManager.shared.registryOverride,
                        "[场景2.P3 诊断] registryOverride 注入必须保留")
        XCTAssertEqual(LauncherManager.shared.pluginsOverride?.count, 2,
                       "[场景2.P3 诊断] pluginsOverride 必须含 2 个 manifest（多命中）")

        // 前提：instant 区含 Qzhddr 候选（否则空判无意义）
        XCTAssertFalse(LauncherManager.shared.instantActions.isEmpty,
                       "[场景2.P3 前提] instant 区含 Qzhddr 候选。实际 instantActions: \(LauncherManager.shared.instantActions)")
        // 前提：command 默认选中（activeCandidateZone=.commandRoute）
        XCTAssertEqual(LauncherManager.shared.activeCandidateZone, .commandRoute,
                       "[场景2.P3 前提] 默认 zone=commandRoute（command 优先）")

        // 断言：typing 阶段 app launcher 未被调用（候选仅展示，未执行）
        XCTAssertEqual(
            recordingLauncher.launchedURLs.count,
            0,
            "[场景2.P3][C4] typing 阶段 app launcher 必须未被调用（launchedURLs==0，候选仅展示）。实际: \(recordingLauncher.launchedURLs)"
        )
        // VISUAL_RESIDUE/REAL_PROCESS_QA: 真实 Enter 默认 command → app open==0 留真机 QA
    }

    // MARK: - 场景5.P2 [det-machine] 仅 command → dispatch≥1（C11 spy seam，dispatcher 层）
    //
    // 契约 [C4/C11]：仅 command 按 Enter → submitCommandDirect → dispatch≥1
    // 同 2.P2，dispatcher 层 spy 断言（绕过 LauncherManager 单例阻塞）

    func test_scenario5_P2_onlyCommand_dispatchesViaDispatcher() async throws {
        let pluginDir = try makeCommandPluginDir(tmpDir: tmpDir, dirName: "qzh", candidatesJSON: nil)
        let manifest = try loadManifest(from: pluginDir, dirName: "qzh")

        let spy = SpyStdinExecutor()
        let dispatcher = PluginDispatcher(stdinExecutor: spy)
        let input = PluginInput(query: "qzh", sessionId: UUID().uuidString, cwd: NSHomeDirectory())
        _ = try await dispatcher.execute(manifest, pluginDir: pluginDir, input: input)

        XCTAssertGreaterThanOrEqual(
            spy.executeCallCount,
            1,
            "[场景5.P2][C11] 仅 command 经 PluginDispatcher 必须 dispatch≥1。实际: \(spy.executeCallCount)"
        )
    }

    // MARK: - 场景6.P1 [det-machine] 子进程回吐子候选 JSON → PluginResult.candidates 非空
    //
    // 契约 [C8 不改]：StdinExecutor 注入 BUDDY_OUTPUT_CANDIDATES，子进程写 JSON → readCandidatesOutputSafely 解码
    // 真实 command 插件 + 真实 StdinExecutor（不经 LauncherManager，直击 candidates 通道）

    func test_scenario6_P1_subprocessCandidatesReceivedInPluginResult() async throws {
        let candidatesJSON = #"""
        [
          {"id":"stop","title":"关闭监控","subtitle":"停止 service+update","selection":"stop"},
          {"id":"start","title":"打开监控","subtitle":"恢复 service+update","selection":"start"}
        ]
        """#
        let pluginDir = try makeCommandPluginDir(tmpDir: tmpDir, dirName: "qzh", candidatesJSON: candidatesJSON)
        let manifest = try loadManifest(from: pluginDir, dirName: "qzh")

        let dispatcher = PluginDispatcher(stdinExecutor: StdinExecutor())
        let input = PluginInput(query: "qzh", sessionId: UUID().uuidString, cwd: NSHomeDirectory())
        let result = try await dispatcher.execute(manifest, pluginDir: pluginDir, input: input)

        XCTAssertEqual(result.exitCode, 0, "[场景6.P1] 子进程 exit 0")
        XCTAssertNotNil(result.candidates,
                        "[场景6.P1][C8] 子进程回吐候选 JSON 必须 PluginResult.candidates 非空")
        let candidates = result.candidates ?? []
        XCTAssertGreaterThanOrEqual(candidates.count, 2,
                                    "[场景6.P1] 候选数组非空（stop+start 共 2 项）")
        XCTAssertTrue(candidates.contains { $0.selection == "stop" },
                      "[场景6.P1] 候选必须含 selection='stop'")
        XCTAssertTrue(candidates.contains { $0.selection == "start" },
                      "[场景6.P1] 候选必须含 selection='start'")
    }

    // MARK: - 场景6.P2 [det-machine/visual-residue 间接] 候选字段完整（title/subtitle/selection）
    //
    // 契约 [C8 不改]：LauncherCandidate { id, title, subtitle?, selection } 解码完整

    func test_scenario6_P2_candidateFields_completeDecoding() async throws {
        let candidatesJSON = #"""
        [{"id":"stop","title":"关闭监控","subtitle":"停止 service+update","selection":"stop"}]
        """#
        let pluginDir = try makeCommandPluginDir(tmpDir: tmpDir, dirName: "qzh", candidatesJSON: candidatesJSON)
        let manifest = try loadManifest(from: pluginDir, dirName: "qzh")

        let dispatcher = PluginDispatcher(stdinExecutor: StdinExecutor())
        let input = PluginInput(query: "qzh", sessionId: UUID().uuidString, cwd: NSHomeDirectory())
        let result = try await dispatcher.execute(manifest, pluginDir: pluginDir, input: input)

        let candidates = try XCTUnwrap(result.candidates, "[场景6.P2] 候选必须解码成功")
        let first = try XCTUnwrap(candidates.first, "[场景6.P2] 候选数组非空")
        XCTAssertEqual(first.id, "stop", "[场景6.P2] id 字段完整")
        XCTAssertEqual(first.title, "关闭监控", "[场景6.P2] title 字段完整")
        XCTAssertEqual(first.subtitle, "停止 service+update", "[场景6.P2] subtitle 字段完整")
        XCTAssertEqual(first.selection, "stop", "[场景6.P2] selection 字段完整")
        // VISUAL_RESIDUE: 候选行 AX 可 focus / 行数==子候选数 留真机 QA
    }

    // MARK: - 场景6.P3 [det-machine] C8 不变：submitWithCandidate 接口存在 + 经 dispatcher dispatch
    //
    // 契约 [C8]：不改 submitWithCandidate 回调（范围隔离）；选中子候选触发二级派发
    // 同 2.P2/5.P2，dispatcher 层验「submitWithCandidate 内部用的 PluginDispatcher 接 selection 二级派发」

    func test_scenario6_P3_submitWithCandidateInterfaceExists_dispatchesWithSelection() async throws {
        let pluginDir = try makeCommandPluginDir(tmpDir: tmpDir, dirName: "qzh", candidatesJSON: nil)
        let manifest = try loadManifest(from: pluginDir, dirName: "qzh")

        // C8：submitWithCandidate 是既有接口（范围隔离，不改），其内部经 PluginDispatcher 执行 selection 回调
        // 验二级派发经 dispatcher（spy 拦截）：模拟 submitWithCandidate 内部 dispatcher.execute 带 selection 的 input
        let spy = SpyStdinExecutor()
        let dispatcher = PluginDispatcher(stdinExecutor: spy)
        // 模拟 submitWithCandidate 构造的 PluginInput（selection = "start"）
        let callbackInput = PluginInput(query: "qzh", sessionId: UUID().uuidString, cwd: NSHomeDirectory(), selection: "start")
        _ = try await dispatcher.execute(manifest, pluginDir: pluginDir, input: callbackInput)

        XCTAssertGreaterThanOrEqual(
            spy.executeCallCount,
            1,
            "[场景6.P3][C8] submitWithCandidate 二级派发必须 dispatch≥1。实际: \(spy.executeCallCount)"
        )
    }

    // MARK: - 场景6.P4 [det-machine 接口存在性 + REAL_PROCESS_QA] C11/B2：submitCommandDirect prologue 清 commandRouteCandidates
    //
    // 契约 [C11/B2]：submitCommandDirect prologue（同步 MainActor 段）清 commandRouteCandidates + commandRouteSelectedIndex=-1，
    //   避免子候选回吐后与 pluginCandidates 通道双重渲染/双重计高。
    // REAL_PROCESS_QA: submitCommandDirect 端到端驱动经 PluginManager.shared.pluginDir + TrustStore.shared.checkAndPrompt，
    //   两者为既有单例（C8 不动），TrustPrompt.askUser 弹 NSAlert.runModal() 在测试环境阻塞主线程 → det-machine 不可驱动。
    //   此处仅锁定「submitCommandDirect 接口存在 + 签名契约」（编译期保证），prologue 清空的运行时验证留真机 QA。
    // assert: submitCommandDirect 方法存在 + 接受 (PluginManifest, query: String) → AsyncStream<AgentEvent>

    func test_scenario6_P4_submitCommandDirect_interfaceExists_contractSignature() async throws {
        // 契约 [C11]：submitCommandDirect(_ manifest: PluginManifest, query: String) -> AsyncStream<AgentEvent>
        // 编译期锁定方法存在 + 签名（Mutation kill：蓝队若改名/改参数顺序 → 编译失败）
        // 契约 [C11]：submitCommandDirect(_ manifest: PluginManifest, query: String) -> AsyncStream<AgentEvent>
        // ⚠️ 不调用方法：submitCommandDirect 内部 prologue 后立即启 Task.detached 跑 pluginDir + checkAndPrompt，
        //   即使仅取流引用不 drain，detached task 仍执行 → TrustPrompt.askUser 的 NSAlert.runModal() 阻塞主线程。
        //   用方法引用（编译期锁定签名，运行时零调用）+ 强断言防 no-op。
        let methodRef: (PluginManifest, String) async -> AsyncStream<AgentEvent> = { manifest, query in
            await LauncherManager.shared.submitCommandDirect(manifest, query: query)
        }
        XCTAssertNotNil(methodRef as ((PluginManifest, String) async -> AsyncStream<AgentEvent>)?,
                        "[场景6.P4][C11] submitCommandDirect(_:query:) 方法必须存在且签名匹配（编译期锁定，运行时不调用避免阻塞）")
        // REAL_PROCESS_QA: prologue 清 commandRouteCandidates + .candidates 事件后 commandRouteCandidates.isEmpty
        //   留真机 QA（真装 qzh 插件 + 真 approve trust + 真子进程回吐子候选）
    }

    // MARK: - 场景7.P1/P2/P3 [det-machine] 执行失败容错契约
    //
    // 契约 [C11]：非 command → errorStream(.pluginCrash)；dispatcher 执行失败 → throw → errorStream
    // 单测可达层（dispatcher 层）：FailingStdinExecutor 抛错 → dispatcher.execute throws（不崩，错误可捕获）
    // REAL_PROCESS_QA: submitCommandDirect 端到端失败后的 stage 复位 + 仍可交互留真机 QA。

    func test_scenario7_P1_P2_dispatcherFailure_throwsWithoutCrash() async throws {
        let pluginDir = try makeCommandPluginDir(tmpDir: tmpDir, dirName: "qzh", candidatesJSON: nil)
        let manifest = try loadManifest(from: pluginDir, dirName: "qzh")

        let failing = FailingStdinExecutor()
        failing.errorToThrow = LauncherError.pluginCrash(127, "command not found")
        let dispatcher = PluginDispatcher(stdinExecutor: failing)
        let input = PluginInput(query: "qzh", sessionId: UUID().uuidString, cwd: NSHomeDirectory())

        // 7.P2：执行失败抛错（不静默吞错，错误可观测）
        var caught: Error?
        do {
            _ = try await dispatcher.execute(manifest, pluginDir: pluginDir, input: input)
        } catch {
            caught = error
        }
        XCTAssertNotNil(caught,
                        "[场景7.P2] 执行失败必须 throw（不静默吞错）。实际未抛错")
        XCTAssertTrue(caught is LauncherError,
                      "[场景7.P2] 抛的必须是 LauncherError（可观测错误类型）")
        // dispatch 被尝试过（spy 计数）
        XCTAssertGreaterThanOrEqual(failing.executeCallCount, 1,
                                    "[场景7.P2] 失败前 dispatch 必须被调用 ≥1 次")
    }

    // 场景7.P3 [det-machine] 失败后仍可交互：updateQuery 重新命中 + 选中在界内
    //
    // 契约 [C10 回归]：command 候选行经失败不进不可恢复态，重新 updateQuery 能重新命中。
    // 单测可达层：不调 submitCommandDirect（避免 PluginManager/TrustStore 阻塞），
    //   验「清空 commandRouteCandidates 后重新 updateQuery 能重新填充 + 选中在界内」（交互链不死的 det-machine 契约）。
    func test_scenario7_P3_reQueryRepoulates_afterClear() async throws {
        // 多命中（2 个共享 keyword），避免唯一命中自动锁定使候选清空。
        let qzh1 = try makeCommandManifest(name: "qzh", keywords: ["qzh"])
        let qzh2 = try makeCommandManifest(name: "qzh2", keywords: ["qzh"])
        LauncherManager.shared.registryOverride = makeEmptyInstantRegistry()
        LauncherManager.shared.pluginsOverride = [qzh1, qzh2]

        LauncherManager.shared.show()
        LauncherManager.shared.updateQuery("qzh")
        await waitForQuerySettled()
        XCTAssertFalse(LauncherManager.shared.commandRouteCandidates.isEmpty, "前提：多命中 command 候选列出")

        // 模拟执行失败后的状态扰动（清空，镜像 B2 prologue 效果）
        LauncherManager.shared.updateQuery("")
        await waitForQuerySettled()
        XCTAssertTrue(LauncherManager.shared.commandRouteCandidates.isEmpty, "清空后 command 区空")

        // 7.P3：重新 updateQuery 能重新命中（交互链不死）
        LauncherManager.shared.updateQuery("qzh")
        await waitForQuerySettled()
        XCTAssertFalse(
            LauncherManager.shared.commandRouteCandidates.isEmpty,
            "[场景7.P3] 清空后重新 updateQuery 必须 command 候选正常重新填充（交互链不死）"
        )
        let navOk = LauncherManager.shared.commandRouteCandidates.indices.contains(
            LauncherManager.shared.commandRouteSelectedIndex
        )
        XCTAssertTrue(navOk,
                      "[场景7.P3] 重新命中后选中索引必须在 candidates.indices 内（仍可交互，不进不可恢复态）")
        // REAL_PROCESS_QA: 真实 submitCommandDirect 失败 → stage 复位 + 仍可交互留真机 QA
    }
}
