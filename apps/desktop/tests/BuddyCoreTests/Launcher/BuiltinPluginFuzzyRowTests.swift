import XCTest
@testable import BuddyCore

// MARK: - BuiltinPluginFuzzyRowTests
//
// 蓝队单测：内置插件模糊接入统一混排（D1-D5，2026-08-30）
//
// 契约引用（state.md ## 契约规约）：
//   C-SCORER-DELEGATION  ：score(query:manifest:) ≡ score(query:name:keywords:)（逐字委托）
//   C-BUILTIN-FUZZY-ROW  ：部分词命中 → 恰一行 id=="builtin:<id>"，score ∈ 8 值闭集，
//                          sourceRank==plugin.priority；单字 query 可经前缀档出行
//   C-BUILTIN-NO-DUP     ：有具体候选 → 无 builtin: 行（条目直显，零重复）
//   C-BUILTIN-EXPAND     ：submitInstantSelection 选中 builtin: 行 → .expandBuiltin(trigger)
//   C-BUILTIN-TAB-NOLOCK ：builtin: 行 handleTabLock()==false；社区插件行仍 true
//   C-BUILTIN-DISABLED   ：关闭态下无插件行无条目；恢复后部分词命中恢复

@MainActor
final class BuiltinPluginFuzzyRowTests: XCTestCase {

    private var defaultsSuiteName: String?

    override func setUp() async throws {
        try await super.setUp()
        LauncherManager.shared.resetSubmittingStateForTesting()
        LauncherManager.shared.instantDebounceMsOverride = 0
        LauncherManager.shared.pluginsOverride = []
        LauncherManager.shared.stdinExecutorOverride = nil
        LauncherManager.shared.registryOverride = makeEmptyRegistry()
        LauncherManager.shared.clearInstantActions()
        LauncherManager.shared.clearLockedCommand()
    }

    override func tearDown() async throws {
        LauncherManager.shared.registryOverride = nil
        LauncherManager.shared.pluginsOverride = nil
        LauncherManager.shared.instantDebounceMsOverride = nil
        LauncherManager.shared.clearInstantActions()
        LauncherManager.shared.clearLockedCommand()
        if let suite = defaultsSuiteName {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            defaultsSuiteName = nil
        }
        try await super.tearDown()
    }

    // MARK: - C-SCORER-DELEGATION：委托等价

    /// score(query:manifest:) ≡ score(query:name:keywords:)（任意输入等价）
    func test_scorerDelegation_manifestVersionEquatesToNameKeywords() {
        let cases: [(query: String, name: String, keywords: [String])] = [
            ("qr", "qr", ["qr", "二维码", "码"]),
            ("qz", "qzh", ["监控"]),
            ("snip", "xyz", ["snippet"]),
            ("码", "qr", ["码"]),
            ("密码", "qr", ["qr", "码"]),
            ("", "qr", ["qr"]),
            ("zzqq", "paste", ["cb", "clipboard", "剪贴板", "paste"]),
            ("pas", "paste", ["cb", "clipboard", "剪贴板", "paste"]),
            ("剪", "paste", ["cb", "clipboard", "剪贴板", "paste"]),
            ("monitor", "some", ["open monitor"]),
            ("QR hello", "xyz", ["qr"]),
            ("qrhello", "xyz", ["qr"]),
            ("snip 今天的周报", "xyz", ["snip"]),
        ]
        for c in cases {
            let m = manifest(name: c.name, keywords: c.keywords)
            XCTAssertEqual(
                UnifiedPluginScorer.score(query: c.query, manifest: m),
                UnifiedPluginScorer.score(query: c.query, name: c.name, keywords: c.keywords),
                "C-SCORER-DELEGATION: query='\(c.query)' name='\(c.name)' 两入口必须等价"
            )
        }
    }

    /// 单字防线只作用 keyword 侧：query 侧无长度限制（保持现状，不加 query 守卫）
    func test_scorerDelegation_singleCharQuery_stillScores() {
        // query「剪」单字，keyword「剪贴板」前缀档命中 → 800（query 侧不设长度防线）
        XCTAssertEqual(UnifiedPluginScorer.score(query: "剪", name: "paste", keywords: PastePlugin.triggers), 800)
    }

    // MARK: - D1：pluginKeywords 协议默认值

    /// 未配置者（extension 默认 []）不参与模糊行
    func test_pluginKeywords_defaultEmptyForUnconfiguredMocks() {
        XCTAssertTrue(EmptyActionsPluginForFuzzyTest().pluginKeywords.isEmpty,
            "未覆盖 pluginKeywords 的 mock → 默认空（不产行）")
    }

