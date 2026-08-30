import XCTest
@testable import BuddyCore

// MARK: - LauncherUnifiedCandidateMixAcceptanceTests
//
// 红队验收测试（TDD 红灯）：插件候选一等公民统一混排——typing 阶段 updateQuery 行为
//
// 设计文档契约引用（## 设计决策 D1/D2/D3/D5 + ## 契约规约 C-UNIFIED-SCORE/C-NO-REGRESS/C-TAB-LOCK）：
//   D1：插件候选桥接 LauncherAction：id="plugin:\(name)"、title=name、subtitle=displaySummary、
//       pluginId=name、iconEmoji=manifest.icon
//   D2：统一分数档位混排，合并截 8，单列表
//   D3：退役 commandRouteCandidates / 自动锁定 / lastRoutePluginName chip；空 query 清锁定
//   C-NO-REGRESS：app 行 Enter 走 performSelectedInstantAction；「密码」instantActions 不含 qr
//
// 测试直调路径（设计文档 Context 声明）：
//   LauncherManager.shared.updateQuery(_:)（instantDebounceMsOverride = 0）→ 断言
//   @Published instantActions: [LauncherAction]、lockedCommand: PluginManifest?
//
// ⚠️ TDD 红灯：LauncherAction 的 iconEmoji 参数、PluginManifest.icon 字段蓝队未加时编译失败，
//   属预期；绝不放宽断言让它过。
//
// ASSUMES blue team：LauncherAction init 追加 iconEmoji: String? 形参（置于 perform 之后，
//   与既有 (id:title:subtitle:icon:pluginId:score:perform:) 顺序兼容）。

@MainActor
final class LauncherUnifiedCandidateMixAcceptanceTests: XCTestCase {

    // MARK: - 生命周期

    override func setUp() async throws {
        try await super.setUp()
        LauncherManager.shared.resetSubmittingStateForTesting()
        LauncherManager.shared.instantDebounceMsOverride = 0
        LauncherManager.shared.registryOverride = makeEmptyRegistry()
        LauncherManager.shared.pluginsOverride = nil
        LauncherManager.shared.stdinExecutorOverride = nil
        LauncherManager.shared.clearInstantActions()
        // D3：空 query 清锁定——清前序测试残留的 lockedCommand
        LauncherManager.shared.updateQuery("")
        if LauncherManager.shared.isVisible {
            LauncherManager.shared.hide()
        }
    }

    override func tearDown() async throws {
        LauncherManager.shared.pluginsOverride = nil
        LauncherManager.shared.registryOverride = nil
        LauncherManager.shared.stdinExecutorOverride = nil
        LauncherManager.shared.clearInstantActions()
        LauncherManager.shared.updateQuery("")
        try await super.tearDown()
    }

    // MARK: - manifest 构造

    private func makeCommandManifest(name: String, keywords: [String], icon: String? = nil,
                                     summary: String? = nil) -> PluginManifest {
        var json: [String: Any] = [
            "name": name,
            "version": "0.1.0-test",
            "description": summary ?? "test command plugin \(name)",
            "keywords": keywords,
            "mode": "command",
            "cmd": "echo",
            "args": [String]()
        ]
        if let icon = icon { json["icon"] = icon }
        if let summary = summary { json["summary"] = summary }
        return try! JSONDecoder().decode(PluginManifest.self, from: JSONSerialization.data(withJSONObject: json))
    }

    // MARK: - 驱动辅助：updateQuery + 稳定等待（instantActions 连续 4 次轮询不变即视为落地）

