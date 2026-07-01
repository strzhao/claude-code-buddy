import XCTest
@testable import BuddyCore

// MARK: - LauncherManagerCommandRouteTests
//
// 蓝队单测：LauncherManager command 路由候选分区改造（方案 B）
//
// 契约引用（state.md ## 契约规约）：
//   C1：commandRouteCandidates 由 updateQuery 填充（command-mode 子集），复位点清空
//   C2：activeCandidateZone 默认 .commandRoute（非空），各 zone 独立索引（不再 -1 钉死 instant）
//   C5：跨区导航四态矩阵 + 单区环形 + pluginCandidates 隔离
//   C9：commandRouteCandidates 仅含 .command 模式
//   C10：仅 instant 或仅 command 时行为同改造前
//   C11：submitCommandDirect 零 provider/零 LLM + stdinExecutorOverride spy seam
//
// TDD：先于实现编写，最初因 LauncherManager 新字段/方法未实现编译失败（RED）。

@MainActor
final class LauncherManagerCommandRouteTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        LauncherManager.shared.resetSubmittingStateForTesting()
        LauncherManager.shared.instantDebounceMsOverride = 0
        LauncherManager.shared.registryOverride = nil
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
        LauncherManager.shared.instantDebounceMsOverride = nil
        LauncherManager.shared.registryOverride = nil
        LauncherManager.shared.clearInstantActions()
        try await super.tearDown()
    }

    // MARK: - C1/C9：updateQuery 多命中填充 command-mode 子集（唯一命中改自动锁定，见 C-UNIQUE-AUTOLOCK 测试）

    /// updateQuery 多命中 command 插件时，commandRouteCandidates 含这些 command 插件（C-MULTI-SELECT-LOCK）。
    /// 注：唯一命中已改为「自动锁定 + 候选清空」（C-UNIQUE-AUTOLOCK），多命中才列候选。
    func test_C1_updateQuery_multiHit_fillsCommandRouteCandidates_withCommandMode() async {
        let qa = makeCommandManifest(name: "qa", keywords: ["q"])
        let qb = makeCommandManifest(name: "qb", keywords: ["q"])
        LauncherManager.shared.pluginsOverride = [qa, qb]
        LauncherManager.shared.instantDebounceMsOverride = 0

        LauncherManager.shared.updateQuery("q xxx")
        // 等 sync 部分落地（commandRouteCandidates 是 updateQuery 同步段填充）
        await Task.yield()

        XCTAssertEqual(LauncherManager.shared.commandRouteCandidates.count, 2,
            "C1: 多命中 command 插件后 commandRouteCandidates 应含 2 项")
        XCTAssertTrue(LauncherManager.shared.commandRouteCandidates.allSatisfy {
            if case .command = $0.modeConfig { return true }; return false
        }, "C9: commandRouteCandidates 必须全部为 command mode")
        XCTAssertNil(LauncherManager.shared.lockedCommand,
            "C-MULTI-SELECT-LOCK: 多命中不应自动锁定")
    }

    /// C-UNIQUE-AUTOLOCK：唯一命中 → 自动锁定，候选清空。
    func test_C1_updateQuery_uniqueHit_autoLocks() async {
        let qzh = makeCommandManifest(name: "qzh", keywords: ["qzh"])
        LauncherManager.shared.pluginsOverride = [qzh]
        LauncherManager.shared.instantDebounceMsOverride = 0

        LauncherManager.shared.updateQuery("qzh")
        await Task.yield()

        XCTAssertEqual(LauncherManager.shared.lockedCommand?.name, "qzh",
            "C-UNIQUE-AUTOLOCK: 唯一命中应自动锁定 qzh")
        XCTAssertTrue(LauncherManager.shared.commandRouteCandidates.isEmpty,
            "C-UNIQUE-AUTOLOCK: 唯一命中锁定后候选应清空")
    }

    /// stdin/prompt 插件不进 commandRouteCandidates（C9）。
    func test_C9_stdinPromptPlugins_notInCommandRouteCandidates() async {
        let stdin = makeStdinManifest(name: "stdin-plug", keywords: ["sp"])
        let prompt = makePromptManifest(name: "prompt-plug", keywords: ["pp"])
        LauncherManager.shared.pluginsOverride = [stdin, prompt]

        LauncherManager.shared.updateQuery("sp")
        await Task.yield()

        XCTAssertTrue(LauncherManager.shared.commandRouteCandidates.isEmpty,
            "C9: stdin/prompt 插件不应进 commandRouteCandidates")
    }

    // MARK: - C2：activeCandidateZone 默认 + 选中索引（多命中两区并存场景）

    /// 两区并存（多命中 command + instant）时默认 activeCandidateZone=.commandRoute + commandRouteSelectedIndex=0 + instant 不预选。
    /// 注：唯一 command 命中会自动锁定（C-UNIQUE-AUTOLOCK）隔离 instant；此测试用多命中验证两区并存。
    func test_C2_bothZonesPresent_defaultActiveIsCommandRoute() async {
        let qa = makeCommandManifest(name: "qa", keywords: ["q"])
        let qb = makeCommandManifest(name: "qb", keywords: ["q"])
        LauncherManager.shared.pluginsOverride = [qa, qb]
        let registry = makeRegistryWithFixedActions([
            makeAction(id: "qzhddr-app", title: "Qzhddr")
        ])
        LauncherManager.shared.registryOverride = registry
        LauncherManager.shared.instantDebounceMsOverride = 0

        LauncherManager.shared.updateQuery("q xxx")
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(LauncherManager.shared.activeCandidateZone, .commandRoute,
            "C2: 两区并存时默认 activeCandidateZone 应为 .commandRoute（command 优先）")
        XCTAssertEqual(LauncherManager.shared.commandRouteSelectedIndex, 0,
            "C2: commandRoute 非空时 commandRouteSelectedIndex 应为 0")
        XCTAssertFalse(LauncherManager.shared.instantActions.isEmpty,
            "C2: 两区并存时 instantActions 应仍可见（只是不预选）")
    }

    /// 仅 instant 命中时 activeCandidateZone=.instant + instantSelectedIndex=0（C10 回归）。
    func test_C10_onlyInstant_activeZoneInstant_selectedIndex0() async {
        let registry = makeRegistryWithFixedActions([
            makeAction(id: "safari-id", title: "Safari")
        ])
        LauncherManager.shared.registryOverride = registry
        LauncherManager.shared.instantDebounceMsOverride = 0

        LauncherManager.shared.updateQuery("saf")
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(LauncherManager.shared.activeCandidateZone, .instant,
            "C10: 仅 instant 命中时 activeCandidateZone 应为 .instant")
        XCTAssertEqual(LauncherManager.shared.instantSelectedIndex, 0,
            "C10: 仅 instant 时 instantSelectedIndex 应为 0（默认选中首项）")
        XCTAssertTrue(LauncherManager.shared.commandRouteCandidates.isEmpty,
            "C10: 仅 instant 命中时 commandRouteCandidates 应空")
    }

    /// 仅 command 唯一命中 → 自动锁定（C-UNIQUE-AUTOLOCK）：候选清空 + instant 隔离 + activeCandidateZone 不再 commandRoute。
    func test_C10_onlyCommand_uniqueHit_autoLocks() async {
        let qzh = makeCommandManifest(name: "qzh", keywords: ["qzh"])
        LauncherManager.shared.pluginsOverride = [qzh]
        LauncherManager.shared.instantDebounceMsOverride = 0
        // 注入空 registry：避免默认 BuiltinPluginRegistry.shared（AppLauncher 扫 /Applications）污染
        LauncherManager.shared.registryOverride = makeEmptyRegistry()

        LauncherManager.shared.updateQuery("qzh")
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(LauncherManager.shared.lockedCommand?.name, "qzh",
            "C-UNIQUE-AUTOLOCK: 唯一命中应自动锁定 qzh")
        XCTAssertTrue(LauncherManager.shared.commandRouteCandidates.isEmpty,
            "C-UNIQUE-AUTOLOCK: 锁定后候选应清空")
        XCTAssertTrue(LauncherManager.shared.instantActions.isEmpty,
            "C-PARAM-ISOLATE: 锁定后 instantActions 应空")

        LauncherManager.shared.registryOverride = nil
    }

    // MARK: - C1 复位点：空 query / show / hide

    /// 空 query 清空 commandRouteCandidates + commandRouteSelectedIndex=-1。
    /// precondition 用多命中（唯一命中会自动锁定使候选清空，无法验证「空 query 清候选」）。
    func test_C1_emptyQuery_clearsCommandRoute() async {
        let qa = makeCommandManifest(name: "qa", keywords: ["q"])
        let qb = makeCommandManifest(name: "qb", keywords: ["q"])
        LauncherManager.shared.pluginsOverride = [qa, qb]

        LauncherManager.shared.updateQuery("q xxx")
        await Task.yield()
        XCTAssertFalse(LauncherManager.shared.commandRouteCandidates.isEmpty, "precondition")

        LauncherManager.shared.updateQuery("")
        XCTAssertTrue(LauncherManager.shared.commandRouteCandidates.isEmpty,
            "C1: 空 query 应清空 commandRouteCandidates")
        XCTAssertEqual(LauncherManager.shared.commandRouteSelectedIndex, -1,
            "C1: 空 query 应复位 commandRouteSelectedIndex 为 -1")
    }

    /// C-ESC-EXIT：唯一命中锁定后，空 query 应清 lockedCommand。
    func test_C1_emptyQuery_clearsLockedCommand() async {
        let qzh = makeCommandManifest(name: "qzh", keywords: ["qzh"])
        LauncherManager.shared.pluginsOverride = [qzh]

        LauncherManager.shared.updateQuery("qzh")
        await Task.yield()
        XCTAssertEqual(LauncherManager.shared.lockedCommand?.name, "qzh", "precondition: 已锁定")

        LauncherManager.shared.updateQuery("")
        XCTAssertNil(LauncherManager.shared.lockedCommand,
            "C-ESC-EXIT: 空 query 应清 lockedCommand")
    }

    /// show() 清空 commandRoute 状态 + lockedCommand（C-ESC-EXIT 复位点）。
    func test_C1_show_clearsCommandRoute() async {
        let qa = makeCommandManifest(name: "qa", keywords: ["q"])
        let qb = makeCommandManifest(name: "qb", keywords: ["q"])
        LauncherManager.shared.pluginsOverride = [qa, qb]

        LauncherManager.shared.updateQuery("q xxx")
        await Task.yield()
        XCTAssertFalse(LauncherManager.shared.commandRouteCandidates.isEmpty, "precondition")

        LauncherManager.shared.show()
        XCTAssertTrue(LauncherManager.shared.commandRouteCandidates.isEmpty,
            "C1: show() 应清空 commandRouteCandidates")
        XCTAssertEqual(LauncherManager.shared.commandRouteSelectedIndex, -1,
            "C1: show() 应复位 commandRouteSelectedIndex 为 -1")
        XCTAssertNil(LauncherManager.shared.lockedCommand,
            "C1: show() 应清 lockedCommand")
        LauncherManager.shared.hide()
    }

    // MARK: - C5：单区环形 + setCommandRouteSelectedIndex

    /// moveCommandRouteSelection 在单区内环形（commandRoute 单区）。
    func test_C5_moveCommandRouteSelection_wrapsWithinZone() async {
        let plugins = [
            makeCommandManifest(name: "qa", keywords: ["q"]),
            makeCommandManifest(name: "qb", keywords: ["q"]),
            makeCommandManifest(name: "qc", keywords: ["q"])
        ]
        LauncherManager.shared.pluginsOverride = plugins
        LauncherManager.shared.instantDebounceMsOverride = 0

        LauncherManager.shared.updateQuery("q")
        await Task.yield()
        XCTAssertEqual(LauncherManager.shared.commandRouteCandidates.count, 3, "precondition")
        XCTAssertEqual(LauncherManager.shared.commandRouteSelectedIndex, 0)

        // 末→首循环
        LauncherManager.shared.setCommandRouteSelectedIndex(2)
        LauncherManager.shared.moveCommandRouteSelection(up: false)
        XCTAssertEqual(LauncherManager.shared.commandRouteSelectedIndex, 0,
            "C5: 末项下移应循环回首项")

        // 首→末循环
        LauncherManager.shared.moveCommandRouteSelection(up: true)
        XCTAssertEqual(LauncherManager.shared.commandRouteSelectedIndex, 2,
            "C5: 首项上移应循环至末项")
    }

    // MARK: - C11：submitCommandDirect 零 provider + spy seam

    /// submitCommandDirect 用 stdinExecutorOverride seam，非 command mode → errorStream。
    func test_C11_submitCommandDirect_nonCommandMode_yieldsError() async {
        let stdin = makeStdinManifest(name: "stdin-plug", keywords: ["sp"])
        let spy = CountingStdinExecutorSpy()
        LauncherManager.shared.stdinExecutorOverride = spy

        let stream = LauncherManager.shared.submitCommandDirect(stdin, query: "sp")
        var sawError = false
        var eventCount = 0
        for await event in stream {
            eventCount += 1
            if case .error = event { sawError = true }
        }
        XCTAssertTrue(sawError, "C11: 非 command mode 调 submitCommandDirect 应 yield error")
        XCTAssertEqual(spy.executeCallCount, 0,
            "C11: 非 command mode 不应调 dispatcher.execute")
        XCTAssertGreaterThan(eventCount, 0, "C11: 应至少产 1 个事件（error）")
    }

    /// submitCommandDirect 调通后 stage idle→calling→streaming→idle，spy.execute 被调至少 1 次。
    /// 需真实落地 plugin dir 到 PluginManager.shared.rootDir（pluginDir 解析在 trust/dispatch 之前）
    /// + 预信任（避免 TrustStore.checkAndPrompt 弹真实 NSAlert 挂死测试）。
    func test_C11_submitCommandDirect_commandMode_invokesSpyAndStageTransitions() async throws {
        let dirName = "qzh-spy-\(UUID().uuidString.prefix(8))"
        let pluginDir = try makeCommandPluginInRoot(dirName: String(dirName))
        defer { try? FileManager.default.removeItem(at: pluginDir) }
        let manifest = try loadManifest(from: pluginDir)
        // 预信任：绕过 NSAlert（trustKey 命中已信任记录 → checkAndPrompt 直接 true）
        let executablePath = pluginDir.appendingPathComponent("run.sh")
        try TrustStore.shared.approve(manifest, executablePath: executablePath)
        let spy = CountingStdinExecutorSpy()
        LauncherManager.shared.stdinExecutorOverride = spy
        LauncherManager.shared.resetSubmittingStateForTesting()
        XCTAssertEqual(LauncherManager.shared.stage, .idle, "precondition: stage=idle")

        let stream = LauncherManager.shared.submitCommandDirect(manifest, query: String(dirName))
        var sawDone = false
        for await event in stream {
            if case .done = event { sawDone = true }
        }

        XCTAssertTrue(sawDone, "C11: command mode 成功执行应产 .done")
        XCTAssertGreaterThanOrEqual(spy.executeCallCount, 1,
            "C11: command mode 应调 dispatcher.execute（经 spy）≥1 次")
        XCTAssertEqual(LauncherManager.shared.stage, .idle,
            "C11: 执行完成后 stage 应回到 .idle")
    }

    /// C11/B2：submitCommandDirect prologue 清空 commandRouteCandidates + selectedIndex=-1。
    /// precondition 用多命中（唯一命中会自动锁定使候选清空）。
    func test_C11_submitCommandDirect_prologue_clearsCommandRoute() async {
        let qzh = makeCommandManifest(name: "qzh-clear", keywords: ["q"])
        let other = makeCommandManifest(name: "other-clear", keywords: ["q"])
        LauncherManager.shared.pluginsOverride = [qzh, other]
        LauncherManager.shared.stdinExecutorOverride = CountingStdinExecutorSpy()

        LauncherManager.shared.updateQuery("q xxx")
        await Task.yield()
        XCTAssertFalse(LauncherManager.shared.commandRouteCandidates.isEmpty, "precondition")

        let stream = LauncherManager.shared.submitCommandDirect(qzh, query: "q xxx")
        // 消费流驱动 prologue 落地
        for await _ in stream {}

        XCTAssertTrue(LauncherManager.shared.commandRouteCandidates.isEmpty,
            "C11/B2: submitCommandDirect prologue 应清空 commandRouteCandidates")
        XCTAssertEqual(LauncherManager.shared.commandRouteSelectedIndex, -1,
            "C11/B2: prologue 应复位 commandRouteSelectedIndex 为 -1")
    }

    // MARK: - 辅助：构造 manifest / registry / action

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
        // fallback: stdin (never expected)
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

    /// 在 PluginManager.shared.rootDir 下落地真实 command 插件目录（供 pluginDir 解析成功）。
    private func makeCommandPluginInRoot(dirName: String) throws -> URL {
        let rootDir = PluginManager.shared.rootDir
        try? FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        let pluginDir = rootDir.appendingPathComponent(dirName)
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)

        let scriptURL = pluginDir.appendingPathComponent("run.sh")
        let script = "#!/bin/bash\necho \"spy ok\"\nexit 0\n"
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let manifestJSON = """
        {
          "name": "\(dirName)",
          "version": "0.1.0",
          "description": "spy test command",
          "keywords": [],
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

    private func makeAction(id: String, title: String) -> LauncherAction {
        LauncherAction(
            id: id, title: title, subtitle: nil, icon: nil,
            pluginId: "test-plugin", score: 100, perform: {}
        )
    }

    private func makeRegistryWithFixedActions(_ actions: [LauncherAction]) -> BuiltinPluginRegistry {
        let plugin = FixedActionsPlugin(mockActions: actions)
        return BuiltinPluginRegistry(plugins: [plugin])
    }

    private func makeEmptyRegistry() -> BuiltinPluginRegistry {
        BuiltinPluginRegistry(plugins: [EmptyActionsPlugin()])
    }
}

// MARK: - Spy：计数 StdinExecutor 调用（C11/I6 spy seam）

/// 注入到 submitCommandDirect 的 stdinExecutorOverride：记录 execute 调用次数，返回空结果（不真起进程）。
final class CountingStdinExecutorSpy: StdinExecutor {
    private(set) var executeCallCount = 0
    override func execute(_ plugin: PluginManifest, pluginDir: URL, input: PluginInput) async throws -> PluginResult {
        executeCallCount += 1
        return PluginResult(stdout: "", stderr: "", exitCode: 0, durationMs: 0, stdoutTruncated: false, actions: [], image: nil, candidates: nil)
    }
}

// MARK: - Mock 固定候选插件

private struct FixedActionsPlugin: BuiltinPlugin {
    let id = "test-plugin"
    let priority = 0
    let sectionTitle = "测试"
    let mockActions: [LauncherAction]

    func actions(for query: String) async -> [LauncherAction] {
        guard !query.isEmpty else { return [] }
        return mockActions
    }
}

private struct EmptyActionsPlugin: BuiltinPlugin {
    let id = "empty-test"
    let priority = 0
    let sectionTitle = "Empty"
    func actions(for query: String) async -> [LauncherAction] { [] }
}