    /// PastePlugin 返回触发词闭集
    func test_pastePlugin_pluginKeywords_equalsTriggers() {
        XCTAssertEqual(PastePlugin.shared.pluginKeywords, PastePlugin.triggers,
            "D1: PastePlugin.pluginKeywords == Self.triggers")
    }

    // MARK: - C-BUILTIN-FUZZY-ROW：部分词 → 内置插件聚合行

    /// 输入 `pas`：恰一行 builtin:paste，字段契约齐全（name 前缀档 830）
    func test_partialQuery_pas_producesSingleBuiltinRow() async {
        LauncherManager.shared.registryOverride = makePasteRegistry()

        let acts = await LauncherManager.shared.unifiedCandidates(for: "pas")
        let rows = acts.filter { $0.id == "builtin:paste" }
        XCTAssertEqual(rows.count, 1, "pas → 恰一行 builtin:paste")

        let row = try! XCTUnwrap(rows.first)
        XCTAssertEqual(row.title, "paste", "title == plugin.id")
        XCTAssertEqual(row.subtitle, PastePlugin.shared.summary, "subtitle == plugin.summary")
        XCTAssertEqual(row.pluginId, "paste")
        XCTAssertNil(row.icon, "icon: nil（渲染 fallback SF Symbol，与社区行同款）")
        XCTAssertNil(row.iconEmoji, "iconEmoji: nil")
        XCTAssertEqual(row.score, 830, "pas 是 name「paste」前缀 → 800 + name +30 = 830（8 值闭集）")
    }

    /// 输入 `剪`（单字 query）：keyword「剪贴板」前缀档 800 出行（query 侧无长度防线）
    func test_partialQuery_cutChar_producesRowScore800() async {
        LauncherManager.shared.registryOverride = makePasteRegistry()

        let acts = await LauncherManager.shared.unifiedCandidates(for: "剪")
        let row = acts.first { $0.id == "builtin:paste" }
        XCTAssertNotNil(row, "「剪」→ keyword 前缀档出行（场景1.P2）")
        XCTAssertEqual(row?.score, 800, "「剪」是 keyword「剪贴板」前缀 → 800（name「paste」不命中）")
    }

    /// 输入 `cl`：keyword「clipboard」前缀档出行
    func test_partialQuery_cl_producesRow() async {
        LauncherManager.shared.registryOverride = makePasteRegistry()

        let acts = await LauncherManager.shared.unifiedCandidates(for: "cl")
        let row = acts.first { $0.id == "builtin:paste" }
        XCTAssertNotNil(row, "cl 是「clipboard」前缀 → 出行（场景1.P4）")
        XCTAssertEqual(row?.score, 800)
    }

    /// 输入无关词 `zzqq`：无 builtin: 行（相关性下界，场景2.P1）
    func test_irrelevantQuery_noBuiltinRow() async {
        LauncherManager.shared.registryOverride = makePasteRegistry()

        let acts = await LauncherManager.shared.unifiedCandidates(for: "zzqq")
        XCTAssertFalse(acts.contains { $0.id.hasPrefix("builtin:") },
            "zzqq 与全部触发词无子串关系 → 无插件行")
    }

    /// C-BUILTIN-FUZZY-ROW sourceRank：同分时 builtin 行（priority 150）排在 app mock（0）前
    func test_sourceRank_sameScore_builtinRowBeatsApp() async {
        LauncherManager.shared.registryOverride = BuiltinPluginRegistry(plugins: [
            StaticAppPluginForFuzzyTest(score: 830),
            PastePlugin.shared,
        ])

        let acts = await LauncherManager.shared.unifiedCandidates(for: "pas")
        let builtinIdx = acts.firstIndex { $0.id == "builtin:paste" }
        let appIdx = acts.firstIndex { $0.pluginId == "mock-app" }
        XCTAssertNotNil(builtinIdx)
        XCTAssertNotNil(appIdx)
        if let b = builtinIdx, let a = appIdx {
            XCTAssertLessThan(b, a, "同分 830：sourceRank=paste priority 150 > app 0")
        }
    }

    // MARK: - C-BUILTIN-NO-DUP：有具体候选 → 无插件行

