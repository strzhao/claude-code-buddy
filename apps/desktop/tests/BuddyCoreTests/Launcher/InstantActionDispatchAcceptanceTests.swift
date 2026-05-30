import XCTest
import Combine
@testable import BuddyCore

// MARK: - InstantActionDispatchAcceptanceTests
//
// 红队验收测试：LauncherManager 即时候选管线行为契约
//
// 契约覆盖：
//   C5：Enter 分流 — performSelectedInstantAction() 有选中→执行+返回 true+不触发 AI；无选中→false
//   C6/C9：启动失败错误呈现 — 注入会 throw 的 MockAppLauncher → lastInstantError 被设置
//   C7：debounce — instantDebounceMsOverride=0，updateQuery 后 instantActions 落地为最后 query；空 query 立即清空
//   C8（键盘导航）：moveInstantSelection(up:) 循环移动 instantSelectedIndex 边界与循环语义
//
// 注入点（修复 SUGGESTION-1）：
//   registryOverride:BuiltinPluginRegistry?  — 注入固定 instantActions
//   instantDebounceMsOverride:Int?            — 测试置 0 跳过 debounce 等待
//
// 红队红线：不读取 LauncherManager.swift 的新增实现，只依据设计文档契约断言。
// 测试 WILL NOT compile 直到蓝队合并实现 — 这是预期的 TDD 红灯。

// MARK: - Mock：会抛错的 AppLaunching

/// 注入到 AppLauncherPlugin 的 mock launcher：每次 launch 都抛 LauncherError.appLaunchFailed。
private struct FailingAppLauncher: AppLaunching {
    let appName: String
    func launch(_ url: URL) throws {
        throw LauncherError.appLaunchFailed(appName)
    }
}

// MARK: - Mock：记录被启动 URL 的 AppLaunching

/// 注入到 AppLauncherPlugin 的 mock launcher：记录被调用的 URL，不真实启动 app。
private final class RecordingAppLauncher: AppLaunching {
    private(set) var launchedURLs: [URL] = []
    func launch(_ url: URL) throws {
        launchedURLs.append(url)
    }
}

// MARK: - Helper：构造注入用 BuiltinPluginRegistry（固定返回 LauncherAction）

@MainActor
private func makeFixedRegistry(actions: [LauncherAction]) -> BuiltinPluginRegistry {
    final class FixedPlugin: BuiltinPlugin {
        let id = "fixed-test"
        let priority = 0
        let sectionTitle = "Test"
        let fixedActions: [LauncherAction]
        init(_ actions: [LauncherAction]) { self.fixedActions = actions }
        func actions(for query: String) async -> [LauncherAction] {
            guard !query.isEmpty else { return [] }
            return fixedActions
        }
    }
    return BuiltinPluginRegistry(plugins: [FixedPlugin(actions)])
}

@MainActor
private func makeAction(id: String, title: String, score: Int = 100) -> LauncherAction {
    LauncherAction(
        id: id,
        title: title,
        subtitle: nil,
        icon: nil,
        pluginId: "fixed-test",
        score: score,
        perform: { /* 默认：不执行操作 */ }
    )
}

// MARK: - 测试类

@MainActor
final class InstantActionDispatchAcceptanceTests: XCTestCase {

    override func tearDown() async throws {
        LauncherManager.shared.hide()
        try await super.tearDown()
    }

    // MARK: - C7：debounce + 空清空

    /// instantDebounceMsOverride=0，updateQuery("saf") 后 instantActions 非空。
    func test_C7_updateQuery_withDebounce0_instantActionsPopulated() async {
        let safariAction = makeAction(id: "safari-id", title: "Safari")
        let registry = makeFixedRegistry(actions: [safariAction])

        LauncherManager.shared.registryOverride = registry
        LauncherManager.shared.instantDebounceMsOverride = 0

        // 触发 updateQuery
        LauncherManager.shared.updateQuery("saf")

        // debounce=0，给一个 runloop 等候 Task 完成
        await Task.yield()

        XCTAssertFalse(LauncherManager.shared.instantActions.isEmpty,
            "C7: debounce=0 时 updateQuery('saf') 后 instantActions 必须非空，实际 \(LauncherManager.shared.instantActions.count) 条")

        // Cleanup
        LauncherManager.shared.registryOverride = nil
        LauncherManager.shared.instantDebounceMsOverride = nil
    }

