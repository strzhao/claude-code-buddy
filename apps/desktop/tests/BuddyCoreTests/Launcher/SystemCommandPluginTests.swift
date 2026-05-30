import XCTest
@testable import BuddyCore

/// 蓝队单元测试 — SystemCommandPlugin（SC1–SC9 覆盖，task 012）
/// 注：不写 *AcceptanceTests.swift（那是红队的）。
@MainActor
final class SystemCommandPluginTests: XCTestCase {

    // MARK: - Mock ScreenLocking Spy

    /// 可注入的 mock spy：记录 lock() 调用次数，可配置为抛错
    final class MockScreenLocker: ScreenLocking {
        var callCount = 0
        var shouldThrow = false

        func lock() throws {
            callCount += 1
            if shouldThrow {
                throw LauncherError.systemCommandFailed("锁定屏幕")
            }
        }
    }

    // MARK: - SC1：基本契约属性

    func test_sc1_id() {
        let plugin = SystemCommandPlugin()
        XCTAssertEqual(plugin.id, "system-command")
    }

    func test_sc1_priority() {
        let plugin = SystemCommandPlugin()
        XCTAssertEqual(plugin.priority, 100)
    }

    func test_sc1_sectionTitle() {
        let plugin = SystemCommandPlugin()
        XCTAssertEqual(plugin.sectionTitle, "系统")
    }

    // MARK: - SC2：完全匹配产出恰好一条

    func test_sc2_exactMatch_lock_english() async {
        let plugin = SystemCommandPlugin()
        let actions = await plugin.actions(for: "lock")
        let lockActions = actions.filter { $0.title == "锁定屏幕" }
        XCTAssertEqual(lockActions.count, 1, "query=lock 应产出恰好一条「锁定屏幕」")
    }

    func test_sc2_exactMatch_lock_pluginId() async {
        let plugin = SystemCommandPlugin()
        let actions = await plugin.actions(for: "lock")
        let lockAction = actions.first { $0.title == "锁定屏幕" }
        XCTAssertNotNil(lockAction)
        XCTAssertEqual(lockAction?.pluginId, "system-command")
    }

    func test_sc2_exactMatch_chinese() async {
        let plugin = SystemCommandPlugin()
        let actions = await plugin.actions(for: "锁屏")
        let lockActions = actions.filter { $0.title == "锁定屏幕" }
        XCTAssertEqual(lockActions.count, 1, "query=锁屏 应产出恰好一条「锁定屏幕」")
    }

    // MARK: - SC3：前缀命中 + 大小写不敏感

    func test_sc3_prefix_loc() async {
        let plugin = SystemCommandPlugin()
        let actions = await plugin.actions(for: "loc")
        XCTAssertTrue(actions.contains { $0.title == "锁定屏幕" }, "query=loc 前缀命中 lock")
    }

    func test_sc3_prefix_lo() async {
        let plugin = SystemCommandPlugin()
        let actions = await plugin.actions(for: "lo")
        XCTAssertTrue(actions.contains { $0.title == "锁定屏幕" }, "query=lo 前缀命中 lock（场景8.P2）")
    }

    func test_sc3_prefix_l() async {
        let plugin = SystemCommandPlugin()
        let actions = await plugin.actions(for: "l")
        XCTAssertTrue(actions.contains { $0.title == "锁定屏幕" }, "query=l 前缀命中 lock")
    }

    func test_sc3_caseInsensitive_LOCK() async {
        let plugin = SystemCommandPlugin()
        let actions = await plugin.actions(for: "LOCK")
        XCTAssertTrue(actions.contains { $0.title == "锁定屏幕" }, "query=LOCK 大小写不敏感命中")
    }

    func test_sc3_prefix_chinese_singleChar() async {
        let plugin = SystemCommandPlugin()
        let actions = await plugin.actions(for: "锁")
        XCTAssertTrue(actions.contains { $0.title == "锁定屏幕" }, "query=锁 前缀命中 锁屏")
    }

    // MARK: - SC4：negate — 无关 query 不产出锁屏候选

    func test_sc4_negate_safari() async {
        let plugin = SystemCommandPlugin()
        let actions = await plugin.actions(for: "safari")
        XCTAssertFalse(actions.contains { $0.title == "锁定屏幕" }, "query=safari 不应命中锁屏候选")
    }

    func test_sc4_negate_emptyQuery() async {
        let plugin = SystemCommandPlugin()
        let actions = await plugin.actions(for: "")
        XCTAssertTrue(actions.isEmpty, "空 query 应返回 []")
    }

