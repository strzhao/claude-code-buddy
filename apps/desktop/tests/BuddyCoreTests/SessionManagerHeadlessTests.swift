import XCTest
@testable import BuddyCore

/// 蓝队单测：headless 检测管线状态机（C-HEADLESS-DETECT / C-HEADLESS-NOCAT /
/// C-HEADLESS-NO-TERMINAL / C-HEADLESS-CLEANUP / C-NO-CAP / C-COLOR-REUSE）。
/// 用 Mock resolver/checker 驱动各判型分支，断言 mock scene 的调用序列。
final class SessionManagerHeadlessTests: XCTestCase {

    var scene: MockScene!
    var manager: SessionManager!
    var resolver: MockHeadlessResolver!
    var checker: MockHeadlessChecker!

    override func setUp() {
        super.setUp()
        scene = MockScene()
        resolver = MockHeadlessResolver(entry: nil)
        checker = MockHeadlessChecker(verdict: .interactive)
        manager = SessionManager(scene: scene, headlessResolver: resolver, headlessChecker: checker)
        try? FileManager.default.removeItem(atPath: SessionManager.colorFilePath)
    }

    override func tearDown() {
        TestHelpers.settleHeadlessDetection(manager)
        try? FileManager.default.removeItem(atPath: SessionManager.colorFilePath)
        super.tearDown()
    }

    private func register(_ sessionId: String, terminalId: String? = nil, event: String = "session_start") {
        manager.handle(message: TestHelpers.makeMessage(
            sessionId: sessionId, event: event, cwd: "/p/\(sessionId)", terminalId: terminalId))
    }

    // MARK: - C-HEADLESS-NOCAT：pending 不上猫（显式断言 mock scene 零 addCat）

    func testPendingDoesNotAddCat() {
        resolver.entry = HeadlessRegistryEntry(pid: 42, procStart: nil)
        checker.verdict = .interactive   // 判型未落定前

        register("s1")
        // 不 settle：handle 同步返回后仍 pending，mock scene 不得收到 addCat
        XCTAssertEqual(scene.addCatCalls.count, 0,
                       "pending 期间不得上猫（防闪猫，C-HEADLESS-NOCAT）")
        XCTAssertEqual(manager.sessions["s1"]?.headlessState, .pending)

        TestHelpers.settleHeadlessDetection(manager)
        XCTAssertEqual(scene.addCatCalls.count, 1, "判型 interactive 落定后上屏")
        XCTAssertEqual(manager.sessions["s1"]?.headlessState, .interactive)
    }

    func testInteractiveVerdictAddsCatAndReplaysState() {
        resolver.entry = HeadlessRegistryEntry(pid: 42, procStart: nil)
        checker.verdict = .interactive

        // 判型未落定期间先推进状态（猫不在场，updateCatState 为 no-op）
        register("s1", event: "session_start")
        manager.handle(message: TestHelpers.makeMessage(sessionId: "s1", event: "thinking"))

        TestHelpers.settleHeadlessDetection(manager)

        XCTAssertEqual(scene.addCatCalls.count, 1)
        // 上屏后必须补放 pending 期间错过的状态迁移（防猫永久 idle 假态）
        let lastState = scene.updateStateCalls.last
        XCTAssertEqual(lastState?.sessionId, "s1")
        XCTAssertEqual(lastState?.state, .thinking)
    }

    func testFailOpenWhenRegistryMissing() {
        resolver.entry = nil   // 注册表无匹配（重试耗尽后）
        register("s1")
        TestHelpers.settleHeadlessDetection(manager)

        XCTAssertEqual(scene.addCatCalls.count, 1, "resolve 失败 → fail-open interactive 上屏")
        XCTAssertEqual(manager.sessions["s1"]?.headlessState, .interactive)
    }

    func testUnknownVerdictFailsOpen() {
        resolver.entry = HeadlessRegistryEntry(pid: 42, procStart: nil)
        checker.verdict = .unknown   // ps 失败等
        register("s1")
        TestHelpers.settleHeadlessDetection(manager)

        XCTAssertEqual(scene.addCatCalls.count, 1, "unknown → fail-open 非 headless")
        XCTAssertEqual(manager.sessions["s1"]?.headlessState, .interactive)
    }

