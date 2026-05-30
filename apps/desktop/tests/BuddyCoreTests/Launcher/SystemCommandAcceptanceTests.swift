import XCTest
@testable import BuddyCore

// MARK: - SystemCommandAcceptanceTests
//
// 红队验收测试：SystemCommandPlugin 锁屏命令契约（SC1–SC9 + 场景 1–9 谓词）
//
// 本文件覆盖：
//   SC1  — 属性契约（id/priority/sectionTitle）
//   SC2  — 双语关键词各产出恰好 1 条 title=="锁定屏幕"，pluginId=="system-command"
//   SC3  — 前缀命中（loc/锁）+ 大小写不敏感（LOCK）
//   SC4  — negate：safari / 空 query 不产出锁屏候选
//   SC5  — score 排序：完全相等关键词 > 前缀命中
//   SC6  — 惰性执行：构造/actions 不触锁屏；perform 后 spy.callCount==1
//   SC7  — seam 抛错 → LauncherError.systemCommandFailed + 中文文案（CJK）
//   SC8  — Registry 仲裁：系统候选（priority 100）在 app 候选（priority 0）之前
//   SC9  — 不触碰像素猫子系统；测试用 mock seam，不真锁屏
//   Extra — reset() 后默认列表仍含 system-command 插件（防 flaky）
//
// 红队红线：
//   - 不读取 apps/desktop/Sources/ClaudeCodeBuddy/Launcher/Builtin/System/ 下任何实现文件
//   - 不读取蓝队 SystemCommandPluginTests.swift
//   - 所有锁屏副作用通过注入 mock ScreenLocking（spy/stub）验证
//   - 真机锁屏验证（3.E2E）标注为人工冒烟，CI 跳过
//
// 测试此刻预期无法编译/失败（蓝队实现尚未合入）— 这是 TDD 红灯，预期行为。

// CONTRACT_AMBIGUOUS: ScreenLocking 协议定义路径尚未确认（蓝队新建），
//   按契约逐字使用：protocol ScreenLocking { func lock() throws }
//   注入点：SystemCommandPlugin(locker: ScreenLocking) 或 SystemCommandPlugin.shared 有 locker 属性

// MARK: - Mock：记录调用次数的 ScreenLocking spy

/// spy mock：记录 callCount，不真锁屏
@MainActor
private final class LockScreenSpy: ScreenLocking {
    private(set) var callCount = 0
    func lock() throws {
        callCount += 1
    }
}

/// stub mock：每次调用都抛错
@MainActor
private struct FailingScreenLocker: ScreenLocking {
    func lock() throws {
        throw NSError(domain: "test.screenlock", code: -1, userInfo: [NSLocalizedDescriptionKey: "mock failure"])
    }
}

// MARK: - Helper：构造 LauncherAction（不依赖实现内部结构）

@MainActor
private func makeAppAction(id: String, title: String) -> LauncherAction {
    LauncherAction(
        id: id,
        title: title,
        subtitle: nil,
        icon: nil,
        pluginId: "app-launcher",
        score: 50,
        perform: {}
    )
}

// MARK: - SC1 + 场景 1.P4：属性契约

@MainActor
final class SystemCommandPluginAttributeAcceptanceTests: XCTestCase {

    // SC1 / 1.P4: id=="system-command", priority==100, sectionTitle=="系统"

    /// 验收场景 1.P4 + SC1：plugin.priority == 100
    func test_SC1_priority_equals100() {
        let plugin = SystemCommandPlugin.shared
        XCTAssertEqual(plugin.priority, 100,
            "SC1 / 1.P4: SystemCommandPlugin.priority 必须为 100（> app 的 0），实际 \(plugin.priority)")
    }

    /// SC1：id == "system-command"
    func test_SC1_id_systemCommand() {
        let plugin = SystemCommandPlugin.shared
        XCTAssertEqual(plugin.id, "system-command",
            "SC1: SystemCommandPlugin.id 必须为 \"system-command\"，实际 \"\(plugin.id)\"")
    }

    /// SC1：sectionTitle == "系统"
    func test_SC1_sectionTitle_系统() {
        let plugin = SystemCommandPlugin.shared
        XCTAssertEqual(plugin.sectionTitle, "系统",
            "SC1: SystemCommandPlugin.sectionTitle 必须为 \"系统\"，实际 \"\(plugin.sectionTitle)\"")
    }

    /// SC1：遵守 BuiltinPlugin 协议（编译期隐式验证，运行期接口断言）
    func test_SC1_conformsTo_BuiltinPlugin() {
        let plugin: any BuiltinPlugin = SystemCommandPlugin.shared
        XCTAssertEqual(plugin.id, "system-command",
            "SC1: SystemCommandPlugin 必须遵守 BuiltinPlugin 协议且 id 正确")
        XCTAssertEqual(plugin.priority, 100,
            "SC1: 通过协议访问 priority 应为 100")
    }
}

// MARK: - SC2 + 场景 1/2：双语关键词各恰好 1 条

@MainActor
final class SystemCommandPluginKeywordAcceptanceTests: XCTestCase {

    // MARK: SC2 / 场景 1.P1、1.P2：英文关键词 "lock"