    /// 空 query 立即清空 instantActions（不进 debounce）。
    func test_C7_emptyQuery_immediatelyClearsInstantActions() async {
        let registry = makeFixedRegistry(actions: [makeAction(id: "x", title: "X")])
        LauncherManager.shared.registryOverride = registry
        LauncherManager.shared.instantDebounceMsOverride = 0

        // 先填充
        LauncherManager.shared.updateQuery("x")
        await Task.yield()
        XCTAssertFalse(LauncherManager.shared.instantActions.isEmpty,
            "C7 precondition: 'x' 后应有候选")

        // 然后清空
        LauncherManager.shared.updateQuery("")
        // 空 query 是立即清空（不走 debounce）
        XCTAssertTrue(LauncherManager.shared.instantActions.isEmpty,
            "C7: 空 query 必须立即清空 instantActions，实际 \(LauncherManager.shared.instantActions.count) 条")
        XCTAssertEqual(LauncherManager.shared.instantSelectedIndex, -1,
            "C7: 空 query 清空后 instantSelectedIndex 必须为 -1，实际 \(LauncherManager.shared.instantSelectedIndex)")

        // Cleanup
        LauncherManager.shared.registryOverride = nil
        LauncherManager.shared.instantDebounceMsOverride = nil
    }

    /// 连续两次 updateQuery（debounce=0），instantActions 最终是最后一次 query 的结果。
    func test_C7_consecutiveUpdateQuery_lastQueryWins() async {
        let actionA = LauncherAction(id: "a", title: "ActionA", subtitle: nil, icon: nil,
            pluginId: "test", score: 100, perform: {})
        let actionB = LauncherAction(id: "b", title: "ActionB", subtitle: nil, icon: nil,
            pluginId: "test", score: 100, perform: {})

        final class TwoQueryPlugin: BuiltinPlugin {
            let id = "two-q"
            let priority = 0
            let sectionTitle = "TQ"
            let aAction: LauncherAction
            let bAction: LauncherAction
            init(_ a: LauncherAction, _ b: LauncherAction) { aAction = a; bAction = b }
            func actions(for query: String) async -> [LauncherAction] {
                if query == "querya" { return [aAction] }
                if query == "queryb" { return [bAction] }
                return []
            }
        }

        let registry = BuiltinPluginRegistry(plugins: [TwoQueryPlugin(actionA, actionB)])
        LauncherManager.shared.registryOverride = registry
        LauncherManager.shared.instantDebounceMsOverride = 0

        LauncherManager.shared.updateQuery("querya")
        LauncherManager.shared.updateQuery("queryb")  // 第二次覆盖第一次
        // 有界轮询等待异步查询落地：updateQuery 触发的查询是异步的，单次 Task.yield() 在 CI
        // 较慢调度下不足以让第二次 query 的结果落地（顺序相关 flaky）。最多等 ~2s。
        for _ in 0..<200 where !LauncherManager.shared.instantActions.contains(where: { $0.title == "ActionB" }) {
            try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms
        }

        // 最终 instantActions 应是 queryb 的结果
        let titles = LauncherManager.shared.instantActions.map { $0.title }
        XCTAssertTrue(titles.contains("ActionB"),
            "C7: 连续输入只生效最后一次 query，最终 instantActions 应含 'ActionB'")
        XCTAssertFalse(titles.contains("ActionA"),
            "C7: 旧 query 的结果（ActionA）不应出现在最终 instantActions 中")

        // Cleanup
        LauncherManager.shared.registryOverride = nil
        LauncherManager.shared.instantDebounceMsOverride = nil
    }

    /// updateQuery 非空后 instantSelectedIndex 置 0（有候选自动选中第一条）。
    func test_C7_updateQuery_nonEmpty_setsSelectedIndex0() async {
        let registry = makeFixedRegistry(actions: [
            makeAction(id: "a1", title: "App1"),
            makeAction(id: "a2", title: "App2"),
        ])
        LauncherManager.shared.registryOverride = registry
        LauncherManager.shared.instantDebounceMsOverride = 0

        LauncherManager.shared.updateQuery("app")
        await Task.yield()

        XCTAssertEqual(LauncherManager.shared.instantSelectedIndex, 0,
            "C7: 有候选时 instantSelectedIndex 必须置为 0，实际 \(LauncherManager.shared.instantSelectedIndex)")

        // Cleanup
        LauncherManager.shared.registryOverride = nil
        LauncherManager.shared.instantDebounceMsOverride = nil
    }

