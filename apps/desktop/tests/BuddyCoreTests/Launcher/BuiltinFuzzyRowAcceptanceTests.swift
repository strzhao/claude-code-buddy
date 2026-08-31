import XCTest
@testable import BuddyCore

// MARK: - BuiltinFuzzyRowAcceptanceTests
//
// 红队验收测试（仅基于设计文档编写，黑盒视角）：
// 内置插件（paste）获得与社区插件同等的「一等公民」模糊搜索待遇 —— 数据层契约。
//
// 设计文档引用（state.md ## 设计文档 D1-D8 / ## 契约规约 / ## 验收场景）：
//   C-BUILTIN-FUZZY-ROW：query 对 pluginKeywords 命中 >0 且无具体候选 → 恰一行
//     id=="builtin:<pluginId>" ∧ title==plugin.id ∧ subtitle==plugin.summary
//     ∧ score ∈ 闭集 {150,180,500,530,800,830,1000,1030} ∧ sourceRank==plugin.priority
//   C-BUILTIN-NO-DUP：scoredActions(for:) 对该插件非空 → 不含 builtin: 行（场景3）
//   C-BUILTIN-DISABLED：enabledStore.isEnabled==false → 任意 query 无该插件任何行（场景6）
//   错误边界：pluginKeywords 空 → 不产行（等价未配置）
//
// 驱动方式：in-process 直调 LauncherManager.shared.unifiedCandidates(for:externalRegistry:)，
//   mock registry / pluginsOverride 注入（LauncherManagerUnifiedCandidatesTests 同构 seam）。
//   mock 内置插件返回固定候选，不依赖真实剪贴板（红队工作规则 5）。