    /// 场景 1.P1 + SC2：query=="lock" → 恰好 1 条 title=="锁定屏幕"
    func test_SC2_queryLock_producesExactlyOne_lockScreenAction() async {
        let plugin = SystemCommandPlugin(locker: LockScreenSpy())
        let actions = await plugin.actions(for: "lock")

        let lockActions = actions.filter { $0.title == "锁定屏幕" }
        XCTAssertEqual(lockActions.count, 1,
            "SC2 / 场景 1.P1: query==\"lock\" 必须恰好产出 1 条 title==\"锁定屏幕\"，实际 \(lockActions.count) 条")
    }

    /// 场景 1.P2 + SC2：query=="lock" 产出的候选 pluginId=="system-command"
    func test_SC2_queryLock_actionPluginId_systemCommand() async {
        let plugin = SystemCommandPlugin(locker: LockScreenSpy())
        let actions = await plugin.actions(for: "lock")

        let lockActions = actions.filter { $0.title == "锁定屏幕" }
        guard let lockAction = lockActions.first else {
            XCTFail("SC2 / 场景 1.P2 precondition: 应有 title==\"锁定屏幕\" 的候选")
            return
        }
        XCTAssertEqual(lockAction.pluginId, "system-command",
            "SC2 / 场景 1.P2: 候选 pluginId 必须为 \"system-command\"，实际 \"\(lockAction.pluginId)\"")
    }

    // MARK: SC2 / 场景 2.P1、2.P2：中文关键词 "锁屏"

    /// 场景 2.P1 + SC2：query=="锁屏" → 恰好 1 条 title=="锁定屏幕"
    func test_SC2_query_锁屏_producesExactlyOne_lockScreenAction() async {
        let plugin = SystemCommandPlugin(locker: LockScreenSpy())
        let actions = await plugin.actions(for: "锁屏")

        let lockActions = actions.filter { $0.title == "锁定屏幕" }
        XCTAssertEqual(lockActions.count, 1,
            "SC2 / 场景 2.P1: query==\"锁屏\" 必须恰好产出 1 条 title==\"锁定屏幕\"，实际 \(lockActions.count) 条")
    }

    /// 场景 2.P2 + SC2：query=="锁屏" 产出的候选 pluginId=="system-command"
    func test_SC2_query_锁屏_actionPluginId_systemCommand() async {
        let plugin = SystemCommandPlugin(locker: LockScreenSpy())
        let actions = await plugin.actions(for: "锁屏")

        let lockActions = actions.filter { $0.title == "锁定屏幕" }
        guard let lockAction = lockActions.first else {
            XCTFail("SC2 / 场景 2.P2 precondition: 应有 title==\"锁定屏幕\" 的候选")
            return
        }
        XCTAssertEqual(lockAction.pluginId, "system-command",
            "SC2 / 场景 2.P2: 候选 pluginId 必须为 \"system-command\"，实际 \"\(lockAction.pluginId)\"")
    }

    // MARK: SC2：候选 subtitle=="锁屏"（契约字面量验证）

    /// SC2 补充：title=="锁定屏幕" 候选的 subtitle 应为 "锁屏"（设计文档字面量）
    func test_SC2_lockAction_subtitle_锁屏() async {
        let plugin = SystemCommandPlugin(locker: LockScreenSpy())
        let actions = await plugin.actions(for: "lock")

        let lockAction = actions.first { $0.title == "锁定屏幕" }
        XCTAssertNotNil(lockAction, "SC2 precondition: 必须有锁屏候选")
        XCTAssertEqual(lockAction?.subtitle, "锁屏",
            "SC2: 锁屏候选 subtitle 必须为 \"锁屏\"，实际 \"\(lockAction?.subtitle ?? "nil")\"")
    }
}

// MARK: - SC3 + 场景 8：前缀命中 + 大小写不敏感

@MainActor
final class SystemCommandPluginPrefixCaseAcceptanceTests: XCTestCase {

    // MARK: 场景 8.P1：query=="loc"

    /// 场景 8.P1 + SC3：query=="loc" → 命中锁屏候选（"lock".hasPrefix("loc")）
    func test_SC3_queryLoc_prefixMatchesLock() async {
        let plugin = SystemCommandPlugin(locker: LockScreenSpy())
        let actions = await plugin.actions(for: "loc")

        let hasLockScreen = actions.contains { $0.title == "锁定屏幕" }
        XCTAssertTrue(hasLockScreen,
            "SC3 / 场景 8.P1: query==\"loc\" 应通过前缀匹配命中 \"锁定屏幕\"，实际 actions.count=\(actions.count)")
    }

    // MARK: 场景 8.P2：query=="lo"（设计文档补充谓词）

    /// 场景 8.P2 + SC3：query=="lo" → 命中锁屏候选（"lock".hasPrefix("lo")）
    func test_SC3_queryLo_prefixMatchesLock() async {
        let plugin = SystemCommandPlugin(locker: LockScreenSpy())
        let actions = await plugin.actions(for: "lo")

        let hasLockScreen = actions.contains { $0.title == "锁定屏幕" }
        XCTAssertTrue(hasLockScreen,
            "SC3 / 场景 8.P2: query==\"lo\" 应通过前缀匹配命中 \"锁定屏幕\"（\"lock\".hasPrefix(\"lo\")），实际 actions.count=\(actions.count)")
    }

    // MARK: 场景 8.S1：进程存活（"lo" 不 crash）

