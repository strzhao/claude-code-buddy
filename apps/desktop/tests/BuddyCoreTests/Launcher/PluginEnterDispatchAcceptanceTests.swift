import XCTest
@testable import BuddyCore

// MARK: - PluginEnterDispatchAcceptanceTests
//
// 红队验收测试（TDD 红灯）：Enter 分流执行——参数 strip / 零 LLM / 三 mode done / Tab 锁定 / 子候选回调
//
// 设计文档契约引用（## 设计决策 D1/D4/D5 + ## 契约规约 C-ENTER-EXEC/C-TAB-LOCK）：
//   D1：插件行 perform 发起执行（Enter on instant 插件行）
//   D4：Enter 分流——lockedCommand→submitCommandDirect；pluginCandidates 子候选态→submitWithCandidate；
//       instant 插件行→command: submitCommandDirect(manifest, query:)（内部 strip、零 LLM）/
//       stdin+prompt: submitWithPlugin(manifest, query:)；app/内置行→performSelectedInstantAction；
//       fallback→submit(q) AI 流；pluginId→manifest 经 PluginManager.find(name:)
//   D5：Tab 仅插件行生效→锁定；D3：锁定粘性 helper lockedPrefixStillMatched
//   C-ENTER-EXEC：command→submitCommandDirect（零 LLM 不经 provider）；stdin/prompt→submitWithPlugin；
//       参数=stripKeywordPrefix 语义
//   C-TAB-LOCK：Tab 仅插件行；「qr 」不自动锁定（lockedCommand==nil）
//
// 观测 seam（设计文档 Context 声明）：stdinExecutorOverride + RecordingStdinExecutorSpy
//   （记录 executeCallCount / lastInput?.query / lastPluginName）
//
// CONTRACT_AMBIGUOUS 清单（本文件涉及）：
//   1. D4「Enter 分流抽为 LauncherManager 可测方法」未给出方法名——instant 插件行的 Enter 语义
//      通过 D1 声明的「行 perform 发起执行」驱动（row.perform() == Enter on 该行）。
//   2. `submitWithPlugin(_:query:)` 为 D4 字面声明名；若蓝队签名不同，只调整调用点，不得改断言。
//   3. Tab 锁定无声明 seam——按既有 handleEscapeForTesting() 同构约定 ASSUMES
//      `handleTabForTesting()`（LockedCommandStateMachineAcceptanceTests 先例）。
//   4. 「pluginCandidates 状态」@Published 字段名未声明——场景15 以 .candidates 事件 +
//      submitWithCandidate 的 PluginInput.selection spy 观测替代。
//
// TDD 红灯：submitWithPlugin / handleTabForTesting / LauncherAction.iconEmoji 未实现时编译失败，属预期。

@MainActor
final class PluginEnterDispatchAcceptanceTests: XCTestCase {

    // MARK: - 生命周期

    override func setUp() async throws {
        try await super.setUp()
        LauncherManager.shared.resetSubmittingStateForTesting()
        LauncherManager.shared.instantDebounceMsOverride = 0
        LauncherManager.shared.registryOverride = makeEmptyRegistry()
        LauncherManager.shared.pluginsOverride = nil
        LauncherManager.shared.stdinExecutorOverride = nil
        LauncherManager.shared.clearInstantActions()
        LauncherManager.shared.updateQuery("")
        if LauncherManager.shared.isVisible {
            LauncherManager.shared.hide()
        }
    }

    override func tearDown() async throws {
        LauncherManager.shared.pluginsOverride = nil
        LauncherManager.shared.registryOverride = nil
        LauncherManager.shared.stdinExecutorOverride = nil
        LauncherManager.shared.configOverride = nil
        LauncherManager.shared.providerFactoryOverride = nil
        LauncherManager.shared.clearInstantActions()
        LauncherManager.shared.updateQuery("")
        try await super.tearDown()
    }

    // MARK: - stub 插件落地（仿 LockedCommandStateMachineAcceptanceTests.makeCommandPluginInRoot）

    /// 在 PluginManager.shared.rootDir 下落地 command/stdin 插件目录（plugin.json + run.sh）。
    /// 可选：run.sh 追加写 $BUDDY_OUTPUT_CANDIDATES（场景15 子候选回吐）。
    private func makePluginInRoot(name: String, dirName: String, keywords: [String],
                                  mode: String, candidatesJSON: String? = nil) throws -> URL {
        let rootDir = PluginManager.shared.rootDir
        try? FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        let pluginDir = rootDir.appendingPathComponent("\(dirName)-\(name)")
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)