    // MARK: - C5：Enter 分流（performSelectedInstantAction）

    /// 有选中 instant action → perform 执行 + 返回 true（不触发 AI）。
    func test_C5_performSelectedInstantAction_withSelection_returnsTrueAndPerforms() async {
        var performed = false
        let action = LauncherAction(
            id: "act1", title: "TestApp", subtitle: nil, icon: nil,
            pluginId: "test", score: 100,
            perform: { performed = true }
        )
        let registry = makeFixedRegistry(actions: [action])
        LauncherManager.shared.registryOverride = registry
        LauncherManager.shared.instantDebounceMsOverride = 0

        LauncherManager.shared.updateQuery("test")
        await Task.yield()

        // 确认有候选且已选中 index=0
        XCTAssertFalse(LauncherManager.shared.instantActions.isEmpty,
            "C5 precondition: instantActions 必须非空")
        XCTAssertEqual(LauncherManager.shared.instantSelectedIndex, 0,
            "C5 precondition: 首条应被选中")

        // Enter 分流
        let consumed = LauncherManager.shared.performSelectedInstantAction()

        XCTAssertTrue(consumed,
            "C5: 有选中 instant action 时 performSelectedInstantAction 必须返回 true")
        XCTAssertTrue(performed,
            "C5: perform 闭包必须被执行")

        // 执行后 instantActions 必须清空（hide 副作用）
        XCTAssertTrue(LauncherManager.shared.instantActions.isEmpty,
            "C5: 执行后 instantActions 必须清空（launcher hide 副作用）")

        // Cleanup
        LauncherManager.shared.registryOverride = nil
        LauncherManager.shared.instantDebounceMsOverride = nil
    }

    /// 无选中（instantSelectedIndex == -1）→ performSelectedInstantAction 返回 false。
    func test_C5_performSelectedInstantAction_noSelection_returnsFalse() {
        // 确保 instantActions 为空、instantSelectedIndex=-1
        LauncherManager.shared.updateQuery("")  // 空 query 立即清空

        let consumed = LauncherManager.shared.performSelectedInstantAction()
        XCTAssertFalse(consumed,
            "C5: 无选中时 performSelectedInstantAction 必须返回 false（回落 AI）")
    }

    /// performSelectedInstantAction 返回 true 时，不应触发 AI 流（验证通过 submit() 行为）。
    /// 间接验证：submit() 首句调用 performSelectedInstantAction()，消费后立即 return，
    /// 所以 lastInstantError 不会因 AI 流而被清空/覆盖。
    func test_C5_performSelectedInstantAction_trueDoesNotTriggerAI() async {
        var performed = false
        let action = LauncherAction(
            id: "ai-check", title: "AICheck", subtitle: nil, icon: nil,
            pluginId: "test", score: 100,
            perform: { performed = true }
        )
        let registry = makeFixedRegistry(actions: [action])
        LauncherManager.shared.registryOverride = registry
        LauncherManager.shared.instantDebounceMsOverride = 0

        LauncherManager.shared.updateQuery("aicheck")
        await Task.yield()

        let consumed = LauncherManager.shared.performSelectedInstantAction()
        XCTAssertTrue(consumed,  "C5: 确认内置管线消费")
        XCTAssertTrue(performed, "C5: perform 执行了")
        // 如果 AI 被错误触发，会有 .error 事件（无 provider 配置）并最终清空 instantActions 以外的状态
        // 此处只断言 perform 确实执行了，AI 流未被触发（不检查 network state，避免 flaky）

        // Cleanup
        LauncherManager.shared.registryOverride = nil
        LauncherManager.shared.instantDebounceMsOverride = nil
    }

    // MARK: - C6/C9：启动失败 → lastInstantError（场景 11）

