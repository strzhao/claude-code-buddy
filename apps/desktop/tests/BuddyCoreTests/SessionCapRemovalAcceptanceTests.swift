import XCTest
@testable import BuddyCore

// MARK: - SessionCapRemovalAcceptanceTests
//
// 红队验收测试 —— 冻结谓词 SSOT：`.autopilot/runtime/requirements/20260917-开始实现/state.md`
//
// 覆盖谓词：
//   S1-P1 [det-machine] 第 9 个交互会话登记完成 → 上屏猫数 == 9 且包含 <session-9-id>
//   S1-P2 [det-machine] registered 集合与 onScreen 集合相等（差集为空——杀「登记不上屏」旧行为）
//   S1-P4 [det-machine] 第 9 只猫上屏 → /tmp/claude-buddy-colors.json 含该会话条目
//   S6-P2 [det-machine] 重启（重建 manager 模拟内存态清空）后再登记新交互会话 → 上屏该会话
//   C-NO-CAP（契约）     猫数量无上限（12 只压力：无 maxCats 门禁 / 无满员驱逐）
//   C-COLOR-REUSE（契约）池满按「在用会话数最少」复用；release 仅在该色无其他持有者时回收
//
// TDD 红灯说明：上限移除/检测链落地前，S1-P1 / S1-P2 / C-NO-CAP / C-COLOR-REUSE 断言失败是预期；
// 编译必须通过（只引用既有符号）。
// 时序依据 C-HEADLESS-DETECT：合成会话无 session 注册表文件 → resolve 重试 0.5s×4 耗尽 →
// fail-open interactive → 上屏（等待上限 failOpenTimeout=25s）。

@MainActor
final class SessionCapRemovalAcceptanceTests: XCTestCase {

    var scene: MockScene!
    var manager: SessionManager!

