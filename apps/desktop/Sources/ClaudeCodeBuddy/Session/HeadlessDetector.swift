import Foundation
import Darwin

// MARK: - 判型结果（C-HEADLESS-DETECT）

/// ps argv 判型四值结果。
/// - `interactive`：argv 无 `-p`/`--print` 精确 token → 交互会话
/// - `headless`：argv 含 `-p` 或 `--print` 精确 token → 后台任务
/// - `processDead`：存活探测 ESRCH → 判 dead，调用方不上猫并按 C-HEADLESS-CLEANUP 清理
/// - `unknown`：其他 ps/探测失败 → fail-open 非 headless（调用方按 interactive 处置）
enum HeadlessArgvVerdict: Equatable, Sendable {
    case interactive
    case headless
    case processDead
    case unknown
}

// MARK: - 注册表反查条目

/// `~/.claude/sessions/<pid>.json` 反查结果。
/// `procStart`（进程启动时间字符串）用于 pid 复用防御（C-HEADLESS-CLEANUP）。
struct HeadlessRegistryEntry: Equatable, Sendable {
    let pid: Int
    let procStart: String?
}

// MARK: - Seam 协议（工程先例：ScreenLocking / AppLaunching / CopyService）

/// sessionId 反查 pid（扫 `~/.claude/sessions/*.json`，文件名 = `<pid>.json`）。
protocol HeadlessResolving: Sendable {
    /// 契约 seam：反查 sessionId 得 pid；无匹配 → nil
    func resolve(pidFor sessionId: String) async -> Int?
    /// 扩展入口：带 procStart 的完整反查（`resolve` 默认实现委托于此）
    func resolveEntry(pidFor sessionId: String) async -> HeadlessRegistryEntry?
}

extension HeadlessResolving {
    func resolve(pidFor sessionId: String) async -> Int? {
        await resolveEntry(pidFor: sessionId)?.pid
    }
}

/// ps argv 判型。
protocol HeadlessChecking: Sendable {
    /// 判型主入口：interactive / headless / processDead(ESRCH) / unknown
    func check(pid: Int) -> HeadlessArgvVerdict
    /// 进程启动时间（`ps -o lstart=`，与注册表 `procStart` 同格式），失败 → nil。
    /// pid 复用防御用（C-HEADLESS-CLEANUP）。
    func processStartTime(pid: Int) -> String?
}

extension HeadlessChecking {
    /// 契约 seam：仅 headless 为 true（processDead/unknown 由 verdict 层分别处置）
    func isHeadless(pid: Int) -> Bool {
        check(pid: pid) == .headless
    }
}

// MARK: - 生产实现：session 注册表反查

struct SessionRegistryPidResolver: HeadlessResolving {

    // C-HEADLESS-DETECT：resolve 重试参数固化为常量（暴露给单测）
    static let resolveRetryInterval: TimeInterval = 0.5
    static let resolveMaxRetries = 4

    private let sessionsDirectory: String
    private let retryInterval: TimeInterval
    private let maxRetries: Int

    /// - Parameters:
    ///   - sessionsDirectory: 注册表目录（默认 `~/.claude/sessions`，测试注入临时目录）
    ///   - retryInterval: 单测注入小间隔验证重试语义（生产 0.5s）
    ///   - maxRetries: 单测注入小次数（生产 4）
    init(
        sessionsDirectory: String = NSHomeDirectory() + "/.claude/sessions",
        retryInterval: TimeInterval = SessionRegistryPidResolver.resolveRetryInterval,
        maxRetries: Int = SessionRegistryPidResolver.resolveMaxRetries
    ) {
        self.sessionsDirectory = sessionsDirectory
        self.retryInterval = retryInterval
        self.maxRetries = maxRetries
    }

    /// 反查 sessionId → 注册表条目。
    /// SessionStart hook 与 session 文件落盘存在同秒级写时机窗口，故文件缺失按
    /// 0.5s×4 重试（首查 + 4 次重试）；耗尽仍无 → nil（调用方 fail-open 非 headless）。
    func resolveEntry(pidFor sessionId: String) async -> HeadlessRegistryEntry? {
        for attempt in 0...maxRetries {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: UInt64(retryInterval * 1_000_000_000))
            }
            if let entry = Self.scanOnce(sessionId: sessionId, directory: sessionsDirectory) {
                return entry
            }
        }
        return nil
    }

    /// 单次扫描（无重试）——纯查找，便于单测。
    /// 判型依据 = argv（进程存活期间由 SessionManager 调 ps），注册表 `kind`/`entrypoint`
    /// 字段禁止用作判型（实证 10/10 含 `-p --headless` 进程在内全为 "interactive"，不可靠）。
    nonisolated static func scanOnce(sessionId: String, directory: String) -> HeadlessRegistryEntry? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: directory) else { return nil }
        for file in files where file.hasSuffix(".json") {
            guard let data = fm.contents(atPath: directory + "/" + file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let entrySessionId = json["sessionId"] as? String,
                  entrySessionId == sessionId,
                  let pid = json["pid"] as? Int else {
                continue
            }
            return HeadlessRegistryEntry(pid: pid, procStart: json["procStart"] as? String)
        }
        return nil
    }
}

// MARK: - 生产实现：ps argv 判型

struct ProcessArgsHeadlessChecker: HeadlessChecking {

    func check(pid: Int) -> HeadlessArgvVerdict {
        // 存活探测：kill(pid, 0) —— ESRCH = 进程不存在（判 dead）；
        // EPERM = 存在但非本用户（视为存活，继续 argv 判型）；其他错误 → unknown。
        if kill(pid_t(pid), 0) != 0 {
            if errno == ESRCH { return .processDead }
            if errno != EPERM { return .unknown }
        }
        guard let args = Self.runPs(field: "args=", pid: pid) else { return .unknown }
        return Self.argvContainsPrintToken(args) ? .headless : .interactive
    }

    func processStartTime(pid: Int) -> String? {
        Self.runPs(field: "lstart=", pid: pid)
    }

    /// 运行 `ps -o <field>= -p <pid>`，退出码 0 返回首行（trim），失败 nil
    private static func runPs(field: String, pid: Int) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", field, "-p", "\(pid)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8) else {
            return nil
        }
        let line = output.split(separator: "\n").first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 纯函数：`ps -o args=` 输出按空白分词，存在 `-p` 或 `--print` **精确 token** → headless。
    /// 非子串匹配（防 `--printer` / `-pp` 误判，C-HEADLESS-DETECT）。
    static func argvContainsPrintToken(_ argsOutput: String) -> Bool {
        let tokens = argsOutput
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
        return tokens.contains("-p") || tokens.contains("--print")
    }
}

// MARK: - 测试宿主默认 resolver

/// XCTest 宿主下 SessionManager 的默认 resolver：立即返回 nil（零等待 fail-open
/// interactive）。测试需要驱动 pending/headless/dead 分支时显式注入 Mock。
struct FailFastHeadlessResolver: HeadlessResolving {
    func resolveEntry(pidFor sessionId: String) async -> HeadlessRegistryEntry? { nil }
}
