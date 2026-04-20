import XCTest
@testable import BuddyCore

// MARK: - TimeoutAcceptanceTests
//
// 红队验收测试：验证以下三项修复的行为契约：
//   1. UserPromptSubmit hook 已注册到 plugin/hooks/hooks.json
//   2. hook 脚本发送 pid 字段（通过 SessionManager.handle 消费验证）
//   3. checkTimeouts() 使用进程存活检测（kill(pid, 0)），超时阈值 30 分钟
//
// 这些测试故意在修复合入前无法通过，修复合入后应全部绿灯。

final class TimeoutAcceptanceTests: XCTestCase {

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

    // MARK: - 场景 1: 进程存活时猫咪永不超时消失

    /// 进程仍在运行（PID = 当前进程），即使 lastActivity 已超过 30 分钟，
    /// checkTimeouts() 不应删除该会话，只应将状态保持在 idle。
    func testProcessAliveSessionNeverRemovedByTimeout() {
        let sid = "alive-process-session"
        let currentPid = Int(ProcessInfo.processInfo.processIdentifier)

        // 创建带当前进程 PID 的会话
        manager.handle(message: TestHelpers.makeMessage(
            sessionId: sid, event: "thinking", cwd: "/projects/alive", pid: currentPid
        ))
        XCTAssertNotNil(manager.sessions[sid], "前提：会话应已创建")

        // 将 lastActivity 设为 31 分钟前（超过 30 分钟 removeTimeout）
        manager.sessions[sid]?.lastActivity = Date(timeIntervalSinceNow: -(31 * 60))

        manager.checkTimeouts()

        // 进程存活 → 会话不应被删除
        XCTAssertNotNil(manager.sessions[sid],
                        "进程存活时，会话不应因超时被删除")
        XCTAssertEqual(manager.sessions[sid]?.state, .idle,
                       "超时后进程存活的会话状态应为 idle")
        XCTAssertFalse(scene.removeCatCalls.contains(sid),
                       "进程存活时，removeCat 不应被调用")
    }

    // MARK: - 场景 2: 进程死亡后猫咪在 30 分钟超时后消失

    /// PID 对应的进程已死亡（使用大概率不存在的 PID 99999），
    /// lastActivity 超过 30 分钟，checkTimeouts() 应删除该会话并释放颜色。
    func testDeadProcessSessionRemovedAfterTimeout() {
        let sid = "dead-process-session"
        let deadPid = 99999

        // 创建带不存在 PID 的会话
        manager.handle(message: TestHelpers.makeMessage(
            sessionId: sid, event: "thinking", cwd: "/projects/dead", pid: deadPid
        ))
        XCTAssertNotNil(manager.sessions[sid], "前提：会话应已创建")
        let color = manager.sessions[sid]!.color

        // 将 lastActivity 设为 31 分钟前（超过 30 分钟 removeTimeout）
        manager.sessions[sid]?.lastActivity = Date(timeIntervalSinceNow: -(31 * 60))

        manager.checkTimeouts()

        // 进程已死 → 会话应被删除
        XCTAssertNil(manager.sessions[sid],
                     "进程死亡且超时后，会话应被删除")
        XCTAssertTrue(scene.removeCatCalls.contains(sid),
                      "进程死亡且超时后，removeCat 应被调用")
        XCTAssertFalse(manager.usedColors.contains(color),
                       "会话删除后，颜色应被释放")
    }

    // MARK: - 场景 3: 无 PID 会话 30 分钟后被清理

    /// 没有 PID 的会话（旧版 hook 或 session_start 先于 pid 到达），
    /// lastActivity 超过 30 分钟，应被 checkTimeouts() 删除。
    func testNoPidSessionRemovedAfterTimeout() {
        let sid = "no-pid-session"

        // 创建无 PID 的会话
        manager.handle(message: TestHelpers.makeMessage(
            sessionId: sid, event: "thinking", cwd: "/projects/nopid"
            // 无 pid 参数
        ))
        XCTAssertNotNil(manager.sessions[sid], "前提：会话应已创建")
        XCTAssertNil(manager.sessions[sid]?.pid, "前提：会话的 pid 应为 nil")

        // 将 lastActivity 设为 31 分钟前（超过 30 分钟 removeTimeout）
        manager.sessions[sid]?.lastActivity = Date(timeIntervalSinceNow: -(31 * 60))

        manager.checkTimeouts()

        // 无 PID → 视同进程不存在，应删除
        XCTAssertNil(manager.sessions[sid],
                     "无 PID 的会话超时后应被删除")
        XCTAssertTrue(scene.removeCatCalls.contains(sid),
                      "无 PID 的会话超时后，removeCat 应被调用")
    }

    // MARK: - 场景 4: 5 分钟 idle 阈值不受影响