        let writeCandidates: String
        if let json = candidatesJSON {
            writeCandidates = """
            if [ -n "$BUDDY_OUTPUT_CANDIDATES" ]; then
              cat > "$BUDDY_OUTPUT_CANDIDATES" <<'BUDDY_EOF'
            \(json)
            BUDDY_EOF
            fi
            """
        } else {
            writeCandidates = ": # no candidates"
        }

        let script = """
        #!/bin/bash
        echo "spy ok"
        \(writeCandidates)
        exit 0
        """
        let scriptURL = pluginDir.appendingPathComponent("run.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let keywordsJSON = "[\"" + keywords.joined(separator: "\",\"") + "\"]"
        let manifestJSON = """
        {
          "name": "\(name)",
          "version": "0.1.0",
          "description": "enter dispatch spy test",
          "keywords": \(keywordsJSON),
          "mode": "\(mode)",
          "cmd": "./run.sh",
          "args": [],
          "env": null,
          "timeout": 10,
          "requiredPath": null
        }
        """
        try manifestJSON.write(to: pluginDir.appendingPathComponent("plugin.json"),
                               atomically: true, encoding: .utf8)
        return pluginDir
    }

    private func loadManifest(from pluginDir: URL) throws -> PluginManifest {
        let data = try Data(contentsOf: pluginDir.appendingPathComponent("plugin.json"))
        return try JSONDecoder().decode(PluginManifest.self, from: data)
    }

    /// 预信任（绕 TOFU NSAlert）
    private func approve(_ pluginDir: URL) throws {
        try TrustStore.shared.approve(try loadManifest(from: pluginDir),
                                      executablePath: pluginDir.appendingPathComponent("run.sh"))
    }

    // MARK: - 驱动辅助

    private func updateQueryAndSettle(_ query: String) async {
        LauncherManager.shared.updateQuery(query)
        var lastCount = -1
        var stablePolls = 0
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline && stablePolls < 4 {
            let count = LauncherManager.shared.instantActions.count
            if count == lastCount { stablePolls += 1 } else { stablePolls = 0; lastCount = count }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// 轮询等待 spy 被调（detached 执行段落地），超时由后续硬断言兜底
    private func waitForSpyCall(_ spy: RecordingStdinExecutorSpy) async {
        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline && spy.executeCallCount == 0 {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func makeEmptyRegistry() -> BuiltinPluginRegistry {
        BuiltinPluginRegistry(plugins: [EmptyActionsPluginForEnterTest()])
    }

    // MARK: - 场景3.P1 [real-process]：keyword+参数 → 参数 == "hello world"

    /// 场景3.P1：updateQuery("stubkw hello world") → 选中插件行（perform = Enter）→
    /// spy 参数 == "hello world"（stripKeywordPrefix 语义），被调插件 == "stub"。
    /// Mutation kill：no-op perform / 不 strip（整句透传）/ 走错插件 → 分别挂三个断言。
    ///
    /// 设计张力注记（CONTRACT_AMBIGUOUS）：D2 前缀档是「query 是 name/keyword 前缀」单向，
    /// 而本权威场景要求 keyword 起始的 query（"stubkw hello world"）仍出插件行——
    /// 以权威验收场景 3 为准断言行可达；若蓝队匹配器不覆盖此形态则红灯上报设计 owner。
    func test_scenario3_P1_keywordWithArgs_performExecutesWithStrippedArgs() async throws {
        let pluginDir = try makePluginInRoot(name: "stub", dirName: "stub-scn3-\(UUID().uuidString.prefix(8))",
                                             keywords: ["stubkw"], mode: "command")
        defer { try? FileManager.default.removeItem(at: pluginDir) }
        let manifest = try loadManifest(from: pluginDir)
        try approve(pluginDir)
        let spy = RecordingStdinExecutorSpy()
        LauncherManager.shared.pluginsOverride = [manifest]
        LauncherManager.shared.stdinExecutorOverride = spy

        await updateQueryAndSettle("stubkw hello world")

        let row = try XCTUnwrap(
            LauncherManager.shared.instantActions.first { $0.pluginId == "stub" },
            "场景3.P1: \"stubkw hello world\" 必须产出 stub 插件行（权威场景3），实际=\(LauncherManager.shared.instantActions.map(\.pluginId))"
        )

        // Enter on 插件行 == 行 perform 发起执行（D1）
        try row.perform()
        await waitForSpyCall(spy)

        XCTAssertGreaterThanOrEqual(spy.executeCallCount, 1,
            "场景3.P1: 插件行 Enter 必须发起执行（spy>=1），实际=\(spy.executeCallCount)")
        XCTAssertEqual(spy.lastInput?.query, "hello world",
            "场景3.P1: 参数必须是 stripKeywordPrefix 后的 \"hello world\"，实际=\(spy.lastInput?.query ?? "<nil>")")
        XCTAssertEqual(spy.lastPluginName, "stub",
            "场景3.P1: 被调插件必须是 stub，实际=\(spy.lastPluginName ?? "<nil>")")
    }

    // MARK: - 场景3.P2 [real-process]：query 仅 keyword → 参数 == ""

    /// 场景3.P2：updateQuery("stubkw") → 选中插件行 Enter → 参数 == ""。
    func test_scenario3_P2_keywordOnly_performExecutesWithEmptyArg() async throws {
        let pluginDir = try makePluginInRoot(name: "stub", dirName: "stub-scn3b-\(UUID().uuidString.prefix(8))",
                                             keywords: ["stubkw"], mode: "command")
        defer { try? FileManager.default.removeItem(at: pluginDir) }
        let manifest = try loadManifest(from: pluginDir)
        try approve(pluginDir)
        let spy = RecordingStdinExecutorSpy()
        LauncherManager.shared.pluginsOverride = [manifest]
        LauncherManager.shared.stdinExecutorOverride = spy

        await updateQueryAndSettle("stubkw")

        let row = try XCTUnwrap(
            LauncherManager.shared.instantActions.first { $0.pluginId == "stub" },
            "场景3.P2: \"stubkw\" 必须产出 stub 插件行（完全档）"
        )

        try row.perform()
        await waitForSpyCall(spy)

        XCTAssertGreaterThanOrEqual(spy.executeCallCount, 1,
            "场景3.P2: 插件行 Enter 必须发起执行（空参也不拒），实际=\(spy.executeCallCount)")
        XCTAssertEqual(spy.lastInput?.query, "",
            "场景3.P2: query 恰为 keyword 时参数必须是空串，实际=\(spy.lastInput?.query ?? "<nil>")")
    }

    // MARK: - 场景4.P1 [det-machine]：Tab 锁定 → lockedCommand?.name == 插件名

    /// 场景4.P1：插件行上 Tab → 锁定（lockedCommand = 该插件），不执行。
    /// ASSUMES blue team：handleTabForTesting()（与既有 handleEscapeForTesting() 同构的测试 seam）。
    func test_scenario4_P1_tabOnPluginRow_locksCommand() async {
        let manifest = makeCommandManifestInMemory(name: "qr", keywords: ["qr", "二维码", "码"])
        let spy = RecordingStdinExecutorSpy()
        LauncherManager.shared.pluginsOverride = [manifest]
        LauncherManager.shared.stdinExecutorOverride = spy

        await updateQueryAndSettle("qr ")
        XCTAssertTrue(LauncherManager.shared.instantActions.contains { $0.pluginId == "qr" },
            "场景4.P1 前置: 「qr 」必须仍列出 qr 行（自动锁定已退役）")

        // Tab on 选中插件行（默认选中 index 0 的 qr 行）
        LauncherManager.shared.handleTabForTesting()

        XCTAssertEqual(LauncherManager.shared.lockedCommand?.name, "qr",
            "场景4.P1: Tab 必须锁定选中插件行（lockedCommand?.name==\"qr\"），实际=\(LauncherManager.shared.lockedCommand?.name ?? "nil")")
        XCTAssertEqual(spy.executeCallCount, 0,
            "场景4.P1: Tab 锁定≠执行（spy 必须为 0），实际=\(spy.executeCallCount)")
    }

    // MARK: - 场景4.P2 [real-process]：锁定态输参数 Enter → 参数 == 锁定后输入全文（strip 后）

    /// 场景4.P2：Tab 锁定 qr → 输参数「qr hello world」（D3 粘性 lockedPrefixStillMatched 保持锁定）→
    /// Enter 走 submitCommandDirect(manifest, query) → 参数 == "hello world"。
    func test_scenario4_P2_lockedThenArgs_enterExecutesWithFullInputStripped() async throws {
        let pluginDir = try makePluginInRoot(name: "qr", dirName: "qr-scn4b-\(UUID().uuidString.prefix(8))",
                                             keywords: ["qr", "二维码", "码"], mode: "command")
        defer { try? FileManager.default.removeItem(at: pluginDir) }
        let manifest = try loadManifest(from: pluginDir)
        try approve(pluginDir)
        let spy = RecordingStdinExecutorSpy()
        LauncherManager.shared.pluginsOverride = [manifest]
        LauncherManager.shared.stdinExecutorOverride = spy

        // Tab 锁定
        await updateQueryAndSettle("qr ")
        LauncherManager.shared.handleTabForTesting()
        XCTAssertEqual(LauncherManager.shared.lockedCommand?.name, "qr", "场景4.P2 前置: Tab 必须先锁定 qr")

        // 锁定态输参数（粘性：lockedPrefixStillMatched）
        LauncherManager.shared.updateQuery("qr hello world")
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(LauncherManager.shared.lockedCommand?.name, "qr",
            "场景4.P2: 锁定态输参数必须粘性保持 lockedCommand==\"qr\"（D3 lockedPrefixStillMatched）")

        // Enter：D4 lockedCommand 分流 → submitCommandDirect(manifest, query:)，参数=strip
        let stream = LauncherManager.shared.submitCommandDirect(manifest, query: "qr hello world")
        var sawDone = false
        for await event in stream {
            if case .done = event { sawDone = true }
        }

        XCTAssertTrue(sawDone, "场景4.P2: 锁定 Enter 执行流必须含 .done 事件")
        XCTAssertGreaterThanOrEqual(spy.executeCallCount, 1,
            "场景4.P2: 锁定 Enter 必须执行（spy>=1），实际=\(spy.executeCallCount)")
        XCTAssertEqual(spy.lastInput?.query, "hello world",
            "场景4.P2: 参数必须是锁定后输入全文 strip keyword 后的 \"hello world\"，实际=\(spy.lastInput?.query ?? "<nil>")")
    }

    // MARK: - 场景7.P1 [det-machine]：三 mode 插件关键词均进列表

    /// 场景7.P1：command/stdin/prompt 三插件共享 keyword「trimode」→ instantActions 含全部三行。
    /// Mutation kill：若某 mode 被漏出列表（如 stdin 仍走旧 narrowCandidates 路由），集合缺员 → 挂。
    func test_scenario7_P1_allThreeModes_listedInInstantActions() async {
        let cmd = makeCommandManifestInMemory(name: "cmd3", keywords: ["trimode"], mode: "command")
        let stdin = makeCommandManifestInMemory(name: "stdin3", keywords: ["trimode"], mode: "stdin")
        let prompt = makePromptManifestInMemory(name: "prompt3", keywords: ["trimode"])
        LauncherManager.shared.pluginsOverride = [cmd, stdin, prompt]

        await updateQueryAndSettle("trimode")

        let pluginIds = Set(LauncherManager.shared.instantActions.map(\.pluginId))
        XCTAssertTrue(pluginIds.contains("cmd3"), "场景7.P1: command 插件必须进列表，实际=\(pluginIds)")
        XCTAssertTrue(pluginIds.contains("stdin3"), "场景7.P1: stdin 插件必须进列表，实际=\(pluginIds)")
        XCTAssertTrue(pluginIds.contains("prompt3"), "场景7.P1: prompt 插件必须进列表，实际=\(pluginIds)")
    }

    // MARK: - 场景7.P2 [real-process]：三 mode 选中 Enter 均产生 done 事件

    /// 场景7.P2（command）：submitCommandDirect → 流含 .done（command 零 LLM，provider 无人调用）。
    func test_scenario7_P2_commandMode_enter_producesDone_zeroLLM() async throws {
        let pluginDir = try makePluginInRoot(name: "cmd3", dirName: "cmd3-\(UUID().uuidString.prefix(8))",
                                             keywords: ["trimode"], mode: "command")
        defer { try? FileManager.default.removeItem(at: pluginDir) }
        let manifest = try loadManifest(from: pluginDir)
        try approve(pluginDir)
        let spy = RecordingStdinExecutorSpy()
        // 故意不配置 provider：command 路径零 LLM 必须不受影响（对称场景9）
        LauncherManager.shared.configOverride = .empty
        LauncherManager.shared.stdinExecutorOverride = spy

        let stream = LauncherManager.shared.submitCommandDirect(manifest, query: "trimode x")
        var sawDone = false
        for await event in stream {
            if case .done = event { sawDone = true }
            if case .error(let err) = event {
                if case .providerNotConfigured = err {
                    XCTFail("场景7.P2: command 插件执行不得触碰 provider（providerNotConfigured 出现）")
                }
            }
        }

        XCTAssertTrue(sawDone, "场景7.P2: command 插件 Enter 执行流必须含 .done")
        XCTAssertGreaterThanOrEqual(spy.executeCallCount, 1,
            "场景7.P2: command 插件必须经 dispatcher 执行（spy>=1），实际=\(spy.executeCallCount)")
    }

    /// 场景7.P2（stdin）：submitWithPlugin → 流含 .done（经 provider seam 的 mock）。
    /// D4 声明名 submitWithPlugin(manifest, query:)；stdin 子进程经 stdinExecutorOverride spy 落地。
    func test_scenario7_P2_stdinMode_enter_producesDone() async throws {
        let pluginDir = try makePluginInRoot(name: "stdin3", dirName: "stdin3-\(UUID().uuidString.prefix(8))",
                                             keywords: ["trimode"], mode: "stdin")
        defer { try? FileManager.default.removeItem(at: pluginDir) }
        let manifest = try loadManifest(from: pluginDir)
        try approve(pluginDir)
        let spy = RecordingStdinExecutorSpy()
        LauncherManager.shared.stdinExecutorOverride = spy
        LauncherManager.shared.configOverride = LauncherConfig(
            activeProvider: "mock",
            providers: ["mock": ProviderConfig(kind: "anthropic", baseURL: nil, model: "test", keyRef: "test")]
        )
        // stdin 走 agent loop：mock 必须返回 tool_use 才触发 toolExecutor 执行插件子进程
        let mockProvider = MockEnterDispatchProvider()
        mockProvider.toolUseResponse = (id: "call-stdin3", name: "stdin3", input: ["query": AnyCodable("hi")])
        LauncherManager.shared.providerFactoryOverride = { _, _ in mockProvider }

        let stream = LauncherManager.shared.submitWithPlugin(manifest, query: "trimode hi")
        var sawDone = false
        for await event in stream {
            if case .done = event { sawDone = true }
            if case .error(let err) = event {
                if case .providerNotConfigured = err {
                    XCTFail("场景7.P2: stdin 插件执行必须走到 provider（mock 已注入），不得 providerNotConfigured")
                }
            }
        }

        XCTAssertTrue(sawDone, "场景7.P2: stdin 插件 Enter 执行流必须含 .done")
        XCTAssertGreaterThanOrEqual(spy.executeCallCount, 1,
            "场景7.P2: stdin 插件必须经 dispatcher 执行（spy>=1），实际=\(spy.executeCallCount)")
    }

    /// 场景7.P2（prompt）：submitWithPlugin → 流含 .done（PromptExecutor 单轮，mock provider）。
    func test_scenario7_P2_promptMode_enter_producesDone() async throws {
        let json: [String: Any] = [
            "name": "prompt3",
            "version": "0.1.0",
            "description": "prompt dispatch test",
            "keywords": ["trimode"],
            "mode": "prompt",
            "systemPrompt": "x",
            "autoCopyToClipboard": false
        ]
        let manifest = try JSONDecoder().decode(PluginManifest.self,
                                                from: JSONSerialization.data(withJSONObject: json))
        LauncherManager.shared.configOverride = LauncherConfig(
            activeProvider: "mock",
            providers: ["mock": ProviderConfig(kind: "anthropic", baseURL: nil, model: "test", keyRef: "test")]
        )
        let provider = MockEnterDispatchProvider()
        LauncherManager.shared.providerFactoryOverride = { _, _ in provider }

        let stream = LauncherManager.shared.submitWithPlugin(manifest, query: "trimode 你好")
        var sawDone = false
        for await event in stream {
            if case .done = event { sawDone = true }
        }

        XCTAssertTrue(sawDone, "场景7.P2: prompt 插件 Enter 执行流必须含 .done")
        XCTAssertGreaterThanOrEqual(provider.callCount, 1,
            "场景7.P2: prompt 插件必须经 provider 执行（callCount>=1），实际=\(provider.callCount)")
    }

    // MARK: - 场景9.P1 [real-process]：无 provider 配置时 command 插件零 LLM 执行成功

    /// 场景9.P1：configOverride = .empty + providerFactoryOverride = nil（providerConfig 为 nil 态）→
    /// command 插件 Enter（submitCommandDirect）→ 流含 .done、无 providerNotConfigured、spy>=1。
    /// Mutation kill：若 command 路径被改回触碰 provider（config 校验前置），流出现 providerNotConfigured → 挂。
    func test_scenario9_P1_nilProviderConfig_commandEnter_zeroLLMSuccess() async throws {
        let pluginDir = try makePluginInRoot(name: "qr", dirName: "qr-scn9-\(UUID().uuidString.prefix(8))",
                                             keywords: ["qr", "二维码", "码"], mode: "command")
        defer { try? FileManager.default.removeItem(at: pluginDir) }
        let manifest = try loadManifest(from: pluginDir)
        try approve(pluginDir)
        let spy = RecordingStdinExecutorSpy()
        LauncherManager.shared.configOverride = .empty
        LauncherManager.shared.providerFactoryOverride = nil
        LauncherManager.shared.stdinExecutorOverride = spy

        let stream = LauncherManager.shared.submitCommandDirect(manifest, query: "qr https://example.com")
        var sawDone = false
        for await event in stream {
            switch event {
            case .done:
                sawDone = true
            case .error(let err):
                if case .providerNotConfigured = err {
                    XCTFail("场景9.P1: providerConfig 为 nil 时 command 插件必须零 LLM 执行成功，不得 providerNotConfigured")
                } else {
                    XCTFail("场景9.P1: command 插件执行不得报错，实际收到 .error(\(err))")
                }
            default:
                break
            }
        }

        XCTAssertTrue(sawDone, "场景9.P1: 流必须含 done 事件")
        XCTAssertGreaterThanOrEqual(spy.executeCallCount, 1,
            "场景9.P1: 必须真实派发子进程执行（spy>=1），实际=\(spy.executeCallCount)")
        XCTAssertEqual(spy.lastInput?.query, "https://example.com",
            "场景9.P1: 参数必须是 strip 后的 \"https://example.com\"，实际=\(spy.lastInput?.query ?? "<nil>")")
    }

    // MARK: - 场景15.P1 [real-process]：command 插件回吐子候选 → submitWithCandidate selection 透传

    /// 场景15.P1（阶段A）：真实 StdinExecutor（不注入 spy）执行 command 插件 →
    /// 子进程写 $BUDDY_OUTPUT_CANDIDATES → 流含 .candidates 事件（stop/start 两项，title 逐字）。
    /// CONTRACT_AMBIGUOUS: 「pluginCandidates 状态」@Published 字段名未声明，以 .candidates 事件观测。
    func test_scenario15_P1_commandPlugin_emitsCandidatesEvent() async throws {
        let candidatesJSON = """
        [
          {"id":"stop","title":"关闭监控","subtitle":"停止 service+update","selection":"stop"},
          {"id":"start","title":"打开监控","subtitle":"恢复 service+update","selection":"start"}
        ]
        """
        let pluginDir = try makePluginInRoot(name: "qzh2", dirName: "qzh2-\(UUID().uuidString.prefix(8))",
                                             keywords: ["qzh2"], mode: "command", candidatesJSON: candidatesJSON)
        defer { try? FileManager.default.removeItem(at: pluginDir) }
        let manifest = try loadManifest(from: pluginDir)
        try approve(pluginDir)

        let stream = LauncherManager.shared.submitCommandDirect(manifest, query: "qzh2")
        var candidatesEvent: [(String, String?)] = []
        for await event in stream {
            if case .candidates(let cands) = event {
                candidatesEvent = cands.map { ($0.id, $0.title) }
            }
        }

        XCTAssertEqual(candidatesEvent.count, 2,
            "场景15.P1: 必须回吐 2 个子候选，实际=\(candidatesEvent)")
        XCTAssertEqual(candidatesEvent.first?.0, "stop", "场景15.P1: 子候选[0].id 必须是 stop")
        XCTAssertEqual(candidatesEvent.last?.0, "start", "场景15.P1: 子候选[1].id 必须是 start")
        XCTAssertTrue(candidatesEvent.contains { $0.1 == "关闭监控" },
            "场景15.P1: 子候选必须含 title==\"关闭监控\"（逐字），实际=\(candidatesEvent)")
    }

    /// 场景15.P1（阶段B）：二次提交走 submitWithCandidate 且 selection 正确传递
    /// （spy 观测 PluginInput.selection / query）。
    func test_scenario15_P1_resubmitWithCandidate_selectionPassedToPluginInput() async throws {
        let candidatesJSON = """
        [{"id":"stop","title":"关闭监控","selection":"stop"}]
        """
        let pluginDir = try makePluginInRoot(name: "qzh2", dirName: "qzh2b-\(UUID().uuidString.prefix(8))",
                                             keywords: ["qzh2"], mode: "command", candidatesJSON: candidatesJSON)
        defer { try? FileManager.default.removeItem(at: pluginDir) }
        let manifest = try loadManifest(from: pluginDir)
        try approve(pluginDir)
        let spy = RecordingStdinExecutorSpy()
        LauncherManager.shared.stdinExecutorOverride = spy

        let stream = LauncherManager.shared.submitWithCandidate(manifest, selection: "stop", query: "qzh2 status")
        for await _ in stream {}

        XCTAssertGreaterThanOrEqual(spy.executeCallCount, 1,
            "场景15.P1: 二次提交必须重入插件执行（spy>=1），实际=\(spy.executeCallCount)")
        XCTAssertEqual(spy.lastInput?.selection, "stop",
            "场景15.P1: selection 必须逐字透传到 PluginInput.selection，实际=\(spy.lastInput?.selection ?? "<nil>")")
        XCTAssertEqual(spy.lastInput?.query, "qzh2 status",
            "场景15.P1: query 必须透传，实际=\(spy.lastInput?.query ?? "<nil>")")
        XCTAssertEqual(spy.lastPluginName, "qzh2",
            "场景15.P1: 重入的必须是同插件 qzh2，实际=\(spy.lastPluginName ?? "<nil>")")
    }

    // MARK: - 内存 manifest 构造（candidates 列表驱动用，无物理目录）

    private func makeCommandManifestInMemory(name: String, keywords: [String],
                                             mode: String = "command") -> PluginManifest {
        let json: [String: Any] = [
            "name": name,
            "version": "0.1.0-test",
            "description": "in-memory \(mode) plugin",
            "keywords": keywords,
            "mode": mode,
            "cmd": "echo",
            "args": [String]()
        ]
        return try! JSONDecoder().decode(PluginManifest.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func makePromptManifestInMemory(name: String, keywords: [String]) -> PluginManifest {
        let json: [String: Any] = [
            "name": name,
            "version": "0.1.0-test",
            "description": "in-memory prompt plugin",
            "keywords": keywords,
            "mode": "prompt",
            "systemPrompt": "x",
            "autoCopyToClipboard": false
        ]
        return try! JSONDecoder().decode(PluginManifest.self, from: JSONSerialization.data(withJSONObject: json))
    }
}

// MARK: - Mock provider（三 mode done 断言用；与既有 mock 同构，私有避免重名）

private final class MockEnterDispatchProvider: LauncherProvider {
    private(set) var callCount = 0
    /// 非空时返回 toolUse 响应（stdin agent loop 场景需 LLM 发起 tool_call 才触发插件执行）
    var toolUseResponse: (id: String, name: String, input: [String: AnyCodable])?

    func send(messages: [AgentMessage], tools: [AgentTool], model: String,
              system: String?) async throws -> AgentResponse {
        callCount += 1
        if let t = toolUseResponse, callCount == 1 {
            return AgentResponse(
                content: [.toolUse(id: t.id, name: t.name, input: t.input)],
                stopReason: "tool_use", usage: nil
            )
        }
        return AgentResponse(content: [.text("mock ok")], stopReason: "end_turn", usage: nil)
    }
}

// MARK: - Mock 空内置插件

private struct EmptyActionsPluginForEnterTest: BuiltinPlugin {
    let id = "empty-enter-test"
    let priority = 0
    let sectionTitle = "Empty"
    func actions(for query: String) async -> [LauncherAction] { [] }
}