    /// 完整触发词下条目直显，不额外出现插件行（场景3.P1/P2 数据层）
    func test_fullTrigger_withEntries_noBuiltinRow() async {
        LauncherManager.shared.registryOverride = BuiltinPluginRegistry(plugins: [KeywordActionsPluginForFuzzyTest()])

        let acts = await LauncherManager.shared.unifiedCandidates(for: "fooword")
        XCTAssertTrue(acts.contains { $0.pluginId == "fuzzymock" && $0.id == "fuzzymock-entry-1" },
            "完整触发词 → 具体候选直显")
        XCTAssertFalse(acts.contains { $0.id.hasPrefix("builtin:") },
            "C-BUILTIN-NO-DUP: 有具体候选 → 不产 builtin: 行")
    }

    // MARK: - C-BUILTIN-DISABLED：关闭态全排除

    /// 关闭态：部分词无行、完整触发词无条目；恢复后部分词命中恢复（场景6.P1-P3 数据层）
    func test_disabledPlugin_noRowNoEntry_recoversAfterEnable() async {
        let suite = "BuiltinPluginFuzzyRowTests-\(UUID().uuidString)"
        defaultsSuiteName = suite
        let defaults = UserDefaults(suiteName: suite)!
        let store = BuiltinPluginEnabledStore(defaults: defaults)
        let registry = BuiltinPluginRegistry(plugins: [KeywordActionsPluginForFuzzyTest()], enabledStore: store)

        store.setEnabled(id: "fuzzymock", enabled: false)
        LauncherManager.shared.registryOverride = registry

        let disabledPartial = await LauncherManager.shared.unifiedCandidates(for: "foo")
        XCTAssertFalse(disabledPartial.contains { $0.pluginId == "fuzzymock" },
            "关闭态：部分词无插件行（6.P1）")
        let disabledFull = await LauncherManager.shared.unifiedCandidates(for: "fooword")
        XCTAssertFalse(disabledFull.contains { $0.pluginId == "fuzzymock" },
            "关闭态：完整触发词无条目（6.P2）")

        store.setEnabled(id: "fuzzymock", enabled: true)
        let recovered = await LauncherManager.shared.unifiedCandidates(for: "foo")
        XCTAssertTrue(recovered.contains { $0.id == "builtin:fuzzymock" },
            "重新启用：部分词命中恢复（6.P3）")
    }

    // MARK: - C-BUILTIN-EXPAND：分流 + 触发词选择

    /// submitInstantSelection 选中 builtin: 行 → .expandBuiltin(trigger)（pas → paste）
    func test_submitInstantSelection_builtinRow_returnsExpandBuiltin() async {
        LauncherManager.shared.registryOverride = makePasteRegistry()
        LauncherManager.shared.updateQuery("pas")
        await waitForDebounce()

        guard let idx = LauncherManager.shared.instantActions.firstIndex(where: { $0.id == "builtin:paste" }) else {
            XCTFail("pas 应出现 builtin:paste 行")
            return
        }
        LauncherManager.shared.setInstantSelectedIndex(idx)

        let route = LauncherManager.shared.submitInstantSelection(query: "pas")
        guard case .expandBuiltin(let trigger) = route else {
            XCTFail("应返回 .expandBuiltin，实际: \(route)")
            return
        }
        XCTAssertEqual(trigger, "paste", "pas 前缀档语义 → 填 paste（场景4.P1）")
    }

    /// builtin: 行分流优先于社区插件解析（防重名 paste 的社区插件被误分流）
    func test_submitInstantSelection_builtinRow_winsOverCommunityPlugin() async {
        LauncherManager.shared.registryOverride = makePasteRegistry()
        LauncherManager.shared.pluginsOverride = [manifest(name: "paste", keywords: ["paste"], mode: "command")]
        LauncherManager.shared.updateQuery("pas")
        await waitForDebounce()

        guard let idx = LauncherManager.shared.instantActions.firstIndex(where: { $0.id == "builtin:paste" }) else {
            XCTFail("pas 应出现 builtin:paste 行")
            return
        }
        LauncherManager.shared.setInstantSelectedIndex(idx)

        let route = LauncherManager.shared.submitInstantSelection(query: "pas")
        guard case .expandBuiltin = route else {
            XCTFail("builtin: 行优先于社区插件解析（防重名误分流），实际: \(route)")
            return
        }
    }

