import XCTest
@testable import BuddyCore

// MARK: - HeadlessDetectionAcceptanceTests
//
// 红队验收测试 —— 冻结谓词 SSOT：`.autopilot/runtime/requirements/20260917-开始实现/state.md`
//
// 覆盖谓词：
//   S2-P1 [det-machine] -p 后台任务被 app 登记 → 上屏猫集合不变（数量保持 K 且不含 <bg-id>）
//   S2-P2 [det-machine] 查询该后台会话 inspect 记录 → is_headless == true
//   S9-P1 [det-machine] buddy session start --id debug-A（无注册表文件）→ fail-open interactive
//                       并上屏（不 pending 卡死、不误判 headless）：onscreen == true && is_headless == false
//   S9-P3 [det-machine] 真实会话注册表文件缺失（resolve 重试耗尽）→ fail-open 判 interactive 上屏
//   C-HEADLESS-DETECT（契约）argv 精确 token 判型：`--print` 命中；`-printer` 子串不命中；
//                       无 token 交互进程不命中；`kind`/`entrypoint` 字段不参与判型（fixture
//                       注册表文件故意不带 kind/entrypoint，判型仍须成立）
//   C-HEADLESS-NOCAT（契约）.pending 会话暂不上猫（防闪猫）
//
// 判型驱动 = 生产行为本身：RedTeamHeadlessFixture 创建真实子进程 + 写
// `~/.claude/sessions/<pid>.json` 注册表文件（字段名与真实注册表一致）。
// TDD 红灯：检测链落地前 S2-P1/S2-P2/C-HEADLESS-* 断言失败是预期；编译必须通过。

@MainActor
final class HeadlessDetectionAcceptanceTests: XCTestCase {

    var scene: MockScene!
    var manager: SessionManager!
    var fixtures: [RedTeamHeadlessFixture] = []

    override func setUp() {
        super.setUp()
        scene = MockScene()
        manager = SessionManager(scene: scene)
        fixtures = []
        try? FileManager.default.removeItem(atPath: SessionManager.colorFilePath)
    }

    override func tearDown() {
        for fixture in fixtures { fixture.cleanup() }
        fixtures = []
        try? FileManager.default.removeItem(atPath: SessionManager.colorFilePath)
        super.tearDown()
    }

    /// 创建 headless 形态 fixture（真实 `-p` 进程 + 注册表文件）
    func makeBackgroundFixture(name: String, argvToken: String? = "-p") throws -> RedTeamHeadlessFixture {
        let fixture = try RedTeamHeadlessFixture(
            sessionId: RedTeamAcceptance.uniqueSessionId(name), argvToken: argvToken)
        fixtures.append(fixture)
        return fixture
    }

    // MARK: - S2-P1 -p 后台任务不占上屏猫