    override func setUp() {
        super.setUp()
        scene = MockScene()
        manager = SessionManager(scene: scene)
        try? FileManager.default.removeItem(atPath: SessionManager.colorFilePath)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: SessionManager.colorFilePath)
        super.tearDown()
    }

    // MARK: - S1-P1 第 9 个交互会话全部上屏

    /// 9 个交互会话（全部无注册表文件 → fail-open interactive）登记完成后，
    /// 上屏猫数必须 == 9 且第 9 个会话在上屏集合中。
    func testS1P1_NinthInteractiveSessionGetsOnScreenCat() {
        var ids: [String] = []
        for i in 1...9 {
            let sid = RedTeamAcceptance.uniqueSessionId("cap\(i)")
            ids.append(sid)
            manager.handle(message: RedTeamAcceptance.makeHookMessage(
                sessionId: sid, event: "session_start", cwd: "/projects/cap\(i)"
            ))
        }
        let ninth = ids[8]

        let allOnScreen = RedTeamAcceptance.waitUntil(timeout: RedTeamAcceptance.failOpenTimeout) {
            self.scene.addCatCalls.count >= 9
        }

        XCTAssertTrue(allOnScreen,
                      "9 个交互会话应全部上屏（上限已移除）；实际 addCat 数 = \(scene.addCatCalls.count)")
        XCTAssertEqual(scene.addCatCalls.count, 9,
                       "上屏猫数应恰为 9")
        XCTAssertTrue(scene.addCatCalls.contains { $0.sessionId == ninth },
                      "第 9 个交互会话（<session-9-id> = \(ninth)）必须在上屏猫集合中")
    }

    // MARK: - S1-P2 registered 集合 == onScreen 集合

    /// 9 个交互会话登记后，sessions（registered）与 addCatCalls（onScreen）差集必须为空。
    /// 直接击杀「登记不发猫且永不回补」旧行为的 no-op 突变。
    func testS1P2_RegisteredSetEqualsOnScreenSet() {
        for i in 1...9 {
            manager.handle(message: RedTeamAcceptance.makeHookMessage(
                sessionId: RedTeamAcceptance.uniqueSessionId("diff\(i)"),
                event: "session_start", cwd: "/projects/diff\(i)"
            ))
        }

        let allOnScreen = RedTeamAcceptance.waitUntil(timeout: RedTeamAcceptance.failOpenTimeout) {
            self.scene.addCatCalls.count >= 9
        }
        XCTAssertTrue(allOnScreen, "前提：9 个交互会话应全部上屏")

        let registered = Set(manager.sessions.keys)
        let onscreen = Set(scene.addCatCalls.map(\.sessionId))

        XCTAssertEqual(registered.subtracting(onscreen), [],
                       "registered − onScreen 差集应为空（登记即上屏，不允许永不回补的滞留会话）")
        XCTAssertEqual(onscreen.subtracting(registered), [],
                       "onScreen − registered 差集应为空（无幽灵猫）")
        XCTAssertEqual(registered.count, 9, "registered 集合应为 9")
    }

    // MARK: - S1-P4 colors.json 含第 9 个会话条目

    /// 第 9 只猫上屏后，/tmp/claude-buddy-colors.json 必须含第 9 个会话条目
    /// （颜色复用后 entry 语义不失真——去上限不得破坏颜色文件契约）。
    func testS1P4_ColorsFileContainsNinthSessionEntry() throws {
        var ids: [String] = []
        for i in 1...9 {
            let sid = RedTeamAcceptance.uniqueSessionId("colorfile\(i)")
            ids.append(sid)
            manager.handle(message: RedTeamAcceptance.makeHookMessage(
                sessionId: sid, event: "session_start", cwd: "/projects/cf\(i)"
            ))
        }
        let ninth = ids[8]

        XCTAssertTrue(
            RedTeamAcceptance.waitUntil(timeout: RedTeamAcceptance.failOpenTimeout) {
                self.scene.addCatCalls.count >= 9
            },
            "前提：9 个交互会话应全部上屏")

        let data = try Data(contentsOf: URL(fileURLWithPath: SessionManager.colorFilePath))
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: [String: String]],
            "colors.json 应为合法 JSON 对象")

        XCTAssertNotNil(json[ninth],
                        "colors.json 必须包含第 9 个会话（\(ninth)）的条目")
        XCTAssertNotNil(json[ninth]?["color"], "第 9 个会话条目必须含 'color' key")
        XCTAssertNotNil(json[ninth]?["hex"], "第 9 个会话条目必须含 'hex' key")
    }

    // MARK: - C-NO-CAP 12 只压力（无门禁、无满员驱逐）

    /// 12 个交互会话全部上屏：不存在 `< 8` 门禁，不存在 maxCats 满员驱逐/evictIdleCat。
    /// 击杀「门禁/驱逐逻辑删一半」的部分修复突变（9 只过、12 只被驱逐）。
    func testCNoCap_TwelveInteractiveSessionsAllOnScreenWithoutEviction() {
        for i in 1...12 {
            manager.handle(message: RedTeamAcceptance.makeHookMessage(
                sessionId: RedTeamAcceptance.uniqueSessionId("stress\(i)"),
                event: "session_start", cwd: "/projects/stress\(i)"
            ))
        }

        let allOnScreen = RedTeamAcceptance.waitUntil(timeout: RedTeamAcceptance.failOpenTimeout) {
            self.scene.addCatCalls.count >= 12
        }

        XCTAssertTrue(allOnScreen,
                      "12 个交互会话应全部上屏（无上限、无驱逐）；实际 addCat 数 = \(scene.addCatCalls.count)")
        XCTAssertEqual(scene.removeCatCalls.count, 0,
                       "上屏过程中不得发生任何驱逐（evictIdleCat 已删除）")
    }

    // MARK: - S6-P2 重启后新交互会话照常上屏

    /// 内存态会话架构：重建 manager 模拟重启清空，再登记 1 个新交互会话必须上屏
    /// （恢复语义由 S6-P2/P3 覆盖——重启后新会话无上限、检测链不因重启卡死）。
    func testS6P2_NewInteractiveSessionOnScreenAfterRestart() {
        // 重启：丢弃旧 manager/scene，全新实例
        scene = MockScene()
        manager = SessionManager(scene: scene)
        try? FileManager.default.removeItem(atPath: SessionManager.colorFilePath)

        let sid = RedTeamAcceptance.uniqueSessionId("restart-new")
        manager.handle(message: RedTeamAcceptance.makeHookMessage(
            sessionId: sid, event: "session_start", cwd: "/projects/restarted"
        ))

        let onScreen = RedTeamAcceptance.waitUntil(timeout: RedTeamAcceptance.failOpenTimeout) {
            self.scene.addCatCalls.contains { $0.sessionId == sid }
        }

        XCTAssertTrue(onScreen,
                      "重启后登记的新交互会话（<session-new-id> = \(sid)）必须上屏")
    }

    // MARK: - C-COLOR-REUSE 池满最少在用复用 + release 精确回收

    /// 9 会话 > 8 色池：第 9 只必须复用既有色（恰一色持有数 == 2）；
    /// releaseColor 精确化：结束共享色的一个持有者 → 色仍 in-use；
    /// 最后一个持有者也结束 → 色才从 usedColors 回收。
    func testCColorReuse_PoolFullReusesLeastUsedColorAndReleaseIsExact() {
        var ids: [String] = []
        for i in 1...9 {
            let sid = RedTeamAcceptance.uniqueSessionId("reuse\(i)")
            ids.append(sid)
            manager.handle(message: RedTeamAcceptance.makeHookMessage(
                sessionId: sid, event: "session_start", cwd: "/projects/reuse\(i)"
            ))
        }

        XCTAssertTrue(
            RedTeamAcceptance.waitUntil(timeout: RedTeamAcceptance.failOpenTimeout) {
                self.scene.addCatCalls.count >= 9
            },
            "前提：9 个交互会话应全部上屏")

        // 9 会话 8 色：恰有一色被两个会话持有，其余各 1
        var holderCount: [SessionColor: Int] = [:]
        for info in manager.sessions.values {
            holderCount[info.color, default: 0] += 1
        }
        XCTAssertEqual(holderCount.values.reduce(0, +), 9, "9 个会话都应持有颜色")
        XCTAssertEqual(Set(manager.sessions.values.map(\.color)).count, 8,
                       "颜色池只有 8 色，第 9 会话必须复用既有色")
        let shared = holderCount.first(where: { $0.value == 2 })?.key
        XCTAssertNotNil(shared, "应恰有一色被复用（持有数 == 2）")
        XCTAssertEqual(manager.usedColors.count, 8,
                       "池满复用态下 8 色全部 in-use（usedColors 语义不失真）")

        // release 精确化：共享色第一个持有者结束 → 色仍被另一持有者占用，不得回收
        guard let sharedColor = shared,
              let holder1 = manager.sessions.values.first(where: { $0.color == sharedColor })?.sessionId
        else {
            XCTFail("前提：应能找到共享色持有者")
            return
        }
        manager.handle(message: RedTeamAcceptance.makeHookMessage(
            sessionId: holder1, event: "session_end"))
        XCTAssertTrue(manager.usedColors.contains(sharedColor),
                      "共享色仍有其他持有者时，releaseColor 不得将其移出 usedColors")

        // 最后一个持有者也结束 → 回收
        guard let holder2 = manager.sessions.values.first(where: { $0.color == sharedColor })?.sessionId
        else {
            XCTFail("前提：共享色应仍有一个持有者")
            return
        }
        manager.handle(message: RedTeamAcceptance.makeHookMessage(
            sessionId: holder2, event: "session_end"))
        XCTAssertFalse(manager.usedColors.contains(sharedColor),
                       "最后一个持有者结束后，颜色应被回收")
    }
}