    /// 场景 8.S1 + SC3：query=="lo" 不导致 crash，进程正常返回
    func test_SC3_queryLo_noCrash() async {
        let plugin = SystemCommandPlugin(locker: LockScreenSpy())
        // 不抛错即通过，crash 会直接 abort
        let actions = await plugin.actions(for: "lo")
        XCTAssertGreaterThanOrEqual(actions.count, 0,
            "SC3 / 场景 8.S1: query==\"lo\" 不应 crash，进程应存活")
    }

    // MARK: SC3：前缀命中中文 "锁"

    /// SC3：query=="锁" → 前缀匹配 "锁屏"，命中锁屏候选
    func test_SC3_query_锁_prefixMatchesLockScreen() async {
        let plugin = SystemCommandPlugin(locker: LockScreenSpy())
        let actions = await plugin.actions(for: "锁")

        let hasLockScreen = actions.contains { $0.title == "锁定屏幕" }
        XCTAssertTrue(hasLockScreen,
            "SC3: query==\"锁\" 应通过前缀匹配命中 \"锁定屏幕\"（\"锁屏\".hasPrefix(\"锁\")），实际 actions.count=\(actions.count)")
    }

    // MARK: SC3：大小写不敏感 "LOCK"

    /// SC3：query=="LOCK" → 大小写不敏感，等同 "lock"，命中锁屏候选
    func test_SC3_queryLOCK_caseInsensitiveMatchesLock() async {
        let plugin = SystemCommandPlugin(locker: LockScreenSpy())
        let actions = await plugin.actions(for: "LOCK")

        let hasLockScreen = actions.contains { $0.title == "锁定屏幕" }
        XCTAssertTrue(hasLockScreen,
            "SC3: query==\"LOCK\" 大小写不敏感应命中 \"锁定屏幕\"，实际 actions.count=\(actions.count)")
    }

    // MARK: SC3：大小写变体 "Lock"（混合大小写）

    /// SC3 补充：query=="Lock" 混合大小写应命中
    func test_SC3_queryLock_mixedCase_matches() async {
        let plugin = SystemCommandPlugin(locker: LockScreenSpy())
        let actions = await plugin.actions(for: "Lock")

        let hasLockScreen = actions.contains { $0.title == "锁定屏幕" }
        XCTAssertTrue(hasLockScreen,
            "SC3: query==\"Lock\" 混合大小写应命中 \"锁定屏幕\"，实际 actions.count=\(actions.count)")
    }
}

// MARK: - SC4 + 场景 4/5：negate（无关查询/空 query 不产出）

@MainActor
final class SystemCommandPluginNegateAcceptanceTests: XCTestCase {

    // MARK: 场景 4.N1：query=="safari"

    /// 场景 4.N1 + SC4：query=="safari" → 不产出锁屏候选（"safari" 不是任何关键词前缀）
    func test_SC4_querySafari_noLockScreenAction() async {
        let plugin = SystemCommandPlugin(locker: LockScreenSpy())
        let actions = await plugin.actions(for: "safari")

        let lockActions = actions.filter { $0.title == "锁定屏幕" }
        XCTAssertEqual(lockActions.count, 0,
            "SC4 / 场景 4.N1: query==\"safari\" 不应产出 \"锁定屏幕\" 候选，实际 \(lockActions.count) 条")
    }

    // MARK: 场景 5.N1：query==""（空 query）

    /// 场景 5.N1 + SC4：query=="" → actions 为空（不产出任何候选）
    func test_SC4_emptyQuery_noActions() async {
        let plugin = SystemCommandPlugin(locker: LockScreenSpy())
        let actions = await plugin.actions(for: "")

        // 契约：空 query 返回 []
        XCTAssertTrue(actions.isEmpty,
            "SC4 / 场景 5.N1: query==\"\" 必须返回空数组，实际 \(actions.count) 条")
    }

    /// 场景 5.N1 negate 变体：空 query 确实不含锁屏候选
    func test_SC4_emptyQuery_noLockScreenAction() async {
        let plugin = SystemCommandPlugin(locker: LockScreenSpy())
        let actions = await plugin.actions(for: "")

        let hasLockScreen = actions.contains { $0.title == "锁定屏幕" }
        XCTAssertFalse(hasLockScreen,
            "SC4 / 场景 5.N1: 空 query 不应含 \"锁定屏幕\" 候选")
    }

    // MARK: SC4 补充：无关中文 query 不产出

    /// SC4 补充：query=="浏览器" → 不命中锁屏
    func test_SC4_query_浏览器_noLockScreenAction() async {
        let plugin = SystemCommandPlugin(locker: LockScreenSpy())
        let actions = await plugin.actions(for: "浏览器")

        let hasLockScreen = actions.contains { $0.title == "锁定屏幕" }
        XCTAssertFalse(hasLockScreen,
            "SC4: query==\"浏览器\" 不应产出 \"锁定屏幕\" 候选")
    }
}

// MARK: - SC5 + 场景 1：score 排序（完全相等 > 前缀）

@MainActor
final class SystemCommandPluginScoreAcceptanceTests: XCTestCase {

    // MARK: SC5：完全相等关键词 score > 前缀命中 score