@MainActor
final class BuiltinFuzzyRowAcceptanceTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        LauncherManager.shared.resetSubmittingStateForTesting()
        LauncherManager.shared.instantDebounceMsOverride = 0
        LauncherManager.shared.registryOverride = makeRegistry([FuzzyPasteMockPlugin()])
        LauncherManager.shared.pluginsOverride = []
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

    // MARK: - 场景1.P1 [det-machine]：pas → 恰一条 paste 插件行

    /// 场景1.P1：部分词 `pas` → 统一混排列表恰含一条 paste 插件行（C-BUILTIN-FUZZY-ROW 全字段）。
    /// Mutation kill：无 D4 行生成 → 行缺失 → 红；行字段（title/subtitle/score）任一错 → 红。
    func test_scenario1_P1_partialWordPas_singleBuiltinRow() async throws {
        let acts = await LauncherManager.shared.unifiedCandidates(for: "pas")

        let rows = acts.filter { $0.id == "builtin:paste" }
        XCTAssertEqual(rows.count, 1,
            "场景1.P1: 「pas」必须恰含一条 id==builtin:paste 的插件行，实际=\(acts.map(\.id))")

        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.title, "paste",
            "C-BUILTIN-FUZZY-ROW: 插件行 title == plugin.id")
        let summary = FuzzyPasteMockPlugin.summaryLiteral
        XCTAssertEqual(row.subtitle, summary,
            "场景1.P1/C-BUILTIN-FUZZY-ROW: subtitle 非空且 == plugin.summary，实际=\(row.subtitle ?? "nil")")
        XCTAssertFalse(row.subtitle?.isEmpty ?? true,
            "场景1.P1: 插件行 subtitle 必须非空（一句话描述）")

        let closedSet: Set<Int> = [150, 180, 500, 530, 800, 830, 1000, 1030]
        XCTAssertTrue(closedSet.contains(row.score),
            "C-BUILTIN-FUZZY-ROW: score 必须 ∈ 闭集 {150,180,500,530,800,830,1000,1030}，实际=\(row.score)")
    }

    // MARK: - 场景1.P2 [det-machine]：中文部分词「剪」→ 同样出插件行

    /// 场景1.P2：单字 query「剪」可经前缀档命中「剪贴板」keyword（单字防线只作用 keyword 侧）。
    func test_scenario1_P2_cjkPartialWordJian_rowAppears() async throws {
        let acts = await LauncherManager.shared.unifiedCandidates(for: "剪")

        let rows = acts.filter { $0.id == "builtin:paste" }
        XCTAssertEqual(rows.count, 1,
            "场景1.P2: 「剪」必须出一条 paste 插件行（keyword「剪贴板」前缀档），实际=\(acts.map(\.id))")
        let row = try XCTUnwrap(rows.first)
        XCTAssertFalse(row.subtitle?.isEmpty ?? true, "场景1.P2: subtitle 非空")
        XCTAssertTrue([150, 180, 500, 530, 800, 830, 1000, 1030].contains(row.score),
            "C-BUILTIN-FUZZY-ROW: 「剪」行 score ∈ 闭集，实际=\(row.score)")
    }

    // MARK: - 场景1.P4 [det-machine]：英文前缀 cl → clipboard 前缀档命中

    /// 场景1.P4：「cl」是触发词「clipboard」的前缀 → 出插件行。
    func test_scenario1_P4_prefixCl_rowAppears() async throws {
        let acts = await LauncherManager.shared.unifiedCandidates(for: "cl")

        let rows = acts.filter { $0.id == "builtin:paste" }
        XCTAssertEqual(rows.count, 1,
            "场景1.P4: 「cl」必须出一条 paste 插件行（clipboard 前缀档），实际=\(acts.map(\.id))")
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.subtitle, FuzzyPasteMockPlugin.summaryLiteral, "场景1.P4: subtitle == summary")
        XCTAssertTrue([150, 180, 500, 530, 800, 830, 1000, 1030].contains(row.score),
            "C-BUILTIN-FUZZY-ROW: 「cl」行 score ∈ 闭集，实际=\(row.score)")
    }

    // MARK: - 场景1.P3 [det-machine]（数据层）：混排同列表、score 非升序、截断 ≤8

    /// 场景1.P3 数据层等价：插件行与 app 结果共存同一数组、score 非升序、总数 ≤ 8。
    /// （count==len(candidates) 与 source 字段属 CLI 信封形态，由
    /// BuiltinFuzzyRowCliEnvelopeAcceptanceTests 覆盖。）
    func test_scenario1_P3_dataLayer_mixedListDescendingTruncated() async {
        // registry：paste 形 mock（出 builtin: 行）+ app 形 mock（出 app 条目）→ 混排
        LauncherManager.shared.registryOverride =
            makeRegistry([FuzzyPasteMockPlugin(), AppLauncherMockPlugin()])

        let acts = await LauncherManager.shared.unifiedCandidates(for: "pas")

        XCTAssertTrue(acts.contains { $0.id.hasPrefix("builtin:") },
            "场景1.P3: 插件行必须与其它来源共存于同一列表，实际=\(acts.map(\.id))")
        XCTAssertTrue(acts.contains { $0.pluginId == "app-launcher" },
            "场景1.P3: 必须含至少一条非插件行来源（app 条目），实际=\(acts.map(\.id))")

        XCTAssertLessThanOrEqual(acts.count, 8,
            "场景1.P3: 统一列表截断上限 builtinActionsLimit=8")

        for i in 0..<(acts.count - 1) {
            XCTAssertGreaterThanOrEqual(acts[i].score, acts[i + 1].score,
                "场景1.P3: 列表必须按 score 非升序混排，index \(i)(\(acts[i].score)) < \(i+1)(\(acts[i+1].score))")
        }
    }

    // MARK: - C-BUILTIN-FUZZY-ROW sourceRank：同分按 plugin.priority 排序

    /// sourceRank==plugin.priority（黑盒经排序键观察）：构造同分 830 的三行
    /// （builtin:paste sourceRank=150 / 内置条目 sourceRank=100 / app 条目 sourceRank=0）
    /// + 社区插件行 800（sourceRank=50）→ 严格顺序 paste 行 > 内置条目 > app 条目 > 社区行。
    /// Mutation kill：sourceRank 硬编码 0 → paste 行掉到 app 条目之后 → 红。
    func test_cbuiltinfuzzyrow_sourceRank_priorityOrdering() async throws {
        LauncherManager.shared.registryOverride = makeRegistry([
            FuzzyPasteMockPlugin(),      // builtin:paste 830，priority 150
            BuiltinEntryMockPlugin(),    // sysmock 条目 830，priority 100（无 keywords，不产行）
            AppLauncherMockPlugin(),     // app-launcher 条目 830，priority 0
        ])
        LauncherManager.shared.pluginsOverride = [
            decodeManifest(name: "pagelug", keywords: ["pastrami"], mode: "command"), // 800，来源序 50
        ]

        let acts = await LauncherManager.shared.unifiedCandidates(for: "pas")

        let pasteIdx = try XCTUnwrap(acts.firstIndex { $0.id == "builtin:paste" },
            "必须有 builtin:paste 行，实际=\(acts.map(\.id))")
        let entryIdx = try XCTUnwrap(acts.firstIndex { $0.pluginId == "sysmock" },
            "必须有 sysmock 条目，实际=\(acts.map(\.id))")
        let appIdx = try XCTUnwrap(acts.firstIndex { $0.pluginId == "app-launcher" },
            "必须有 app 条目，实际=\(acts.map(\.id))")
        let communityIdx = try XCTUnwrap(acts.firstIndex { $0.pluginId == "pagelug" },
            "必须有社区插件行，实际=\(acts.map(\.id))")

        XCTAssertLessThan(pasteIdx, entryIdx,
            "同分 830：paste 行（sourceRank=priority 150）必须在内置条目（100）前")
        XCTAssertLessThan(entryIdx, appIdx,
            "同分 830：内置条目（100）必须在 app 条目（0）前")
        XCTAssertLessThan(appIdx, communityIdx,
            "830 组（app 0）必须在 800 组（社区 50）前")
    }

    // MARK: - 场景2.P1 [det-machine]：无关词 zzqq → 无任何 paste 行

    /// 场景2.P1：与 name/触发词均无关的「zzqq」→ 不存在 paste 插件行（相关性下界，不兜底展示）。
    func test_scenario2_P1_unrelatedWord_noPasteRow() async {
        let acts = await LauncherManager.shared.unifiedCandidates(for: "zzqq")

        XCTAssertFalse(acts.contains { $0.id == "builtin:paste" },
            "场景2.P1: 无关词不得出 paste 插件行，实际=\(acts.map(\.id))")
        XCTAssertTrue(acts.filter { $0.pluginId == "paste" }.isEmpty,
            "场景2.P1: 无关词下无 paste 的任何内容（行与条目均无）")
    }

    // MARK: - 场景3.P1 / 3.P2 [det-machine]（数据层）+ C-BUILTIN-NO-DUP：完整触发词条目直显

    /// 场景3.P1：完整触发词 `paste`（历史非空，由 mock 固定候选保证）→ 直接显示剪贴板历史条目，
    /// 不额外出 builtin: 插件行（C-BUILTIN-NO-DUP）。
    /// Mutation kill：D4 忘记「无具体候选才产行」的去重 → paste 查询出 builtin:paste 行 → 红。
    func test_scenario3_P1_fullTriggerPaste_entriesNoPluginRow() async {
        let acts = await LauncherManager.shared.unifiedCandidates(for: "paste")

        let entries = acts.filter { $0.pluginId == "paste" && !$0.id.hasPrefix("builtin:") }
        XCTAssertGreaterThanOrEqual(entries.count, 1,
            "场景3.P1: 完整触发词 paste 必须直接出剪贴板历史条目，实际=\(acts.map(\.id))")
        XCTAssertTrue(entries.contains { $0.title == "buddy-acceptance-seed" },
            "场景3.P1: 条目含种子内容（mock 固定候选），实际=\(entries.map(\.title))")
        XCTAssertFalse(acts.contains { $0.id.hasPrefix("builtin:") },
            "场景3.P1/C-BUILTIN-NO-DUP: 有具体候选时不得出 builtin: 插件行（零重复），实际=\(acts.map(\.id))")
    }

    /// 场景3.P2：完整触发词 `cb` → 同样条目直显且无插件行。
    func test_scenario3_P2_fullTriggerCb_entriesNoPluginRow() async {
        let acts = await LauncherManager.shared.unifiedCandidates(for: "cb")

        let entries = acts.filter { $0.pluginId == "paste" && !$0.id.hasPrefix("builtin:") }
        XCTAssertGreaterThanOrEqual(entries.count, 1,
            "场景3.P2: 完整触发词 cb 必须条目直显，实际=\(acts.map(\.id))")
        XCTAssertEqual(acts.filter { $0.id.hasPrefix("builtin:") }.count, 0,
            "场景3.P2/C-BUILTIN-NO-DUP: cb 查询不得出 builtin: 行，实际=\(acts.map(\.id))")
        XCTAssertEqual(acts.filter { $0.id.hasPrefix("plugin:") }.count, 0,
            "场景3.P2: 无社区插件时不出 plugin: 行")
    }

    // MARK: - 场景6.P1 / 6.P2 [det-machine]（数据层）+ C-BUILTIN-DISABLED：关闭态全排除

    /// 场景6.P1/P2：插件关闭（enabledStore.isEnabled==false）后，部分词 `pas` 与完整触发词 `cb`
    /// 均无该插件任何内容（插件行与条目均无）。
    /// Mutation kill：D3 fuzzyMatchablePlugins 忘过滤 enabledStore → 关闭态出 builtin: 行 → 红。
    /// 隔离：独立 UserDefaults suite（BuiltinPluginEnabledStoreTests 同构），不触碰 .standard。
    func test_scenario6_P1_P2_disabled_noPasteContentAnyQuery() async {
        let store = makeIsolatedStore()
        store.setEnabled(id: "paste", enabled: false)
        let registry = BuiltinPluginRegistry(plugins: [FuzzyPasteMockPlugin()], enabledStore: store)
        LauncherManager.shared.registryOverride = registry

        for query in ["pas", "cb"] {
            let acts = await LauncherManager.shared.unifiedCandidates(for: query)
            let pasteContent = acts.filter { $0.pluginId == "paste" }
            XCTAssertTrue(pasteContent.isEmpty,
                "场景6.\(query == "pas" ? "P1" : "P2"): 关闭态下「\(query)」无 paste 任何行（行与条目均无），实际=\(acts.map(\.id))")
            XCTAssertFalse(acts.contains { $0.id == "builtin:paste" },
                "C-BUILTIN-DISABLED: 关闭态不产 builtin: 行")
        }
    }

    // MARK: - 场景6.P3 [det-machine]（数据层）：重新启用后部分词命中恢复

    /// 场景6.P3：重新开启插件后输入 `pas` → builtin:paste 行恢复（关闭态不残留）。
    func test_scenario6_P3_reenabled_rowRestored() async throws {
        let store = makeIsolatedStore()
        store.setEnabled(id: "paste", enabled: false)
        let registry = BuiltinPluginRegistry(plugins: [FuzzyPasteMockPlugin()], enabledStore: store)
        LauncherManager.shared.registryOverride = registry

        let disabledActs = await LauncherManager.shared.unifiedCandidates(for: "pas")
        XCTAssertFalse(disabledActs.contains { $0.id == "builtin:paste" },
            "场景6.P3 前置: 关闭态无行")

        store.setEnabled(id: "paste", enabled: true)

        let acts = await LauncherManager.shared.unifiedCandidates(for: "pas")
        let rows = acts.filter { $0.id == "builtin:paste" }
        XCTAssertEqual(rows.count, 1,
            "场景6.P3: 重新启用后「pas」恢复出 paste 插件行，实际=\(acts.map(\.id))")
    }

    // MARK: - 错误边界：pluginKeywords 空 → 不产行

    /// 错误边界（契约规约）：pluginKeywords 空的内置插件等价未配置，任何 query 不产行。
    /// app 形 mock（无 keywords）只出条目、不出 builtin:app-launcher 行。
    func test_errorBoundary_emptyPluginKeywords_noRow() async {
        LauncherManager.shared.registryOverride = makeRegistry([AppLauncherMockPlugin()])

        let acts = await LauncherManager.shared.unifiedCandidates(for: "app")
        XCTAssertFalse(acts.contains { $0.id.hasPrefix("builtin:") },
            "错误边界: pluginKeywords 空 → 不产 builtin: 行，实际=\(acts.map(\.id))")
        XCTAssertTrue(acts.contains { $0.pluginId == "app-launcher" },
            "条目通路不受影响（既有行为零变化）")
    }

    // MARK: - 辅助

    private func makeRegistry(_ plugins: [any BuiltinPlugin]) -> BuiltinPluginRegistry {
        BuiltinPluginRegistry(plugins: plugins)
    }

    /// 独立 UserDefaults suite（BuiltinPluginEnabledStoreTests 同构，避免污染 .standard）。
    private func makeIsolatedStore() -> BuiltinPluginEnabledStore {
        let suiteName = "test-builtin-fuzzy-row-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        for key in defaults.dictionaryRepresentation().keys {
            defaults.removeObject(forKey: key)
        }
        return BuiltinPluginEnabledStore(defaults: defaults)
    }

    private func decodeManifest(name: String, keywords: [String], mode: String) -> PluginManifest {
        let json: [String: Any] = [
            "name": name,
            "version": "0.1.0",
            "description": "test command plugin \(name)",
            "keywords": keywords,
            "mode": mode,
            "cmd": "echo",
            "args": [] as [String]
        ]
        return try! JSONDecoder().decode(PluginManifest.self, from: try JSONSerialization.data(withJSONObject: json))
    }
}