    /// 展开语义数据层：模拟 View 消费（query = trigger）→ 具体候选直显、无 builtin: 行
    func test_expandSemantics_afterFillingTrigger_concreteEntriesNoRow() async {
        LauncherManager.shared.registryOverride = BuiltinPluginRegistry(plugins: [KeywordActionsPluginForFuzzyTest()])

        let before = await LauncherManager.shared.unifiedCandidates(for: "foo")
        XCTAssertTrue(before.contains { $0.id == "builtin:fuzzymock" }, "前置：部分词 foo 出插件行")

        // View 消费 .expandBuiltin("fooword")：query = trigger（勿清空，清空会清列表）
        LauncherManager.shared.updateQuery("fooword")
        await waitForDebounce()

        let expanded = LauncherManager.shared.instantActions
        XCTAssertTrue(expanded.contains { $0.pluginId == "fuzzymock" && $0.id == "fuzzymock-entry-1" },
            "展开后为该插件具体候选")
        XCTAssertFalse(expanded.contains { $0.id.hasPrefix("builtin:") },
            "展开后不含 builtin: 行")
    }

    // MARK: - bestTriggerWord（纯函数）

    func test_bestTriggerWord_pas_picksPaste() {
        XCTAssertEqual(
            LauncherManager.bestTriggerWord(keywords: PastePlugin.triggers, query: "pas"),
            "paste", "pas 贴合用户输入意图 → paste"
        )
    }

    func test_bestTriggerWord_cutChar_picksClipboardChinese() {
        XCTAssertEqual(
            LauncherManager.bestTriggerWord(keywords: PastePlugin.triggers, query: "剪"),
            "剪贴板", "「剪」→ 剪贴板"
        )
    }

    /// 同分（同档）取最短
    func test_bestTriggerWord_sameScore_picksShortest() {
        XCTAssertEqual(
            LauncherManager.bestTriggerWord(keywords: ["apples", "app"], query: "ap"),
            "app", "同为前缀档 800 → 取最短"
        )
    }

    /// 完全档 > 前缀档
    func test_bestTriggerWord_exactBeatsPrefix() {
        XCTAssertEqual(
            LauncherManager.bestTriggerWord(keywords: ["paste", "pa"], query: "pa"),
            "pa", "「pa」对自身完全档 1000 > 对 paste 前缀档 800"
        )
    }

    /// 全不命中 → nil
    func test_bestTriggerWord_noHit_returnsNil() {
        XCTAssertNil(LauncherManager.bestTriggerWord(keywords: ["foo"], query: "zzqq"))
    }

    // MARK: - C-BUILTIN-TAB-NOLOCK：Tab 守卫

    /// builtin: 行 Tab 不锁定（内置无参数语义）
    func test_handleTabLock_builtinRow_returnsFalse() async {
        LauncherManager.shared.registryOverride = makePasteRegistry()
        LauncherManager.shared.updateQuery("pas")
        await waitForDebounce()

        guard let idx = LauncherManager.shared.instantActions.firstIndex(where: { $0.id == "builtin:paste" }) else {
            XCTFail("pas 应出现 builtin:paste 行")
            return
        }
        LauncherManager.shared.setInstantSelectedIndex(idx)

        XCTAssertFalse(LauncherManager.shared.handleTabLock(), "内置插件行 Tab 忽略")
        XCTAssertNil(LauncherManager.shared.lockedCommand, "状态不变（不进入参数锁定态）")
    }

    /// 社区插件行 Tab 仍锁定（既有行为零变化）
    func test_handleTabLock_communityRow_stillLocks() async {
        LauncherManager.shared.registryOverride = makeEmptyRegistry()
        LauncherManager.shared.pluginsOverride = [manifest(name: "qr", keywords: ["qr"], mode: "command")]
        LauncherManager.shared.updateQuery("qr")
        await waitForDebounce()

        guard let idx = LauncherManager.shared.instantActions.firstIndex(where: { $0.id == "plugin:qr" }) else {
            XCTFail("qr 应出现社区插件行")
            return
        }
        LauncherManager.shared.setInstantSelectedIndex(idx)

        XCTAssertTrue(LauncherManager.shared.handleTabLock(), "社区插件行 Tab 仍锁定（既有行为）")
        XCTAssertEqual(LauncherManager.shared.lockedCommand?.name, "qr")
    }

    // MARK: - QA auto-fix 回归锁定（qa-reviewer Important 1）