    /// SC5："lock"（完全相等关键词）的 score 应高于 "loc"（前缀）的 score
    func test_SC5_exactMatchScore_greaterThan_prefixScore() async {
        let plugin = SystemCommandPlugin(locker: LockScreenSpy())

        let exactActions  = await plugin.actions(for: "lock")
        let prefixActions = await plugin.actions(for: "loc")

        guard let exactAction  = exactActions.first(where:  { $0.title == "锁定屏幕" }),
              let prefixAction = prefixActions.first(where: { $0.title == "锁定屏幕" })
        else {
            XCTFail("SC5 precondition: \"lock\" 和 \"loc\" 都必须命中 \"锁定屏幕\"")
            return
        }

        XCTAssertGreaterThan(exactAction.score, prefixAction.score,
            "SC5: 完全相等关键词的 score(\(exactAction.score)) 必须 > 前缀命中的 score(\(prefixAction.score))，保证确定性命中稳定置顶")
    }

    // MARK: SC5 补充：中文完全相等 > 中文前缀

    /// SC5 补充：query=="锁屏"（完全相等）的 score 应高于 query=="锁"（前缀）的 score
    func test_SC5_chineseExactMatchScore_greaterThan_prefixScore() async {
        let plugin = SystemCommandPlugin(locker: LockScreenSpy())

        let exactActions  = await plugin.actions(for: "锁屏")
        let prefixActions = await plugin.actions(for: "锁")

        guard let exactAction  = exactActions.first(where:  { $0.title == "锁定屏幕" }),
              let prefixAction = prefixActions.first(where: { $0.title == "锁定屏幕" })
        else {
            XCTFail("SC5 precondition: \"锁屏\" 和 \"锁\" 都必须命中 \"锁定屏幕\"")
            return
        }

        XCTAssertGreaterThan(exactAction.score, prefixAction.score,
            "SC5: 中文完全相等的 score(\(exactAction.score)) 必须 > 前缀的 score(\(prefixAction.score))")
    }

    // MARK: 场景 1.P4：priority 高于 app 的 0（score 层面 + priority 层面双验证）

    /// 场景 1.P4：SystemCommandPlugin.priority==100 > AppLauncherPlugin 的 0
    func test_SC5_systemCommandPriority_higherthan_appLauncherPriority() {
        let systemPlugin = SystemCommandPlugin.shared
        // AppLauncherPlugin.priority 已知为 0（既有契约）
        XCTAssertGreaterThan(systemPlugin.priority, 0,
            "场景 1.P4: SystemCommandPlugin.priority(\(systemPlugin.priority)) 必须 > AppLauncherPlugin 的 0")
    }
}

// MARK: - SC6 + 场景 3：惰性执行（构造/actions 不触锁屏，perform 后 callCount==1）

@MainActor
final class SystemCommandPluginLazyExecutionAcceptanceTests: XCTestCase {

    // MARK: SC6 / 场景 3.P1：构造后 spy.callCount==0

    /// SC6：构造 SystemCommandPlugin 时，注入的 spy.callCount 为 0（构造期不触发锁屏）
    func test_SC6_construction_doesNotTriggerLock() {
        let spy = LockScreenSpy()
        _ = SystemCommandPlugin(locker: spy)

        XCTAssertEqual(spy.callCount, 0,
            "SC6: 构造 SystemCommandPlugin 不应触发锁屏，spy.callCount 必须为 0，实际 \(spy.callCount)")
    }

    // MARK: SC6：actions(for:) 调用不触发锁屏

    /// SC6：调用 actions(for:) 后，spy.callCount 仍为 0（惰性，查询期不触发锁屏）
    func test_SC6_actionsQuery_doesNotTriggerLock() async {
        let spy = LockScreenSpy()
        let plugin = SystemCommandPlugin(locker: spy)

        _ = await plugin.actions(for: "lock")

        XCTAssertEqual(spy.callCount, 0,
            "SC6: actions(for:\"lock\") 不应触发锁屏（惰性），spy.callCount 必须为 0，实际 \(spy.callCount)")
    }

    // MARK: SC6 / 场景 3.P1：perform 后 spy.callCount==1（状态变迁硬断言）

    /// SC6 / 场景 3.P1：按 Enter 执行（perform()）后，spy.callCount 恰好 == 1
    ///
    /// Mutation-Survival 自检：
    /// - No-op mutant（perform 什么都不做）→ callCount 仍 0 → 本断言失败（捕获）
    /// - Conditional-Flip（跳过 seam 调用）→ callCount 仍 0 → 本断言失败（捕获）
    /// - State-Update-Skip（不累加 callCount）→ callCount 仍 0 → 本断言失败（捕获）
    func test_SC6_performAction_callsLockSeamExactlyOnce() async throws {
        let spy = LockScreenSpy()
        let plugin = SystemCommandPlugin(locker: spy)

        let actions = await plugin.actions(for: "lock")
        guard let lockAction = actions.first(where: { $0.title == "锁定屏幕" }) else {
            XCTFail("SC6 / 场景 3.P1 precondition: 必须有 title==\"锁定屏幕\" 的候选")
            return
        }

        // 执行动作（模拟按 Enter）
        XCTAssertNoThrow(try lockAction.perform(),
            "SC6 / 场景 3.P1: 正常情况下 perform() 不应抛错")

        // 硬断言：callCount 从 0 变迁到 1（状态变迁）
        XCTAssertEqual(spy.callCount, 1,
            "SC6 / 场景 3.P1: perform() 后 spy.callCount 必须为 1（恰好调用 seam 一次），实际 \(spy.callCount)")
    }

    // MARK: SC6：多次 perform 只增加 callCount（不共享全局状态）