    func testHeadlessVerdictNeverAddsCat() {
        resolver.entry = HeadlessRegistryEntry(pid: 42, procStart: nil)
        checker.verdict = .interactive
        for i in 1...2 { register("base\(i)") }   // 交互基线
        TestHelpers.settleHeadlessDetection(manager)
        XCTAssertEqual(scene.addCatCalls.count, 2)

        checker.verdict = .headless   // 切判型：bg 为后台任务
        register("bg")
        TestHelpers.settleHeadlessDetection(manager)

        // C-HEADLESS-NOCAT：不上猫、不驱逐其他猫
        XCTAssertEqual(scene.addCatCalls.count, 2, "headless 会话不得 addCat")
        XCTAssertEqual(scene.removeCatCalls.filter { $0 != "bg" }.count, 0,
                       "headless 会话不得触发对其他猫的驱逐")
        XCTAssertEqual(manager.sessions["bg"]?.headlessState, .headless)
        XCTAssertNotNil(manager.sessions["bg"], "后台会话仍登记在册（popover 展示）")
    }

    func testDeadVerdictRemovesSessionWithoutCat() {
        resolver.entry = HeadlessRegistryEntry(pid: 999_999, procStart: nil)
        checker.verdict = .processDead
        register("s1")
        TestHelpers.settleHeadlessDetection(manager)

        XCTAssertNil(manager.sessions["s1"], "ESRCH 判 dead → 按 C-HEADLESS-CLEANUP 清理")
        XCTAssertTrue(scene.addCatCalls.isEmpty, "dead 会话不上猫")
    }

    // MARK: - 每 session 至多检测一次（结果缓存）

    func testDetectionRunsOnlyOncePerSession() {
        resolver.entry = HeadlessRegistryEntry(pid: 42, procStart: nil)
        checker.verdict = .interactive
        register("s1")
        TestHelpers.settleHeadlessDetection(manager)

        // 后续消息不得再触发检测
        let callsBefore = resolver.resolveCalls.count
        register("s1", event: "thinking")
        register("s1", event: "idle")
        TestHelpers.settleHeadlessDetection(manager)

        XCTAssertEqual(resolver.resolveCalls.count, callsBefore,
                       "每 session 至多检测一次（结果缓存于 SessionInfo）")
        XCTAssertEqual(scene.addCatCalls.count, 1, "不重复上猫")
    }

    // MARK: - C-HEADLESS-NO-TERMINAL：创建/更新分支 dual-path 双堵

    func testTerminalIdCreationBranchStashedThenAppliedForInteractive() {
        var tabTitleEvents: [SessionInfo] = []
        manager.onSessionNeedsTabTitle = { tabTitleEvents.append($0) }
        resolver.entry = nil
        checker.verdict = .interactive

        register("s1", terminalId: "tab-1")
        // pending 期间：不存储、不触发
        XCTAssertNil(manager.sessions["s1"]?.terminalId, "pending 期间 terminal_id 不得存储")
        XCTAssertTrue(tabTitleEvents.isEmpty, "pending 期间不得触发 tab title")

        TestHelpers.settleHeadlessDetection(manager)
        XCTAssertEqual(manager.sessions["s1"]?.terminalId, "tab-1", "判型 interactive 后应用暂存 tid")
        XCTAssertEqual(tabTitleEvents.count, 1, "应用时触发一次 tab title 同步")
        XCTAssertEqual(tabTitleEvents.first?.terminalId, "tab-1")
    }

    func testTerminalIdDiscardedForHeadless() {
        var tabTitleEvents: [SessionInfo] = []
        manager.onSessionNeedsTabTitle = { tabTitleEvents.append($0) }
        resolver.entry = HeadlessRegistryEntry(pid: 42, procStart: nil)
        checker.verdict = .headless

        register("bg", terminalId: "ghostty-fallback-tab-1")
        TestHelpers.settleHeadlessDetection(manager)

        XCTAssertNil(manager.sessions["bg"]?.terminalId,
                     "headless 创建分支不存储 terminal_id（S4-P3：缺省形态）")
        XCTAssertTrue(tabTitleEvents.isEmpty, "headless 会话不得触发 tab title 写入（S4-P1）")
    }

    func testTerminalIdUpdateBranchBlockedForHeadless() {
        resolver.entry = HeadlessRegistryEntry(pid: 42, procStart: nil)
        checker.verdict = .headless

        register("bg")   // 无 tid 创建
        TestHelpers.settleHeadlessDetection(manager)   // 判定 headless

        // 更新分支：headless 判定后 hook 再发 tid → 不存储
        register("bg", terminalId: "ghostty-fallback-tab-2", event: "thinking")
        TestHelpers.settleHeadlessDetection(manager)

        XCTAssertNil(manager.sessions["bg"]?.terminalId,
                     "headless 更新分支同样不存储（dual-path 双堵）")
    }