    /// 空历史 + query==完整触发词 → builtin: 行仍在（scoredActions 空不去重）→ 分流仍返回
    /// `.expandBuiltin("paste")`。View 侧修复（赋同值时 onChange 不触发 → 直调 updateQuery 幂等驱动）
    /// 由 enum 穷尽性编译守卫锁定；本测试锁 manager 侧前半段 + 直调幂等行为。
    func test_expand_emptyHistory_queryEqualsTrigger_stillRoutesExpandBuiltin() async {
        LauncherManager.shared.registryOverride = BuiltinPluginRegistry(
            plugins: [EmptyHistoryPasteLikePluginForFuzzyTest()]
        )
        LauncherManager.shared.updateQuery("paste")
        await waitForDebounce()

        guard let idx = LauncherManager.shared.instantActions.firstIndex(where: { $0.id == "builtin:paste" }) else {
            XCTFail("空历史下完整触发词 paste 应出现 builtin:paste 行（无具体候选 → 不去重）")
            return
        }
        LauncherManager.shared.setInstantSelectedIndex(idx)

        let route = LauncherManager.shared.submitInstantSelection(query: "paste")
        guard case .expandBuiltin(let trigger) = route else {
            XCTFail("期望 .expandBuiltin，实际 \(route)")
            return
        }
        XCTAssertEqual(trigger, "paste")

        // View 修复的 manager 侧等价行为：updateQuery(trigger) 直调幂等（空历史无具体候选，行保持）
        LauncherManager.shared.updateQuery(trigger)
        await waitForDebounce()
        XCTAssertTrue(
            LauncherManager.shared.instantActions.contains { $0.id == "builtin:paste" },
            "空历史展开后 builtin: 行保持（无内容可展开但管线被驱动，非 onChange 不触发的死角）"
        )
    }

    // MARK: - 辅助

    /// 等待 debounce 落地（override=0；多次 yield 保证 MainActor Task 调度完成）
    private func waitForDebounce() async {
        for _ in 0..<10 { await Task.yield() }
    }

    private func makeEmptyRegistry() -> BuiltinPluginRegistry {
        BuiltinPluginRegistry(plugins: [EmptyActionsPluginForFuzzyTest()])
    }

    private func makePasteRegistry() -> BuiltinPluginRegistry {
        BuiltinPluginRegistry(plugins: [PastePlugin.shared])
    }

    private func manifest(name: String, keywords: [String], mode: String = "command") -> PluginManifest {
        var json: [String: Any] = [
            "name": name,
            "version": "0.0.1-test",
            "description": "test \(mode) plugin",
            "keywords": keywords,
            "cmd": "echo",
            "args": [] as [String],
            "mode": mode,
        ]
        if mode == "prompt" {
            json["systemPrompt"] = "x"
            json["maxIterations"] = 1
            json["autoCopyToClipboard"] = false
        }
        return try! JSONDecoder().decode(PluginManifest.self, from: try JSONSerialization.data(withJSONObject: json))
    }
}

// MARK: - Mock 插件

/// 空候选 mock（pluginKeywords 未配置 → 默认 []）
private struct EmptyActionsPluginForFuzzyTest: BuiltinPlugin {
    let id = "empty-fuzzy-test"
    let priority = 0
    let sectionTitle = "Empty"
    func actions(for query: String) async -> [LauncherAction] { [] }
}

/// keywords 齐全但永远无候选的 mock（模拟空剪贴板历史的 paste：QA Important 1 场景）
private struct EmptyHistoryPasteLikePluginForFuzzyTest: BuiltinPlugin {
    let id = "paste"
    let priority = 150
    let sectionTitle = "剪贴板"
    var pluginKeywords: [String] { ["cb", "clipboard", "剪贴板", "paste"] }
    func actions(for query: String) async -> [LauncherAction] { [] }
}

/// 固定返回单条候选的 app mock（priority=0 模拟 AppLauncher）
private struct StaticAppPluginForFuzzyTest: BuiltinPlugin {
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

/// 带触发词 + 条件出候选的 mock（id=fuzzymock，keyword=fooword，完整触发词时直显条目）
private struct KeywordActionsPluginForFuzzyTest: BuiltinPlugin {
    let id = "fuzzymock"
    let priority = 150
    let sectionTitle = "Mock"
    var pluginKeywords: [String] { ["fooword"] }
    func actions(for query: String) async -> [LauncherAction] {
        guard query.lowercased().hasPrefix("fooword") else { return [] }
        return [
            LauncherAction(
                id: "fuzzymock-entry-1",
                title: "Mock Entry",
                subtitle: nil,
                icon: nil,
                iconEmoji: nil,
                pluginId: id,
                score: 900,
                perform: {}
            )
        ]
    }
}