    /// SC6 补充：两次 perform 两次调用，callCount==2（验证 seam 调用次数与 perform 次数一致）
    func test_SC6_performTwice_callsSeamTwice() async throws {
        let spy = LockScreenSpy()
        let plugin = SystemCommandPlugin(locker: spy)

        let actions = await plugin.actions(for: "lock")
        guard let lockAction = actions.first(where: { $0.title == "锁定屏幕" }) else {
            XCTFail("SC6 precondition: 必须有锁屏候选")
            return
        }

        try lockAction.perform()
        try lockAction.perform()

        XCTAssertEqual(spy.callCount, 2,
            "SC6: 两次 perform 后 spy.callCount 必须为 2，实际 \(spy.callCount)")
    }

    // MARK: 场景 3.P3：执行完成无二次确认弹窗（negate）

    // REAL_PROCESS: 真机人工冒烟，CI 跳过（3.E2E）
    // 场景 3.E2E：真机手动按 Enter → 屏幕进入锁屏/登录界面（每次发版前一次冒烟，CI 不自动化）

    /// 场景 3.P3 negate：perform 不应显示 modal/alert 弹窗（mock seam 不触发弹窗验证）
    func test_SC6_perform_noModalAlert() async throws {
        let spy = LockScreenSpy()
        let plugin = SystemCommandPlugin(locker: spy)

        let actions = await plugin.actions(for: "lock")
        guard let lockAction = actions.first(where: { $0.title == "锁定屏幕" }) else {
            XCTFail("场景 3.P3 precondition: 必须有锁屏候选")
            return
        }

        // 注入 mock，不真锁屏；确保 perform 直接完成，不等待任何弹窗确认
        try lockAction.perform()

        // perform 调用 spy（立即返回），callCount==1 说明无阻塞弹窗介入
        XCTAssertEqual(spy.callCount, 1,
            "场景 3.P3: perform() 必须立即调用 seam（callCount==1），无二次确认弹窗介入，实际 \(spy.callCount)")
    }
}

// MARK: - SC7 + 场景 6：抛错路径（systemCommandFailed + 中文文案）

@MainActor
final class SystemCommandPluginErrorAcceptanceTests: XCTestCase {

    // MARK: 场景 6.E2 + SC7：抛错 case == .systemCommandFailed

    /// 场景 6.E2 + SC7：seam 抛错 → perform 向上抛 LauncherError.systemCommandFailed
    ///
    /// Mutation-Survival 自检：
    /// - 吞错 mutant（catch{} 不 rethrow）→ XCTAssertThrowsError 失败（捕获）
    /// - 错误类型 mutant（抛其他 LauncherError）→ case 匹配失败（捕获）
    func test_SC7_seamThrows_performRethrows_systemCommandFailed() async {
        let stub = FailingScreenLocker()
        let plugin = SystemCommandPlugin(locker: stub)

        let actions = await plugin.actions(for: "lock")
        guard let lockAction = actions.first(where: { $0.title == "锁定屏幕" }) else {
            XCTFail("SC7 precondition: 必须有锁屏候选")
            return
        }

        XCTAssertThrowsError(try lockAction.perform(),
            "SC7 / 场景 6.E2: seam 抛错时 perform() 必须向上抛出 LauncherError.systemCommandFailed") { error in
            guard case LauncherError.systemCommandFailed = error else {
                XCTFail("SC7 / 场景 6.E2: 期望 LauncherError.systemCommandFailed，实际 \(error)")
                return
            }
        }
    }

    // MARK: 场景 6.E1 + SC7：错误文案含 CJK 字符

    /// 场景 6.E1 + SC7：LauncherError.systemCommandFailed 的 errorDescription 含 ≥1 CJK 字符，length>=4
    ///
    /// Mutation-Survival 自检：
    /// - 裸英文文案 mutant → hasChinese 为 false → 本断言失败（捕获）
    /// - 空文案 mutant → length<4 → 本断言失败（捕获）
    func test_SC7_systemCommandFailed_errorDescription_containsCJK() {
        // 直接从 LauncherError 取 errorDescription（契约字面量已在 LauncherError.swift 注册）
        let err = LauncherError.systemCommandFailed("锁定屏幕")
        guard let desc = err.errorDescription else {
            XCTFail("SC7 / 场景 6.E1: LauncherError.systemCommandFailed 必须有 errorDescription")
            return
        }

        // 含 CJK 字符（U+4E00–U+9FFF）
        let hasCJK = desc.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF }
        XCTAssertTrue(hasCJK,
            "SC7 / 场景 6.E1: errorDescription 必须含 CJK 字符（中文文案），实际：\"\(desc)\"")

