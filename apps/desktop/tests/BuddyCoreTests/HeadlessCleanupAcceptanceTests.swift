import XCTest
@testable import BuddyCore

// MARK: - HeadlessCleanupAcceptanceTests
//
// 红队验收测试 —— 冻结谓词 SSOT：`.autopilot/runtime/requirements/20260917-开始实现/state.md`
//
// 覆盖谓词（S8 后台任务异常退出 kill 的终态与清理）：
//   S8-P1 [det-machine] 后台进程被 kill → 该会话离开后台分组（终态 ∈ {removed, exited, failed}，
//                       in-process 断言面 = sessions 中条目移除）
//   S8-P2 [det-machine] 后台进程被 kill → 上屏猫集合不变（无幽灵猫）
//   S8-P3 [det-machine] 后台进程被 kill → 无关联该会话的 tab title 写入/终端跳转事件
//   C-HEADLESS-CLEANUP（契约）headless 不依赖 SessionEnd hook 也可清理——idle（5 分钟无 hook
//                       活动）后 kill(pid,0) 探测，进程死亡即移除（不受 30 分钟 removeTimeout
//                       制约；交互会话清理行为不变）
//
// 加速手段（场景 S8 编排器注明允许）：「临时会话直接构造 idle 态」——直接改
// lastActivity 至 idle 阈值（5 分钟）之外、removeTimeout（30 分钟）之内，再调 checkTimeouts()。
// 时序依赖：kill 必须发生在判型完成之后（RedTeamAcceptance.headlessVerdictWindow），
// 否则 ps 探测失败会按契约 fail-open 成 interactive。

@MainActor
final class HeadlessCleanupAcceptanceTests: XCTestCase {

    var scene: MockScene!
    var manager: SessionManager!
    var tabTitleEvents: [SessionInfo] = []

    override func setUp() {
        super.setUp()
        scene = MockScene()
        manager = SessionManager(scene: scene)
        tabTitleEvents = []
        manager.onSessionNeedsTabTitle = { [weak self] info in
            self?.tabTitleEvents.append(info)
        }
        try? FileManager.default.removeItem(atPath: SessionManager.colorFilePath)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: SessionManager.colorFilePath)
        super.tearDown()
    }

    // MARK: - S8-P1 + S8-P2 + S8-P3 kill 后终态移除、无幽灵猫、无污染

    /// 后台会话（真实 -p 进程 + 注册表文件）→ 判型窗口后 kill 进程 → 构造 idle 态
    /// （6 分钟 > 5 分钟 idle 阈值，< 30 分钟 removeTimeout）→ checkTimeouts()：
    /// ① 会话从 sessions 移除（终态 removed）；② 上屏集合不变（从未上屏 + 无 removeCat 补偿）；
    /// ③ 零 tab title 写入事件。
    func testS8_KilledBackgroundProcessRemovedAtIdleThresholdWithoutGhostCatOrPollution() throws {
        let fixture = try RedTeamHeadlessFixture(
            sessionId: RedTeamAcceptance.uniqueSessionId("killed-bg"), argvToken: "-p")
        defer { fixture.cleanup() }

        manager.handle(message: RedTeamAcceptance.makeHookMessage(
            sessionId: fixture.sessionId, event: "session_start", cwd: "/projects/killed-bg"
        ))
        manager.handle(message: RedTeamAcceptance.makeHookMessage(
            sessionId: fixture.sessionId, event: "thinking", terminalId: "ghostty-fallback-tab-9"
        ))

        // 等判型完成（headless → 不上屏）
        Thread.sleep(forTimeInterval: RedTeamAcceptance.headlessVerdictWindow)
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))

        let onScreenBeforeKill = Set(scene.addCatCalls.map(\.sessionId))
        XCTAssertFalse(onScreenBeforeKill.contains(fixture.sessionId),
                       "前提：后台会话判型后不上屏")
        XCTAssertEqual(manager.sessions[fixture.sessionId]?.state, .thinking,
                       "前提：会话仍登记在册")

        // 异常退出：kill 进程（非 session_end hook 路径）
        fixture.killProcess()

        // 构造 idle 态：6 分钟无 hook 活动（> 5 分钟 idle 阈值；< 30 分钟 removeTimeout）
        manager.sessions[fixture.sessionId]?.lastActivity = Date(timeIntervalSinceNow: -(6 * 60))
        manager.checkTimeouts()

        // S8-P1：终态 = removed（离开后台分组/sessions）
        XCTAssertNil(manager.sessions[fixture.sessionId],
                     "headless 进程死亡 + idle 超阈值后，会话必须被清理（不受 30 分钟 removeTimeout 制约）")

        // S8-P2：上屏猫集合不变（无幽灵猫——既从未上屏，也不因清理误 add/remove 其他猫）
        let onScreenAfterKill = Set(scene.addCatCalls.map(\.sessionId))
        XCTAssertEqual(onScreenAfterKill, onScreenBeforeKill,
                       "kill 清理前后上屏猫集合必须不变")
        XCTAssertFalse(scene.addCatCalls.contains { $0.sessionId == fixture.sessionId },
                       "后台会话全程不得上屏（<bg-id> 不在 onscreen 集合）")

        // S8-P3：无关联该会话的 tab title 写入 / 终端跳转事件
        let polluted = tabTitleEvents.filter { $0.sessionId == fixture.sessionId }
        XCTAssertEqual(polluted.count, 0,
                       "kill 前后不得产生关联该会话的 tab title 写入事件（polluted_event_count == 0）")
    }

    // MARK: - C-HEADLESS-CLEANUP 交互会话清理行为不变

    /// 交互会话（fail-open interactive，hook 带死亡 pid）idle 6 分钟后：
    /// 必须仍保留（30 分钟 removeTimeout 规则不变）——击杀「快速清理路径误伤交互会话」突变。
    func testCHeadlessCleanup_InteractiveSessionCleanupBehaviorUnchanged() {
        let sid = RedTeamAcceptance.uniqueSessionId("interactive-keep")
        let deadPid = 99999

        manager.handle(message: RedTeamAcceptance.makeHookMessage(
            sessionId: sid, event: "session_start", cwd: "/projects/keep", pid: deadPid
        ))
        XCTAssertTrue(
            RedTeamAcceptance.waitUntil(timeout: RedTeamAcceptance.failOpenTimeout) {
                self.scene.addCatCalls.contains { $0.sessionId == sid }
            },
            "前提：交互会话应上屏")

        // idle 6 分钟（超过 5 分钟 idle 阈值，未到 30 分钟 remove 阈值），进程已死
        manager.sessions[sid]?.lastActivity = Date(timeIntervalSinceNow: -(6 * 60))
        manager.checkTimeouts()

        XCTAssertNotNil(manager.sessions[sid],
                        "交互会话 6 分钟 idle + 进程死亡不得被清理（30 分钟 removeTimeout 行为不变）")
        XCTAssertFalse(scene.removeCatCalls.contains(sid),
                       "交互会话未到 remove 阈值时 removeCat 不得被调用")
        XCTAssertTrue(scene.addCatCalls.contains { $0.sessionId == sid },
                      "交互会话的猫必须始终在屏")
    }
}
