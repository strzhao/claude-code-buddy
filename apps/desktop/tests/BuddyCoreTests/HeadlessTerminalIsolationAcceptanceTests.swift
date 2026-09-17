import XCTest
@testable import BuddyCore

// MARK: - HeadlessTerminalIsolationAcceptanceTests
//
// 红队验收测试 —— 冻结谓词 SSOT：`.autopilot/runtime/requirements/20260917-开始实现/state.md`
//
// 覆盖谓词：
//   S4-P1 [det-machine] 后台会话存续期间，app 不产生关联该会话的 tab title 写入事件
//                       （in-process 观测点 = onSessionNeedsTabTitle 回调不触发，
//                        设计文档声明的下游触发链：guard terminalId != nil → setTabTitle）
//   S4-P3 [det-machine] 后台会话登记后，inspect 不携带兜底 terminal_id
//                       （terminal_id ∈ {null, 空串, 缺省}——此处断言「缺省」，最强形态）
//   S5-P1（in-process 半场）交互会话 A/B 上报的 terminal_id 互不相同且与各自上报值逐一相等
//                       （真实终端 tab 的绑定由 HeadlessAcceptanceE2EChecklist.sh 真机半场覆盖）
//   S5-P4（in-process 半场）真实 terminal_id 已上报后，后续缺省 terminal_id 的消息不得清掉绑定
//                       // CONTRACT_AMBIGUOUS: 交互会话后续消息携带「不同」terminal_id 的语义
//                       //（换 tab 合法更新 vs 兜底拒绝）设计未声明，本用例只断言缺省值不清除；
//                       // 真实兜底覆盖计数（fallback_override_count == 0）走 checklist 日志驱动。
//   C-HEADLESS-NO-TERMINAL（契约）创建分支与更新分支 dual-path 双堵：headless 会话对
//                       hook 发来的 terminal_id 一律不存储
//
// TDD 红灯：S4-P1/S4-P3 在修复前失败是预期（当前 hook 发来的 terminal_id 会被存储）。

@MainActor
final class HeadlessTerminalIsolationAcceptanceTests: XCTestCase {

    var scene: MockScene!
    var manager: SessionManager!
    var fixtures: [RedTeamHeadlessFixture] = []
    var tabTitleEvents: [SessionInfo] = []

    override func setUp() {
        super.setUp()
        scene = MockScene()
        manager = SessionManager(scene: scene)
        fixtures = []
        tabTitleEvents = []
        manager.onSessionNeedsTabTitle = { [weak self] info in
            self?.tabTitleEvents.append(info)
        }
        try? FileManager.default.removeItem(atPath: SessionManager.colorFilePath)
    }

    override func tearDown() {
        for fixture in fixtures { fixture.cleanup() }
        fixtures = []
        try? FileManager.default.removeItem(atPath: SessionManager.colorFilePath)
        super.tearDown()
    }

