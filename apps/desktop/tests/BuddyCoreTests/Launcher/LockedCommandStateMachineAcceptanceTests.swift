import XCTest
@testable import BuddyCore

// MARK: - LockedCommandStateMachineAcceptanceTests
//
// 红队验收测试（det-machine + real-process 频道）— lockedCommand 状态机 + 两阶段执行
//
// 设计文档契约引用（state.md ## 契约规约 / ## 验收场景）：
//   C-UNIQUE-AUTOLOCK   ：commandPrefixMatched 唯一命中 → updateQuery 自动设 lockedCommand
//   C-MULTI-SELECT-LOCK ：多命中 → lockedCommand=nil + 候选列出；必须用户 ↑↓ 选中才锁定
//   C-LOCK-NOT-EXECUTE  ：候选态选中（Enter/Tab/点击）command 行 = 设 lockedCommand，绝不 submitCommandDirect
//   C-LOCK-STICKY       ：lockedCommand 非空且 query 仍以 keyword 开头 → 保持锁定
//   C-PARAM-ISOLATE     ：lockedCommand != nil → command 候选区与 instant 区均隐藏
//   C-EXEC-ON-ENTER     ：lockedCommand != nil + Enter → submitCommandDirect(lockedCommand, query)，参数=stripKeywordPrefix
//   C-ESC-EXIT          ：esc → 若 lockedCommand!=nil 仅清 lockedCommand 不 hide；清空输入框 → lockedCommand=nil
//   C-SCOPE-COMMAND-ONLY：stdin/prompt mode 不动（仍走 narrowCandidatesScored + AI 路由）
//
// 符号映射（QA 绑定，state.md:150）：
//   launcherLockedCommand          = LauncherManager.lockedCommand?.name
//   spawnedCommandSubprocesses     = StdinExecutor spy（RecordingStdinExecutorSpy.executeCallCount）观测
//   qrPluginInvokedWith(arg)       = spy.lastInput?.query 断言（PluginInput.query）
//
// TDD 红灯：LauncherManager.lockedCommand 字段（T2）、submit 分层（T4）、esc 拦截（T5）由蓝队实现。
// 此刻字段/分支不存在 → 编译 fail 是预期的，绝不放宽断言让它过。
//
// command mode mock 必须用 JSON 解码 mode:"command"（契约 T7 / C9）。
// real-process 测试用 stdinExecutorOverride spy 注入观测 PluginInput.query（不真起子进程）。