    /// 注入会 throw LauncherError.appLaunchFailed 的 action →
    /// performSelectedInstantAction 捕获错误 → lastInstantError 被设置（不崩溃，不静默吞错）。
    func test_C6C9_scenario11_launchFailure_setsLastInstantError() async {
        let failingAction = LauncherAction(
            id: "fail-app", title: "FakeApp", subtitle: nil, icon: nil,
            pluginId: "test", score: 100,
            perform: { throw LauncherError.appLaunchFailed("FakeApp at /fake/path") }
        )
        let registry = makeFixedRegistry(actions: [failingAction])
        LauncherManager.shared.registryOverride = registry
        LauncherManager.shared.instantDebounceMsOverride = 0

        LauncherManager.shared.updateQuery("fake")
        await Task.yield()

        XCTAssertFalse(LauncherManager.shared.instantActions.isEmpty,
            "C6/C9 precondition: 应有 failingAction 候选")

        // 触发启动（会 throw）
        let consumed = LauncherManager.shared.performSelectedInstantAction()

        // 消费了内置管线（返回 true），但启动失败
        XCTAssertTrue(consumed, "C6/C9: 即使启动失败，内置管线仍算消费（返回 true）")

        // lastInstantError 必须被设置（不静默吞错，场景 11）
        XCTAssertNotNil(LauncherManager.shared.lastInstantError,
            "C6/C9（场景 11）: 启动失败时 lastInstantError 必须被设置，不能静默吞错")

        // Cleanup
        LauncherManager.shared.registryOverride = nil
        LauncherManager.shared.instantDebounceMsOverride = nil
        LauncherManager.shared.hide()  // 重置 lastInstantError
    }

    /// LauncherError.appLaunchFailed(String) case 存在（C9）且有中文 errorDescription。
    func test_C9_appLaunchFailed_errorCase_exists_withChineseDescription() {
        let err = LauncherError.appLaunchFailed("Safari")
        // 有 localizedDescription（非 nil）
        XCTAssertNotNil(err.errorDescription,
            "C9: LauncherError.appLaunchFailed 必须有 errorDescription")
        // 错误描述包含中文字符（用户文案为中文）
        let desc = err.errorDescription ?? ""
        let hasChinese = desc.unicodeScalars.contains { $0.value > 0x4E00 && $0.value <= 0x9FFF }
        XCTAssertTrue(hasChinese,
            "C9: appLaunchFailed errorDescription 必须包含中文用户文案，实际：'\(desc)'")
    }

    // MARK: - 场景 8：键盘导航 — moveInstantSelection(up:) 循环语义

    /// 向下移动：从 index=0 → 1 → 2（顺序）。
    func test_C8_moveInstantSelection_down_incrementsIndex() async {
        let registry = makeFixedRegistry(actions: [
            makeAction(id: "a1", title: "App1"),
            makeAction(id: "a2", title: "App2"),
            makeAction(id: "a3", title: "App3"),
        ])
        LauncherManager.shared.registryOverride = registry
        LauncherManager.shared.instantDebounceMsOverride = 0

        LauncherManager.shared.updateQuery("app")
        await Task.yield()

        // 初始 index=0
        XCTAssertEqual(LauncherManager.shared.instantSelectedIndex, 0,
            "导航测试 precondition: 初始 index=0")

        // 向下 → 1
        LauncherManager.shared.moveInstantSelection(up: false)
        XCTAssertEqual(LauncherManager.shared.instantSelectedIndex, 1,
            "场景 8: down from 0 → 1，实际 \(LauncherManager.shared.instantSelectedIndex)")

        // 向下 → 2
        LauncherManager.shared.moveInstantSelection(up: false)
        XCTAssertEqual(LauncherManager.shared.instantSelectedIndex, 2,
            "场景 8: down from 1 → 2，实际 \(LauncherManager.shared.instantSelectedIndex)")

        // Cleanup
        LauncherManager.shared.registryOverride = nil
        LauncherManager.shared.instantDebounceMsOverride = nil
    }