    func test_sc4_negate_unrelated_english() async {
        let plugin = SystemCommandPlugin()
        let actions = await plugin.actions(for: "sleep")
        XCTAssertFalse(actions.contains { $0.title == "锁定屏幕" }, "query=sleep 不应命中锁屏候选")
    }

    // MARK: - SC5：完全匹配 score > 前缀命中 score

    func test_sc5_exactScore_greaterThan_prefixScore() async {
        let plugin = SystemCommandPlugin()
        let exactActions = await plugin.actions(for: "lock")
        let prefixActions = await plugin.actions(for: "loc")

        let exactScore = exactActions.first { $0.title == "锁定屏幕" }?.score ?? 0
        let prefixScore = prefixActions.first { $0.title == "锁定屏幕" }?.score ?? 0

        XCTAssertGreaterThan(exactScore, prefixScore, "完全匹配 score (\(exactScore)) 应 > 前缀命中 score (\(prefixScore))")
    }

    // MARK: - SC6：perform 惰性执行 — 构造后 callCount==0，perform 后 callCount==1

    func test_sc6_perform_lazyExecution_notCalledOnActionsFor() async {
        let spy = MockScreenLocker()
        let plugin = SystemCommandPlugin(locker: spy)
        _ = await plugin.actions(for: "lock")
        XCTAssertEqual(spy.callCount, 0, "actions(for:) 不应触发 lock()，callCount 应为 0")
    }

    func test_sc6_perform_calledExactlyOnce() async throws {
        let spy = MockScreenLocker()
        let plugin = SystemCommandPlugin(locker: spy)
        let actions = await plugin.actions(for: "lock")
        let lockAction = try XCTUnwrap(actions.first { $0.title == "锁定屏幕" })

        XCTAssertEqual(spy.callCount, 0, "perform 前 callCount 应为 0")
        try lockAction.perform()
        XCTAssertEqual(spy.callCount, 1, "perform 后 callCount 应为 1")
    }

    func test_sc6_perform_calledOnce_notTwice() async throws {
        let spy = MockScreenLocker()
        let plugin = SystemCommandPlugin(locker: spy)
        let actions = await plugin.actions(for: "lock")
        let lockAction = try XCTUnwrap(actions.first { $0.title == "锁定屏幕" })

        try lockAction.perform()
        XCTAssertEqual(spy.callCount, 1, "第一次 perform 后 callCount==1")
        // 再调一次验证是独立计数
        try lockAction.perform()
        XCTAssertEqual(spy.callCount, 2, "第二次 perform 后 callCount==2（每次调用各计 1）")
    }

    // MARK: - SC7：seam 抛错 → perform 抛 systemCommandFailed，文案含 CJK

    func test_sc7_errorPropagation_throwsSystemCommandFailed() async {
        let spy = MockScreenLocker()
        spy.shouldThrow = true
        let plugin = SystemCommandPlugin(locker: spy)
        let actions = await plugin.actions(for: "lock")
        guard let lockAction = actions.first(where: { $0.title == "锁定屏幕" }) else {
            XCTFail("未找到锁屏 action")
            return
        }

        do {
            try lockAction.perform()
            XCTFail("应抛出错误")
        } catch let error as LauncherError {
            if case .systemCommandFailed = error {
                // 正确
            } else {
                XCTFail("应为 LauncherError.systemCommandFailed，实际为 \(error)")
            }
        } catch {
            XCTFail("应为 LauncherError，实际为 \(error)")
        }
    }

    func test_sc7_errorDescription_containsCJK() {
        let error = LauncherError.systemCommandFailed("锁定屏幕")
        let desc = error.errorDescription ?? ""
        let hasCJK = desc.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) ||
            (0x3000...0x303F).contains(scalar.value) ||
            (0xFF00...0xFFEF).contains(scalar.value)
        }
        XCTAssertTrue(hasCJK, "errorDescription 应含 CJK 字符，实际：\(desc)")
        XCTAssertGreaterThanOrEqual(desc.count, 4, "errorDescription 长度应 >= 4")
    }

    func test_sc7_errorDescription_notPureASCII() {
        let error = LauncherError.systemCommandFailed("锁定屏幕")
        let desc = error.errorDescription ?? ""
        let isAllASCII = desc.unicodeScalars.allSatisfy { $0.value < 128 }
        XCTAssertFalse(isAllASCII, "errorDescription 不应为纯 ASCII")
    }
}
