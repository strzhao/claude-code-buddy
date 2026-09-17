import Foundation
@testable import BuddyCore

// MARK: - RedTeamAcceptanceSupport
//
// 红队验收测试共享基建（非测试类，仅供 *AcceptanceTests 使用）。
//
// 设计约束（红队信息隔离）：
//  - 只引用「既有」符号 + 设计文档 `## 契约规约` 已声明的接口名/字面量，
//    不引用本次实现新增的类型（蓝队未落地时测试必须可编译，断言允许失败 = TDD 红灯）。
//  - headless 判型驱动走**生产行为本身**：真实子进程（argv 含 `-p`/`--print` 精确 token）
//    + Claude Code session 注册表文件 `~/.claude/sessions/<pid>.json`
//    （字段名 sessionId/pid/cwd/startedAt 与真实注册表一致，2026-09-17 实证），
//    不注入任何未声明的 mock 协议（注入点未在契约中声明）。
//  - 时序依据 C-HEADLESS-DETECT：resolve 重试退避 0.5s×4 → 无注册表文件的合成会话
//    fail-open interactive 约 ≥2s；注册表文件在场的 fixture 会话判型远快于此。

enum RedTeamAcceptance {

    /// 红队合成 sessionId 前缀（UUID 后缀防与真实会话/其他测试撞车）
    static let sessionPrefix = "redteam-acc-"

    /// Claude Code session 注册表目录（设计文档声明的反查数据源）
    static var registryDirectory: String {
        NSString(string: "~/.claude/sessions").expandingTildeInPath
    }

    /// 有注册表文件在场的 fixture 会话：resolve+check 很快，判型窗口余量
    static let headlessVerdictWindow: TimeInterval = 5.0

    /// 无注册表文件的合成会话：resolve 重试 0.5s×4 耗尽后 fail-open，等待上屏的上限
    static let failOpenTimeout: TimeInterval = 25.0

    static func uniqueSessionId(_ name: String) -> String {
        "\(sessionPrefix)\(name)-\(UUID().uuidString.prefix(8).lowercased())"
    }

    // MARK: RunLoop 泵式等待（主队列 / MainActor 闭包在等待期间照常执行）

    /// 轮询 condition 直到成立或超时；期间泵 RunLoop 让主队列工作（检测链回主 actor 的落点）得以推进。
    /// 返回 condition 是否在超时前成立。
    ///
    /// ⚠️ 仅限**同步**测试方法使用：async 测试方法本身是主 actor 上的一个 job，
    /// 同步自旋不挂起会让检测链排队的主 actor 回跳任务饿死（协作式调度无法抢占）。
    /// async 测试用 `waitUntilAsync` / `waitForVerdictWindow`。
    @discardableResult
    static func waitUntil(timeout: TimeInterval, interval: TimeInterval = 0.05, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(interval))
        }
        return condition()
    }

    /// async 版轮询：每次检查间 `Task.sleep` 挂起，让主 actor 排空检测链回跳任务后再复查。
    @discardableResult
    static func waitUntilAsync(timeout: TimeInterval, interval: TimeInterval = 0.05, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        return condition()
    }

    /// async 版判型窗口等待：挂起 `headlessVerdictWindow` 秒，保证 fixture 会话的
    /// resolve→check→回主 actor 判型链完成后再做观察（等价 sync 侧 Thread.sleep + 泵）。
    static func waitForVerdictWindow() async {
        try? await Task.sleep(nanoseconds: UInt64(headlessVerdictWindow * 1_000_000_000))
    }

    // MARK: HookMessage 构造（含 total_tokens；TestHelpers.makeMessage 不带该字段）

    static func makeHookMessage(
        sessionId: String,
        event: String,
        cwd: String? = nil,
        pid: Int? = nil,
        terminalId: String? = nil,
        totalTokens: Int? = nil,
        timestamp: TimeInterval = 1_700_000_000
    ) -> HookMessage {
        var dict: [String: Any] = [
            "session_id": sessionId,
            "event": event,
            "timestamp": timestamp,
        ]
        if let cwd = cwd { dict["cwd"] = cwd }
        if let pid = pid { dict["pid"] = pid }
        if let tid = terminalId { dict["terminal_id"] = tid }
        if let tokens = totalTokens { dict["total_tokens"] = tokens }
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(HookMessage.self, from: data)
    }
}

// MARK: - RedTeamHeadlessFixture
// 真实进程 + 真实注册表文件构成的 headless/交互会话 fixture。
// argv 形态：
//   "-p"      → `/bin/sh -c sleep 30 -p`   （ps 空白分词含精确 token `-p` → headless 形态）
//   "--print" → 同上，`--print` token       → headless 形态
//   "-printer"→ 子串干扰形态（token `-printer` ≠ `-p`，非子串误判防线 → 交互形态）
//   nil       → `/bin/sh -c sleep 30`      → 交互形态

final class RedTeamHeadlessFixture {

    let sessionId: String
    let process: Process
    let registryFilePath: String
    private(set) var processKilled = false

    /// 创建真实存活进程并写入 session 注册表文件（`<pid>.json`）。
    /// - Parameters:
    ///   - sessionId: 红队唯一 sessionId（RedTeamAcceptance.uniqueSessionId 产出）
    ///   - argvToken: 见类型注释；nil = 交互形态
    init(sessionId: String, argvToken: String?) throws {
        self.sessionId = sessionId

        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        if let token = argvToken {
            sh.arguments = ["-c", "sleep 30", token]
        } else {
            sh.arguments = ["-c", "sleep 30"]
        }
        sh.standardOutput = FileHandle.nullDevice
        sh.standardError = FileHandle.nullDevice
        try sh.run()
        self.process = sh

        // 注册表文件：字段名与真实 Claude Code 注册表一致（sessionId/pid/cwd/startedAt）
        let pid = Int(sh.processIdentifier)
        let dir = RedTeamAcceptance.registryDirectory
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent("\(pid).json")
        let content: [String: Any] = [
            "sessionId": sessionId,
            "pid": pid,
            "cwd": "/tmp/redteam-acceptance",
            "startedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        let data = try JSONSerialization.data(withJSONObject: content)
        try data.write(to: URL(fileURLWithPath: path))
        self.registryFilePath = path
    }

    /// 进程存活快照（避免直接依赖 process.isRunning 的竞态，走 ps 同款系统事实）
    var isProcessAlive: Bool {
        process.isRunning
    }

    /// kill 进程（S8 异常退出路径）。注意：需在判型窗口（RedTeamAcceptance.headlessVerdictWindow）之后再 kill，
    /// 否则 ps 探测失败会按契约 fail-open 成 interactive。
    /// terminate() 后必须 waitUntilExit()：SIGTERM 在途约 200ms 内 kill(pid,0) 仍报活，且未 reap 的
    /// zombie 恒报活——不等待会令 testS8 的「进程死亡 + idle → 清理」断言撞上 fixture 自身竞态
    /// （QA 四方独立定位，2026-09-18；断言语义零改动，仅修测试机制）。
    func killProcess() {
        guard !processKilled else { return }
        processKilled = true
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }

    /// 清理：终止进程 + 删除注册表文件（tearDown 必调，绝不污染真实注册表）
    func cleanup() {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        try? FileManager.default.removeItem(atPath: registryFilePath)
    }
}