    private func updateQueryAndSettle(_ query: String) async {
        LauncherManager.shared.updateQuery(query)
        var lastCount = -1
        var stablePolls = 0
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline && stablePolls < 4 {
            let count = LauncherManager.shared.instantActions.count
            if count == lastCount {
                stablePolls += 1
            } else {
                stablePolls = 0
                lastCount = count
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - 场景1.P1 [det-machine]：输「二维码」→ instantActions[0].pluginId == qr

    /// 场景1.P1：qr 插件 keywords [qr,二维码,码]，输「二维码」完全档 1000 → 单列表首位是 qr 行。
    /// assert: instantActions[0].pluginId == "qr"（精确字面量，kill 排序/桥接 no-op mutation）
    func test_scenario1_P1_queryErweima_firstRowIsQrPlugin() async {
        LauncherManager.shared.pluginsOverride = [makeCommandManifest(name: "qr", keywords: ["qr", "二维码", "码"])]

        await updateQueryAndSettle("二维码")

        let actions = LauncherManager.shared.instantActions
        XCTAssertFalse(actions.isEmpty, "场景1.P1: 输「二维码」必须有候选（qr 完全档 1000）")
        XCTAssertEqual(actions[0].pluginId, "qr",
            "场景1.P1: instantActions[0].pluginId 必须精确为 \"qr\"，实际=\(actions.map(\.pluginId))")
    }

    // MARK: - 场景1.P2 [det-machine]：单一数组混排无分区

    /// 场景1.P2：插件行与内置行共存于同一个 instantActions 数组（无 commandRoute 分区数组）。
    /// mock 内置插件返回 score 300 的行（低于 qr 的 1000）→ 两行同列、插件行在前。
    /// assert: count>=2 && 两个 pluginId 都在同一数组内 && qr 在 index 0。
    /// Mutation kill：若插件仍走独立 commandRouteCandidates（旧分区），instantActions 只含内置行 → 挂。
    func test_scenario1_P2_singleArray_pluginAndBuiltinCoexist() async {
        let builtin = FixedScoreActionsPlugin(id: "mock-builtin", priority: 50, actions: [
            makeMockAction(id: "builtin-row", title: "内置命中", pluginId: "mock-builtin", score: 300, flag: nil)
        ])
        LauncherManager.shared.registryOverride = BuiltinPluginRegistry(plugins: [builtin])
        LauncherManager.shared.pluginsOverride = [makeCommandManifest(name: "qr", keywords: ["qr", "二维码", "码"])]

        await updateQueryAndSettle("二维码")

        let actions = LauncherManager.shared.instantActions
        let pluginIds = actions.map(\.pluginId)
        XCTAssertGreaterThanOrEqual(actions.count, 2,
            "场景1.P2: 插件行与内置行必须混排在同一数组（count>=2），实际=\(pluginIds)")
        XCTAssertTrue(pluginIds.contains("qr"), "场景1.P2: 同一数组必须含插件行 qr，实际=\(pluginIds)")
        XCTAssertTrue(pluginIds.contains("mock-builtin"), "场景1.P2: 同一数组必须含内置行 mock-builtin，实际=\(pluginIds)")
        XCTAssertEqual(actions[0].pluginId, "qr",
            "场景1.P2: 统一分数混排——qr(1000) 必须排在 mock-builtin(300) 之前")
    }

    // MARK: - 场景1.P4 [det-machine]：档位不变量——合并截 8

    /// 场景1.P4：10 个同 keyword 插件全部完全档 1000 → 合并后列表 ≤8（截断契约）。
    /// assert: instantActions.count <= 8 && 非空。
    /// Mutation kill：无截断 mutation → count==10 → 挂。
    func test_scenario1_P4_mergedList_truncatedTo8() async {
        let many = (1...10).map { makeCommandManifest(name: "many\($0)", keywords: ["many"]) }
        LauncherManager.shared.pluginsOverride = many

        await updateQueryAndSettle("many")

        let actions = LauncherManager.shared.instantActions
        XCTAssertFalse(actions.isEmpty, "场景1.P4: 完全档命中必须有候选")
        XCTAssertLessThanOrEqual(actions.count, 8,
            "场景1.P4: 合并截 8——实际=\(actions.count)（pluginIds=\(actions.map(\.pluginId))）")
    }

    // MARK: - 场景2 [det-machine]：app 行优先 + Enter 走 performSelectedInstantAction

    /// 场景2.P1+P2：输「wechat」→ [0] 为 app 行（微信，score 1000）；插件行（keyword "wechatpay"，
    /// query "wechat" 前缀档 800 < 1000）index >= 1。
    /// assert: instantActions[0].pluginId == "app-launcher" && 插件行 index>=1。
    /// 注：插件 keyword 取 "wechatpay"（前缀 800）而非 "wechat"（完全 1000 会与 app 行打平，
    ///   D2 来源序 tie-break 权重「内置 priority 降序>社区 50>app 0」的精确语义未冻结——
    ///   CONTRACT_AMBIGUOUS: 同分 tie-break 不在本测试断言范围，仅断言严格分数差下的顺序。
    func test_scenario2_P1_P2_wechat_appRowFirst_pluginRowAfter() async throws {
        let appPlugin = FixedScoreActionsPlugin(id: "app-launcher", priority: 0, actions: [
            makeMockAction(id: "app-wechat", title: "微信", pluginId: "app-launcher", score: 1000, flag: nil)
        ])
        LauncherManager.shared.registryOverride = BuiltinPluginRegistry(plugins: [appPlugin])
        LauncherManager.shared.pluginsOverride = [makeCommandManifest(name: "wechatpay", keywords: ["wechatpay"])]

        await updateQueryAndSettle("wechat")

        let actions = LauncherManager.shared.instantActions
        XCTAssertFalse(actions.isEmpty, "场景2 前置: 输「wechat」必须有候选")
        XCTAssertEqual(actions[0].pluginId, "app-launcher",
            "场景2.P1: app 行（微信 1000）必须在 [0]，实际=\(actions.map(\.pluginId))")
        let pluginIndex = actions.firstIndex { $0.pluginId == "wechatpay" }
        let idx = try XCTUnwrap(pluginIndex, "场景2.P2: 插件行必须在列表内")
        XCTAssertGreaterThanOrEqual(idx, 1,
            "场景2.P2: 插件行（800）必须排在 app 行（1000）之后，实际 index=\(idx)")
    }

    /// 场景2.P3 [det-machine]：app 行 Enter 走 performSelectedInstantAction 分支（非插件执行）。
    /// assert: performSelectedInstantAction()==true && app 行 perform 闭包被执行 && spy 未被调（0 次）。
    /// Mutation kill：若 Enter 误派发到插件执行路径，spy.executeCallCount>0 或 appFlag==false → 挂。
    func test_scenario2_P3_appRowEnter_performSelectedInstantAction_notPluginExecution() async throws {
        var appFlag = false
        let spy = RecordingStdinExecutorSpy()
        let appPlugin = FixedScoreActionsPlugin(id: "app-launcher", priority: 0, actions: [
            makeMockAction(id: "app-wechat", title: "微信", pluginId: "app-launcher", score: 1000) { appFlag = true }
        ])
        LauncherManager.shared.registryOverride = BuiltinPluginRegistry(plugins: [appPlugin])
        LauncherManager.shared.pluginsOverride = [makeCommandManifest(name: "wechatpay", keywords: ["wechatpay"])]
        LauncherManager.shared.stdinExecutorOverride = spy

        await updateQueryAndSettle("wechat")
        XCTAssertEqual(LauncherManager.shared.instantActions.first?.pluginId, "app-launcher",
            "场景2.P3 前置: 选中行必须是 app 行")

        let consumed = LauncherManager.shared.performSelectedInstantAction()

        XCTAssertTrue(consumed, "场景2.P3: app 行 Enter 必须被 performSelectedInstantAction 消费（返回 true）")
        XCTAssertTrue(appFlag, "场景2.P3: app 行 perform 闭包必须被执行（C-NO-REGRESS）")
        XCTAssertEqual(spy.executeCallCount, 0,
            "场景2.P3: app 行 Enter 不得触发插件子进程执行（spy==0），实际=\(spy.executeCallCount)")
    }

    // MARK: - 场景5.P1 [det-machine]：插件行同构（D1 字段映射）

    /// 场景5.P1：插件行视觉同构——D1 字段逐字断言：
    ///   id=="plugin:qr"、title=="qr"、subtitle==displaySummary、pluginId=="qr"、iconEmoji==manifest.icon。
    func test_scenario5_P1_pluginRow_shapePerD1() async throws {
        let manifest = makeCommandManifest(name: "qr", keywords: ["qr", "二维码", "码"],
                                           icon: "🏷", summary: "生成二维码图片")
        LauncherManager.shared.pluginsOverride = [manifest]

        await updateQueryAndSettle("二维码")

        let row = try XCTUnwrap(
            LauncherManager.shared.instantActions.first { $0.pluginId == "qr" },
            "场景5.P1: 「二维码」必须产出 qr 插件行"
        )
        XCTAssertEqual(row.id, "plugin:qr", "场景5.P1/D1: 插件行 id 必须是 \"plugin:\\(name)\" 格式")
        XCTAssertEqual(row.title, "qr", "场景5.P1/D1: 插件行 title 必须是插件名 name")
        XCTAssertEqual(row.subtitle, manifest.displaySummary,
            "场景5.P1/D1: 插件行 subtitle 必须等于 displaySummary（\"生成二维码图片\"），实际=\(row.subtitle ?? "nil")")
        XCTAssertEqual(row.iconEmoji, "🏷", "场景5.P1/D1: 插件行 iconEmoji 必须等于 manifest.icon")
    }

    // MARK: - 场景10 [det-machine]：前缀/大小写进列表（updateQuery 集成）

    /// 场景10.P1：输「qz」→ qzh 进列表（前缀档 800）。
    func test_scenario10_P1_queryQz_qzhInList() async {
        LauncherManager.shared.pluginsOverride = [makeCommandManifest(name: "qzh", keywords: ["qzh", "圈住"])]

        await updateQueryAndSettle("qz")

        let pluginIds = LauncherManager.shared.instantActions.map(\.pluginId)
        XCTAssertTrue(pluginIds.contains("qzh"),
            "场景10.P1: 输「qz」qzh 必须以前缀档进列表，实际=\(pluginIds)")
    }

    /// 场景10.P2：输「QR」→ qr 进列表（大小写不敏感，完全档 1000）。
    func test_scenario10_P2_queryQRCaseInsensitive_qrInList() async {
        LauncherManager.shared.pluginsOverride = [makeCommandManifest(name: "qr", keywords: ["qr", "二维码", "码"])]

        await updateQueryAndSettle("QR")

        let pluginIds = LauncherManager.shared.instantActions.map(\.pluginId)
        XCTAssertTrue(pluginIds.contains("qr"),
            "场景10.P2: 输「QR」大小写不敏感必须命中 qr，实际=\(pluginIds)")
    }

    // MARK: - 场景11.P1 [det-machine]：输「qr 」不自动锁定且混排列表

    /// 场景11.P1：自动锁定退役（D3）——输「qr 」（keyword+空格）→ lockedCommand==nil
    /// 且 qr 行仍在混排列表（不消失、不独占）。
    /// assert: lockedCommand==nil && instantActions 含 pluginId=="qr" 的行。
    /// Mutation kill：若旧「唯一命中自动锁」残留，lockedCommand?.name=="qr" → 挂。
    func test_scenario11_P1_queryQrSpace_noAutoLock_rowStillListed() async {
        LauncherManager.shared.pluginsOverride = [makeCommandManifest(name: "qr", keywords: ["qr", "二维码", "码"])]

        await updateQueryAndSettle("qr ")

        XCTAssertNil(LauncherManager.shared.lockedCommand,
            "场景11.P1: 自动锁定必须退役——输「qr 」lockedCommand 必须为 nil，实际=\(LauncherManager.shared.lockedCommand?.name ?? "nil")")
        let pluginIds = LauncherManager.shared.instantActions.map(\.pluginId)
        XCTAssertTrue(pluginIds.contains("qr"),
            "场景11.P1: 输「qr 」qr 行必须仍在混排列表（不隐藏），实际=\(pluginIds)")
    }

    // MARK: - 场景13.P1 [det-machine]：pluginsOverride 空集不崩

    /// 场景13.P1：pluginsOverride = []（空集 override）→ 候选全来自 app/builtin，不崩、无插件行。
    /// assert: updateQuery 完成后无 "plugin:" 前缀 id 的行（D1 插件行 id 标记）&& 内置行在场。
    func test_scenario13_P1_emptyPluginOverride_candidatesFromBuiltinOnly_noCrash() async {
        let builtin = FixedScoreActionsPlugin(id: "solo-builtin", priority: 100, actions: [
            makeMockAction(id: "solo-row", title: "内置唯一", pluginId: "solo-builtin", score: 900, flag: nil)
        ])
        LauncherManager.shared.registryOverride = BuiltinPluginRegistry(plugins: [builtin])
        LauncherManager.shared.pluginsOverride = []

        await updateQueryAndSettle("anycase")

        let actions = LauncherManager.shared.instantActions
        XCTAssertTrue(actions.allSatisfy { !$0.id.hasPrefix("plugin:") },
            "场景13.P1: 空插件集时不得出现插件行（D1 id 前缀 plugin:），实际=\(actions.map(\.id))")
        XCTAssertTrue(actions.contains { $0.pluginId == "solo-builtin" },
            "场景13.P1: 候选应全来自 app/builtin（内置行在场），实际=\(actions.map(\.pluginId))")
    }

    // MARK: - 场景14 [det-machine]：「密码」/「验证码」不含 qr；「码」qr 进列表

    /// 场景14.P1：单字 keyword 防误命中——输「密码」/「验证码」instantActions 不含 qr。
    /// Mutation kill：旧 contains 语义（keyword「码」∈ query）回归 → qr 行出现 → 挂。
    func test_scenario14_P1_mimaAndyanzhengma_doNotShowQrRow() async {
        LauncherManager.shared.pluginsOverride = [makeCommandManifest(name: "qr", keywords: ["qr", "二维码", "码"])]

        await updateQueryAndSettle("密码")
        XCTAssertFalse(LauncherManager.shared.instantActions.contains { $0.pluginId == "qr" },
            "场景14.P1: 输「密码」instantActions 不得含 qr 行，实际=\(LauncherManager.shared.instantActions.map(\.pluginId))")

        await updateQueryAndSettle("验证码")
        XCTAssertFalse(LauncherManager.shared.instantActions.contains { $0.pluginId == "qr" },
            "场景14.P1: 输「验证码」instantActions 不得含 qr 行，实际=\(LauncherManager.shared.instantActions.map(\.pluginId))")
    }

    /// 场景14.P2：输「码」→ qr 进列表（单字 keyword 完全档 1000 仍有效）。
    func test_scenario14_P2_queryMa_alone_showsQrRow() async {
        LauncherManager.shared.pluginsOverride = [makeCommandManifest(name: "qr", keywords: ["qr", "二维码", "码"])]

        await updateQueryAndSettle("码")

        XCTAssertTrue(LauncherManager.shared.instantActions.contains { $0.pluginId == "qr" },
            "场景14.P2: 输「码」qr 必须以完全档进列表，实际=\(LauncherManager.shared.instantActions.map(\.pluginId))")
    }

    // MARK: - 辅助：空 registry（避免 AppLauncher 扫 /Applications 污染断言）

    private func makeEmptyRegistry() -> BuiltinPluginRegistry {
        BuiltinPluginRegistry(plugins: [EmptyActionsPluginForMixTest()])
    }

    private func makeMockAction(id: String, title: String, pluginId: String, score: Int,
                                flag: (() -> Void)? = nil) -> LauncherAction {
        LauncherAction(
            id: id,
            title: title,
            subtitle: nil,
            icon: nil,
            iconEmoji: nil,
            pluginId: pluginId,
            score: score,
            perform: { flag?() }
        )
    }
}

// MARK: - Mock：固定候选内置插件（任意非空 query 返回固定行）

private struct FixedScoreActionsPlugin: BuiltinPlugin {
    let id: String
    let priority: Int
    let sectionTitle = "mix-test"
    let actions: [LauncherAction]

    func actions(for query: String) async -> [LauncherAction] {
        query.isEmpty ? [] : actions
    }
}

// MARK: - Mock：空内置插件（与 LockedCommandStateMachineAcceptanceTests 同构，私有避免重名）

private struct EmptyActionsPluginForMixTest: BuiltinPlugin {
    let id = "empty-mix-test"
    let priority = 0
    let sectionTitle = "Empty"
    func actions(for query: String) async -> [LauncherAction] { [] }
}