    func testTerminalIdUpdateBranchStashedWhilePending() {
        resolver.entry = nil
        register("s1")   // pending（未 settle）
        register("s1", terminalId: "real-tab", event: "thinking")

        XCTAssertNil(manager.sessions["s1"]?.terminalId, "pending 更新分支只暂存不存储")
        TestHelpers.settleHeadlessDetection(manager)
        XCTAssertEqual(manager.sessions["s1"]?.terminalId, "real-tab",
                       "暂存 tid 在判型 interactive 后应用")
    }

    // MARK: - C-NO-CAP + 检测链共存

    func testNineInteractiveSessionsAllOnScreen() {
        resolver.entry = nil
        for i in 1...9 { register("s\(i)") }
        TestHelpers.settleHeadlessDetection(manager)

        XCTAssertEqual(scene.addCatCalls.count, 9, "C-NO-CAP：9 个交互会话全部上屏")
        XCTAssertTrue(scene.removeCatCalls.isEmpty, "无满员驱逐")
    }

    // MARK: - C-COLOR-REUSE

    func testColorReuseWhenPoolExhausted() {
        resolver.entry = nil
        for i in 1...9 { register("s\(i)") }
        TestHelpers.settleHeadlessDetection(manager)

        let holderCount = Dictionary(grouping: manager.sessions.values, by: { $0.color })
            .mapValues(\.count)
        XCTAssertEqual(holderCount.values.reduce(0, +), 9)
        XCTAssertEqual(Set(manager.sessions.values.map(\.color)).count, 8,
                       "第 9 会话必须复用既有色")
        XCTAssertEqual(manager.usedColors.count, 8, "复用态 8 色全部 in-use")
    }

    func testReleaseColorKeptWhileOtherHolderExists() {
        resolver.entry = nil
        for i in 1...9 { register("s\(i)") }
        TestHelpers.settleHeadlessDetection(manager)

        let counts = Dictionary(grouping: manager.sessions.values, by: { $0.color })
        let sharedColor = counts.first(where: { $0.value.count == 2 })?.key
        XCTAssertNotNil(sharedColor, "前提：应恰有一色被两个会话持有")
        let holders = counts[sharedColor!]!.map(\.sessionId)

        register(holders[0], event: "session_end")
        XCTAssertTrue(manager.usedColors.contains(sharedColor!),
                      "共享色仍有持有者时不得回收（C-COLOR-REUSE）")
        register(holders[1], event: "session_end")
        XCTAssertFalse(manager.usedColors.contains(sharedColor!),
                       "最后一个持有者结束后颜色回收")
    }

    // MARK: - C-HEADLESS-CLEANUP：headless 短路清理

    private func makeHeadlessSession(_ sessionId: String, pid: Int, procStart: String? = nil) {
        resolver.entry = HeadlessRegistryEntry(pid: pid, procStart: procStart)
        checker.verdict = .headless
        register(sessionId)
        TestHelpers.settleHeadlessDetection(manager)
    }

    func testHeadlessDeadProcessRemovedAtIdleThreshold() {
        makeHeadlessSession("bg", pid: 999_999)

        // idle 6 分钟（> 5 分钟 idle 阈值，< 30 分钟 removeTimeout）
        manager.sessions["bg"]?.lastActivity = Date(timeIntervalSinceNow: -(6 * 60))
        manager.checkTimeouts()

        XCTAssertNil(manager.sessions["bg"],
                     "headless 进程死亡 + idle 超阈值 → 移除（不受 30min removeTimeout 制约）")
        XCTAssertTrue(scene.addCatCalls.isEmpty, "headless 全程无猫（MockScene 会记录无猫 removeCat，生产为 no-op）")
    }

    func testHeadlessAliveProcessKeptPastRemoveTimeout() {
        // 用当前测试进程 pid：必然存活；procStart 匹配 → 视为存活
        let pid = Int(ProcessInfo.processInfo.processIdentifier)
        checker.startTime = "Thu Sep 17 13:22:30 2026"
        makeHeadlessSession("bg", pid: pid, procStart: "Thu Sep 17 13:22:30 2026")

        // 超过 30 分钟 removeTimeout——headless 不受其制约：存活即保留
        manager.sessions["bg"]?.lastActivity = Date(timeIntervalSinceNow: -(31 * 60))
        manager.checkTimeouts()

        XCTAssertNotNil(manager.sessions["bg"],
                       "headless 进程存活 → 保留（即使超 30min removeTimeout）")
        XCTAssertEqual(manager.sessions["bg"]?.state, .idle, "idle 超阈值状态转 idle（popover 诚实显示）")
    }