// MARK: - Mock 内置插件（本文件私有）

/// paste 形 mock（D1：pluginKeywords = 触发词闭集；触发词 hasPrefix 才出具体候选）。
/// 固定候选不依赖真实剪贴板。priority/summary/触发词闭集取自设计文档 D1 + PastePlugin 既有契约。
@MainActor
private struct FuzzyPasteMockPlugin: BuiltinPlugin {
    static let keywords = ["cb", "clipboard", "剪贴板", "paste"]
    static let summaryLiteral = "剪贴板历史：输入「cb」查看并粘贴近期复制内容"

    let id = "paste"
    let priority = 150
    let sectionTitle = "剪贴板"
    let summary = FuzzyPasteMockPlugin.summaryLiteral
    /// 蓝队合流前为普通额外属性（编译无害）；合流后满足协议要求（D1）。
    var pluginKeywords: [String] { Self.keywords }

    func actions(for query: String) async -> [LauncherAction] {
        let lower = query.lowercased()
        guard Self.keywords.contains(where: { lower.hasPrefix($0) }) else { return [] }
        return [
            LauncherAction(id: "paste://seed-0", title: "buddy-acceptance-seed", subtitle: "文本",
                           icon: nil, iconEmoji: nil, pluginId: "paste", score: 1000, perform: {}),
            LauncherAction(id: "paste://seed-1", title: "older-entry", subtitle: "文本",
                           icon: nil, iconEmoji: nil, pluginId: "paste", score: 990, perform: {}),
        ]
    }
}

/// app 形 mock（无 pluginKeywords → 错误边界；条目 pluginId=app-launcher → CLI source "app"）。
@MainActor
private struct AppLauncherMockPlugin: BuiltinPlugin {
    let id = "app-launcher"
    let priority = 0
    let sectionTitle = "应用"

    func actions(for query: String) async -> [LauncherAction] {
        guard !query.isEmpty else { return [] }
        return [
            LauncherAction(id: "/Applications/Pages.app", title: "Pages", subtitle: nil,
                           icon: nil, iconEmoji: nil, pluginId: "app-launcher", score: 830, perform: {})
        ]
    }
}

/// 通用内置条目 mock（无 pluginKeywords；条目 pluginId=sysmock → CLI source "builtin" 对照）。
@MainActor
private struct BuiltinEntryMockPlugin: BuiltinPlugin {
    let id = "sysmock"
    let priority = 100
    let sectionTitle = "系统"

    func actions(for query: String) async -> [LauncherAction] {
        guard !query.isEmpty else { return [] }
        return [
            LauncherAction(id: "sysmock://lock", title: "锁定屏幕", subtitle: nil,
                           icon: nil, iconEmoji: nil, pluginId: "sysmock", score: 830, perform: {})
        ]
    }
}