        // 文案长度 ≥ 4（非空短串）
        XCTAssertGreaterThanOrEqual(desc.count, 4,
            "SC7 / 场景 6.E1: errorDescription 长度必须 ≥ 4，实际 \(desc.count)")
    }

    // MARK: 场景 6.N1 + SC7：文案非全 ASCII（不裸透传英文 error）

    /// 场景 6.N1 + SC7：错误文案不全是 ASCII（不能裸透传英文 error message）
    ///
    /// Mutation-Survival 自检：
    /// - 裸英文 mutant → isAllASCII 为 true → 本断言失败（捕获）
    func test_SC7_systemCommandFailed_errorDescription_notAllASCII() {
        let err = LauncherError.systemCommandFailed("锁定屏幕")
        guard let desc = err.errorDescription else {
            XCTFail("SC7 / 场景 6.N1 precondition: 必须有 errorDescription")
            return
        }

        let isAllASCII = desc.unicodeScalars.allSatisfy { $0.value < 128 }
        XCTAssertFalse(isAllASCII,
            "SC7 / 场景 6.N1: errorDescription 不能全是 ASCII（不能裸透传英文 error），实际：\"\(desc)\"")
    }

    // MARK: 场景 6.E3：抛错时 stage=.error（通过 LauncherManager 集成路径验证）

    /// 场景 6.E3：seam 抛错 → LauncherManager.performSelectedInstantAction() 捕获 → lastInstantError 非 nil
    ///
    /// Mutation-Survival 自检：
    /// - 静默吞错 mutant（catch{} 不设置 lastInstantError）→ lastInstantError 仍 nil → 本断言失败（捕获）
    func test_SC7_scenario6E3_seamThrows_launcherManagerSetsLastInstantError() async {
        let stub = FailingScreenLocker()
        let plugin = SystemCommandPlugin(locker: stub)

        // 用 BuiltinPluginRegistry 注入含抛错 lock action 的 system plugin
        let registry = BuiltinPluginRegistry(plugins: [plugin])
        LauncherManager.shared.registryOverride = registry
        LauncherManager.shared.instantDebounceMsOverride = 0

        LauncherManager.shared.updateQuery("lock")
        await Task.yield()

        guard !LauncherManager.shared.instantActions.isEmpty else {
            XCTFail("场景 6.E3 precondition: instantActions 必须非空（system plugin 应产出 lock 候选）")
            LauncherManager.shared.registryOverride = nil
            LauncherManager.shared.instantDebounceMsOverride = nil
            return
        }

        // 模拟按 Enter（会 throw，LauncherManager 捕获）
        let consumed = LauncherManager.shared.performSelectedInstantAction()

        XCTAssertTrue(consumed,
            "场景 6.E3: 即使 seam 抛错，内置管线仍算消费（返回 true）")

        // lastInstantError 必须被设置（不静默关闭，不吞错）
        XCTAssertNotNil(LauncherManager.shared.lastInstantError,
            "场景 6.E3: seam 抛错时 LauncherManager.lastInstantError 必须被设置（浮窗不静默关闭），实际为 nil")

        // Cleanup
        LauncherManager.shared.registryOverride = nil
        LauncherManager.shared.instantDebounceMsOverride = nil
        LauncherManager.shared.hide()
    }
}

// MARK: - SC8 + 场景 7：Registry 仲裁（系统候选置顶）

@MainActor
final class SystemCommandPluginRegistryArbitrationAcceptanceTests: XCTestCase {

    // MARK: 场景 7.P1 + SC8：仲裁后系统候选 index==0（priority 100 最高）

    /// 场景 7.P1 + SC8：注入含 lock 关键词的 mock app 候选 + 系统候选，
    /// 仲裁后系统候选排 index==0（priority 100 > app priority 0）
    ///
    /// Mutation-Survival 自检：
    /// - priority 值错误 mutant（system priority==0）→ index(system)>index(app) → 本断言失败（捕获）
    /// - 排序反向 mutant → result[0].pluginId != "system-command" → 本断言失败（捕获）
    func test_SC8_scenario7P1_systemCandidateFirst_afterArbitration() async {
        // mock app 候选（priority=0，分高）
        let appPlugin = MockBuiltinPlugin_System(
            id: "app-launcher",
            priority: 0,
            sectionTitle: "应用",
            actions: [
                LauncherAction(id: "app-lock", title: "LockApp", subtitle: nil, icon: nil,
                               pluginId: "app-launcher", score: 1000, perform: {})
            ]
        )

        // system 候选（priority=100，分低）
        let spy = LockScreenSpy()
        let systemPlugin = SystemCommandPlugin(locker: spy)

        let registry = BuiltinPluginRegistry(plugins: [appPlugin, systemPlugin])
        let result = await registry.actions(for: "lock")

        guard !result.isEmpty else {
            XCTFail("SC8 / 场景 7.P1 precondition: 仲裁结果不能为空")
            return
        }

        // 场景 7.P1：系统候选 index==0
        XCTAssertEqual(result[0].pluginId, "system-command",
            "SC8 / 场景 7.P1: 仲裁后 result[0] 必须来自 system-command（priority 100），实际 pluginId=\(result[0].pluginId)")
    }

    // MARK: 场景 7.P2 + SC8：系统候选 index < 首个非系统候选 index

    /// 场景 7.P2 + SC8：系统候选的所有 index 都小于首个 app 候选 index
    func test_SC8_scenario7P2_systemIndex_before_appIndex() async {
        let appPlugin = MockBuiltinPlugin_System(
            id: "app-launcher",
            priority: 0,
            sectionTitle: "应用",
            actions: [
                LauncherAction(id: "app1", title: "Lock Screen Simulator", subtitle: nil, icon: nil,
                               pluginId: "app-launcher", score: 500, perform: {})
            ]
        )

        let spy = LockScreenSpy()
        let systemPlugin = SystemCommandPlugin(locker: spy)

        let registry = BuiltinPluginRegistry(plugins: [appPlugin, systemPlugin])
        let result = await registry.actions(for: "lock")

        let systemIndices = result.enumerated().filter { $0.element.pluginId == "system-command" }.map { $0.offset }
        let appIndices    = result.enumerated().filter { $0.element.pluginId == "app-launcher" }.map { $0.offset }

        guard let lastSystemIdx = systemIndices.max(),
              let firstAppIdx   = appIndices.min()
        else {
            XCTFail("SC8 / 场景 7.P2 precondition: system 和 app 候选都必须出现在结果中")
            return
        }

        XCTAssertLessThan(lastSystemIdx, firstAppIdx,
            "SC8 / 场景 7.P2: 系统候选最后位置(\(lastSystemIdx)) 必须 < app 候选最先位置(\(firstAppIdx))")
    }