    func testHeadlessPidReuseDetectedByProcStartMismatch() {
        // pid 存活（当前进程），但 procStart 与记录不符 → pid 已被复用 → 原进程已死
        let pid = Int(ProcessInfo.processInfo.processIdentifier)
        checker.startTime = "Fri Sep 18 00:00:00 2026"   // ≠ 记录值
        makeHeadlessSession("bg", pid: pid, procStart: "Thu Sep 17 13:22:30 2026")

        manager.sessions["bg"]?.lastActivity = Date(timeIntervalSinceNow: -(6 * 60))
        manager.checkTimeouts()

        XCTAssertNil(manager.sessions["bg"],
                     "procStart 比对不一致（pid 复用）→ 视为进程死亡，执行清理")
    }

    func testHeadlessFreshSessionNotProbed() {
        makeHeadlessSession("bg", pid: 999_999)   // 进程已死但尚未 idle
        manager.checkTimeouts()

        XCTAssertNotNil(manager.sessions["bg"],
                        "未到 idle 阈值（5 分钟）不探测不清理")
    }

    func testInteractiveSessionCleanupBehaviorUnchanged() {
        // 交互会话（fail-open）idle 6 分钟 + 进程死亡 → 仍保留（30min 规则不变）
        resolver.entry = nil
        checker.verdict = .interactive
        register("s1")
        manager.sessions["s1"]?.pid = 999_999
        TestHelpers.settleHeadlessDetection(manager)

        manager.sessions["s1"]?.lastActivity = Date(timeIntervalSinceNow: -(6 * 60))
        manager.checkTimeouts()

        XCTAssertNotNil(manager.sessions["s1"],
                        "交互会话 6 分钟 idle 不得被 headless 短路清理误伤")
    }

    // MARK: - debug- / CLI 会话 fail-open（C-BACKCOMPAT）

    func testDebugSessionFailOpenOnScreen() {
        resolver.entry = nil   // debug-A 无注册表文件
        register("debug-A")
        TestHelpers.settleHeadlessDetection(manager)

        XCTAssertEqual(scene.addCatCalls.count, 1, "debug 猫 fail-open 照常上屏")
        XCTAssertEqual(manager.sessions["debug-A"]?.headlessState, .interactive)
        XCTAssertEqual(manager.sessions["debug-A"]?.isHeadless, false)
    }

    // MARK: - C-INSPECT-FIELD：inspect 字段

    @MainActor
    func testInspectExposesIsHeadlessAndOnscreen() async {
        resolver.entry = HeadlessRegistryEntry(pid: 42, procStart: nil)
        checker.verdict = .headless
        register("bg")
        await TestHelpers.settleHeadlessDetectionAsync(manager)

        let handler = QueryHandler(sessionManager: manager, scene: scene, eventStore: manager.eventStore)
        let data = await handler.handle(query: ["action": "inspect", "session_id": "bg"])
        let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        let session = ((json["data"] as! [String: Any])["session"] as! [String: Any])

        XCTAssertEqual(session["is_headless"] as? Bool, true)
        XCTAssertEqual(session["onscreen"] as? Bool, false, "headless 无猫 → onscreen false")
        XCTAssertNil(session["terminal_id"])
    }

    @MainActor
    func testInspectAllExposesFieldsForBothGroups() async {
        resolver.entry = nil
        register("i1")
        await TestHelpers.settleHeadlessDetectionAsync(manager)
        scene.stubbedCatSnapshots["i1"] = CatSnapshot(
            sessionId: "i1", x: 100, y: 24, state: "idle", facingRight: true,
            isDebug: false, activityBoundsMin: 48, activityBoundsMax: 752,
            labelText: "i1", tabName: nil, hasAlertOverlay: false,
            hasPersistentBadge: false, hasUpdateBadge: false, permissionAcknowledged: false)

        let handler = QueryHandler(sessionManager: manager, scene: scene, eventStore: manager.eventStore)
        let data = await handler.handle(query: ["action": "inspect"])
        let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        let sessions = (json["data"] as! [String: Any])["sessions"] as! [[String: Any]]

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0]["is_headless"] as? Bool, false)
        XCTAssertEqual(sessions[0]["onscreen"] as? Bool, true)
    }

    // MARK: - color 文件 headless 标记（buddy status 数据源）

    func testColorFileCarriesHeadlessMarker() throws {
        makeHeadlessSession("bg", pid: 42)
        let data = try Data(contentsOf: URL(fileURLWithPath: SessionManager.colorFilePath))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: [String: String]])
        XCTAssertEqual(json["bg"]?["headless"], "yes")
    }
}
