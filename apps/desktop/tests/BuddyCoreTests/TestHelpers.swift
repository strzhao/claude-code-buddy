import Foundation
@testable import BuddyCore

/// Factory helpers shared across all SessionManager test classes.
enum TestHelpers {

    /// 默认注入 FailFastHeadlessResolver：单测内检测立即 fail-open（零重试等待）。
    /// 需要驱动 pending/headless/dead 分支时用 MockHeadlessResolver/MockHeadlessChecker 显式构造。
    static func makeManager(scene: MockScene = MockScene()) -> (SessionManager, MockScene) {
        let manager = SessionManager(scene: scene, headlessResolver: FailFastHeadlessResolver())
        return (manager, scene)
    }

    static func makeMessage(
        sessionId: String = "test-session",
        event: String = "idle",
        cwd: String? = nil,
        pid: Int? = nil,
        terminalId: String? = nil,
        tool: String? = nil,
        description: String? = nil,
        label: String? = nil,
        timestamp: TimeInterval = 1_700_000_000
    ) -> HookMessage {
        var dict: [String: Any] = [
            "session_id": sessionId,
            "event": event,
            "timestamp": timestamp
        ]
        if let cwd = cwd { dict["cwd"] = cwd }
        if let pid = pid { dict["pid"] = pid }
        if let tid = terminalId { dict["terminal_id"] = tid }
        if let tool = tool { dict["tool"] = tool }
        if let desc = description { dict["description"] = desc }
        if let lbl = label { dict["label"] = lbl }
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(HookMessage.self, from: data)
    }

    /// 等待 headless 检测链全部落定（泵主 RunLoop 让主队列块执行）。
    /// 配合 FailFastHeadlessResolver 注入时单次落定 ≤ 2 个 runloop turn。
    /// tearDown 也应调用：防止在飞检测的迟到落定污染下一测试的共享 color 文件。
    /// 注意：仅用于同步测试（XCTest 主线程）；async 测试用 settleHeadlessDetectionAsync。
    static func settleHeadlessDetection(_ manager: SessionManager, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while manager.headlessDetectionsInFlight > 0 && Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        // 再泵一拍，确保落定块（DispatchQueue.main.async）执行完
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }

    /// async 版 settle：挂起让出主 actor，主队列落定块得以执行（同步版在 async 上下文泵不动主队列）。
    static func settleHeadlessDetectionAsync(_ manager: SessionManager, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while manager.headlessDetectionsInFlight > 0 && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

// MARK: - Headless Detection Mocks（C-HEADLESS-DETECT seam）

/// 可编程 resolver：固定返回注入条目（nil = 模拟注册表无匹配 → fail-open）
final class MockHeadlessResolver: HeadlessResolving {
    var entry: HeadlessRegistryEntry?
    /// 记录每次反查的 sessionId（断言「每 session 至多检测一次」）
    private(set) var resolveCalls: [String] = []

    init(entry: HeadlessRegistryEntry?) {
        self.entry = entry
    }

    func resolveEntry(pidFor sessionId: String) async -> HeadlessRegistryEntry? {
        resolveCalls.append(sessionId)
        return entry
    }
}

/// 可编程 checker：固定返回注入 verdict；processStartTime 可编程（pid 复用防御单测）
final class MockHeadlessChecker: HeadlessChecking {
    var verdict: HeadlessArgvVerdict
    var startTime: String?
    private(set) var checkedPids: [Int] = []

    init(verdict: HeadlessArgvVerdict = .interactive, startTime: String? = nil) {
        self.verdict = verdict
        self.startTime = startTime
    }

    func check(pid: Int) -> HeadlessArgvVerdict {
        checkedPids.append(pid)
        return verdict
    }

    func processStartTime(pid: Int) -> String? {
        startTime
    }
}