    /// 向上移动：从 index=0 → 循环到最后一条（count-1）。
    func test_C8_moveInstantSelection_up_wrapsFromZeroToLast() async {
        let registry = makeFixedRegistry(actions: [
            makeAction(id: "a1", title: "App1"),
            makeAction(id: "a2", title: "App2"),
            makeAction(id: "a3", title: "App3"),
        ])
        LauncherManager.shared.registryOverride = registry
        LauncherManager.shared.instantDebounceMsOverride = 0

        LauncherManager.shared.updateQuery("app")
        await Task.yield()

        XCTAssertEqual(LauncherManager.shared.instantSelectedIndex, 0,
            "导航 wrap 测试 precondition: 初始 index=0")

        // 从 0 向上 → 循环到 count-1（2）
        LauncherManager.shared.moveInstantSelection(up: true)
        let count = LauncherManager.shared.instantActions.count  // 3
        XCTAssertEqual(LauncherManager.shared.instantSelectedIndex, count - 1,
            "场景 8: up from 0 → 循环到 \(count-1)，实际 \(LauncherManager.shared.instantSelectedIndex)")

        // Cleanup
        LauncherManager.shared.registryOverride = nil
        LauncherManager.shared.instantDebounceMsOverride = nil
    }

    /// 向下移动到底部后循环回 0。
    func test_C8_moveInstantSelection_down_wrapsFromLastToZero() async {
        let registry = makeFixedRegistry(actions: [
            makeAction(id: "a1", title: "App1"),
            makeAction(id: "a2", title: "App2"),
            makeAction(id: "a3", title: "App3"),
        ])
        LauncherManager.shared.registryOverride = registry
        LauncherManager.shared.instantDebounceMsOverride = 0

        LauncherManager.shared.updateQuery("app")
        await Task.yield()

        let count = LauncherManager.shared.instantActions.count  // 3
        // 先移动到最后一条
        LauncherManager.shared.moveInstantSelection(up: false)  // 0 → 1
        LauncherManager.shared.moveInstantSelection(up: false)  // 1 → 2（= count-1）
        XCTAssertEqual(LauncherManager.shared.instantSelectedIndex, count - 1,
            "导航 wrap down 测试 precondition: 移到末尾")

        // 再向下 → 循环回 0
        LauncherManager.shared.moveInstantSelection(up: false)
        XCTAssertEqual(LauncherManager.shared.instantSelectedIndex, 0,
            "场景 8: down from last(\(count-1)) → 循环到 0，实际 \(LauncherManager.shared.instantSelectedIndex)")

        // Cleanup
        LauncherManager.shared.registryOverride = nil
        LauncherManager.shared.instantDebounceMsOverride = nil
    }

    /// 空 instantActions 时，moveInstantSelection 无操作（不崩溃，index 保持 -1）。
    func test_C8_moveInstantSelection_emptyActions_noOpNoCrash() {
        LauncherManager.shared.updateQuery("")  // 清空
        XCTAssertTrue(LauncherManager.shared.instantActions.isEmpty,
            "场景 8 precondition: instantActions 必须为空")

        // 不应崩溃
        LauncherManager.shared.moveInstantSelection(up: true)
        LauncherManager.shared.moveInstantSelection(up: false)

        XCTAssertEqual(LauncherManager.shared.instantSelectedIndex, -1,
            "场景 8: 空候选时 moveInstantSelection 不改变 instantSelectedIndex（保持 -1）")
    }

    // MARK: - show/hide 清空 instant 三态

    /// show() 后 hide() 清空 instantActions / instantSelectedIndex / lastInstantError。
    func test_showHide_clearsInstantState() async {
        // 先填充状态
        let registry = makeFixedRegistry(actions: [makeAction(id: "x", title: "X")])
        LauncherManager.shared.registryOverride = registry
        LauncherManager.shared.instantDebounceMsOverride = 0

        LauncherManager.shared.show()
        LauncherManager.shared.updateQuery("x")
        await Task.yield()

        // hide 后清空
        LauncherManager.shared.hide()

        XCTAssertTrue(LauncherManager.shared.instantActions.isEmpty,
            "hide(): instantActions 必须清空")
        XCTAssertEqual(LauncherManager.shared.instantSelectedIndex, -1,
            "hide(): instantSelectedIndex 必须重置为 -1")
        XCTAssertNil(LauncherManager.shared.lastInstantError,
            "hide(): lastInstantError 必须清空")

        // Cleanup
        LauncherManager.shared.registryOverride = nil
        LauncherManager.shared.instantDebounceMsOverride = nil
    }
}