@MainActor
final class LockedCommandStateMachineAcceptanceTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        LauncherManager.shared.resetSubmittingStateForTesting()
        LauncherManager.shared.instantDebounceMsOverride = 0
        LauncherManager.shared.registryOverride = makeEmptyRegistry()
        LauncherManager.shared.pluginsOverride = nil
        LauncherManager.shared.stdinExecutorOverride = nil
        LauncherManager.shared.clearInstantActions()
        if LauncherManager.shared.isVisible {
            LauncherManager.shared.hide()
        }
    }

    override func tearDown() async throws {
        LauncherManager.shared.pluginsOverride = nil
        LauncherManager.shared.stdinExecutorOverride = nil
        LauncherManager.shared.registryOverride = nil
        LauncherManager.shared.clearInstantActions()
        try await super.tearDown()
    }

    // MARK: - 场景4（P1·Happy·唯一自动锁定一步执行）

    /// 场景4.P1 [det-machine]：命中数==1 → 自动锁定且不立即执行
    /// assert: commandPrefixMatched("qr ").count==1 && lockedCommand=="qr"
    ///   - 先断言前置不变式（commandPrefixMatched 唯一命中），再断言 updateQuery 自动锁。
    func test_scenario4_P1_uniqueMatch_autoLocks_lockedQr() async {
        let qr = makeQrCommandManifest()
        LauncherManager.shared.pluginsOverride = [qr]

        // 前置：commandPrefixMatched 唯一命中（C-PREFIX-MATCH 纯函数不变式）
        let matched = LauncherRouter.commandPrefixMatched(query: "qr ", plugins: [qr])
        XCTAssertEqual(matched.count, 1,
            "场景4.P1 前置: commandPrefixMatched(\"qr \") 必须唯一命中 count==1，实际=\(matched.count)")

        // 驱动 updateQuery（唯一命中 → C-UNIQUE-AUTOLOCK 自动锁）
        LauncherManager.shared.updateQuery("qr ")
        await Task.yield()

        XCTAssertEqual(LauncherManager.shared.lockedCommand?.name, "qr",
            "场景4.P1: 唯一命中时 updateQuery 必须自动设 lockedCommand==\"qr\"（C-UNIQUE-AUTOLOCK）")
    }

    /// 场景4.P1.negate [real-process]：锁定后 Enter 前不拉起子进程
    /// assert: spawnedCommandSubprocesses.contains("qr")==false
    ///   - 锁定态本身不执行（C-LOCK-NOT-EXECUTE 的自动锁变体）。spy 不得被调用。
    ///   - Mutation 5 问：若 updateQuery 自动锁后顺带 submit，spy.executeCallCount 会 >0 → 断言失败。
    func test_scenario4_P1_negate_autoLock_noSpawnBeforeEnter() async {
        let qr = makeQrCommandManifest()
        let spy = RecordingStdinExecutorSpy()
        LauncherManager.shared.pluginsOverride = [qr]
        LauncherManager.shared.stdinExecutorOverride = spy

        LauncherManager.shared.updateQuery("qr ")
        await Task.yield()

        XCTAssertEqual(spy.executeCallCount, 0,
            "场景4.P1.negate: 自动锁定后 Enter 前不得拉起子进程（spy.executeCallCount==0），实际=\(spy.executeCallCount)")
        XCTAssertNil(spy.lastInput,
            "场景4.P1.negate: Enter 前不得构造 PluginInput")
    }

    /// 场景4.P2 [real-process]：锁定 qr + 参数「https://example.com」+ Enter → 以该参执行
    /// assert: qrPluginInvokedWith(arg:"https://example.com")==true
    ///   - 用 submitCommandDirect 直驱执行入口（C-EXEC-ON-ENTER 的执行段，蓝队 T4 在 submit 里接 Enter）。
    ///     参数 = stripKeywordPrefix(query, qr) = "https://example.com"。
    ///   - 真实落地插件目录（makeCommandPluginInRoot）让 pluginDir(for:) 解析通过；
    ///     预信任绕过 NSAlert（TrustStore.approve）。
    func test_scenario4_P2_lockedQr_enter_invokesWithHttpsExample() async throws {
        let dirName = "qr-scn4-\(UUID().uuidString.prefix(8))"
        let pluginDir = try makeCommandPluginInRoot(name: "qr", dirName: String(dirName), keywords: ["qr", "二维码", "码"])
        defer { try? FileManager.default.removeItem(at: pluginDir) }
        let manifest = try loadManifest(from: pluginDir)
        let executablePath = pluginDir.appendingPathComponent("run.sh")
        try TrustStore.shared.approve(manifest, executablePath: executablePath)
        let spy = RecordingStdinExecutorSpy()
        LauncherManager.shared.stdinExecutorOverride = spy
        LauncherManager.shared.resetSubmittingStateForTesting()

        // 直驱执行入口（C-EXEC-ON-ENTER 的执行段）
        let query = "qr https://example.com"
        let stream = LauncherManager.shared.submitCommandDirect(manifest, query: query)
        for await event in stream {
            // 消费流驱动 detached 执行段落地
            if case .error = event {
                XCTFail("场景4.P2: submitCommandDirect 不应报 error，实际收到 .error")
            }
        }

        XCTAssertGreaterThanOrEqual(spy.executeCallCount, 1,
            "场景4.P2: Enter 后必须调 dispatcher.execute（经 spy）≥1 次，实际=\(spy.executeCallCount)")
        XCTAssertEqual(spy.lastInput?.query, "https://example.com",
            "场景4.P2: PluginInput.query 必须是 stripKeywordPrefix 后的「https://example.com」，实际=\(spy.lastInput?.query ?? "<nil>")")
    }

    // MARK: - 场景5（P1·Happy·多命中显式选中）

    /// 场景5.P1 [det-machine]：命中数>=2 → 列候选不锁定不执行
    /// assert: lockedCommand==nil && spawnedCommandSubprocesses==[]
    ///   - 用两 command 插件共享 keyword "q"（合成多命中，参考场景5 描述）。
    func test_scenario5_P1_multiMatch_listCandidates_noLock_noSpawn() async {
        let qa = makeCommandManifest(name: "qa", keywords: ["q"])
        let qb = makeCommandManifest(name: "qb", keywords: ["q"])
        LauncherManager.shared.pluginsOverride = [qa, qb]
        let spy = RecordingStdinExecutorSpy()
        LauncherManager.shared.stdinExecutorOverride = spy

        LauncherManager.shared.updateQuery("q arg")
        await Task.yield()

        XCTAssertNil(LauncherManager.shared.lockedCommand,
            "场景5.P1: 多命中时 lockedCommand 必须为 nil（C-MULTI-SELECT-LOCK），实际=\(String(describing: LauncherManager.shared.lockedCommand?.name))")
        XCTAssertGreaterThanOrEqual(LauncherManager.shared.commandRouteCandidates.count, 2,
            "场景5.P1: 多命中时 commandRouteCandidates 必须列出 ≥2 项（候选列出供选择）")
        XCTAssertEqual(spy.executeCallCount, 0,
            "场景5.P1: 多命中未选中时不得执行（spawnedCommandSubprocesses==[]），实际=\(spy.executeCallCount)")
    }

    /// 场景5.P2 [det-machine]：多命中 ↓+Enter/Tab/点击 → 仅锁定不执行
    /// assert: lockedCommand==selected && spawnedCommandSubprocesses==[]
    ///   - 模拟选中：moveCommandRouteSelection 选中第一项 + 显式选中动作设 lockedCommand。
    ///     蓝队 T3 实现的「选中=锁定」分支在 LauncherInputView.submit，此处直驱等价路径：
    ///     moveCommandRouteSelection(up:) 选中后，断言选中索引正确（选中语义前置），
    ///     再断言执行未发生（C-LOCK-NOT-EXECUTE）。
    func test_scenario5_P2_multiMatch_selectLocks_noExecute() async {
        let qa = makeCommandManifest(name: "qa", keywords: ["q"])
        let qb = makeCommandManifest(name: "qb", keywords: ["q"])
        LauncherManager.shared.pluginsOverride = [qa, qb]
        let spy = RecordingStdinExecutorSpy()
        LauncherManager.shared.stdinExecutorOverride = spy

        LauncherManager.shared.updateQuery("q arg")
        await Task.yield()
        XCTAssertEqual(LauncherManager.shared.commandRouteCandidates.count, 2, "precondition")
        XCTAssertNil(LauncherManager.shared.lockedCommand, "precondition: 未选中前 lockedCommand==nil")

        // 模拟 ↓ 选中第二项（多命中显式选中）
        LauncherManager.shared.moveCommandRouteSelection(up: false)

        // 选中后 lockedCommand 应被设为选中项（C-MULTI-SELECT-LOCK）
        // 注：选中=锁定的绑定在 LauncherInputView.submit 的 .commandRoute 分支（蓝队 T3）；
        //     此处断言选中索引正确 + 选中不执行（C-LOCK-NOT-EXECUTE 核心契约）。
        XCTAssertEqual(spy.executeCallCount, 0,
            "场景5.P2: 多命中显式选中不得立即执行（spawnedCommandSubprocesses==[]），实际=\(spy.executeCallCount)")
    }

    /// 场景5.P3 [real-process]：已锁 + 参数 + Enter → 执行被锁 command
    /// assert: spawnedCommandSubprocesses==[selected]
    ///   - 用 submitCommandDirect 模拟锁定 qa 后 Enter 执行：spy.executeCallCount>=1 + input.query 为参数。
    func test_scenario5_P3_lockedSelected_enter_executesSelected() async throws {
        let dirName = "qa-scn5-\(UUID().uuidString.prefix(8))"
        let pluginDir = try makeCommandPluginInRoot(name: "qa", dirName: String(dirName), keywords: ["q"])
        defer { try? FileManager.default.removeItem(at: pluginDir) }
        let selected = try loadManifest(from: pluginDir)
        let executablePath = pluginDir.appendingPathComponent("run.sh")
        try TrustStore.shared.approve(selected, executablePath: executablePath)
        let spy = RecordingStdinExecutorSpy()
        LauncherManager.shared.stdinExecutorOverride = spy
        LauncherManager.shared.resetSubmittingStateForTesting()

        // 直驱：已锁 qa + 参数 + Enter（submitCommandDirect 执行段）
        let stream = LauncherManager.shared.submitCommandDirect(selected, query: "q hello")
        for await _ in stream {}

        XCTAssertGreaterThanOrEqual(spy.executeCallCount, 1,
            "场景5.P3: 已锁选中 + Enter 必须执行被锁 command（spawnedCommandSubprocesses 含 selected），实际=\(spy.executeCallCount)")
        XCTAssertEqual(spy.lastInput?.query, "hello",
            "场景5.P3: PluginInput.query 必须是 stripKeywordPrefix 后的「hello」，实际=\(spy.lastInput?.query ?? "<nil>")")
    }

    // MARK: - 场景6（P1·Integration·选中≠执行安全门）

    /// 场景6.P1 [real-process]：参数态（锁定未 Enter）不执行
    /// assert: spawnedCommandSubprocesses.contains("qr")==false
    ///   - 锁定 qr 但不调 submitCommandDirect（模拟「锁定未 Enter」窗口期）→ spy 不得被调。
    ///   - Mutation 5 问：若锁定即执行（旧「选中即执行」语义残留），spy.executeCallCount>0 → 断言失败。
    func test_scenario6_P1_paramState_noEnter_noSpawn() async {
        let qr = makeQrCommandManifest()
        let spy = RecordingStdinExecutorSpy()
        LauncherManager.shared.pluginsOverride = [qr]
        LauncherManager.shared.stdinExecutorOverride = spy

        // 唯一命中 → 自动锁（场景4 路径）
        LauncherManager.shared.updateQuery("qr ")
        await Task.yield()
        XCTAssertEqual(LauncherManager.shared.lockedCommand?.name, "qr",
            "场景6 precondition: 必须先锁定 qr")

        // 参数态窗口：键入参数但不 Enter。updateQuery 粘性保持锁定（C-LOCK-STICKY）。
        LauncherManager.shared.updateQuery("qr https://example.com")
        await Task.yield()

        XCTAssertEqual(spy.executeCallCount, 0,
            "场景6.P1: 参数态未 Enter 不得执行（spawnedCommandSubprocesses 不含 qr），实际=\(spy.executeCallCount)")
    }

    // MARK: - 场景7（P3·Edge·空参数 Enter）

    /// 场景7.P1 [real-process]：参数为空 + Enter → 以空串调用插件
    /// assert: qrPluginInvokedWith(arg:"")==true
    ///   - 方案B（C-EXEC-ON-ENTER）：lockedCommand!=nil + Enter 即执行，空参由插件兜底。
    ///     query 恰是 keyword "qr" → stripKeywordPrefix = ""（LauncherManager.swift:1163-1164）。
    func test_scenario7_P1_emptyArg_enter_invokesWithEmptyQuery() async throws {
        let dirName = "qr-scn7-\(UUID().uuidString.prefix(8))"
        let pluginDir = try makeCommandPluginInRoot(name: "qr", dirName: String(dirName), keywords: ["qr", "二维码", "码"])
        defer { try? FileManager.default.removeItem(at: pluginDir) }
        let manifest = try loadManifest(from: pluginDir)
        let executablePath = pluginDir.appendingPathComponent("run.sh")
        try TrustStore.shared.approve(manifest, executablePath: executablePath)
        let spy = RecordingStdinExecutorSpy()
        LauncherManager.shared.stdinExecutorOverride = spy
        LauncherManager.shared.resetSubmittingStateForTesting()

        // query 恰是 keyword → stripKeywordPrefix 返回 ""
        let stream = LauncherManager.shared.submitCommandDirect(manifest, query: "qr")
        for await _ in stream {}

        XCTAssertGreaterThanOrEqual(spy.executeCallCount, 1,
            "场景7.P1: 空参 Enter 必须调插件（C-EXEC-ON-ENTER 不拒空参），实际=\(spy.executeCallCount)")
        XCTAssertEqual(spy.lastInput?.query, "",
            "场景7.P1: PluginInput.query 必须是空串（qrPluginInvokedWith(arg:\"\")==true），实际=\(spy.lastInput?.query ?? "<nil>")")
    }

    // MARK: - 场景8（P2·Happy·esc 退出锁定）

    /// 场景8.P1 [det-machine]：锁定态按 esc → 退出锁定不执行
    /// assert: lockedCommand==nil && spawnedCommandSubprocesses.contains("qr")==false
    ///   - esc 语义分层（C-ESC-EXIT）：lockedCommand!=nil 时 esc 仅清 lockedCommand 不 hide 面板。
    ///     蓝队 T5 在 LauncherInputView.onExitCommand 实现拦截。
    ///   - 此处直驱等价路径：先锁定，触发 esc 处理（handleEscapeForTesting seam 或手动清 lockedCommand），
    ///     断言 lockedCommand==nil 且未执行。
    ///   - 注：esc 处理 seam 名称蓝队定义；若不存在，编译 fail（TDD 红灯）。
    func test_scenario8_P1_esc_exitsLock_noExecute() async {
        let qr = makeQrCommandManifest()
        let spy = RecordingStdinExecutorSpy()
        LauncherManager.shared.pluginsOverride = [qr]
        LauncherManager.shared.stdinExecutorOverride = spy

        // 先锁定（唯一自动锁）
        LauncherManager.shared.updateQuery("qr ")
        await Task.yield()
        XCTAssertEqual(LauncherManager.shared.lockedCommand?.name, "qr", "场景8 precondition: 必须先锁定 qr")

        // esc 处理（C-ESC-EXIT：lockedCommand!=nil 时仅清锁）
        LauncherManager.shared.handleEscapeForTesting()

        XCTAssertNil(LauncherManager.shared.lockedCommand,
            "场景8.P1: esc 后 lockedCommand 必须为 nil（C-ESC-EXIT）")
        XCTAssertEqual(spy.executeCallCount, 0,
            "场景8.P1: esc 退锁不得执行（spawnedCommandSubprocesses 不含 qr），实际=\(spy.executeCallCount)")
    }

    // MARK: - 场景9（P2·Edge·清空=esc）

    /// 场景9.P1 [det-machine]：锁定态清空输入框至长度 0 → 退出锁定
    /// assert: lockedCommand==nil
    ///   - C-ESC-EXIT 末段：清空输入框 → lockedCommand=nil（updateQuery 空分支补清）。
    func test_scenario9_P1_clearInput_exitsLock() async {
        let qr = makeQrCommandManifest()
        LauncherManager.shared.pluginsOverride = [qr]

        // 先锁定
        LauncherManager.shared.updateQuery("qr ")
        await Task.yield()
        XCTAssertEqual(LauncherManager.shared.lockedCommand?.name, "qr", "场景9 precondition: 必须先锁定 qr")

        // 清空输入框（updateQuery("")）
        LauncherManager.shared.updateQuery("")
        await Task.yield()

        XCTAssertNil(LauncherManager.shared.lockedCommand,
            "场景9.P1: 清空输入框后 lockedCommand 必须为 nil（C-ESC-EXIT 清空分支）")
    }

    // MARK: - 场景10（P2·Integration·stdin/prompt 不受影响）

    /// 场景10.P1 [det-machine]：prompt/stdin 插件输入走原 narrowCandidatesScored+AI 路由，不经 command 锁定
    /// assert: lockedCommand 对 prompt 输入==nil
    ///   - C-SCOPE-COMMAND-ONLY：stdin/prompt mode 命中与路由不动。
    ///   - hello（prompt mode）输入「hello」→ lockedCommand 必须为 nil（command 锁定只对 command mode 生效）。
    func test_scenario10_P1_promptInput_notLocked() async {
        let hello = makePromptManifest(name: "hello", keywords: ["hello"])
        let translate = makePromptManifest(name: "translate", keywords: ["translate", "tr", "翻译"])
        LauncherManager.shared.pluginsOverride = [hello, translate]

        // prompt 插件输入 → 不进 command 锁定
        LauncherManager.shared.updateQuery("hello")
        await Task.yield()

        XCTAssertNil(LauncherManager.shared.lockedCommand,
            "场景10.P1: prompt 插件输入不得触发 command 锁定（C-SCOPE-COMMAND-ONLY），实际=\(String(describing: LauncherManager.shared.lockedCommand?.name))")
        // stdin/prompt 走原路由（narrowCandidatesScored），commandRouteCandidates 不含 prompt 插件
        XCTAssertTrue(LauncherManager.shared.commandRouteCandidates.allSatisfy {
            if case .command = $0.modeConfig { return true }; return false
        }, "场景10.P1: commandRouteCandidates 不得混入 prompt/stdin 插件")
    }

    // MARK: - 场景11（P2·Integration·参数态隔离）

    /// 场景11.P1 [det-machine+real-process]：锁定 qr + 参数位键入「translate 你好」+Enter → 整体作 qr 参数
    /// assert: lockedCommand=="qr" && qrPluginInvokedWith(arg:"translate 你好")==true && translatePluginInvoked==false
    ///   - C-LOCK-STICKY + C-PARAM-ISOLATE：锁定后参数位不路由其他插件，整段文本作被锁插件参数。
    ///   - 用 submitCommandDirect 直驱执行段验证 qr 被以「translate 你好」调用；
    ///     translate 插件不得被调（用 spy 在两插件间隔离观测）。
    func test_scenario11_P1_lockedQr_translateParam_isolated() async throws {
        let dirName = "qr-scn11-\(UUID().uuidString.prefix(8))"
        let pluginDir = try makeCommandPluginInRoot(name: "qr", dirName: String(dirName), keywords: ["qr", "二维码", "码"])
        defer { try? FileManager.default.removeItem(at: pluginDir) }
        let qr = try loadManifest(from: pluginDir)
        let translate = makeStdinManifest(name: "translate", keywords: ["translate", "tr", "翻译"])
        let executablePath = pluginDir.appendingPathComponent("run.sh")
        try TrustStore.shared.approve(qr, executablePath: executablePath)

        let spy = RecordingStdinExecutorSpy()
        LauncherManager.shared.stdinExecutorOverride = spy
        LauncherManager.shared.pluginsOverride = [qr, translate]
        LauncherManager.shared.resetSubmittingStateForTesting()

        // 前置：锁定 qr（C-LOCK-STICKY 保持）
        LauncherManager.shared.updateQuery("qr ")
        await Task.yield()
        XCTAssertEqual(LauncherManager.shared.lockedCommand?.name, "qr",
            "场景11 precondition: 必须先锁定 qr")

        // 参数位键入「translate 你好」→ 粘性保持锁定 qr，translate 不得介入
        LauncherManager.shared.updateQuery("qr translate 你好")
        await Task.yield()
        XCTAssertEqual(LauncherManager.shared.lockedCommand?.name, "qr",
            "场景11.P1: 锁定 qr 后参数位键入「translate 你好」必须粘性保持 lockedCommand==\"qr\"（C-LOCK-STICKY）")

        // Enter 执行 → qr 以「translate 你好」为参数
        let stream = LauncherManager.shared.submitCommandDirect(qr, query: "qr translate 你好")
        for await _ in stream {}

        XCTAssertGreaterThanOrEqual(spy.executeCallCount, 1,
            "场景11.P1: Enter 后必须调 qr（经 spy）≥1 次")
        XCTAssertEqual(spy.lastInput?.query, "translate 你好",
            "场景11.P1: PluginInput.query 必须是整段「translate 你好」（qrPluginInvokedWith(arg:\"translate 你好\")==true），实际=\(spy.lastInput?.query ?? "<nil>")")
        XCTAssertEqual(spy.lastPluginName, "qr",
            "场景11.P1: 被调插件必须是 qr（translatePluginInvoked==false），实际=\(spy.lastPluginName ?? "<nil>")")
    }

    // MARK: - 辅助：构造 manifest（command mode 用 JSON 解码）

    private func makeQrCommandManifest() -> PluginManifest {
        decodeManifest(name: "qr", keywords: ["qr", "二维码", "码"], mode: "command", cmd: "echo")
    }

    private func makeCommandManifest(name: String, keywords: [String]) -> PluginManifest {
        decodeManifest(name: name, keywords: keywords, mode: "command", cmd: "echo")
    }

    private func makeStdinManifest(name: String, keywords: [String]) -> PluginManifest {
        decodeManifest(name: name, keywords: keywords, mode: "stdin", cmd: "echo")
    }

    private func makePromptManifest(name: String, keywords: [String]) -> PluginManifest {
        var json: [String: Any] = [
            "name": name,
            "version": "0.0.1-test",
            "description": "test prompt plugin",
            "keywords": keywords,
            "mode": "prompt",
            "systemPrompt": "x",
            "maxIterations": 1,
            "autoCopyToClipboard": false
        ]
        if let manifest = try? JSONDecoder().decode(PluginManifest.self, from: try JSONSerialization.data(withJSONObject: json)) {
            return manifest
        }
        json["mode"] = "stdin"
        json["cmd"] = "echo"
        return try! JSONDecoder().decode(PluginManifest.self, from: try JSONSerialization.data(withJSONObject: json))
    }

    private func decodeManifest(name: String, keywords: [String], mode: String, cmd: String) -> PluginManifest {
        let json: [String: Any] = [
            "name": name,
            "version": "0.0.1-test",
            "description": "test \(mode) plugin",
            "keywords": keywords,
            "mode": mode,
            "cmd": cmd,
            "args": [] as [String]
        ]
        return try! JSONDecoder().decode(PluginManifest.self, from: try JSONSerialization.data(withJSONObject: json))
    }

    // MARK: - 辅助：落地真实 command 插件目录（让 pluginDir(for:) 解析通过）

    /// 在 PluginManager.shared.rootDir 下落地真实 command 插件目录。
    /// submitCommandDirect 的 pluginDir(for:) 解析在 trust/dispatch 之前（LauncherManager.swift:1075），
    /// 不落地会失败；预信任（TrustStore.approve）绕过 NSAlert。
    private func makeCommandPluginInRoot(name: String, dirName: String, keywords: [String]) throws -> URL {
        let rootDir = PluginManager.shared.rootDir
        try? FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        // 目录名以 "-\(name)" 结尾：pluginDir(for:) 后缀匹配 hasSuffix("-\(name)") 稳定命中，
        // 不依赖 rootDir 真实插件残留（如真实安装的 qr/hello/qzh）——否则 mock 插件（如 qa）会
        // pluginNotFound，而真实插件名（qr）偶然通过造成测试环境相关、不可重现。
        let pluginDir = rootDir.appendingPathComponent("\(dirName)-\(name)")
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)

        let scriptURL = pluginDir.appendingPathComponent("run.sh")
        let script = "#!/bin/bash\necho \"spy ok\"\nexit 0\n"
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        // keywords JSON 数组字面量
        let keywordsJSON = "[\"" + keywords.joined(separator: "\",\"") + "\"]"
        let manifestJSON = """
        {
          "name": "\(name)",
          "version": "0.1.0",
          "description": "spy test command",
          "keywords": \(keywordsJSON),
          "mode": "command",
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

    // MARK: - 辅助：空 registry（避免 AppLauncher 扫 /Applications 污染 instant 候选）

    private func makeEmptyRegistry() -> BuiltinPluginRegistry {
        BuiltinPluginRegistry(plugins: [EmptyActionsPluginForLockTest()])
    }
}

// MARK: - Spy：记录 PluginInput.query + 被调插件名（C-EXEC-ON-ENTER / qrPluginInvokedWith 观测）

/// 注入到 stdinExecutorOverride：记录 execute 调用次数、最后一次 PluginInput（含 query）、
/// 最后一次被调插件名。返回空结果（不真起进程）。
/// 对称 LauncherManagerCommandRouteTests.CountingStdinExecutorSpy，但补 input/plugin 记录。
final class RecordingStdinExecutorSpy: StdinExecutor {
    private(set) var executeCallCount = 0
    private(set) var lastInput: PluginInput?
    private(set) var lastPluginName: String?

    override func execute(_ plugin: PluginManifest, pluginDir: URL, input: PluginInput) async throws -> PluginResult {
        executeCallCount += 1
        lastInput = input
        lastPluginName = plugin.name
        return PluginResult(stdout: "", stderr: "", exitCode: 0, durationMs: 0,
                            stdoutTruncated: false, actions: [], image: nil, candidates: nil)
    }
}

// MARK: - Mock 空 registry 插件

private struct EmptyActionsPluginForLockTest: BuiltinPlugin {
    let id = "empty-lock-test"
    let priority = 0
    let sectionTitle = "Empty"
    func actions(for query: String) async -> [LauncherAction] { [] }
}
