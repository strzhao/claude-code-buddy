import XCTest
@testable import BuddyCore

// MARK: - LauncherManagerUnifiedCandidatesTests
//
// 蓝队单测：LauncherManager 统一混排管线（D2/D3，C-UNIFIED-SCORE）
//
// 契约引用（state.md ## 契约规约 / ## 设计决策）：
//   C-UNIFIED-SCORE：统一量纲（完全 1000/前缀 800/词首 500/contains 150，name +30；
//                    单字 keyword 仅完全档）；排序键 (score desc, 来源序, title)；截 8
//   D3.3            ：合并列表进 instantActions（插件不分 mode）
//   D3.5            ：typing 期 activeCandidateZone 恒 .instant（.commandRoute 已删）
//   D3.6/C-TAB-LOCK：「唯一命中自动锁定」「keyword+空格自动锁定」不存在；Tab 锁定粘性保留
//   C-ESC-EXIT      ：空输入清锁定
//   C11             ：submitCommandDirect spy seam（stdinExecutorOverride）
//   C-NO-REGRESS ⑬ ：pluginsOverride 空集 → 仅 app+内置候选，不崩

@MainActor
final class LauncherManagerUnifiedCandidatesTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        LauncherManager.shared.resetSubmittingStateForTesting()
        LauncherManager.shared.instantDebounceMsOverride = 0
        LauncherManager.shared.registryOverride = makeEmptyRegistry()
        LauncherManager.shared.pluginsOverride = nil
        LauncherManager.shared.stdinExecutorOverride = nil
        LauncherManager.shared.clearInstantActions()
        LauncherManager.shared.clearLockedCommand()
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
        LauncherManager.shared.clearLockedCommand()
        try await super.tearDown()
    }

    // MARK: - D3.3：插件候选（不分 mode）进 unifiedCandidates

    /// command/stdin/prompt 三 mode 插件均按关键词进统一列表（场景7.P1 数据层）
    func test_D33_allModes_pluginsEnterUnifiedList() async {
        let cmd = decodeManifest(name: "cmdplug", keywords: ["cmdkw"], mode: "command")
        let stdin = decodeManifest(name: "stdinplug", keywords: ["stdinkw"], mode: "stdin")
        let prompt = decodeManifest(name: "promptplug", keywords: ["promptkw"], mode: "prompt")
        LauncherManager.shared.pluginsOverride = [cmd, stdin, prompt]

        let forCmd = await LauncherManager.shared.unifiedCandidates(for: "cmdkw")
        let forStdin = await LauncherManager.shared.unifiedCandidates(for: "stdinkw")
        let forPrompt = await LauncherManager.shared.unifiedCandidates(for: "promptkw")

        XCTAssertTrue(forCmd.contains { $0.pluginId == "cmdplug" }, "command 插件进统一列表")
        XCTAssertTrue(forStdin.contains { $0.pluginId == "stdinplug" }, "stdin 插件进统一列表（不分 mode）")
        XCTAssertTrue(forPrompt.contains { $0.pluginId == "promptplug" }, "prompt 插件进统一列表（不分 mode）")
    }

    /// 插件候选映射契约（D1）：id="plugin:<name>"、title=name、subtitle=displaySummary、iconEmoji=icon
    func test_D1_pluginCandidateMapping_fields() async {
        let qr = decodeManifest(name: "qrplug", keywords: ["qrkw"], mode: "command")
        LauncherManager.shared.pluginsOverride = [qr]

        let acts = await LauncherManager.shared.unifiedCandidates(for: "qrkw")
        let row = try! XCTUnwrap(acts.first { $0.pluginId == "qrplug" })
        XCTAssertEqual(row.id, "plugin:qrplug")
        XCTAssertEqual(row.title, "qrplug")
        XCTAssertEqual(row.subtitle, qr.displaySummary)
        XCTAssertEqual(row.iconEmoji, qr.icon)
        XCTAssertEqual(row.score, 1000, "keyword 完全命中 → 1000（keyword 无 name+30）")
    }

    /// D2 排序键：分数降序；同分时插件（来源序 50）在 app（来源序 0）前
    func test_D2_sortKey_scoreDescThenSourceRank() async {
        let kwPlugin = decodeManifest(name: "kwplug", keywords: ["sameday"], mode: "command")
        LauncherManager.shared.pluginsOverride = [kwPlugin]
        // app 候选：name "sameday app" 前缀命中 1000+50=1050 太高；用同分构造：
        // 插件 keyword 完全命中 1000；app mock 候选 score 1000（registry mock 直接给分）
        LauncherManager.shared.registryOverride = makeStaticRegistry(score: 1000)

        let acts = await LauncherManager.shared.unifiedCandidates(for: "sameday")
        // 插件（来源 50）应排在同分 app mock（来源 0）前
        let pluginIdx = acts.firstIndex { $0.pluginId == "kwplug" }
        let appIdx = acts.firstIndex { $0.pluginId == "mock-app" }
        XCTAssertNotNil(pluginIdx)
        XCTAssertNotNil(appIdx)
        if let p = pluginIdx, let a = appIdx {
            XCTAssertLessThan(p, a, "同分时社区插件（来源序 50）> app（来源序 0）")
        }
    }

    /// C-UNIFIED-SCORE 截断：合并列表 ≤ 8
    func test_D2_mergeList_truncatedTo8() async {
        var plugins: [PluginManifest] = []
        for i in 0..<12 {
            plugins.append(decodeManifest(name: "p\(i)", keywords: ["sharedkw\(i)"], mode: "command"))
        }
        LauncherManager.shared.pluginsOverride = plugins
        // query "sharedkw" 每个插件前缀命中 keyword（800）
        let acts = await LauncherManager.shared.unifiedCandidates(for: "sharedkw")
        XCTAssertLessThanOrEqual(acts.count, 8, "统一列表截 builtinActionsLimit=8")
    }

    // MARK: - D3.5 / D3.6：updateQuery 语义

    /// updateQuery 后插件候选进 instantActions 且 activeCandidateZone 恒 .instant
    func test_D35_updateQuery_instantActionsUnified_zoneInstant() async {
        let qr = decodeManifest(name: "qr", keywords: ["qr", "二维码", "码"], mode: "command")
        LauncherManager.shared.pluginsOverride = [qr]

        LauncherManager.shared.updateQuery("二维码")
        await Task.yield()

        XCTAssertTrue(LauncherManager.shared.instantActions.contains { $0.pluginId == "qr" },
            "输「二维码」qr 完全命中进 instantActions（场景1.P1 数据层）")
        XCTAssertEqual(LauncherManager.shared.activeCandidateZone, .instant,
            "D3.5：typing 期活动区恒 .instant")
    }

    /// C-TAB-LOCK：输「qr 」（keyword+空格）不自动锁定（场景11.P1）
    func test_CTABLOCK_keywordSpace_noAutoLock() async {
        let qr = decodeManifest(name: "qr", keywords: ["qr", "二维码", "码"], mode: "command")
        LauncherManager.shared.pluginsOverride = [qr]

        LauncherManager.shared.updateQuery("qr ")
        await Task.yield()

        XCTAssertNil(LauncherManager.shared.lockedCommand,
            "C-TAB-LOCK：keyword+空格不得自动锁定（自动锁定已退役）")
        XCTAssertFalse(LauncherManager.shared.instantActions.isEmpty,
            "场景11.P1: 候选保持统一混排列表")
    }

    /// 场景14.P1：输「密码」「验证码」instantActions 不含 qr（单字 keyword 档位排除）
    func test_CNOREGRESS6_密码_notInInstantActions() async {
        let qr = decodeManifest(name: "qr", keywords: ["qr", "qrcode", "二维码", "码"], mode: "command")
        LauncherManager.shared.pluginsOverride = [qr]

        LauncherManager.shared.updateQuery("密码")
        await Task.yield()
        XCTAssertFalse(LauncherManager.shared.instantActions.contains { $0.pluginId == "qr" },
            "场景14.P1: 「密码」不得出现 qr 行")

        LauncherManager.shared.updateQuery("验证码")
        await Task.yield()
        XCTAssertFalse(LauncherManager.shared.instantActions.contains { $0.pluginId == "qr" },
            "场景14.P1: 「验证码」不得出现 qr 行")
    }

    /// 场景14.P2：输「码」（恰为单字 keyword）qr 进列表（完全档有效）
    func test_CNOREGRESS6_码_exactStillEnters() async {
        let qr = decodeManifest(name: "qr", keywords: ["qr", "qrcode", "二维码", "码"], mode: "command")
        LauncherManager.shared.pluginsOverride = [qr]

        LauncherManager.shared.updateQuery("码")
        await Task.yield()
        XCTAssertTrue(LauncherManager.shared.instantActions.contains { $0.pluginId == "qr" },
            "场景14.P2: query 恰为单字 keyword「码」→ 完全档进列表")
    }

    /// 场景10.P1：输「qz」（qzh 前缀）qzh 进统一列表
    func test_scenario10_P1_fuzzyPrefix_entersList() async {
        let qzh = decodeManifest(name: "qzh", keywords: ["qzh", "qzhddr", "监控"], mode: "command")
        LauncherManager.shared.pluginsOverride = [qzh]

        LauncherManager.shared.updateQuery("qz")
        await Task.yield()
        XCTAssertTrue(LauncherManager.shared.instantActions.contains { $0.pluginId == "qzh" },
            "场景10.P1: 「qz」前缀命中 → qzh 进列表（旧严格前缀下不出现的场景）")
    }

    /// D5 Tab 锁定：lockPluginCandidate 进入锁定态 + instant 隔离（场景4.P1 数据层）
    func test_D5_lockPluginCandidate_entersParamState() async {
        let qr = decodeManifest(name: "qr", keywords: ["qr", "二维码"], mode: "command")
        LauncherManager.shared.pluginsOverride = [qr]
        LauncherManager.shared.updateQuery("qr")
        await Task.yield()

        LauncherManager.shared.lockPluginCandidate(qr)

        XCTAssertEqual(LauncherManager.shared.lockedCommand?.name, "qr",
            "D5: Tab 锁定后 lockedCommand == qr（场景4.P1）")
        XCTAssertTrue(LauncherManager.shared.instantActions.isEmpty,
            "D5: 锁定后候选隔离（参数态）")
    }

    /// D3.6 锁定粘性：锁定后输参数不重算候选（C-PARAM-ISOLATE）
    func test_D36_lockSticky_paramInputKeepsLock() async {
        let qr = decodeManifest(name: "qr", keywords: ["qr", "二维码"], mode: "command")
        let translate = decodeManifest(name: "translate", keywords: ["tr", "翻译"], mode: "stdin")
        LauncherManager.shared.pluginsOverride = [qr, translate]
        LauncherManager.shared.updateQuery("qr")
        await Task.yield()
        LauncherManager.shared.lockPluginCandidate(qr)

        LauncherManager.shared.updateQuery("qr translate 你好")
        await Task.yield()

        XCTAssertEqual(LauncherManager.shared.lockedCommand?.name, "qr",
            "D3.6: 参数位输入保持锁定（粘性）")
        XCTAssertTrue(LauncherManager.shared.instantActions.isEmpty, "参数态候选隔离")
    }

    /// D3.6 锁定粘性：query 偏离 locked 前缀 → 解锁落正常匹配
    func test_D36_lockBroken_whenPrefixDeviates() async {
        let qr = decodeManifest(name: "qr", keywords: ["qr", "二维码"], mode: "command")
        LauncherManager.shared.pluginsOverride = [qr]
        LauncherManager.shared.updateQuery("qr")
        await Task.yield()
        LauncherManager.shared.lockPluginCandidate(qr)

        LauncherManager.shared.updateQuery("we")
        await Task.yield()

        XCTAssertNil(LauncherManager.shared.lockedCommand,
            "D3.6: query 不再以 locked 前缀开头 → 解锁")
    }

    /// C-ESC-EXIT：空输入清锁定（场景9.P1）
    func test_CESCEXIT_emptyQuery_clearsLock() async {
        let qr = decodeManifest(name: "qr", keywords: ["qr", "二维码"], mode: "command")
        LauncherManager.shared.pluginsOverride = [qr]
        LauncherManager.shared.lockPluginCandidate(qr)
        XCTAssertNotNil(LauncherManager.shared.lockedCommand)

        LauncherManager.shared.updateQuery("")
        await Task.yield()

        XCTAssertNil(LauncherManager.shared.lockedCommand, "C-ESC-EXIT: 清空输入退出锁定")
    }

    /// C-NO-REGRESS ⑬：pluginsOverride 空集 → 仅内置候选（空 registry 时为空列表），不崩
    func test_CNOREGRESS13_emptyPluginsDir_degradesGracefully() async {
        LauncherManager.shared.pluginsOverride = []
        let acts = await LauncherManager.shared.unifiedCandidates(for: "anything")
        XCTAssertTrue(acts.allSatisfy { !$0.id.hasPrefix("plugin:") },
            "空插件目录 → 无插件候选（不崩）")
    }

    // MARK: - C11：submitCommandDirect（保留回归）

    func test_C11_submitCommandDirect_nonCommandMode_yieldsError() async {
        let stdin = decodeManifest(name: "stdinx", keywords: ["sx"], mode: "stdin")
        let stream = LauncherManager.shared.submitCommandDirect(stdin, query: "sx")
        var sawError = false
        for await event in stream {
            if case .error = event { sawError = true }
        }
        XCTAssertTrue(sawError, "C11: 非 command mode → errorStream")
    }

    func test_C11_submitCommandDirect_commandMode_invokesSpy() async throws {
        let dirName = "qr-\(UUID().uuidString.prefix(8))"
        let pluginDir = try makeCommandPluginInRoot(name: "qr", dirName: String(dirName), keywords: ["qr"])
        defer { try? FileManager.default.removeItem(at: pluginDir) }
        let manifest = try loadManifest(from: pluginDir)
        try TrustStore.shared.approve(manifest, executablePath: pluginDir.appendingPathComponent("run.sh"))
        let spy = RecordingStdinExecutorSpy()
        LauncherManager.shared.stdinExecutorOverride = spy
        LauncherManager.shared.resetSubmittingStateForTesting()

        let stream = LauncherManager.shared.submitCommandDirect(manifest, query: "qr hello")
        for await _ in stream {}

        XCTAssertGreaterThanOrEqual(spy.executeCallCount, 1, "C11: spy 被调 ≥1")
        XCTAssertEqual(spy.lastInput?.query, "hello", "C11: 参数 stripKeywordPrefix 后")
    }

    // MARK: - D4 分流主体（submitInstantSelection）

    /// D4：插件行（stdin mode）→ .stream + manifest（submitWithPlugin 语义）
    func test_D4_stdinPluginRow_returnsStream() async {
        let stdin = decodeManifest(name: "stdinx", keywords: ["stdinkw"], mode: "stdin")
        LauncherManager.shared.pluginsOverride = [stdin]
        LauncherManager.shared.updateQuery("stdinkw")
        await Task.yield()
        // 选中插件行
        if let idx = LauncherManager.shared.instantActions.firstIndex(where: { $0.pluginId == "stdinx" }) {
            LauncherManager.shared.setInstantSelectedIndex(idx)
        }

        switch LauncherManager.shared.submitInstantSelection(query: "stdinkw hello") {
        case .stream(_, let manifest):
            XCTAssertEqual(manifest.name, "stdinx", "D4: stdin 插件行 → 分发该 manifest")
        case .performed:
            XCTFail("D4: 插件行不得走 performSelectedInstantAction")
        case .notInstant:
            XCTFail("D4: 选中插件行应返回 .stream")
        }
    }

    /// D4：app/内置行 → .performed（performSelectedInstantAction 执行）
    func test_D4_builtinRow_performed() async {
        LauncherManager.shared.registryOverride = makeStaticRegistry(score: 1000)
        LauncherManager.shared.pluginsOverride = []
        LauncherManager.shared.updateQuery("mockq")
        await Task.yield()
        // 候选非空时 instantSelectedIndex 已置 0
        LauncherManager.shared.setInstantSelectedIndex(0)

        let route = LauncherManager.shared.submitInstantSelection(query: "mockq")
        guard case .performed = route else {
            XCTFail("D4: 内置行应返回 .performed，实际: \(route)")
            return
        }
    }

    /// D4：无选中 → .notInstant（落 fallback AI 流）
    func test_D4_noSelection_notInstant() async {
        LauncherManager.shared.registryOverride = makeEmptyRegistry()
        LauncherManager.shared.updateQuery("")
        await Task.yield()
        // 空列表 + 选中哨兵 -1（clearInstantActions 语义）
        let route = LauncherManager.shared.submitInstantSelection(query: "anything")
        guard case .notInstant = route else {
            XCTFail("D4: 无选中应返回 .notInstant")
            return
        }
    }

    // MARK: - 辅助

    private func makeEmptyRegistry() -> BuiltinPluginRegistry {
        BuiltinPluginRegistry(plugins: [EmptyActionsPluginForUnifiedTest()])
    }

    /// 静态分数 mock 插件（固定返回一个 score=指定值 的 app 候选，pluginId="mock-app"）
    private func makeStaticRegistry(score: Int) -> BuiltinPluginRegistry {
        BuiltinPluginRegistry(plugins: [StaticActionPlugin(score: score)])
    }

    private func decodeManifest(name: String, keywords: [String], mode: String) -> PluginManifest {
        var json: [String: Any] = [
            "name": name,
            "version": "0.0.1-test",
            "description": "test \(mode) plugin",
            "keywords": keywords,
            "cmd": "echo",
            "args": [] as [String]
        ]
        if mode == "prompt" {
            json["mode"] = "prompt"
            json["systemPrompt"] = "x"
            json["maxIterations"] = 1
            json["autoCopyToClipboard"] = false
        } else {
            json["mode"] = mode
        }
        return try! JSONDecoder().decode(PluginManifest.self, from: try JSONSerialization.data(withJSONObject: json))
    }

    private func makeCommandPluginInRoot(name: String, dirName: String, keywords: [String]) throws -> URL {
        let rootDir = PluginManager.shared.rootDir
        try? FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        let pluginDir = rootDir.appendingPathComponent("\(dirName)-\(name)")
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        let scriptURL = pluginDir.appendingPathComponent("run.sh")
        let script = "#!/bin/bash\necho \"spy ok\"\nexit 0\n"
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        let keywordsJSON = "[\"" + keywords.joined(separator: "\",\"") + "\"]"
        let manifestJSON = """
        {
          "name": "\(name)",
          "version": "0.1.0",
          "description": "spy test command",
          "keywords": \(keywordsJSON),
          "mode": "command",
          "cmd": "./run.sh",
          "args": []
        }
        """
        try manifestJSON.write(to: pluginDir.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
        return pluginDir
    }

    private func loadManifest(from pluginDir: URL) throws -> PluginManifest {
        let data = try Data(contentsOf: pluginDir.appendingPathComponent("plugin.json"))
        return try JSONDecoder().decode(PluginManifest.self, from: data)
    }
}

// MARK: - Mock 插件

private struct EmptyActionsPluginForUnifiedTest: BuiltinPlugin {
    let id = "empty-unified-test"
    let priority = 0
    let sectionTitle = "Empty"
    func actions(for query: String) async -> [LauncherAction] { [] }
}

/// 固定返回单条候选的 mock 内置插件（来源序用 priority 模拟 app=0）
private struct StaticActionPlugin: BuiltinPlugin {
    let score: Int
    var id: String { "mock-app" }
    var priority: Int { 0 }
    var sectionTitle: String { "Mock" }
    func actions(for query: String) async -> [LauncherAction] {
        [
            LauncherAction(
                id: "mock://app",
                title: "Mock App",
                subtitle: nil,
                icon: nil,
                iconEmoji: nil,
                pluginId: "mock-app",
                score: score,
                perform: {}
            )
        ]
    }
}