    /// 后台 fixture + 创建分支 / 更新分支双路径灌入 terminal_id（dual-path 双堵的攻击面）
    func registerBackgroundWithTerminalIds() throws -> RedTeamHeadlessFixture {
        let fixture = try RedTeamHeadlessFixture(
            sessionId: RedTeamAcceptance.uniqueSessionId("tid-bg"), argvToken: "-p")
        fixtures.append(fixture)

        // 创建分支：首条消息（session_start）携带兜底 terminal_id
        manager.handle(message: RedTeamAcceptance.makeHookMessage(
            sessionId: fixture.sessionId, event: "session_start",
            cwd: "/projects/tid-bg", terminalId: "ghostty-fallback-tab-1"
        ))
        // 等过判型窗口（文件在场，判型远早于此）
        Thread.sleep(forTimeInterval: RedTeamAcceptance.headlessVerdictWindow)
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))

        // 更新分支：后续消息（thinking）携带另一个兜底 terminal_id
        manager.handle(message: RedTeamAcceptance.makeHookMessage(
            sessionId: fixture.sessionId, event: "thinking",
            terminalId: "ghostty-fallback-tab-2"
        ))
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        return fixture
    }

    // MARK: - S4-P1 无 tab title 写入事件

    /// headless 会话存续 + 双路径灌入 terminal_id：
    /// ① SessionInfo.terminalId 保持 nil（不存储）；② onSessionNeedsTabTitle 对 <bg-id> 零触发
    /// （下游 setTabTitle 的唯一入口，等价于「app 日志 title 写入类事件 count == 0」）。
    func testS4P1_NoTabTitleWriteEventsForBackgroundSession() throws {
        let fixture = try registerBackgroundWithTerminalIds()

        XCTAssertNil(manager.sessions[fixture.sessionId]?.terminalId,
                     "headless 会话 terminal_id 一律不存储（创建+更新分支双堵）")
        let pollution = tabTitleEvents.filter { $0.sessionId == fixture.sessionId }
        XCTAssertEqual(pollution.count, 0,
                       "不得产生关联后台会话的 tab title 写入事件（观察点：onSessionNeedsTabTitle）")
        XCTAssertEqual(manager.sessions[fixture.sessionId]?.state, .thinking,
                       "前提：会话正常登记且状态已更新（排除「消息未达」假绿）")
    }

    // MARK: - S4-P3 inspect 不携带兜底 terminal_id

    /// inspect JSON 的 terminal_id 字段 ∈ {null, 空串, 缺省}——断言最强形态「缺省」
    ///（序列化契约：terminalId 非 nil 才写 key）。
    func testS4P3_InspectCarriesNoFallbackTerminalId() async throws {
        let fixture = try registerBackgroundWithTerminalIds()
        // async 上下文：挂起等判型回跳排空后再观察（同步 Thread.sleep 只能保证时长，
        // 排空靠下一处 await 完成但顺序不保证 FIFO——显式再挂一个判型窗口最稳）
        await RedTeamAcceptance.waitForVerdictWindow()

        let handler = QueryHandler(sessionManager: manager, scene: scene, eventStore: manager.eventStore)
        let data = await handler.handle(query: ["action": "inspect", "session_id": fixture.sessionId])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let dataDict = try XCTUnwrap(json["data"] as? [String: Any])
        let session = try XCTUnwrap(dataDict["session"] as? [String: Any])

        XCTAssertNil(session["terminal_id"],
                     "inspect 不得携带兜底 terminal_id（negate: fallback_terminal_id_assigned）；实际 = \(String(describing: session["terminal_id"]))")
        XCTAssertEqual(session["id"] as? String, fixture.sessionId,
                       "前提：inspect 的是后台会话本身")
    }

    // MARK: - S5-P1（in-process 半场）交互会话 terminal_id 绑定互不串扰

    /// A、B 两个交互会话各自上报真实 terminal_id 后：
    /// inspect 记录互不相同且各自等于上报值（tid_A != tid_B && 各自 == 上报 tab id）。
    func testS5P1_InteractiveSessionsKeepDistinctReportedTerminalIds() async throws {
        let sidA = RedTeamAcceptance.uniqueSessionId("tabA")
        let sidB = RedTeamAcceptance.uniqueSessionId("tabB")
        manager.handle(message: RedTeamAcceptance.makeHookMessage(
            sessionId: sidA, event: "session_start", cwd: "/projects/tabA"))
        manager.handle(message: RedTeamAcceptance.makeHookMessage(
            sessionId: sidB, event: "session_start", cwd: "/projects/tabB"))
        let bothOnScreen = await RedTeamAcceptance.waitUntilAsync(timeout: RedTeamAcceptance.failOpenTimeout) {
            self.scene.addCatCalls.contains { $0.sessionId == sidA }
                && self.scene.addCatCalls.contains { $0.sessionId == sidB }
        }
        XCTAssertTrue(bothOnScreen, "前提：A、B 交互会话应上屏")

        // 各自上报真实 terminal_id
        manager.handle(message: RedTeamAcceptance.makeHookMessage(
            sessionId: sidA, event: "thinking", terminalId: "real-tab-A"))
        manager.handle(message: RedTeamAcceptance.makeHookMessage(
            sessionId: sidB, event: "thinking", terminalId: "real-tab-B"))

        let handler = QueryHandler(sessionManager: manager, scene: scene, eventStore: manager.eventStore)
        let dataA = await handler.handle(query: ["action": "inspect", "session_id": sidA])
        let dataB = await handler.handle(query: ["action": "inspect", "session_id": sidB])
        let sessionA = try XCTUnwrap(((try XCTUnwrap(JSONSerialization.jsonObject(with: dataA) as? [String: Any]))["data"] as? [String: Any])?["session"] as? [String: Any])
        let sessionB = try XCTUnwrap(((try XCTUnwrap(JSONSerialization.jsonObject(with: dataB) as? [String: Any]))["data"] as? [String: Any])?["session"] as? [String: Any])

        XCTAssertEqual(sessionA["terminal_id"] as? String, "real-tab-A",
                       "A 的 inspect terminal_id 必须等于其真实上报值")
        XCTAssertEqual(sessionB["terminal_id"] as? String, "real-tab-B",
                       "B 的 inspect terminal_id 必须等于其真实上报值")
        XCTAssertNotEqual(sessionA["terminal_id"] as? String, sessionB["terminal_id"] as? String,
                          "A、B 的 terminal_id 互不相同（不串扰）")
    }

    // MARK: - S5-P4（in-process 半场）真实绑定不被缺省值清除

    /// 真实 terminal_id 已上报后，后续不带 terminal_id 的消息不得清掉 A 的绑定
    ///（兜底值以「缺省」形态到达时不得覆盖真实绑定；真实覆盖计数走 checklist）。
    func testS5P4_MissingTerminalIdDoesNotClobberExistingBinding() async throws {
        let sidA = RedTeamAcceptance.uniqueSessionId("bindA")
        manager.handle(message: RedTeamAcceptance.makeHookMessage(
            sessionId: sidA, event: "session_start", cwd: "/projects/bindA"))
        let onScreen = await RedTeamAcceptance.waitUntilAsync(timeout: RedTeamAcceptance.failOpenTimeout) {
            self.scene.addCatCalls.contains { $0.sessionId == sidA }
        }
        XCTAssertTrue(onScreen, "前提：交互会话应上屏")

        manager.handle(message: RedTeamAcceptance.makeHookMessage(
            sessionId: sidA, event: "thinking", terminalId: "real-tab-A"))
        XCTAssertEqual(manager.sessions[sidA]?.terminalId, "real-tab-A",
                       "前提：真实绑定已生效")

        // 后续消息缺省 terminal_id（兜底/未上报形态）——绑定必须保持
        manager.handle(message: RedTeamAcceptance.makeHookMessage(
            sessionId: sidA, event: "idle"))
        XCTAssertEqual(manager.sessions[sidA]?.terminalId, "real-tab-A",
                       "缺省 terminal_id 的后续消息不得覆盖/清除已上报的真实绑定")

        let handler = QueryHandler(sessionManager: manager, scene: scene, eventStore: manager.eventStore)
        let data = await handler.handle(query: ["action": "inspect", "session_id": sidA])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let dataDict = try XCTUnwrap(json["data"] as? [String: Any])
        let session = try XCTUnwrap(dataDict["session"] as? [String: Any])
        XCTAssertEqual(session["terminal_id"] as? String, "real-tab-A",
                       "inspect 视角的绑定同样保持不变")
    }
}