    // MARK: 场景 1.P3 + SC8：Registry 排序结果 index(system) < index(app)

    /// 场景 1.P3：Registry 排序后，系统候选 index 小于最前 app 候选 index
    func test_SC8_scenario1P3_registrySorting_systemBeforeApp() async {
        let appPlugin = MockBuiltinPlugin_System(
            id: "app-launcher",
            priority: 0,
            sectionTitle: "应用",
            actions: [
                LauncherAction(id: "app-lock", title: "MockApp", subtitle: nil, icon: nil,
                               pluginId: "app-launcher", score: 999, perform: {})
            ]
        )

        let systemPlugin = SystemCommandPlugin(locker: LockScreenSpy())
        let registry = BuiltinPluginRegistry(plugins: [appPlugin, systemPlugin])
        let result = await registry.actions(for: "lock")

        let systemIdx = result.firstIndex { $0.pluginId == "system-command" }
        let appIdx    = result.firstIndex { $0.pluginId == "app-launcher" }

        guard let si = systemIdx, let ai = appIdx else {
            XCTFail("场景 1.P3 precondition: 系统和 app 候选都必须出现")
            return
        }

        XCTAssertLessThan(si, ai,
            "场景 1.P3: 系统候选 index(\(si)) 必须 < app 候选 index(\(ai))（priority 100 > 0）")
    }
}

// MARK: - SC9：不触碰像素猫子系统 + 隔离验证

@MainActor
final class SystemCommandPluginIsolationAcceptanceTests: XCTestCase {

    // MARK: SC9：System/ 源码不引用像素猫符号（文件系统扫描）

    /// SC9：Launcher/Builtin/System/ 下的 .swift 文件不得引用像素猫子系统类型
    func test_SC9_systemSources_noDependencyOn_pixelCatTypes() throws {
        let systemDir = Self.systemSourceDir()

        // 如果 System/ 目录尚未创建（蓝队未合并），跳过
        guard let dir = systemDir else {
            throw XCTSkip("System/ 源码目录尚不存在，蓝队合并后运行")
        }

        guard let enumerator = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw XCTSkip("无法枚举 System/ 目录")
        }

        let forbiddenSymbols = [
            "SessionManager",
            "BuddyScene",
            "CatSprite",
            "FoodManager",
            "BuddyEvent",
            "SocketServer",
            "EventBus",
        ]

        var scannedFiles = 0
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "swift" else { continue }
            scannedFiles += 1
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            for symbol in forbiddenSymbols {
                XCTAssertFalse(
                    content.contains(symbol),
                    "SC9: System 源文件 '\(fileURL.lastPathComponent)' 引用了像素猫符号 '\(symbol)'，必须完全隔离"
                )
            }
        }

        // 如果 System/ 存在但为空（蓝队刚新建目录），跳过内容检查
        if scannedFiles == 0 {
            throw XCTSkip("System/ 目录存在但无 .swift 文件，蓝队合并后运行")
        }
    }

    // MARK: SC9：mock seam 不触真锁屏（spy callCount 验证）

    /// SC9：测试全程使用 mock seam，spy.callCount 反映的是 mock 调用，不是真实系统锁屏
    func test_SC9_mockSeam_noRealLockScreen() async throws {
        let spy = LockScreenSpy()
        let plugin = SystemCommandPlugin(locker: spy)

        let actions = await plugin.actions(for: "lock")
        guard let lockAction = actions.first(where: { $0.title == "锁定屏幕" }) else {
            XCTFail("SC9 precondition: 必须有锁屏候选")
            return
        }

        // 用 spy 执行，callCount==1 说明调用的是 mock，不是真实系统锁屏
        try lockAction.perform()

        XCTAssertEqual(spy.callCount, 1,
            "SC9: perform() 后 spy.callCount==1，确认用的是 mock seam（不真锁屏）")
    }

    // MARK: 辅助：定位 System 源码目录

    private static func systemSourceDir() -> URL? {
        let thisFile = URL(fileURLWithPath: #file)
        let desktopDir = thisFile
            .deletingLastPathComponent()  // Launcher/
            .deletingLastPathComponent()  // BuddyCoreTests/
            .deletingLastPathComponent()  // tests/
            .deletingLastPathComponent()  // apps/desktop/

        let systemDir = desktopDir
            .appendingPathComponent("Sources")
            .appendingPathComponent("ClaudeCodeBuddy")
            .appendingPathComponent("Launcher")
            .appendingPathComponent("Builtin")
            .appendingPathComponent("System")

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: systemDir.path, isDirectory: &isDir),
              isDir.boolValue else {
            return nil
        }
        return systemDir
    }
}

// MARK: - Extra：reset() 后默认列表仍含 system-command 插件（防 flaky）