    /// 登记后台任务前后，上屏猫集合不变：数量保持 K，且不含 <bg-id>。
    /// negate 断言：上屏集合新增条目即为失败（击杀「判型缺失 → 全部上屏」no-op 突变）。
    func testS2P1_BackgroundSessionDoesNotEnterOnScreenSet() throws {
        // 先造 K=2 个交互会话作为基线上屏集合
        var interactiveIds: [String] = []
        for i in 1...2 {
            let sid = RedTeamAcceptance.uniqueSessionId("base\(i)")
            interactiveIds.append(sid)
            manager.handle(message: RedTeamAcceptance.makeHookMessage(
                sessionId: sid, event: "session_start", cwd: "/projects/base\(i)"
            ))
        }
        XCTAssertTrue(
            RedTeamAcceptance.waitUntil(timeout: RedTeamAcceptance.failOpenTimeout) {
                self.scene.addCatCalls.count >= 2
            },
            "前提：2 个基线交互会话应上屏")

        let onScreenBefore = Set(scene.addCatCalls.map(\.sessionId))

        // 登记 -p 后台任务（真实进程 + 注册表文件）
        let fixture = try makeBackgroundFixture(name: "bg")
        manager.handle(message: RedTeamAcceptance.makeHookMessage(
            sessionId: fixture.sessionId, event: "session_start", cwd: "/projects/bg"
        ))

        // 等过判型窗口（文件在场，判型应远早于此），上屏集合必须保持原样
        Thread.sleep(forTimeInterval: RedTeamAcceptance.headlessVerdictWindow)
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))

        let onScreenAfter = Set(scene.addCatCalls.map(\.sessionId))
        XCTAssertEqual(onScreenAfter, onScreenBefore,
                       "后台任务登记后上屏猫集合必须不变（K = \(onScreenBefore.count)）")
        XCTAssertFalse(onScreenAfter.contains(fixture.sessionId),
                       "上屏集合不得包含后台会话 <bg-id> = \(fixture.sessionId)")
        XCTAssertFalse(scene.addCatCalls.contains { $0.sessionId == fixture.sessionId },
                       "addCat 不得被后台会话触发")
        XCTAssertTrue(manager.sessions[fixture.sessionId] != nil,
                      "后台会话应被登记（在 registered 集合，只是不上屏）")
        _ = interactiveIds // 基线集合即 onScreenBefore
    }

    // MARK: - S2-P2 inspect 归类为后台任务

    /// 后台会话的 inspect 记录 is_headless == true（C-INSPECT-FIELD 声明的字段名，逐字一致）。
    /// （蓝队编译修复：QueryHandler.handle 为 async，本测试函数需 async 才能编译——断言零改动）
    func testS2P2_InspectReportsIsHeadlessTrue() async throws {
        let fixture = try makeBackgroundFixture(name: "inspect-bg")
        manager.handle(message: RedTeamAcceptance.makeHookMessage(
            sessionId: fixture.sessionId, event: "session_start", cwd: "/projects/inspect-bg"
        ))

        XCTAssertTrue(
            RedTeamAcceptance.waitUntil(timeout: RedTeamAcceptance.headlessVerdictWindow) {
                self.manager.sessions[fixture.sessionId] != nil
            },
            "前提：后台会话应被登记")
        // 挂起等判型完成（async 上下文不能用同步自旋，会饿死主 actor 上的检测链回跳）
        await RedTeamAcceptance.waitForVerdictWindow()

        let handler = QueryHandler(sessionManager: manager, scene: scene, eventStore: manager.eventStore)
        let data = await handler.handle(query: ["action": "inspect", "session_id": fixture.sessionId])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["status"] as? String, "ok", "inspect 应成功返回")
        let dataDict = try XCTUnwrap(json["data"] as? [String: Any])
        let session = try XCTUnwrap(dataDict["session"] as? [String: Any])

        XCTAssertEqual(session["is_headless"] as? Bool, true,
                       "inspect 的 session 记录必须带 is_headless == true（后台任务归类）")
    }

    // MARK: - C-HEADLESS-NOCAT pending 防闪猫

    /// 合成会话（无注册表文件，判型须走 0.5s×4 重试耗尽）在 handle 后极短窗口内
    /// 不得上猫（.pending 防闪猫），判定后才按类型处置（此处 fail-open → 上屏）。
    /// 今天（无检测链）：同步上猫 → 立即红；落地后：pending ≥ 重试窗口 → 绿。
    func testCHeadlessNoCat_PendingSessionDoesNotFlashCat() {
        let sid = RedTeamAcceptance.uniqueSessionId("pending")
        manager.handle(message: RedTeamAcceptance.makeHookMessage(
            sessionId: sid, event: "session_start", cwd: "/projects/pending"
        ))

        let flashed = RedTeamAcceptance.waitUntil(timeout: 0.8) {
            self.scene.addCatCalls.contains { $0.sessionId == sid }
        }
        XCTAssertFalse(flashed, "pending 期间不得上猫（防闪猫）——判型完成前 addCat 即违规")

        // 判定（fail-open interactive）后应上屏：不 pending 卡死
        let settled = RedTeamAcceptance.waitUntil(timeout: RedTeamAcceptance.failOpenTimeout) {
            self.scene.addCatCalls.contains { $0.sessionId == sid }
        }
        XCTAssertTrue(settled, "fail-open interactive 判定后会话应上屏（不得永久 pending）")
    }

    // MARK: - S9-P1 debug- 前缀 fail-open interactive 上屏

    /// `buddy session start --id debug-A` 等价的 CLI/调试路径（无 session 注册表文件）：
    /// fail-open 判 interactive 并上屏；inspect 断言 onscreen == true && is_headless == false。
    func testS9P1_DebugSessionFailsOpenInteractiveAndOnScreen() async throws {
        let sid = "debug-" + RedTeamAcceptance.uniqueSessionId("dbg")
        manager.handle(message: RedTeamAcceptance.makeHookMessage(
            sessionId: sid, event: "session_start", cwd: "/projects/debug-path"
        ))

        let onScreen = await RedTeamAcceptance.waitUntilAsync(timeout: RedTeamAcceptance.failOpenTimeout) {
            self.scene.addCatCalls.contains { $0.sessionId == sid }
        }
        XCTAssertTrue(onScreen, "debug 会话（无注册表文件）必须 fail-open interactive 上屏，不得 pending 卡死")

        let handler = QueryHandler(sessionManager: manager, scene: scene, eventStore: manager.eventStore)
        let data = await handler.handle(query: ["action": "inspect", "session_id": sid])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let dataDict = try XCTUnwrap(json["data"] as? [String: Any])
        let session = try XCTUnwrap(dataDict["session"] as? [String: Any])

        XCTAssertEqual(session["is_headless"] as? Bool, false,
                       "debug 会话不得被误判 headless")
        XCTAssertTrue(session["onscreen"] as? Bool == true,
                      "inspect onscreen 必须 == true（S9-P1 断言面）")
    }

    // MARK: - S9-P3 真实会话注册表文件缺失 → fail-open 上屏

    /// 非 debug 前缀的真实会话 id，注册表文件不存在（resolve 重试耗尽）：
    /// is_headless == false && onscreen == true。
    func testS9P3_MissingRegistryFileFailsOpenInteractiveOnScreen() async throws {
        // 唯一 id 保证注册表目录里没有任何匹配文件（resolve 重试耗尽路径）
        let sid = RedTeamAcceptance.uniqueSessionId("no-registry")
        manager.handle(message: RedTeamAcceptance.makeHookMessage(
            sessionId: sid, event: "session_start", cwd: "/projects/no-registry"
        ))

        let onScreen = await RedTeamAcceptance.waitUntilAsync(timeout: RedTeamAcceptance.failOpenTimeout) {
            self.scene.addCatCalls.contains { $0.sessionId == sid }
        }
        XCTAssertTrue(onScreen, "注册表文件缺失的会话必须 fail-open 判 interactive 并上屏")

        let handler = QueryHandler(sessionManager: manager, scene: scene, eventStore: manager.eventStore)
        let data = await handler.handle(query: ["action": "inspect", "session_id": sid])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let dataDict = try XCTUnwrap(json["data"] as? [String: Any])
        let session = try XCTUnwrap(dataDict["session"] as? [String: Any])

        XCTAssertEqual(session["is_headless"] as? Bool, false,
                       "resolve 失败必须 fail-open 判非 headless")
        XCTAssertTrue(session["onscreen"] as? Bool == true,
                      "fail-open 会话 onscreen == true")
    }

    // MARK: - C-HEADLESS-DETECT --print token 同样判 headless

    func testCHeadlessDetect_PrintTokenIsAlsoHeadless() throws {
        let fixture = try makeBackgroundFixture(name: "print-bg", argvToken: "--print")
        manager.handle(message: RedTeamAcceptance.makeHookMessage(
            sessionId: fixture.sessionId, event: "session_start", cwd: "/projects/print-bg"
        ))

        Thread.sleep(forTimeInterval: RedTeamAcceptance.headlessVerdictWindow)
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))

        XCTAssertFalse(scene.addCatCalls.contains { $0.sessionId == fixture.sessionId },
                       "`--print` 精确 token 的进程必须判 headless，不上屏")
    }

    // MARK: - C-HEADLESS-DETECT 子串 token 不误判（-printer ≠ -p）

    /// 进程 argv 含 `-printer`（`-p` 的子串形态）：按空白分词后不存在精确 token `-p`，
    /// 必须判 interactive 并上屏（非子串误判防线）。
    func testCHeadlessDetect_SubstringTokenIsNotHeadless() throws {
        let fixture = try makeBackgroundFixture(name: "printer", argvToken: "-printer")
        manager.handle(message: RedTeamAcceptance.makeHookMessage(
            sessionId: fixture.sessionId, event: "session_start", cwd: "/projects/printer"
        ))

        let onScreen = RedTeamAcceptance.waitUntil(timeout: RedTeamAcceptance.failOpenTimeout) {
            self.scene.addCatCalls.contains { $0.sessionId == fixture.sessionId }
        }
        XCTAssertTrue(onScreen, "`-printer` 子串形态不得误判为 headless，会话应上屏")
    }

    // MARK: - C-HEADLESS-DETECT 无 token 交互进程不判 headless

    func testCHeadlessDetect_InteractiveArgvStaysOnScreen() throws {
        let fixture = try makeBackgroundFixture(name: "tty", argvToken: nil)
        manager.handle(message: RedTeamAcceptance.makeHookMessage(
            sessionId: fixture.sessionId, event: "session_start", cwd: "/projects/tty"
        ))

        let onScreen = RedTeamAcceptance.waitUntil(timeout: RedTeamAcceptance.failOpenTimeout) {
            self.scene.addCatCalls.contains { $0.sessionId == fixture.sessionId }
        }
        XCTAssertTrue(onScreen, "argv 无 `-p`/`--print` token 的存活进程必须判 interactive 并上屏")
    }
}