    /// lastActivity 为 6 分钟前（超过 5 分钟 idleTimeout，但未超过 30 分钟 removeTimeout），
    /// 会话应继续存在，状态应变为 idle，不应被删除。
    func testIdleThresholdTransitionsToIdleWithoutRemoval() {
        let sid = "idle-threshold-session"

        manager.handle(message: TestHelpers.makeMessage(
            sessionId: sid, event: "thinking", cwd: "/projects/idle"
        ))
        XCTAssertEqual(manager.sessions[sid]?.state, .thinking, "前提：初始状态应为 thinking")

        // 将 lastActivity 设为 6 分钟前（仅超过 idle 阈值，未超过 remove 阈值）
        manager.sessions[sid]?.lastActivity = Date(timeIntervalSinceNow: -(6 * 60))

        manager.checkTimeouts()

        // 未超过 removeTimeout → 会话存在
        XCTAssertNotNil(manager.sessions[sid],
                        "6 分钟未活跃的会话不应被删除（remove 阈值为 30 分钟）")
        XCTAssertEqual(manager.sessions[sid]?.state, .idle,
                       "超过 5 分钟 idle 阈值后，会话状态应变为 idle")
        XCTAssertFalse(scene.removeCatCalls.contains(sid),
                       "仅超过 idle 阈值时，removeCat 不应被调用")
    }

    // MARK: - 场景 5: hooks.json 包含 UserPromptSubmit 注册

    /// plugin/hooks/hooks.json 必须包含 "UserPromptSubmit" key，
    /// 确保 hook 脚本在用户提交 prompt 时也能触发，从而发送 pid 字段给 app。
    func testHooksJsonContainsUserPromptSubmit() throws {
        let hooksJsonPath = findHooksJsonPath()
        XCTAssertNotNil(hooksJsonPath,
                        "应能找到 plugin/hooks/hooks.json 文件")

        guard let path = hooksJsonPath else { return }

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
            "hooks.json 应为合法 JSON 对象"
        )
        let hooks = try XCTUnwrap(
            json["hooks"] as? [String: Any],
            "hooks.json 顶层应包含 'hooks' 字典"
        )

        XCTAssertNotNil(hooks["UserPromptSubmit"],
                        "hooks.json 必须注册 'UserPromptSubmit' hook，以确保 pid 字段能被发送")
    }

    // MARK: - 场景 6: 多会话独立超时（存活进程保留，死亡进程删除）

    /// 同时存在两个会话：
    ///   A — PID 为当前进程（存活），lastActivity 超过 30 分钟
    ///   B — PID 为 99999（死亡），lastActivity 超过 30 分钟
    /// checkTimeouts() 后：A 保留，B 删除。
    func testMultipleSessionsIndependentTimeout() {
        let sidA = "multi-alive-session"
        let sidB = "multi-dead-session"
        let currentPid = Int(ProcessInfo.processInfo.processIdentifier)
        let deadPid = 99999

        // 创建会话 A（存活进程）
        manager.handle(message: TestHelpers.makeMessage(
            sessionId: sidA, event: "thinking", cwd: "/projects/a", pid: currentPid
        ))
        // 创建会话 B（死亡进程）
        manager.handle(message: TestHelpers.makeMessage(
            sessionId: sidB, event: "thinking", cwd: "/projects/b", pid: deadPid
        ))

        XCTAssertNotNil(manager.sessions[sidA], "前提：会话 A 应已创建")
        XCTAssertNotNil(manager.sessions[sidB], "前提：会话 B 应已创建")

        let colorB = manager.sessions[sidB]!.color

        // 两个会话都设为 31 分钟前活跃（超过 30 分钟 removeTimeout）
        let staleTime = Date(timeIntervalSinceNow: -(31 * 60))
        manager.sessions[sidA]?.lastActivity = staleTime
        manager.sessions[sidB]?.lastActivity = staleTime

        manager.checkTimeouts()

        // A（存活）应保留
        XCTAssertNotNil(manager.sessions[sidA],
                        "会话 A（进程存活）不应被超时删除")
        XCTAssertFalse(scene.removeCatCalls.contains(sidA),
                       "会话 A（进程存活）的 removeCat 不应被调用")

        // B（死亡）应被删除
        XCTAssertNil(manager.sessions[sidB],
                     "会话 B（进程死亡）应被超时删除")
        XCTAssertTrue(scene.removeCatCalls.contains(sidB),
                      "会话 B（进程死亡）的 removeCat 应被调用")
        XCTAssertFalse(manager.usedColors.contains(colorB),
                       "会话 B 删除后，其颜色应被释放")
    }

    // MARK: - Private Helpers

    /// 从测试 bundle 的可执行文件路径上溯，找到仓库根目录下的 plugin/hooks/hooks.json。
    /// 支持 Xcode 和 swift test 两种运行环境。
    private func findHooksJsonPath() -> String? {
        // 策略 1：从 Bundle 可执行文件上溯（swift test 产出物通常在 .build/ 下）
        var url = Bundle.main.bundleURL
        for _ in 0..<10 {
            let candidate = url.appendingPathComponent("plugin/hooks/hooks.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate.path
            }
            url = url.deletingLastPathComponent()
        }

        // 策略 2：从 #file 的源文件路径上溯（编译时 #file 包含源文件绝对路径）
        let sourceFile = URL(fileURLWithPath: #file)
        var sourceUrl = sourceFile.deletingLastPathComponent()
        for _ in 0..<10 {
            let candidate = sourceUrl.appendingPathComponent("plugin/hooks/hooks.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate.path
            }
            sourceUrl = sourceUrl.deletingLastPathComponent()
        }

        return nil
    }
}