@MainActor
final class SystemCommandPluginRegistryResetAcceptanceTests: XCTestCase {

    // MARK: Extra：reset() 后默认列表含 system-command

    /// 防 flaky：BuiltinPluginRegistry.shared.reset() 后，默认列表仍含 system-command 插件
    /// （实现计划步骤4：init 与 reset 两处都追加 SystemCommandPlugin.shared）
    ///
    /// Mutation-Survival 自检：
    /// - 只改 init 漏 reset 的 mutant → reset 后 system-command 消失 → 本断言失败（捕获）
    func test_extra_reset_stillContainsSystemCommandPlugin() {
        BuiltinPluginRegistry.shared.reset()

        let hasSystemPlugin = BuiltinPluginRegistry.shared.plugins.contains { $0.id == "system-command" }
        XCTAssertTrue(hasSystemPlugin,
            "Extra（防 flaky）: reset() 后默认插件列表必须仍含 id==\"system-command\" 的插件，实际 plugins=\(BuiltinPluginRegistry.shared.plugins.map { $0.id })")
    }

    // MARK: Extra：初始化后默认列表含 system-command

    /// BuiltinPluginRegistry 默认初始化（plugins==nil）时包含 SystemCommandPlugin
    func test_extra_defaultInit_containsSystemCommandPlugin() {
        let registry = BuiltinPluginRegistry()

        let hasSystemPlugin = registry.plugins.contains { $0.id == "system-command" }
        XCTAssertTrue(hasSystemPlugin,
            "Extra: 默认初始化的 Registry 必须含 system-command 插件，实际 plugins=\(registry.plugins.map { $0.id })")
    }

    // MARK: Extra：reset 后调用 actions(for:\"lock\") 仍产出锁屏候选

    /// reset 后内置管线仍可正常响应 "lock" 查询，不因 reset 导致 system-command 插件消失
    func test_extra_afterReset_lockQueryStillProducesCandidate() async {
        BuiltinPluginRegistry.shared.reset()

        let result = await BuiltinPluginRegistry.shared.actions(for: "lock")

        let hasLockScreen = result.contains { $0.title == "锁定屏幕" }
        XCTAssertTrue(hasLockScreen,
            "Extra（防 flaky）: reset() 后 actions(for:\"lock\") 必须仍含 \"锁定屏幕\" 候选（system-command 未被 reset 清除），实际 result.count=\(result.count)")
    }
}

// MARK: - SC9 / 场景 9：debounce 期间不重复触发（既有 debounce 行为验证）

@MainActor
final class SystemCommandPluginDebounceAcceptanceTests: XCTestCase {

    // MARK: 场景 9.P1：debounce 窗口内连续追加仅触发最终态

    /// 场景 9.P1：连续 l→lo→loc→lock 输入，稳定后 instantActions 是最终态（lock 的候选），
    /// 验证本插件不引入额外触发（与既有 debounce 行为兼容）
    func test_SC9_debounce_consecutiveInput_onlyFinalStateTriggered() async {
        let spy = LockScreenSpy()
        let systemPlugin = SystemCommandPlugin(locker: spy)
        let registry = BuiltinPluginRegistry(plugins: [systemPlugin])

        LauncherManager.shared.registryOverride = registry
        LauncherManager.shared.instantDebounceMsOverride = 0

        // 模拟连续追加输入（debounce=0 时每次都会触发，最终 lock 是最后一次）
        LauncherManager.shared.updateQuery("l")
        LauncherManager.shared.updateQuery("lo")
        LauncherManager.shared.updateQuery("loc")
        LauncherManager.shared.updateQuery("lock")

        // 有界等待，最多 2s
        for _ in 0..<200 where !LauncherManager.shared.instantActions.contains(where: { $0.title == "锁定屏幕" }) {
            try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms
        }

        // 稳定后最终态：lock 的候选（"锁定屏幕"）
        let hasLockScreen = LauncherManager.shared.instantActions.contains { $0.title == "锁定屏幕" }
        XCTAssertTrue(hasLockScreen,
            "场景 9.P1: 连续输入稳定后 instantActions 必须含 \"锁定屏幕\" 候选（最终态 lock），实际 \(LauncherManager.shared.instantActions.count) 条")

        // spy.callCount 仍为 0（actions 查询不触发锁屏）
        XCTAssertEqual(spy.callCount, 0,
            "场景 9.P1: debounce 过程中 spy.callCount 必须仍为 0（actions 查询不触发锁屏），实际 \(spy.callCount)")

        // Cleanup
        LauncherManager.shared.registryOverride = nil
        LauncherManager.shared.instantDebounceMsOverride = nil
    }
}

// MARK: - 私有 Mock（仅 SC8 仲裁测试使用）

/// SC8 测试专用：固定返回预设候选的 app-launcher mock 插件
@MainActor
private final class MockBuiltinPlugin_System: BuiltinPlugin {
    let id: String
    let priority: Int
    let sectionTitle: String
    private let fixedActions: [LauncherAction]

    init(id: String, priority: Int, sectionTitle: String, actions: [LauncherAction]) {
        self.id = id
        self.priority = priority
        self.sectionTitle = sectionTitle
        self.fixedActions = actions
    }

    func actions(for query: String) async -> [LauncherAction] {
        guard !query.isEmpty else { return [] }
        return fixedActions
    }
}
