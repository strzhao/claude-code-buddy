import Foundation
import Security
import CryptoKit
import IOKit

// MARK: - Constants

private let socketPath = "/tmp/claude-buddy.sock"
private let colorFilePath = "/tmp/claude-buddy-colors.json"
private let appVersion = "0.6.0"

// MARK: - Launcher Config Constants (mirror of Sources/ClaudeCodeBuddy/Launcher/LauncherConstants.swift)
// ⚠️ SOURCE OF TRUTH: BuddyCore/Launcher/LauncherConstants.swift
// ⚠️ Any change here must be reflected in BuddyCore (and vice versa)
// CLI cannot depend on BuddyCore (would pull in AppKit/SwiftUI/SpriteKit, slowing buddy CLI startup)
// 注：优先读 $HOME 环境变量（便于测试时通过 HOME 重定向到临时目录隔离）；
// 生产环境 $HOME 与 NSHomeDirectory() 等价；fallback 保证 $HOME 未设时仍可用。
private let launcherKeychainService = "claude-code-buddy.launcher"
private let buddyHomeDir: String = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
private let launcherConfigDir = "\(buddyHomeDir)/.buddy"
private let launcherConfigPath = "\(launcherConfigDir)/launcher.json"
private let launcherPluginsDir = "\(launcherConfigDir)/launcher-plugins"
private let launcherTrustPath = "\(launcherConfigDir)/launcher-trust.json"
private let launcherMinAPIKeyLength = 8

// MARK: - Log Path Constants (mirror of Sources/ClaudeCodeBuddy/Logging/LogConfig.swift)
// ⚠️ SOURCE OF TRUTH: BuddyCore/Logging/LogConfig.swift（契约 C1/C5）
// ⚠️ Any change here must be reflected in BuddyCore (and vice versa)
// CLI 不能 import BuddyCore（避免引入 AppKit/SpriteKit），路径常量在此 mirror。
// 优先级：BUDDY_LOG_DIR env > $HOME/.buddy/logs（与 LogConfig.logsDir 同语义）
private let logsDir: String = ProcessInfo.processInfo.environment["BUDDY_LOG_DIR"] ?? "\(buddyHomeDir)/.buddy/logs"
private let currentLogPath: String = "\(logsDir)/buddy.jsonl"
// ⚠️ MIRROR: 级别字符串集合须与 BuddyCore LogLevel.rawValue 完全一致（契约 C5）
private let validLogLevels: Set<String> = ["debug", "info", "warn", "error"]
// ⚠️ MIRROR: 行 schema 字段名须与 BuddyCore LogConfig.field* 同构（契约 C1/C5）
private let logFieldTimestamp = "ts"
private let logFieldLevel = "level"
private let logFieldSubsystem = "subsystem"
private let logFieldMessage = "msg"
private let logFieldMeta = "meta"

// MARK: - Message Types

private let validEvents = [
    "thinking", "tool_start", "tool_end", "idle",
    "session_start", "session_end", "set_label", "set_tokens",
    "permission_request", "task_complete"
]

private struct BuddyMessage: Encodable {
    let sessionId: String
    let event: String
    let tool: String?
    let timestamp: TimeInterval
    let cwd: String?
    let label: String?
    let pid: Int?
    let terminalId: String?
    let description: String?
    let totalTokens: Int?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case event, tool, timestamp, cwd, label, pid
        case terminalId = "terminal_id"
        case description
        case totalTokens = "total_tokens"
    }
}

// MARK: - Socket Client

private enum SocketError: Error, CustomStringConvertible {
    case notRunning
    case connectFailed(String)
    case sendFailed(String)
    case responseTimeout
    case responseInvalid(String)

    var description: String {
        switch self {
        case .notRunning:
            return "Buddy app is not running. Start the app first."
        case .connectFailed(let reason):
            return "Cannot connect to socket: \(reason)"
        case .sendFailed(let reason):
            return "Failed to send message: \(reason)"
        case .responseTimeout:
            return "Timeout waiting for response from Buddy app"
        case .responseInvalid(let reason):
            return "Invalid response from Buddy app: \(reason)"
        }
    }
}

private func sendMessage(_ message: BuddyMessage) throws {
    let encoder = JSONEncoder()
    let data = try encoder.encode(message)
    guard var payload = String(data: data, encoding: .utf8) else {
        throw SocketError.sendFailed("Failed to encode message")
    }
    payload.append("\n")

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        throw SocketError.connectFailed("Failed to create socket")
    }
    defer { close(fd) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    guard let pathData = socketPath.data(using: .utf8) else {
        throw SocketError.connectFailed("Invalid socket path")
    }
    pathData.withUnsafeBytes { ptr in
        guard let base = ptr.baseAddress else { return }
        memcpy(&addr.sun_path, base, min(pathData.count, MemoryLayout.size(ofValue: addr.sun_path) - 1))
    }

    let connectResult = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
            connect(fd, rebound, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }

    guard connectResult == 0 else {
        throw SocketError.notRunning
    }

    let sendResult = payload.withCString { ptr in
        send(fd, ptr, payload.utf8.count, 0)
    }

    guard sendResult >= 0 else {
        throw SocketError.sendFailed(String(cString: strerror(errno)))
    }
}

private func checkSocket() -> Bool {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    guard let pathData = socketPath.data(using: .utf8) else { return false }
    pathData.withUnsafeBytes { ptr in
        guard let base = ptr.baseAddress else { return }
        memcpy(&addr.sun_path, base, min(pathData.count, MemoryLayout.size(ofValue: addr.sun_path) - 1))
    }

    let result = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
            connect(fd, rebound, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }

    return result == 0
}

// MARK: - Query Support (Bidirectional)

/// Sends a query to the Buddy app and reads the JSON response.
/// Returns the raw response data, or throws SocketError on failure.
private func sendQuery(_ query: [String: Any], timeout: TimeInterval = 2.0) throws -> Data {
    guard let payloadData = try? JSONSerialization.data(withJSONObject: query) else {
        throw SocketError.sendFailed("Failed to encode query")
    }
    var payload = String(data: payloadData, encoding: .utf8) ?? ""
    payload.append("\n")

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        throw SocketError.connectFailed("Failed to create socket")
    }
    defer { close(fd) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    guard let pathData = socketPath.data(using: .utf8) else {
        throw SocketError.connectFailed("Invalid socket path")
    }
    pathData.withUnsafeBytes { ptr in
        guard let base = ptr.baseAddress else { return }
        memcpy(&addr.sun_path, base, min(pathData.count, MemoryLayout.size(ofValue: addr.sun_path) - 1))
    }

    let connectResult = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
            connect(fd, rebound, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }

    guard connectResult == 0 else {
        throw SocketError.notRunning
    }

    // Send query
    let sendResult = payload.withCString { ptr in
        send(fd, ptr, payload.utf8.count, 0)
    }
    guard sendResult >= 0 else {
        throw SocketError.sendFailed(String(cString: strerror(errno)))
    }

    // Read response with timeout
    var response = Data()
    var buf = [UInt8](repeating: 0, count: 4096)
    let deadline = Date().addingTimeInterval(timeout)

    while Date() < deadline {
        let n = read(fd, &buf, buf.count)
        if n > 0 {
            response.append(contentsOf: buf[0..<n])
            // Check if we have a complete line (response ends with \n)
            if response.last == UInt8(ascii: "\n") {
                // Remove trailing newline
                response.removeLast()
                break
            }
        } else if n == 0 {
            // EOF
            if response.last == UInt8(ascii: "\n") {
                response.removeLast()
            }
            break
        } else {
            throw SocketError.responseInvalid(String(cString: strerror(errno)))
        }
    }

    if response.isEmpty {
        throw SocketError.responseTimeout
    }

    return response
}

// MARK: - Argument Parsing

private struct CLIOptions {
    var command: String = ""
    var subcommand: String = ""
    var sessionId: String?
    var cwd: String?
    var tool: String?
    var desc: String?
    var label: String?
    var delay: UInt64 = 1
    var last: Int = 0
    var xPosition: Double?
    var positionalArgs: [String] = []
    // Launcher config fields (task 002)
    var providerId: String = ""
    var kind: String = ""
    var baseURL: String = ""
    var model: String = ""
    var apiKey: String = ""
    /// B2：关闭 LLM thinking 模式
    var noThinking: Bool = false
    // Launcher hotkey (task 2026-06-15)
    var hotkeyKey: String = ""
    var hotkeyModifiers: String = ""
    // Launcher debug perform: 候选索引（默认 0）
    var launcherDebugIndex: Int = 0
    // C4 Launcher run: 插件输入（--input "xxx"，默认空串）
    var launcherRunInput: String = ""
    // C4 Launcher run: --json 输出（默认 false = 纯 stdout）
    var launcherRunJSON: Bool = false
    // Log 子命令参数
    var logLevel: String = ""           // --level L
    var logSubsystem: String = ""       // --subsystem S
    var logSince: String = ""           // --since D (Nh/Nm/Nd)
    var logLines: Int = 0               // --lines N (0 = 默认语义由子命令定)
    var logFollow: Bool = false         // --follow
    var logIgnoreCase: Bool = false     // -i (grep)
    // Generic boolean long-form flags (task 007)
    var flags: [String] = []
}

private func printHelp() {
    print("""
    buddy \(appVersion) — CLI for Claude Code Buddy

    Usage:
      buddy <command> [options]

    Commands:
      ping                              Check if Buddy app is running
      session start [--id ID] [--cwd PATH]   Create a debug cat
      session end [--id ID]                  Remove a debug cat
      emit <event> [--id ID] [--tool NAME] [--desc TEXT]  Send event
      label <id> <text>                      Set cat label
      token <id> <amount>                    Set token count (e.g. 500000, 1.2M, 5M)
      test [--delay N]                       Auto-test: cycle all states
      test-tokens [--delay N]                Auto-test: cycle all token levels
      sizes                                 List all token levels and scale sizes
      status                                Show active sessions
      inspect [--id ID]                      Query session and cat state (JSON)
      food [--id ID] [--x N]                 Drop food near a cat or at position X
      events [--id ID] [--last N]            Show recent event history (JSON)
      health                                System health check (JSON)
      log path                              Print current log file path
      log tail [--lines N] [--follow]       Last N lines (default 50), human-readable
      log show [--level L] [--subsystem S] [--since D] [--lines N] [--json]   Filtered lines
      log grep <pattern> [--level L] [-i]   Lines matching pattern in msg
      log clear [--yes]                     Archive current log and start fresh
      help                                  Show this help

    Events: \(validEvents.joined(separator: ", "))

    Options:
      --id <ID>       Session ID (default: auto-generated debug-<timestamp>)
      --cwd <PATH>    Working directory
      --tool <NAME>   Tool name (for tool_start/tool_end)
      --desc <TEXT>   Description text
      --delay <N>     Delay between states in seconds (default: 1)
      --last <N>      Number of recent events to show (for events command)

    Examples:
      buddy session start --id debug-A --cwd ~/myproject
      buddy emit thinking --id debug-A
      buddy token debug-A 1.5M
      buddy test-tokens --delay 3
      buddy inspect --id debug-A
      buddy session end --id debug-A

    Launcher subcommands:
      buddy launcher config <get|set|use> ...   查看/设置/切换 LLM provider
      buddy launcher install <name>             从官方 marketplace 安装插件（gitURL/gitSubdir/file）
      buddy launcher add <user>/<repo>          从任意 GitHub repo 安装（与 marketplace 无关）
      buddy launcher list [--json]              列出已装插件；--json 输出 MarketplaceInspection
      buddy launcher disable <name>             禁用插件（touch .disabled）
      buddy launcher enable <name>              启用插件（rm .disabled）
      buddy launcher reseed                     清 marketplace cache，下次 app 启动重新 seed
      buddy launcher remove <name>              彻底删除插件目录
      buddy launcher inspect <name>             查看插件详情（JSON）
      buddy launcher hotkey show                查看当前启动器热键（含 isDefault）
      buddy launcher hotkey set --key K --modifiers CSV   设置热键（如 --key space --modifiers control）
      buddy launcher hotkey clear               重置为默认热键 (Ctrl+Space)
      buddy launcher debug candidates <query>   生成内置插件候选（JSON，功能调试用）
      buddy launcher debug perform <query> [--index N]   执行第 N 个候选并读剪贴板（默认 N=0）
      buddy launcher debug registry             列出已注册内置插件（priority 降序，JSON）
      buddy launcher debug route <query>        AI 路由调试：query → narrow → AI select → LLM 响应（JSON）
      buddy launcher debug open-settings [section]  打开设置窗口（绕过 LSUIElement osascript 不路由），可选预选分类
      buddy launcher debug select-section <section> 选中主分类（general/about/hotkey/ai/skins/plugins）
      buddy launcher debug select-plugin <name>  在插件分类内选中具名插件（如 snip）切右栏面板
      buddy launcher debug get-state            dump 设置窗口几何 + 选中态（JSON，帧谓词求值用）

    Hotkey 参数：
      --key <key>           热键主键（如 space, a, f1, return；字母 a-z / 数字 0-9）
      --modifiers <csv>     修饰键逗号列表（command,shift,control,option）
                            例：--modifiers control
                                --modifiers command,shift

    热键示例：
      buddy launcher hotkey show
      buddy launcher hotkey set --key space --modifiers control
      buddy launcher hotkey set --key p --modifiers command,shift
      buddy launcher hotkey clear
    """)
}

private func parseArguments(_ args: [String]) -> CLIOptions {
    var opts = CLIOptions()
    var i = 0

    while i < args.count {
        let arg = args[i]
        switch arg {
        case "--id":
            i += 1
            if i < args.count { opts.sessionId = args[i] }
        case "--cwd":
            i += 1
            if i < args.count { opts.cwd = args[i] }
        case "--tool":
            i += 1
            if i < args.count { opts.tool = args[i] }
        case "--desc":
            i += 1
            if i < args.count { opts.desc = args[i] }
        case "--delay":
            i += 1
            if i < args.count, let d = UInt64(args[i]) { opts.delay = d }
        case "--last":
            i += 1
            if i < args.count, let n = Int(args[i]) { opts.last = n }
        case "--x":
            i += 1
            if i < args.count, let x = Double(args[i]) { opts.xPosition = x }
        case "--label":
            i += 1
            if i < args.count { opts.label = args[i] }
        case "--provider":
            i += 1
            if i < args.count { opts.providerId = args[i] }
        case "--kind":
            i += 1
            if i < args.count { opts.kind = args[i] }
        case "--base-url":
            i += 1
            if i < args.count { opts.baseURL = args[i] }
        case "--model":
            i += 1
            if i < args.count { opts.model = args[i] }
        case "--api-key":
            i += 1
            if i < args.count { opts.apiKey = args[i] }
        case "--key":
            i += 1
            if i < args.count { opts.hotkeyKey = args[i] }
        case "--modifiers":
            i += 1
            if i < args.count { opts.hotkeyModifiers = args[i] }
        case "--no-thinking":
            opts.noThinking = true
        case "--index":
            i += 1
            if i < args.count, let n = Int(args[i]) { opts.launcherDebugIndex = n }
        case "--input":
            // C4 launcher run --input "xxx"
            i += 1
            if i < args.count { opts.launcherRunInput = args[i] }
        case "--level":
            i += 1
            if i < args.count { opts.logLevel = args[i] }
        case "--subsystem":
            i += 1
            if i < args.count { opts.logSubsystem = args[i] }
        case "--since":
            i += 1
            if i < args.count { opts.logSince = args[i] }
        case "--lines":
            i += 1
            if i < args.count, let n = Int(args[i]) { opts.logLines = n }
        case "--follow":
            opts.logFollow = true
        case "-i":
            opts.logIgnoreCase = true
        case let f where f.hasPrefix("--") && !f.contains("="):
            // 通用布尔型长 flag（task 007）：--json / --strict 等，不消费下一个 arg
            opts.flags.append(f)
        default:
            if opts.command.isEmpty {
                opts.command = arg
            } else if opts.command == "session" && opts.subcommand.isEmpty {
                opts.subcommand = arg
            } else if (opts.command == "label" || opts.command == "token") && opts.positionalArgs.count < 2 {
                opts.positionalArgs.append(arg)
            } else if opts.command == "emit" && opts.subcommand.isEmpty {
                opts.subcommand = arg
            } else if opts.command == "launcher" && opts.subcommand.isEmpty {
                opts.subcommand = arg
            } else if opts.command == "log" && opts.subcommand.isEmpty {
                opts.subcommand = arg
            } else {
                opts.positionalArgs.append(arg)
            }
        }
        i += 1
    }

    return opts
}

// MARK: - Command Handlers

private func cmdPing() {
    if checkSocket() {
        print("Buddy is running ✓")
    } else {
        fputs("Buddy app is not running. Start the app first.\n", stderr)
        exit(1)
    }
}

private func cmdSessionStart(_ opts: CLIOptions) {
    let sid = opts.sessionId ?? "debug-\(Int(Date().timeIntervalSince1970))"
    let message = BuddyMessage(
        sessionId: sid,
        event: "session_start",
        tool: nil,
        timestamp: Date().timeIntervalSince1970,
        cwd: opts.cwd ?? FileManager.default.currentDirectoryPath,
        label: nil,
        pid: nil,
        terminalId: nil,
        description: nil,
        totalTokens: nil
    )

    do {
        try sendMessage(message)
        print("Session started: \(sid)")
    } catch {
        fputs("\(error)\n", stderr)
        exit(1)
    }
}

private func cmdSessionEnd(_ opts: CLIOptions) {
    guard let sid = opts.sessionId else {
        fputs("Error: --id is required for session end\n", stderr)
        exit(2)
    }

    let message = BuddyMessage(
        sessionId: sid,
        event: "session_end",
        tool: nil,
        timestamp: Date().timeIntervalSince1970,
        cwd: nil,
        label: nil,
        pid: nil,
        terminalId: nil,
        description: nil,
        totalTokens: nil
    )

    do {
        try sendMessage(message)
        print("Session ended: \(sid)")
    } catch {
        fputs("\(error)\n", stderr)
        exit(1)
    }
}

private func cmdEmit(_ opts: CLIOptions) {
    let event = opts.subcommand
    guard validEvents.contains(event) else {
        fputs("Invalid event '\(event)'. Valid events: \(validEvents.joined(separator: ", "))\n", stderr)
        exit(2)
    }

    let sid = opts.sessionId ?? "debug-\(Int(Date().timeIntervalSince1970))"
    let message = BuddyMessage(
        sessionId: sid,
        event: event,
        tool: opts.tool,
        timestamp: Date().timeIntervalSince1970,
        cwd: opts.cwd,
        label: opts.label,
        pid: nil,
        terminalId: nil,
        description: opts.desc,
        totalTokens: nil
    )

    do {
        try sendMessage(message)
        print("Event sent: \(event)")
    } catch {
        fputs("\(error)\n", stderr)
        exit(1)
    }
}

private func cmdLabel(_ opts: CLIOptions) {
    guard opts.positionalArgs.count >= 2 else {
        fputs("Usage: buddy label <id> <text>\n", stderr)
        exit(2)
    }

    let sid = opts.positionalArgs[0]
    let text = opts.positionalArgs[1]

    let message = BuddyMessage(
        sessionId: sid,
        event: "set_label",
        tool: nil,
        timestamp: Date().timeIntervalSince1970,
        cwd: nil,
        label: text,
        pid: nil,
        terminalId: nil,
        description: nil,
        totalTokens: nil
    )

    do {
        try sendMessage(message)
        print("Label set: \(sid) -> \(text)")
    } catch {
        fputs("\(error)\n", stderr)
        exit(1)
    }
}

private func cmdStatus() {
    guard FileManager.default.fileExists(atPath: colorFilePath) else {
        print("No active sessions")
        return
    }

    guard let data = FileManager.default.contents(atPath: colorFilePath),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          !json.isEmpty else {
        print("No active sessions")
        return
    }

    print("Active sessions (\(json.count)):")
    for (sessionId, info) in json.sorted(by: { $0.key < $1.key }) {
        if let details = info as? [String: Any] {
            let color = details["color"] as? String ?? "?"
            let label = details["label"] as? String ?? sessionId
            print("  \(sessionId)  color=\(color)  label=\(label)")
        }
    }
}

// MARK: - Query Commands

private func cmdInspect(_ opts: CLIOptions) {
    var query: [String: Any] = ["action": "inspect"]
    if let sid = opts.sessionId {
        query["session_id"] = sid
    }

    do {
        let data = try sendQuery(query)
        if let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    } catch {
        fputs("\(error)\n", stderr)
        exit(1)
    }
}

private func cmdFood(_ opts: CLIOptions) {
    var query: [String: Any] = ["action": "food"]
    if let sid = opts.sessionId {
        query["session_id"] = sid
    }
    if let x = opts.xPosition {
        query["x"] = x
    }

    do {
        let data = try sendQuery(query)
        if let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    } catch {
        fputs("\(error)\n", stderr)
        exit(1)
    }
}

private func cmdClick(_ opts: CLIOptions) {
    guard let sid = opts.sessionId else {
        fputs("Usage: buddy click --id <session_id>\n", stderr)
        exit(2)
    }

    let query: [String: Any] = ["action": "click", "session_id": sid]
    do {
        let data = try sendQuery(query)
        if let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    } catch {
        fputs("\(error)\n", stderr)
        exit(1)
    }
}

private func cmdEvents(_ opts: CLIOptions) {
    var query: [String: Any] = ["action": "events"]
    if let sid = opts.sessionId {
        query["session_id"] = sid
    }
    if opts.last > 0 {
        query["last"] = opts.last
    }

    do {
        let data = try sendQuery(query)
        if let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    } catch {
        fputs("\(error)\n", stderr)
        exit(1)
    }
}

private func cmdHealth() {
    let query: [String: Any] = ["action": "health"]

    do {
        let data = try sendQuery(query)
        if let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    } catch {
        fputs("\(error)\n", stderr)
        exit(1)
    }
}

private struct TestStep {
    let event: String
    let tool: String?
    let desc: String?
}

private func cmdTest(_ opts: CLIOptions) {
    let sid = "debug-test-\(Int(Date().timeIntervalSince1970))"

    print("Starting test session: \(sid)")

    do {
        // Create session
        try sendMessage(BuddyMessage(
            sessionId: sid, event: "session_start", tool: nil,
            timestamp: Date().timeIntervalSince1970,
            cwd: "/tmp", label: nil, pid: nil, terminalId: nil, description: nil, totalTokens: nil
        ))
        print("  ✓ session_start")
        Thread.sleep(forTimeInterval: 1)

        // Cycle through states
        let steps: [TestStep] = [
            TestStep(event: "thinking", tool: nil, desc: nil),
            TestStep(event: "tool_start", tool: "Read", desc: "Reading source file"),
            TestStep(event: "tool_end", tool: "Read", desc: nil),
            TestStep(event: "idle", tool: nil, desc: nil),
            TestStep(event: "thinking", tool: nil, desc: nil),
            TestStep(event: "tool_start", tool: "Bash", desc: "Running tests"),
            TestStep(event: "tool_end", tool: "Bash", desc: nil),
            TestStep(event: "permission_request", tool: "Write", desc: "Write to config file"),
            TestStep(event: "thinking", tool: nil, desc: nil),
            TestStep(event: "task_complete", tool: nil, desc: nil),
        ]

        for step in steps {
            try sendMessage(BuddyMessage(
                sessionId: sid, event: step.event, tool: step.tool,
                timestamp: Date().timeIntervalSince1970,
                cwd: nil, label: nil, pid: nil, terminalId: nil, description: step.desc, totalTokens: nil
            ))
            let toolInfo = step.tool.map { " (\($0))" } ?? ""
            print("  ✓ \(step.event)\(toolInfo)")
            Thread.sleep(forTimeInterval: Double(opts.delay))
        }

        // Set label
        try sendMessage(BuddyMessage(
            sessionId: sid, event: "set_label", tool: nil,
            timestamp: Date().timeIntervalSince1970,
            cwd: nil, label: "Test Cat", pid: nil, terminalId: nil, description: nil, totalTokens: nil
        ))
        print("  ✓ set_label -> Test Cat")
        Thread.sleep(forTimeInterval: 1)

        // End session
        try sendMessage(BuddyMessage(
            sessionId: sid, event: "session_end", tool: nil,
            timestamp: Date().timeIntervalSince1970,
            cwd: nil, label: nil, pid: nil, terminalId: nil, description: nil, totalTokens: nil
        ))
        print("  ✓ session_end")
        print("Test complete!")

    } catch {
        fputs("Test failed: \(error)\n", stderr)
        exit(1)
    }
}

// MARK: - Token Commands

/// Parse a token amount string like "500000", "1.5M", "500K" into an integer.
private func parseTokenAmount(_ str: String) -> Int? {
    let upper = str.uppercased()
    if upper.hasSuffix("M") {
        let numStr = String(upper.dropLast())
        guard let num = Double(numStr) else { return nil }
        return Int(num * 1_000_000)
    } else if upper.hasSuffix("K") {
        let numStr = String(upper.dropLast())
        guard let num = Double(numStr) else { return nil }
        return Int(num * 1_000)
    } else {
        return Int(str)
    }
}

private func formatTokensForDisplay(_ tokens: Int) -> String {
    if tokens >= 1_000_000 {
        let m = Double(tokens) / 1_000_000.0
        return m < 10 ? String(format: "%.1fM", m) : String(format: "%.0fM", m)
    } else if tokens >= 1000 {
        return String(format: "%.0fK", Double(tokens) / 1000.0)
    } else {
        return "\(tokens)"
    }
}

private func cmdToken(_ opts: CLIOptions) {
    guard opts.positionalArgs.count >= 2 else {
        fputs("Usage: buddy token <id> <amount>\n  amount: 500000, 1.5M, 500K\n", stderr)
        exit(2)
    }

    let sid = opts.positionalArgs[0]
    let amountStr = opts.positionalArgs[1]

    guard let tokens = parseTokenAmount(amountStr) else {
        fputs("Invalid token amount: \(amountStr)\n  Examples: 500000, 1.5M, 500K\n", stderr)
        exit(2)
    }

    let message = BuddyMessage(
        sessionId: sid,
        event: "set_tokens",
        tool: nil,
        timestamp: Date().timeIntervalSince1970,
        cwd: nil,
        label: nil,
        pid: nil,
        terminalId: nil,
        description: nil,
        totalTokens: tokens
    )

    do {
        try sendMessage(message)
        let formatted = formatTokensForDisplay(tokens)
        print("Tokens set: \(sid) -> \(formatted)")
    } catch {
        fputs("\(error)\n", stderr)
        exit(1)
    }
}

private func cmdTestTokens(_ opts: CLIOptions) {
    let sid = "debug-token-\(Int(Date().timeIntervalSince1970))"
    let delay = Double(opts.delay)

    print("Starting token level test: \(sid)")

    let levels: [(name: String, tokens: Int)] = [
        ("Lv1 (0)", 0),
        ("Lv2 (100K)", 100_000),
        ("Lv3 (300K)", 300_000),
        ("Lv4 (500K)", 500_000),
        ("Lv5 (800K)", 800_000),
        ("Lv6 (1.2M)", 1_200_000),
        ("Lv7 (2M)", 2_000_000),
        ("Lv8 (3M)", 3_000_000),
        ("Lv9 (5M)", 5_000_000),
        ("Lv10 (7M)", 7_000_000),
        ("Lv11 (10M)", 10_000_000),
        ("Lv12 (15M)", 15_000_000),
        ("Lv13 (20M)", 20_000_000),
        ("Lv14 (30M)", 30_000_000),
        ("Lv15 (50M)", 50_000_000),
        ("Lv16 (100M)", 100_000_000),
    ]

    do {
        // Create session
        try sendMessage(BuddyMessage(
            sessionId: sid, event: "session_start", tool: nil,
            timestamp: Date().timeIntervalSince1970,
            cwd: "/tmp", label: nil, pid: nil, terminalId: nil, description: nil, totalTokens: nil
        ))
        print("  ✓ session_start")
        Thread.sleep(forTimeInterval: 1)

        // Cycle through all token levels
        for level in levels {
            try sendMessage(BuddyMessage(
                sessionId: sid, event: "set_tokens", tool: nil,
                timestamp: Date().timeIntervalSince1970,
                cwd: nil, label: nil, pid: nil, terminalId: nil, description: nil, totalTokens: level.tokens
            ))
            print("  ✓ \(level.name)")
            Thread.sleep(forTimeInterval: delay)
        }

        // Wait a bit then end session
        print("  All levels shown! Ending in 3s...")
        Thread.sleep(forTimeInterval: 3)

        try sendMessage(BuddyMessage(
            sessionId: sid, event: "session_end", tool: nil,
            timestamp: Date().timeIntervalSince1970,
            cwd: nil, label: nil, pid: nil, terminalId: nil, description: nil, totalTokens: nil
        ))
        print("  ✓ session_end")
        print("Token test complete!")

    } catch {
        fputs("Test failed: \(error)\n", stderr)
        exit(1)
    }
}

private func cmdSizes() {
    let levels: [[String]] = [
        ["Lv1", "0", "1.00x", "80pt"],
        ["Lv2", "100K", "1.02x", "82pt"],
        ["Lv3", "300K", "1.05x", "84pt"],
        ["Lv4", "500K", "1.07x", "86pt"],
        ["Lv5", "800K", "1.10x", "88pt"],
        ["Lv6", "1.2M", "1.12x", "90pt"],
        ["Lv7", "2M", "1.15x", "92pt"],
        ["Lv8", "3M", "1.17x", "93pt"],
        ["Lv9", "5M", "1.19x", "95pt"],
        ["Lv10", "7M", "1.21x", "97pt"],
        ["Lv11", "10M", "1.23x", "98pt"],
        ["Lv12", "15M", "1.26x", "100pt"],
        ["Lv13", "20M", "1.28x", "102pt"],
        ["Lv14", "30M", "1.30x", "104pt"],
        ["Lv15", "50M", "1.33x", "106pt"],
        ["Lv16", "100M", "1.35x", "108pt"],
    ]

    func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
    }

    print("\(pad("Level", 6)) \(pad("Threshold", 11)) \(pad("Scale", 6)) \(pad("Height", 6))")
    print(String(repeating: "\u{2500}", count: 33))
    for lv in levels {
        print("\(pad(lv[0], 6)) \(pad(lv[1], 11)) \(pad(lv[2], 6)) \(pad(lv[3], 6))")
    }
}

// MARK: - Main

private func main() {
    let args = Array(CommandLine.arguments.dropFirst())
    let opts = parseArguments(args)

    switch opts.command {
    case "ping":
        cmdPing()
    case "session":
        switch opts.subcommand {
        case "start":
            cmdSessionStart(opts)
        case "end":
            cmdSessionEnd(opts)
        default:
            fputs("Usage: buddy session <start|end> [--id ID] [--cwd PATH]\n", stderr)
            exit(2)
        }
    case "emit":
        guard !opts.subcommand.isEmpty else {
            fputs("Usage: buddy emit <event> [--id ID] [--tool NAME] [--desc TEXT]\n", stderr)
            exit(2)
        }
        cmdEmit(opts)
    case "label":
        cmdLabel(opts)
    case "token":
        cmdToken(opts)
    case "test":
        cmdTest(opts)
    case "test-tokens":
        cmdTestTokens(opts)
    case "sizes":
        cmdSizes()
    case "status":
        cmdStatus()
    case "inspect":
        cmdInspect(opts)
    case "food":
        cmdFood(opts)
    case "click":
        cmdClick(opts)
    case "events":
        cmdEvents(opts)
    case "health":
        cmdHealth()
    case "launcher":
        switch opts.subcommand {
        case "config":
            switch opts.positionalArgs.first {
            case "set":
                cmdLauncherConfigSet(opts)
            case "get":
                cmdLauncherConfigGet(opts)
            case "use":
                cmdLauncherConfigUse(opts)
            default:
                fputs("Usage: buddy launcher config <set|get|use> ...\n", stderr)
                exit(2)
            }
        case "add":
            cmdLauncherAdd(opts.positionalArgs.first ?? "")
        case "install":
            cmdLauncherInstall(opts.positionalArgs.first ?? "")
        case "disable":
            cmdLauncherDisable(opts.positionalArgs.first ?? "")
        case "enable":
            cmdLauncherEnable(opts.positionalArgs.first ?? "")
        case "reseed":
            cmdLauncherReseed()
        case "list":
            if opts.flags.contains("--json") {
                cmdLauncherListJSON()
            } else {
                cmdLauncherList()
            }
        case "remove":
            cmdLauncherRemove(opts.positionalArgs.first ?? "")
        case "inspect":
            cmdLauncherInspect(opts.positionalArgs.first ?? "")
        case "run":
            // C4 dry-run：buddy launcher run <name> --input "xxx" [--json]
            // 直接执行具名插件（不经候选路由），经 socket 由 app 执行（复用 StdinExecutor/trust/日志）。
            let name = opts.positionalArgs.first ?? ""
            cmdLauncherRun(
                name: name,
                input: opts.launcherRunInput,
                json: opts.flags.contains("--json")
            )
        case "hotkey":
            switch opts.positionalArgs.first {
            case "set":
                cmdLauncherHotkeySet(opts)
            case "show":
                cmdLauncherHotkeyShow()
            case "clear":
                cmdLauncherHotkeyClear()
            default:
                fputs("Usage: buddy launcher hotkey <set|show|clear> ...\n", stderr)
                exit(2)
            }
        case "debug":
            // positionalArgs[0] = op(candidates/perform/registry)，[1] = query（candidates/perform 需要）
            switch opts.positionalArgs.first {
            case "candidates":
                let q = opts.positionalArgs.dropFirst().first ?? ""
                guard !q.isEmpty else {
                    fputs("Usage: buddy launcher debug candidates <query>\n", stderr)
                    exit(2)
                }
                cmdLauncherDebugCandidates(q)
            case "perform":
                let q = opts.positionalArgs.dropFirst().first ?? ""
                guard !q.isEmpty else {
                    fputs("Usage: buddy launcher debug perform <query> [--index N]\n", stderr)
                    exit(2)
                }
                cmdLauncherDebugPerform(q, index: opts.launcherDebugIndex)
            case "registry":
                cmdLauncherDebugRegistry()
            case "route":
                let q = opts.positionalArgs.dropFirst().first ?? ""
                guard !q.isEmpty else {
                    fputs("Usage: buddy launcher debug route <query>\n", stderr)
                    exit(2)
                }
                cmdLauncherDebugRoute(q)
            case "open-settings":
                // 可选 positional：open-settings [section]（general/about/hotkey/ai/skins/plugins）
                let section = opts.positionalArgs.dropFirst().first
                cmdSettingsOpen(section: section)
            case "select-section":
                let section = opts.positionalArgs.dropFirst().first ?? ""
                guard !section.isEmpty else {
                    fputs("Usage: buddy launcher debug select-section <general|about|hotkey|ai|skins|plugins>\n", stderr)
                    exit(2)
                }
                cmdSettingsSelectSection(section)
            case "select-plugin":
                let name = opts.positionalArgs.dropFirst().first ?? ""
                guard !name.isEmpty else {
                    fputs("Usage: buddy launcher debug select-plugin <name>\n", stderr)
                    exit(2)
                }
                cmdSettingsSelectPlugin(name)
            case "get-state":
                cmdSettingsGetState()
            case "snip-expand":
                let mode = opts.positionalArgs.dropFirst().first ?? "create"
                cmdSettingsSnipExpand(mode)
            default:
                fputs("Usage: buddy launcher debug <candidates|perform|registry|route|open-settings|select-section|select-plugin|snip-expand|get-state> ...\n", stderr)
                exit(2)
            }
        default:
            fputs("Usage: buddy launcher <config|add|install|list|disable|enable|reseed|remove|inspect|run|hotkey|debug> ...\n", stderr)
            exit(2)
        }
    case "log":
        switch opts.subcommand {
        case "path":
            cmdLogPath()
        case "tail":
            cmdLogTail(opts)
        case "show":
            cmdLogShow(opts)
        case "grep":
            let pattern = opts.positionalArgs.first ?? ""
            guard !pattern.isEmpty else {
                fputs("Usage: buddy log grep <pattern> [--level L] [-i]\n", stderr)
                exit(2)
            }
            cmdLogGrep(pattern: pattern, opts: opts)
        case "clear":
            cmdLogClear(opts)
        default:
            fputs("Usage: buddy log <path|tail|show|grep|clear> ...\n", stderr)
            exit(2)
        }
    case "help", "--help", "-h", "":
        printHelp()
    default:
        fputs("Unknown command: \(opts.command)\n\n", stderr)
        printHelp()
        exit(2)
    }
}

main()

// MARK: - Log Command Handlers (Foundation-only，直接读文件)
// ⚠️ 契约 C4：app 不运行也可用（场景 4）；CLI 为 Foundation-only，不依赖 BuddyCore。
// 路径常量 mirror 自 LogConfig（上方 logsDir / currentLogPath）。

private func cmdLogPath() {
    print(currentLogPath)
}

/// `buddy log tail [--lines N] [--follow]` — 最近 N 行（默认 50），人类可读摘要。
private func cmdLogTail(_ opts: CLIOptions) {
    guard FileManager.default.fileExists(atPath: currentLogPath) else {
        fputs("log file not found: \(currentLogPath)\n", stderr)
        exit(1)
    }
    let lines = opts.logLines > 0 ? opts.logLines : 50
    let content = readLogTail(maxBytes: 256 * 1024)   // 读最后 ~256KB
    let allLines = content.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    let recent = Array(allLines.suffix(lines))
    for line in recent {
        print(formatLogLine(line))
    }
    guard opts.logFollow else { return }
    // --follow：每 0.5s 增量读
    var lastSize = (try? FileManager.default.attributesOfItem(atPath: currentLogPath)[.size] as? Int) ?? 0
    while true {
        Thread.sleep(forTimeInterval: 0.5)
        let nowSize = (try? FileManager.default.attributesOfItem(atPath: currentLogPath)[.size] as? Int) ?? lastSize
        if nowSize > lastSize {
            if let data = try? FileHandle(forReadingFrom: URL(fileURLWithPath: currentLogPath)) {
                try? data.seek(toOffset: UInt64(lastSize))
                let newBytes = (try? data.readToEnd()) ?? Data()
                try? data.close()
                if let newStr = String(data: newBytes, encoding: .utf8) {
                    for line in newStr.split(separator: "\n").map(String.init) where !line.isEmpty {
                        print(formatLogLine(line))
                    }
                }
            }
            lastSize = nowSize
        }
    }
}

/// `buddy log show [--lines N] [--level L] [--subsystem S] [--since D] [--json]`
private func cmdLogShow(_ opts: CLIOptions) {
    let asJSON = opts.flags.contains("--json")
    let maxLines = opts.logLines > 0 ? opts.logLines : 0   // 0 = 不限
    let filtered = filterLogLines(opts: opts, maxLines: maxLines)
    if asJSON {
        for line in filtered { print(line.raw) }
    } else {
        for line in filtered { print(formatLogLine(line.raw)) }
    }
}

/// `buddy log grep <pattern> [--level L] [-i]`
private func cmdLogGrep(pattern: String, opts: CLIOptions) {
    let asJSON = opts.flags.contains("--json")
    let maxLines = 0
    var filtered = filterLogLines(opts: opts, maxLines: maxLines)
    // grep 在 msg 子串匹配
    let needle = opts.logIgnoreCase ? pattern.lowercased() : pattern
    filtered = filtered.filter { entry in
        let hay = opts.logIgnoreCase ? entry.msg.lowercased() : entry.msg
        return hay.contains(needle)
    }
    for line in filtered { print(asJSON ? line.raw : formatLogLine(line.raw)) }
}

/// `buddy log clear [--yes]` — 归档当前文件并新建。
private func cmdLogClear(_ opts: CLIOptions) {
    let fm = FileManager.default
    guard fm.fileExists(atPath: currentLogPath) else {
        print("no log file to clear")
        return
    }
    let confirmed = opts.flags.contains("--yes") || opts.positionalArgs.contains("--yes")
    if !confirmed {
        // 非 TTY（管道）直接执行；TTY 下需 --yes 或交互确认
        let isTTY = isatty(fileno(stdout)) != 0
        if isTTY {
            fputs("Clear log \(currentLogPath)? This archives the current file. Use --yes to skip. [y/N] ", stderr)
            var response = ""
            if let line = readLine() { response = line }
            guard response.lowercased() == "y" || response.lowercased() == "yes" else {
                fputs("aborted\n", stderr)
                exit(1)
            }
        }
    }
    // rename 为归档
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.locale = Locale(identifier: "en_US_POSIX")
    let archivePath = "\(logsDir)/buddy-\(formatter.string(from: Date())).jsonl"
    do {
        try fm.moveItem(atPath: currentLogPath, toPath: archivePath)
    } catch {
        fputs("failed to archive log: \(error)\n", stderr)
        exit(1)
    }
    fm.createFile(atPath: currentLogPath, contents: nil, attributes: [.posixPermissions: NSNumber(value: 0o600)])
    print("cleared: \(currentLogPath) (archived to \(archivePath))")
}

// MARK: - Log Filtering Helpers

private struct LogEntry {
    let raw: String
    let msg: String
}

/// 逐行解析 JSONL，按级别/子系统/时间过滤，返回匹配条目（含 raw 原始行）。
private func filterLogLines(opts: CLIOptions, maxLines: Int) -> [LogEntry] {
    guard let content = try? String(contentsOfFile: currentLogPath, encoding: .utf8) else { return [] }
    let allLines = content.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    var minOrder = -1
    if !opts.logLevel.isEmpty {
        switch opts.logLevel.lowercased() {
        case "debug": minOrder = 0
        case "info": minOrder = 1
        case "warn": minOrder = 2
        case "error": minOrder = 3
        default:
            fputs("invalid level '\(opts.logLevel)'; expected debug|info|warn|error\n", stderr)
            exit(2)
        }
    }
    let sinceCutoff = parseSinceCutoff(opts.logSince)
    var result: [LogEntry] = []
    for line in allLines {
        guard let data = line.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            continue   // 非法 JSON 行跳过（容错）
        }
        // 级别过滤
        if minOrder >= 0 {
            let levelStr = (json[logFieldLevel] as? String) ?? ""
            let order = levelOrder(levelStr)
            if order < minOrder { continue }
        }
        // 子系统过滤（精确匹配）
        if !opts.logSubsystem.isEmpty {
            let sub = (json[logFieldSubsystem] as? String) ?? ""
            if sub != opts.logSubsystem { continue }
        }
        // 时间过滤
        if let cutoff = sinceCutoff {
            let ts = (json[logFieldTimestamp] as? String) ?? ""
            if let lineDate = parseISO8601(ts), lineDate < cutoff { continue }
        }
        let msg = (json[logFieldMessage] as? String) ?? ""
        result.append(LogEntry(raw: line, msg: msg))
    }
    if maxLines > 0 {
        result = Array(result.suffix(maxLines))
    }
    return result
}

/// 人类可读摘要格式：`HH:MM:SS.mmm [LEVEL] [subsystem] msg`（meta 以 ` k=v` 追加）。
private func formatLogLine(_ raw: String) -> String {
    guard let data = raw.data(using: .utf8),
          let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        return raw   // 非法 JSON 原样返回（容错）
    }
    let ts = (json[logFieldTimestamp] as? String) ?? ""
    let time = shortTime(ts)
    let level = (json[logFieldLevel] as? String) ?? "?"
    let subsystem = (json[logFieldSubsystem] as? String) ?? "?"
    let msg = (json[logFieldMessage] as? String) ?? ""
    var line = "\(time) [\(level.uppercased())] [\(subsystem)] \(msg)"
    if let meta = json[logFieldMeta] as? [String: Any], !meta.isEmpty {
        let pairs = meta.map { (k, v) in "\(k)=\(stringifyMetaValue(v))" }.sorted().joined(separator: " ")
        line += "  " + pairs
    }
    return line
}

/// 读日志文件最后 maxBytes 字节。
private func readLogTail(maxBytes: Int) -> String {
    guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: currentLogPath)) else {
        return ""
    }
    defer { try? handle.close() }
    let total = (try? handle.seekToEnd()) ?? 0
    let start = total > UInt64(maxBytes) ? total - UInt64(maxBytes) : 0
    try? handle.seek(toOffset: start)
    let data = (try? handle.readToEnd()) ?? Data()
    return String(data: data, encoding: .utf8) ?? ""
}

/// 级别字符串 → 数字序（mirror BuddyCore LogLevel.order）。
private func levelOrder(_ level: String) -> Int {
    switch level {
    case "debug": return 0
    case "info": return 1
    case "warn": return 2
    case "error": return 3
    default: return -1
    }
}

/// `--since` 解析为截止 Date（接受 Nh/Nm/Nd，如 1h/30m/7d）。
private func parseSinceCutoff(_ since: String) -> Date? {
    guard !since.isEmpty else { return nil }
    let trimmed = since.trimmingCharacters(in: .whitespaces)
    guard let lastChar = trimmed.last, let amount = Int(trimmed.dropLast()) else { return nil }
    let now = Date()
    switch lastChar {
    case "h": return now.addingTimeInterval(-Double(amount) * 3600)
    case "m": return now.addingTimeInterval(-Double(amount) * 60)
    case "d": return now.addingTimeInterval(-Double(amount) * 86400)
    default: return nil
    }
}

/// ISO8601（含毫秒）解析。
private func parseISO8601(_ str: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: str)
}

/// ISO8601 ts → `HH:MM:SS.mmm`（本地时区，人类可读）。
private func shortTime(_ ts: String) -> String {
    guard let date = parseISO8601(ts) else { return ts }
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter.string(from: date)
}

/// meta 值转人类可读字符串（数字/字符串/嵌套 JSON）。
private func stringifyMetaValue(_ value: Any) -> String {
    if let s = value as? String { return s }
    if let n = value as? NSNumber { return n.stringValue }
    if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
       let s = String(data: data, encoding: .utf8) {
        return s
    }
    return "\(value)"
}

// MARK: - Launcher Config (Inline Implementation)
// ⚠️ 不依赖 BuddyCore：CLI 不引入 AppKit/SwiftUI/SpriteKit 以保持低启动延迟
// JSON schema 与 BuddyCore LauncherConfig / ProviderConfig 保持一致

private struct CLIProviderConfig: Codable {
    let kind: String
    let baseURL: String?
    let model: String
    let keyRef: String
    /// B2：关闭 LLM thinking 模式（对应 ProviderConfig.noThinking）
    var noThinking: Bool?

    init(kind: String, baseURL: String?, model: String, keyRef: String, noThinking: Bool? = nil) {
        self.kind = kind
        self.baseURL = baseURL
        self.model = model
        self.keyRef = keyRef
        self.noThinking = noThinking
    }
}

private struct CLILauncherConfig: Codable {
    var activeProvider: String
    var providers: [String: CLIProviderConfig]
}

private func cliLoadConfig() -> CLILauncherConfig {
    let url = URL(fileURLWithPath: launcherConfigPath)
    guard let data = try? Data(contentsOf: url),
          let cfg = try? JSONDecoder().decode(CLILauncherConfig.self, from: data) else {
        return CLILauncherConfig(activeProvider: "", providers: [:])
    }
    return cfg
}

private func cliSaveConfig(_ cfg: CLILauncherConfig) throws {
    try FileManager.default.createDirectory(
        atPath: launcherConfigDir,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(cfg)
    let url = URL(fileURLWithPath: launcherConfigPath)
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: launcherConfigPath
    )
}

private func cliKeychainSave(account: String, value: String) -> Bool {
    let data = Data(value.utf8)
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: launcherKeychainService,
        kSecAttrAccount as String: account
    ]
    SecItemDelete(query as CFDictionary)
    var attrs = query
    attrs[kSecValueData as String] = data
    return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
}

// MARK: - Secret persistence (ad-hoc-aware)
// ⚠️ MIRROR: BuddyCore/Launcher/Config/SecretStore.swift + EncryptedFileSecretStore.swift
// CLI cannot depend on BuddyCore，下面的逻辑必须与 BuddyCore 侧保持同构：
//   - ad-hoc 签名 / 无 TeamID → ChaChaPoly 写 ~/.buddy/launcher-secrets.enc
//   - 否则 → Keychain（生产签名走这条）
// 选择需与 app 侧 SecretStoreFactory 一致，否则 CLI 写入的位置 app 读不到。

private func cliIsAdHocSigned() -> Bool {
    var codeRef: SecCode?
    guard SecCodeCopySelf([], &codeRef) == errSecSuccess, let code = codeRef else {
        return true
    }
    var infoCF: CFDictionary?
    let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
    let staticCode = unsafeBitCast(code, to: SecStaticCode.self)
    guard SecCodeCopySigningInformation(staticCode, flags, &infoCF) == errSecSuccess,
          let info = infoCF as? [String: Any] else {
        return true
    }
    if let csFlagsNum = info[kSecCodeInfoFlags as String] as? NSNumber,
       (csFlagsNum.uint32Value & 0x2) != 0 {
        return true
    }
    let teamID = (info[kSecCodeInfoTeamIdentifier as String] as? String) ?? ""
    return teamID.isEmpty
}

private func cliDeriveSecretsKey() throws -> SymmetricKey {
    let port: mach_port_t = kIOMainPortDefault
    let svc = IOServiceGetMatchingService(port, IOServiceMatching("IOPlatformExpertDevice"))
    defer { IOObjectRelease(svc) }
    guard let cf = IORegistryEntryCreateCFProperty(
        svc, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0
    )?.takeRetainedValue(),
    let uuid = cf as? String else {
        throw NSError(domain: "buddy.cli", code: 1, userInfo: [NSLocalizedDescriptionKey: "IOPlatformUUID unavailable"])
    }
    let salt = "claude-code-buddy.launcher.v1"
    let material = Data((uuid + salt).utf8)
    let hash = SHA256.hash(data: material)
    return SymmetricKey(data: Data(hash))
}

private func cliEncryptedFileSave(account: String, value: String) -> Bool {
    do {
        let key = try cliDeriveSecretsKey()
        // 注：launcherConfigDir 是 top-level `let`，初始化早于 main()；
        // 直接 inline 路径，避免重新引入 main() 之后才能初始化的 top-level 常量。
        let path = URL(fileURLWithPath: "\(launcherConfigDir)/launcher-secrets.enc")
        var cache: [String: String] = [:]
        if FileManager.default.fileExists(atPath: path.path) {
            let encrypted = try Data(contentsOf: path)
            let sealed = try ChaChaPoly.SealedBox(combined: encrypted)
            let decrypted = try ChaChaPoly.open(sealed, using: key)
            cache = try JSONDecoder().decode([String: String].self, from: decrypted)
        }
        cache[account] = value
        try FileManager.default.createDirectory(
            atPath: launcherConfigDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let plaintext = try JSONEncoder().encode(cache)
        let sealed = try ChaChaPoly.seal(plaintext, using: key)
        try sealed.combined.write(to: path, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: path.path
        )
        return true
    } catch {
        fputs("Error: encrypted secrets write failed: \(error)\n", stderr)
        return false
    }
}

private func cliSecretSave(account: String, value: String) -> Bool {
    if cliIsAdHocSigned() {
        return cliEncryptedFileSave(account: account, value: value)
    }
    return cliKeychainSave(account: account, value: value)
}

private func cmdLauncherConfigSet(_ opts: CLIOptions) {
    guard !opts.providerId.isEmpty, !opts.kind.isEmpty, !opts.model.isEmpty, !opts.apiKey.isEmpty else {
        fputs("Usage: buddy launcher config set --provider <id> --kind <anthropic|openai-compatible> [--base-url URL] --model NAME --api-key KEY\n", stderr)
        exit(2)
    }
    guard opts.apiKey.count >= launcherMinAPIKeyLength else {
        fputs("Error: API key must be at least \(launcherMinAPIKeyLength) characters\n", stderr)
        exit(2)
    }
    if opts.kind == "openai-compatible" {
        guard !opts.baseURL.isEmpty,
              opts.baseURL.hasPrefix("http://") || opts.baseURL.hasPrefix("https://") else {
            fputs("Error: openai-compatible kind requires --base-url <http(s)://...>\n", stderr)
            exit(2)
        }
    } else if opts.kind != "anthropic" {
        fputs("Error: kind must be 'anthropic' or 'openai-compatible'\n", stderr)
        exit(2)
    }

    let keyRef = "\(opts.providerId).apiKey"
    guard cliSecretSave(account: keyRef, value: opts.apiKey) else {
        fputs("Error: secret store write failed. Please launch buddy app and configure via app UI.\n", stderr)
        exit(3)
    }

    var cfg = cliLoadConfig()
    cfg.providers[opts.providerId] = CLIProviderConfig(
        kind: opts.kind,
        baseURL: opts.kind == "openai-compatible" ? opts.baseURL : nil,
        model: opts.model,
        keyRef: keyRef,
        noThinking: opts.noThinking ? true : nil  // B2：--no-thinking 设置时传 true，否则 nil
    )
    if cfg.activeProvider.isEmpty {
        cfg.activeProvider = opts.providerId
    }
    do {
        try cliSaveConfig(cfg)
    } catch {
        fputs("Error: write \(launcherConfigPath) failed: \(error)\n", stderr)
        exit(1)
    }

    print("Provider \(opts.providerId) configured.")
    print("  kind: \(opts.kind), model: \(opts.model)")
    if opts.kind == "openai-compatible" { print("  base_url: \(opts.baseURL)") }
    if opts.noThinking { print("  no_thinking: yes") }
    if cfg.activeProvider == opts.providerId { print("  active: yes") }
}

private func cmdLauncherConfigGet(_ opts: CLIOptions) {
    let cfg = cliLoadConfig()
    if cfg.providers.isEmpty {
        print("No providers configured. Use: buddy launcher config set --provider <id> ...")
        return
    }
    if !opts.providerId.isEmpty {
        guard let p = cfg.providers[opts.providerId] else {
            fputs("Provider \(opts.providerId) not found.\n", stderr)
            exit(1)
        }
        let baseURLStr = p.baseURL.map { ", base_url=\($0)" } ?? ""
        let activeStr = cfg.activeProvider == opts.providerId ? " [active]" : ""
        let thinkingStr = p.noThinking == true ? ", no_thinking=true" : ""
        print("\(opts.providerId): kind=\(p.kind), model=\(p.model)\(baseURLStr)\(thinkingStr)\(activeStr)")
    } else {
        for (id, p) in cfg.providers.sorted(by: { $0.key < $1.key }) {
            let baseURLStr = p.baseURL.map { ", base_url=\($0)" } ?? ""
            let activeStr = cfg.activeProvider == id ? " [active]" : ""
            let thinkingStr = p.noThinking == true ? ", no_thinking=true" : ""
            print("\(id): kind=\(p.kind), model=\(p.model)\(baseURLStr)\(thinkingStr)\(activeStr)")
        }
    }
}

private func cmdLauncherConfigUse(_ opts: CLIOptions) {
    let target = opts.positionalArgs.dropFirst().first ?? (opts.positionalArgs.first ?? opts.providerId)
    guard !target.isEmpty else {
        fputs("Usage: buddy launcher config use <provider-id>\n", stderr)
        exit(2)
    }
    var cfg = cliLoadConfig()
    guard cfg.providers[target] != nil else {
        fputs("Provider \(target) not found. Configure first with: buddy launcher config set ...\n", stderr)
        exit(1)
    }
    cfg.activeProvider = target
    do {
        try cliSaveConfig(cfg)
    } catch {
        fputs("Write failed: \(error)\n", stderr)
        exit(1)
    }
    print("Active provider: \(target)")
}

// MARK: - Launcher Hotkey Commands (2026-06-15)
// 通过 socket 让 app 进程调 KeyboardShortcuts 库 API（CLI 不依赖 BuddyCore/KeyboardShortcuts 库）
// 契约 2：请求 action ∈ {hotkey_set, hotkey_show, hotkey_clear}；
//         响应 {status:"ok", data:{combo, isDefault}} 或 {status:"error", message}

private func cmdLauncherHotkeyShow() {
    let query: [String: Any] = ["action": "hotkey_show"]
    do {
        let data = try sendQuery(query)
        if let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    } catch {
        fputs("\(error)\n", stderr)
        exit(1)
    }
}

private func cmdLauncherHotkeySet(_ opts: CLIOptions) {
    guard !opts.hotkeyKey.isEmpty else {
        fputs("Usage: buddy launcher hotkey set --key <key> [--modifiers <csv>]\n", stderr)
        fputs("  --key: 主键（如 space, a, f1, return；字母 a-z / 数字 0-9）\n", stderr)
        fputs("  --modifiers: 修饰键逗号列表（command,shift,control,option）\n", stderr)
        exit(2)
    }
    let modStrs = opts.hotkeyModifiers
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    // CLI 侧纯字符串校验（真正的 Key 构造在 app 侧 HotkeyKeyMapper 完成）
    let validModifiers: Set<String> = ["command", "cmd", "super", "shift", "control", "ctrl", "option", "opt", "alt"]
    for m in modStrs {
        guard validModifiers.contains(m.lowercased()) else {
            fputs("Error: invalid modifier '\(m)'. Allowed: command, shift, control, option\n", stderr)
            exit(2)
        }
    }
    // 至少需要一个修饰键（无修饰键的全局热键会与普通打字冲突，库也建议带修饰键）
    guard !modStrs.isEmpty else {
        fputs("Error: --modifiers is required (at least one of: command, shift, control, option)\n", stderr)
        fputs("  全局热键必须带修饰键，否则会与普通打字冲突\n", stderr)
        exit(2)
    }

    let query: [String: Any] = [
        "action": "hotkey_set",
        "key": opts.hotkeyKey,
        "modifiers": modStrs,
    ]
    do {
        let data = try sendQuery(query)
        // 解析响应：成功打印 combo，失败打印 message 到 stderr 并 exit 非 0
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            fputs("Error: invalid response from app: \(String(data: data, encoding: .utf8) ?? "?")\n", stderr)
            exit(1)
        }
        if let status = json["status"] as? String, status == "ok" {
            if let str = String(data: data, encoding: .utf8) {
                print(str)
            }
        } else {
            let message = json["message"] as? String ?? "unknown error"
            fputs("Error: \(message)\n", stderr)
            exit(1)
        }
    } catch {
        fputs("\(error)\n", stderr)
        exit(1)
    }
}

private func cmdLauncherHotkeyClear() {
    let query: [String: Any] = ["action": "hotkey_clear"]
    do {
        let data = try sendQuery(query)
        if let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    } catch {
        fputs("\(error)\n", stderr)
        exit(1)
    }
}

// MARK: - Launcher Debug (功能调试：CLI 驱动候选生成，不经键盘自动化)
// 通过 socket 让 app 进程调 BuiltinPluginRegistry（直驱，不经 LauncherManager）。
// 契约：
//   请求 action ∈ {launcher_debug_candidates, launcher_debug_perform, launcher_debug_registry}
//     - candidates/perform 请求字段：query:String（非空）；perform 另含 index:Int（默认 0）
//   响应：
//     - candidates → {status:"ok", data:{query, count, candidates[{pluginId,title,subtitle,score}]}}
//     - perform    → {status:"ok", data:{pluginId, performed:true, copied?}}（copied 仅当 perform 后 pasteboard 非空）
//     - registry   → {status:"ok", data:{plugins[{id,priority,sectionTitle}]}}（priority 降序）

private func cmdLauncherDebugCandidates(_ query: String) {
    let queryDict: [String: Any] = [
        "action": "launcher_debug_candidates",
        "query": query,
    ]
    do {
        let data = try sendQuery(queryDict)
        if let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    } catch {
        fputs("\(error)\n", stderr)
        exit(1)
    }
}

private func cmdLauncherDebugPerform(_ query: String, index: Int) {
    let queryDict: [String: Any] = [
        "action": "launcher_debug_perform",
        "query": query,
        "index": index,
    ]
    do {
        let data = try sendQuery(queryDict)
        if let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    } catch {
        fputs("\(error)\n", stderr)
        exit(1)
    }
}

private func cmdLauncherDebugRegistry() {
    let queryDict: [String: Any] = ["action": "launcher_debug_registry"]
    do {
        let data = try sendQuery(queryDict)
        if let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    } catch {
        fputs("\(error)\n", stderr)
        exit(1)
    }
}

// MARK: - Launcher Debug Route (AI 路由调试：query → narrow → AI select → LLM 响应)
//   请求 action = launcher_debug_route，字段 query:String（非空）
//   响应：{status:"ok", data:{query, decision, candidates[], outputText, durationMs}}
private func cmdLauncherDebugRoute(_ query: String) {
    let queryDict: [String: Any] = [
        "action": "launcher_debug_route",
        "query": query,
    ]
    do {
        let data = try sendQuery(queryDict, timeout: 30.0)
        if let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    } catch {
        fputs("\(error)\n", stderr)
        exit(1)
    }
}

// MARK: - Settings Debug（GUI 自动化：CLI 经 socket 驱动设置窗口，绕过 LSUIElement osascript 不路由）
//
// 契约（SOURCE OF TRUTH: Sources/BuddyCLI/main.swift + QueryHandler + AppDelegate）：
//   LSUIElement accessory app 下 osascript click/AXPress/keystroke 对非 key 窗口不路由（patterns/2026-06-23）。
//   这些命令经 socket 让 app 进程直驱 in-process API（AppDelegate.showSettings / selectSection /
//   PluginGalleryViewController.selectPlugin），是唯一可靠的设置窗口自动化打开/切换路径。
//
//   命令：
//     buddy launcher debug open-settings [section]     打开设置窗口，可选预选分类
//     buddy launcher debug select-section <section>    选中主分类（general/about/hotkey/ai/skins/plugins）
//     buddy launcher debug select-plugin <name>        在插件分类内选中具名插件（如 snip）
//     buddy launcher debug get-state                   dump 窗口几何 + 选中态（JSON，供帧谓词求值）
//   section 取值 = SettingsSection.rawValue（general/about/hotkey/ai/skins/plugins）。
//   响应：{status:"ok", data:{...}}；失败 {status:"error", message} + CLI exit 非 0。

/// `buddy launcher debug open-settings [section]` → action settings_open
private func cmdSettingsOpen(section: String?) {
    var queryDict: [String: Any] = ["action": "settings_open"]
    if let s = section, !s.isEmpty { queryDict["section"] = s }
    do {
        let data = try sendQuery(queryDict)
        if let str = String(data: data, encoding: .utf8) { print(str) }
    } catch {
        fputs("\(error)\n", stderr)
        exit(1)
    }
}

/// `buddy launcher debug select-section <section>` → action settings_select_section
private func cmdSettingsSelectSection(_ section: String) {
    let queryDict: [String: Any] = [
        "action": "settings_select_section",
        "section": section,
    ]
    do {
        let data = try sendQuery(queryDict)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = obj["status"] as? String else {
            fputs("invalid response from app\n", stderr)
            exit(1)
        }
        if let str = String(data: data, encoding: .utf8) { print(str) }
        if status != "ok" { exit(1) }
    } catch {
        fputs("\(error)\n", stderr)
        exit(1)
    }
}

/// `buddy launcher debug select-plugin <name>` → action settings_select_plugin
private func cmdSettingsSelectPlugin(_ name: String) {
    let queryDict: [String: Any] = [
        "action": "settings_select_plugin",
        "name": name,
    ]
    do {
        let data = try sendQuery(queryDict, timeout: 5.0)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = obj["status"] as? String else {
            fputs("invalid response from app\n", stderr)
            exit(1)
        }
        if let str = String(data: data, encoding: .utf8) { print(str) }
        if status != "ok" { exit(1) }
    } catch {
        fputs("\(error)\n", stderr)
        exit(1)
    }
}

/// `buddy launcher debug snip-expand <create|edit>` → action settings_snip_expand
/// autopilot 2026-07-13：驱动 snip 面板编辑态（展开新建/编辑表单），验证 content 编辑器布局。
private func cmdSettingsSnipExpand(_ mode: String) {
    let queryDict: [String: Any] = [
        "action": "settings_snip_expand",
        "mode": mode,
    ]
    do {
        let data = try sendQuery(queryDict, timeout: 5.0)
        if let str = String(data: data, encoding: .utf8) { print(str) }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = obj["status"] as? String, status == "ok" else {
            exit(1)
        }
    } catch {
        fputs("\(error)\n", stderr)
        exit(1)
    }
}

/// `buddy launcher debug get-state` → action settings_get_state（pretty-print JSON）
private func cmdSettingsGetState() {
    let queryDict: [String: Any] = ["action": "settings_get_state"]
    do {
        let data = try sendQuery(queryDict)
        // pretty-print 便于人读；保持 jq 友好（sortedKeys）
        if let obj = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
           let str = String(data: pretty, encoding: .utf8) {
            print(str)
        } else if let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    } catch {
        fputs("\(error)\n", stderr)
        exit(1)
    }
}

// MARK: - Launcher Run（C4 dry-run：直接执行具名插件，不经候选路由）
//
// 契约 C4（SOURCE OF TRUTH: Sources/BuddyCLI/main.swift + QueryHandler）：
//   命令：buddy launcher run <name> --input "xxx" [--json]
//   实现：Foundation-only，经 socket query app（action launcher_debug_run_plugin），不 spawn 子进程。
//   app 侧 QueryHandler 加分支 → 按 name 找外部插件 manifest → TrustStore.checkAndPrompt（B1）
//     → 信任通过则 PluginDispatcher.execute() 直驱 → 返回 JSON {name,stdout,stderr,exit_code,duration_ms}。
//   trust 失败返回 {status:"error", message:"not trusted"} + CLI 退出码非 0。
//   退出码：插件正常退出透传 exit_code（0=成功）；未找到/trust 拒绝/app 错误 → 非 0。
//   不经候选路由：区别于 debug perform（query→candidates→perform N），run 是 name→直接 execute。
private func cmdLauncherRun(name: String, input: String, json: Bool) {
    guard !name.isEmpty else {
        fputs("Usage: buddy launcher run <name> --input \"xxx\" [--json]\n", stderr)
        exit(2)
    }
    let queryDict: [String: Any] = [
        "action": "launcher_debug_run_plugin",
        "name": name,
        "input": input,
    ]
    let data: Data
    do {
        data = try sendQuery(queryDict)
    } catch {
        fputs("\(error)\n", stderr)
        exit(1)
    }
    // 解析 app 返回的 JSON：{status:"ok"|"error", data?:{...}, message?:...}
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let status = obj["status"] as? String else {
        fputs("invalid response from app\n", stderr)
        exit(1)
    }
    if status != "ok" {
        let message = obj["message"] as? String ?? "run failed"
        fputs("\(message)\n", stderr)
        exit(1)
    }
    // 成功：data = {name, stdout, stderr, exit_code, duration_ms}
    guard let result = obj["data"] as? [String: Any] else {
        fputs("invalid run result data\n", stderr)
        exit(1)
    }
    let exitCode = (result["exit_code"] as? Int) ?? 0
    if json {
        // --json：输出完整结果 JSON
        if let out = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
           let str = String(data: out, encoding: .utf8) {
            print(str)
        }
    } else {
        // 默认：输出插件 stdout（场景 9 断言 stdout 非空）
        let stdout = (result["stdout"] as? String) ?? ""
        if !stdout.isEmpty {
            print(stdout)
        }
        // stderr 非空时也打到 stderr（便于排查）
        let stderrStr = (result["stderr"] as? String) ?? ""
        if !stderrStr.isEmpty {
            fputs(stderrStr, stderr)
            if !stderrStr.hasSuffix("\n") { fputs("\n", stderr) }
        }
    }
    // 退出码：插件正常退出透传（0=成功）；崩溃/trust 拒绝已在上面 exit(1)
    exit(Int32(exitCode))
}

// MARK: - Launcher Plugin Management (task 006)
// SOURCE OF TRUTH: BuddyCore/Launcher/Plugin/TrustStore.swift TrustRecord
// CLI inlined to avoid BuddyCore dependency
private struct CLITrustRecord: Codable {
    let trustKey: String
    let pluginName: String
    let approvedAt: Date
}

private struct CLITrustFile: Codable {
    var records: [CLITrustRecord]
}

private struct CLIPluginManifestCheck: Codable {
    let name: String
    let version: String
    let description: String
    /// C1/C5 mirror：与 BuddyCore PluginManifest.summary 同构（可选，降级）。
    let summary: String?
    /// C1/C5：keywords 可选（向后兼容无 keywords 的旧 plugin.json，自动合成 decodeIfPresent 容错）
    let keywords: [String]?
    let mode: String?              // nil 默认 "stdin"
    // stdin 字段
    let cmd: String?
    let args: [String]?
    // prompt 字段
    let systemPrompt: String?
    let maxIterations: Int?
    let model: String?
    let autoCopyToClipboard: Bool?
    /// M1/C5 mirror：与 BuddyCore PluginManifest.deps 同构（可选，降级）。
    /// decodeIfPresent ?? []，向后兼容无 deps 字段的 legacy plugin.json。
    let deps: [CLIPluginDep]?

    /// M1/C5 mirror：PluginDep 结构镜像（Foundation-only，与 BuddyCore PluginDep 字段逐字一致）。
    struct CLIPluginDep: Codable {
        let check: String
        let brew: String?
        let label: String?

        init(check: String, brew: String? = nil, label: String? = nil) {
            self.check = check
            self.brew = brew
            self.label = label
        }

        // swiftlint:disable:next nesting - CLIPluginDep 嵌套在 CLIPluginManifest 内（mirror 必要），CodingKeys 为其 Codable 自定义 init 服务
        private enum CodingKeys: String, CodingKey { case check, brew, label }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let decodedCheck = try c.decode(String.self, forKey: .check)
            guard !decodedCheck.isEmpty else {
                throw DecodingError.dataCorruptedError(forKey: .check, in: c, debugDescription: "CLIPluginDep.check must be non-empty")
            }
            check = decodedCheck
            let decodedBrew = try c.decodeIfPresent(String.self, forKey: .brew)
            if let brewValue = decodedBrew, !brewValue.isEmpty {
                // B1 安全 mirror：brew 包名白名单（防 shell 注入，与 BuddyCore PluginDep 逐字一致）
                let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._+-/@")
                guard brewValue.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
                    throw DecodingError.dataCorruptedError(forKey: .brew, in: c, debugDescription: "CLIPluginDep.brew 包名含非法字符（防 shell 注入）")
                }
            }
            brew = decodedBrew
            label = try c.decodeIfPresent(String.self, forKey: .label)
        }
    }

    /// M1/C5：deps 访问器，永远返回数组（无字段 → 空数组）。
    /// SOURCE OF TRUTH: BuddyCore PluginManifest.deps accessor（双绑，逐字一致降级语义）。
    var cliDeps: [CLIPluginDep] {
        deps ?? []
    }

    /// C1/C5 降级（SOURCE OF TRUTH: BuddyCore PluginManifest.displaySummary，双绑）。
    /// 取值优先级：summary 非空 → summary；否则 description 首句（按 。/./换行切第一段 trim）；都空 → name。
    /// 与 BuddyCore `firstSentence` 同切分语义。
    var cliDisplaySummary: String {
        if let s = summary?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            return s
        }
        let descFirst = cliFirstSentence(of: description)
        if !descFirst.isEmpty { return descFirst }
        return name
    }
}

/// C5 mirror：与 BuddyCore PluginManifest.firstSentence 同切分语义。
/// 取字符串首句：按 。/换行/". "切第一段并 trim；句末单独 "." 也算句末。
private func cliFirstSentence(of text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }
    var cutIndex: String.Index?
    for sep in ["。", "\n", ". "] {
        if let range = trimmed.range(of: sep) {
            if let existing = cutIndex {
                if range.lowerBound < existing { cutIndex = range.lowerBound }
            } else {
                cutIndex = range.lowerBound
            }
        }
    }
    if trimmed.hasSuffix(".") {
        let suffixIdx = trimmed.index(before: trimmed.endIndex)
        if let existing = cutIndex {
            if suffixIdx < existing { cutIndex = suffixIdx }
        } else {
            cutIndex = suffixIdx
        }
    }
    if let idx = cutIndex {
        return String(trimmed[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return trimmed
}

private func cliLoadTrustFile() -> CLITrustFile {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: launcherTrustPath)),
          let file = try? JSONDecoder.iso8601().decode(CLITrustFile.self, from: data) else {
        return CLITrustFile(records: [])
    }
    return file
}

private func cliSaveTrustFile(_ file: CLITrustFile) throws {
    try FileManager.default.createDirectory(atPath: launcherConfigDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let encoder = JSONEncoder.iso8601Pretty()
    let data = try encoder.encode(file)
    try data.write(to: URL(fileURLWithPath: launcherTrustPath))
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: launcherTrustPath)
}

private func cmdLauncherAdd(_ userRepo: String) {
    let parts = userRepo.split(separator: "/")
    guard parts.count == 2,
          !parts[0].isEmpty, !parts[1].isEmpty,
          !parts.contains(where: { $0.hasPrefix(".") }) else {
        fputs("Invalid user/repo format: '\(userRepo)'. Expected <user>/<repo>\n", stderr)
        exit(2)
    }
    let dirName = userRepo.replacingOccurrences(of: "/", with: "-")
    let targetDir = URL(fileURLWithPath: "\(launcherPluginsDir)/\(dirName)")
    guard !FileManager.default.fileExists(atPath: targetDir.path) else {
        fputs("Plugin already installed: \(dirName)\n", stderr)
        exit(3)
    }
    try? FileManager.default.createDirectory(atPath: launcherPluginsDir, withIntermediateDirectories: true, attributes: nil)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["clone", "--depth", "1", "https://github.com/\(userRepo).git", targetDir.path]
    process.environment = ProcessInfo.processInfo.environment

    do {
        try process.run()
    } catch {
        fputs("git clone failed to start: \(error)\n", stderr)
        exit(1)
    }
    // 60s timeout
    let timeoutWork = DispatchWorkItem {
        if process.isRunning { process.terminate() }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: timeoutWork)
    process.waitUntilExit()
    timeoutWork.cancel()

    guard process.terminationStatus == 0 else {
        try? FileManager.default.removeItem(at: targetDir)
        fputs("git clone failed (exit \(process.terminationStatus))\n", stderr)
        exit(1)
    }

    let manifestURL = targetDir.appending(path: "plugin.json")
    guard FileManager.default.fileExists(atPath: manifestURL.path) else {
        try? FileManager.default.removeItem(at: targetDir)
        fputs("Missing plugin.json in \(userRepo)\n", stderr)
        exit(2)
    }

    do {
        let data = try Data(contentsOf: manifestURL)
        _ = try JSONDecoder().decode(CLIPluginManifestCheck.self, from: data)
    } catch {
        try? FileManager.default.removeItem(at: targetDir)
        fputs("Invalid plugin.json: \(error)\n", stderr)
        exit(2)
    }
    print("Installed \(userRepo) -> \(targetDir.path)")
}

private func cliComputeTrustKeyStdin(cmd: String, args: [String], executableURL: URL) -> String? {
    guard let exeData = try? Data(contentsOf: executableURL) else { return nil }
    let exeDigest = SHA256.hash(data: exeData)
    let exeHashHex = exeDigest.map { String(format: "%02x", $0) }.joined()
    let combined = "\(cmd)\n\(args.joined(separator: "\n"))\n\(exeHashHex)"
    let digest = SHA256.hash(data: Data(combined.utf8))
    return "stdin:" + digest.map { String(format: "%02x", $0) }.joined()
}

private func cliComputeTrustKeyPrompt(systemPrompt: String, maxIterations: Int, model: String?) -> String {
    // 结构性 tag：nil → "0", 非 nil → "1:value"，避免 nil 与字符串 "default" 等碰撞
    // SOURCE OF TRUTH: BuddyCore/Launcher/Plugin/TrustStore.swift trustKey()
    let modelPart = model.map { "1:\($0)" } ?? "0"
    let combined = "\(systemPrompt)\n\(maxIterations)\n\(modelPart)"
    let digest = SHA256.hash(data: Data(combined.utf8))
    let hex = digest.map { String(format: "%02x", $0) }.joined()
    return "prompt:" + hex
}

private func cliComputeTrustKeyCommand(cmd: String, args: [String], executableURL: URL) -> String? {
    // SOURCE OF TRUTH: BuddyCore/Launcher/Plugin/TrustStore.swift trustKey() .command case
    // 与 stdin 同构（cmd + args + sha256(exe_bytes)），仅 mode 前缀 "command:" 不同
    guard let exeData = try? Data(contentsOf: executableURL) else { return nil }
    let exeDigest = SHA256.hash(data: exeData)
    let exeHashHex = exeDigest.map { String(format: "%02x", $0) }.joined()
    let combined = "\(cmd)\n\(args.joined(separator: "\n"))\n\(exeHashHex)"
    let digest = SHA256.hash(data: Data(combined.utf8))
    return "command:" + digest.map { String(format: "%02x", $0) }.joined()
}

private func cliTrustStatus(manifest: CLIPluginManifestCheck, pluginDir: URL) -> String {
    let mode = manifest.mode ?? "stdin"
    let trustFile = cliLoadTrustFile()
    guard let record = trustFile.records.first(where: { $0.pluginName == manifest.name }) else {
        return "never_run"
    }
    switch mode {
    case "stdin":
        guard let cmd = manifest.cmd, let args = manifest.args else {
            return "untrusted"
        }
        let exeURL = pluginDir.appending(path: cmd)
        guard let currentKey = cliComputeTrustKeyStdin(cmd: cmd, args: args, executableURL: exeURL) else {
            return "untrusted"
        }
        return currentKey == record.trustKey ? "trusted" : "untrusted"
    case "prompt":
        guard let systemPrompt = manifest.systemPrompt else {
            return "untrusted"
        }
        let currentKey = cliComputeTrustKeyPrompt(
            systemPrompt: systemPrompt,
            maxIterations: manifest.maxIterations ?? 1,
            model: manifest.model
        )
        return currentKey == record.trustKey ? "trusted" : "untrusted"
    case "command":
        // command mode：与 stdin 同构 trustKey（cmd+args+sha256(exe)），仅前缀 "command:"
        guard let cmd = manifest.cmd, let args = manifest.args else {
            return "untrusted"
        }
        let exeURL = pluginDir.appending(path: cmd)
        guard let currentKey = cliComputeTrustKeyCommand(cmd: cmd, args: args, executableURL: exeURL) else {
            return "untrusted"
        }
        return currentKey == record.trustKey ? "trusted" : "untrusted"
    default:
        _ = record
        return "unknown_mode"
    }
}

private func cmdLauncherList() {
    let baseURL = URL(fileURLWithPath: launcherPluginsDir)
    guard let entries = try? FileManager.default.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: nil) else {
        print("No plugins installed.")
        return
    }
    var listedNames = Set<String>()
    var count = 0
    // 第一遍：扫描所有有效 plugin（含已禁用），加 [禁用] 后缀
    for entry in entries {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else { continue }
        let manifestURL = entry.appending(path: "plugin.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let m = try? JSONDecoder().decode(CLIPluginManifestCheck.self, from: data) else { continue }
        let disabled = FileManager.default.fileExists(atPath: entry.appending(path: ".disabled").path)
        let status = cliTrustStatus(manifest: m, pluginDir: entry)
        let suffix = disabled ? " [禁用]" : ""
        // C1/C5：list 展示用 summary（降级后非空）
        print("\(m.name)\(suffix) (v\(m.version)) [\(status)] - \(m.cliDisplaySummary)")
        listedNames.insert(m.name)
        count += 1
    }
    // 第二遍：扫描 plugin.json 无效但带 .disabled marker 的目录
    for entry in entries {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else { continue }
        let dirName = entry.lastPathComponent
        if listedNames.contains(dirName) { continue }
        let disabled = FileManager.default.fileExists(atPath: entry.appending(path: ".disabled").path)
        guard disabled else { continue }
        print("\(dirName) [禁用] (info unavailable)")
        count += 1
    }
    if count == 0 {
        print("No plugins installed.")
    }
}

private func cmdLauncherRemove(_ name: String) {
    guard !name.isEmpty else {
        fputs("Usage: buddy launcher remove <name>\n", stderr)
        exit(2)
    }
    let baseURL = URL(fileURLWithPath: launcherPluginsDir)
    let entries = (try? FileManager.default.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: nil)) ?? []
    var found: URL?
    for entry in entries {
        let manifestURL = entry.appending(path: "plugin.json")
        if let data = try? Data(contentsOf: manifestURL),
           let m = try? JSONDecoder().decode(CLIPluginManifestCheck.self, from: data),
           m.name == name {
            found = entry
            break
        }
    }
    guard let targetDir = found else {
        fputs("Plugin not found: \(name)\n", stderr)
        exit(1)
    }
    do {
        try FileManager.default.removeItem(at: targetDir)
    } catch {
        fputs("Failed to remove plugin dir: \(error)\n", stderr)
        exit(1)
    }
    // Sync trust.json
    var trustFile = cliLoadTrustFile()
    trustFile.records.removeAll { $0.pluginName == name }
    try? cliSaveTrustFile(trustFile)
    print("Removed plugin: \(name)")
}

private func cmdLauncherInspect(_ name: String) {
    guard !name.isEmpty else {
        fputs("Usage: buddy launcher inspect <name>\n", stderr)
        exit(2)
    }
    let baseURL = URL(fileURLWithPath: launcherPluginsDir)
    let entries = (try? FileManager.default.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: nil)) ?? []
    var foundManifest: CLIPluginManifestCheck?
    var foundDir: URL?
    for entry in entries {
        let manifestURL = entry.appending(path: "plugin.json")
        if let data = try? Data(contentsOf: manifestURL),
           let m = try? JSONDecoder().decode(CLIPluginManifestCheck.self, from: data),
           m.name == name {
            foundManifest = m
            foundDir = entry
            break
        }
    }
    guard let m = foundManifest, let dir = foundDir else {
        fputs("Plugin not found: \(name)\n", stderr)
        exit(1)
    }
    let status = cliTrustStatus(manifest: m, pluginDir: dir)
    let resolvedMode = m.mode ?? "stdin"
    var out: [String: Any] = [
        "name": m.name,
        "version": m.version,
        // C1/C5：summary 字段（应用降级规则，永不空）
        "summary": m.cliDisplaySummary,
        "description": m.description,
        "mode": resolvedMode,
        "trust_status": status,
        "install_path": dir.path
    ]
    switch resolvedMode {
    case "stdin":
        if let cmd = m.cmd { out["cmd"] = cmd }
        if let args = m.args { out["args"] = args }
    case "prompt":
        if let systemPrompt = m.systemPrompt {
            let summary = String(systemPrompt.prefix(200))
            out["system_prompt_summary"] = systemPrompt.count > 200 ? "\(summary)..." : summary
        }
        if let maxIterations = m.maxIterations { out["max_iterations"] = maxIterations }
        if let model = m.model { out["model"] = model }
        if let autoCopy = m.autoCopyToClipboard { out["auto_copy_to_clipboard"] = autoCopy }
    case "command":
        // command mode：与 stdin 同构，输出 cmd/args（CLAUDE.md SOURCE OF TRUTH 双绑）
        if let cmd = m.cmd { out["cmd"] = cmd }
        if let args = m.args { out["args"] = args }
    default:
        break
    }
    // M1/C5：deps 字段输出（场景 8 契约：inspect JSON 含 deps，列 check 名）。
    // 始终输出数组（无声明 → []，向后兼容）；每个 dep 展开为 {check,brew,label} 字典。
    out["deps"] = m.cliDeps.map { d in
        var dict: [String: Any] = ["check": d.check]
        if let brew = d.brew { dict["brew"] = brew }
        if let label = d.label { dict["label"] = label }
        return dict
    }
    if let data = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]),
       let str = String(data: data, encoding: .utf8) {
        print(str)
    } else {
        fputs("Failed to encode inspect output\n", stderr)
        exit(1)
    }
}

// MARK: - Marketplace Mirror Schema (task 007)
// ⚠️ SOURCE OF TRUTH: BuddyCore/Launcher/Marketplace/{MarketplaceManifest,MarketplaceManager}.swift
// CLI mirror 与 marketplace.json / marketplace-meta.json JSON 字段完全一致
// 任何 BuddyCore schema 改动都必须同步到此 mirror（双绑陷阱）

struct CLIMarketplaceManifest: Codable {
    let schemaVersion: Int
    let name: String
    let plugins: [CLIMarketplacePlugin]
}

struct CLIMarketplacePlugin: Codable {
    let name: String
    let version: String
    let description: String?
    let source: CLIPluginSourceConfig
}

/// 与 BuddyCore `PluginSourceConfig` JSON 表示一致：String 简写 = .localSubdir，
/// 否则按 `source` 字段判别 `git-subdir` / `url` / `file`
enum CLIPluginSourceConfig: Codable {
    case localSubdir(path: String)
    case gitSubdir(url: String, path: String, ref: String, sha: String?)
    case gitURL(url: String, sha: String?)
    case file(path: String)

    private enum CodingKeys: String, CodingKey {
        case source
        case url
        case path
        case ref
        case sha
    }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let value = try? single.decode(String.self) {
            self = .localSubdir(path: value)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .source)
        switch kind {
        case "git-subdir":
            self = .gitSubdir(
                url: try container.decode(String.self, forKey: .url),
                path: try container.decode(String.self, forKey: .path),
                ref: try container.decode(String.self, forKey: .ref),
                sha: try container.decodeIfPresent(String.self, forKey: .sha)
            )
        case "url":
            self = .gitURL(
                url: try container.decode(String.self, forKey: .url),
                sha: try container.decodeIfPresent(String.self, forKey: .sha)
            )
        case "file":
            self = .file(path: try container.decode(String.self, forKey: .path))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .source,
                in: container,
                debugDescription: "unknown source kind: \(kind)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .localSubdir(let path):
            var single = encoder.singleValueContainer()
            try single.encode(path)
        case .gitSubdir(let url, let path, let ref, let sha):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("git-subdir", forKey: .source)
            try container.encode(url, forKey: .url)
            try container.encode(path, forKey: .path)
            try container.encode(ref, forKey: .ref)
            try container.encodeIfPresent(sha, forKey: .sha)
        case .gitURL(let url, let sha):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("url", forKey: .source)
            try container.encode(url, forKey: .url)
            try container.encodeIfPresent(sha, forKey: .sha)
        case .file(let path):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("file", forKey: .source)
            try container.encode(path, forKey: .path)
        }
    }
}

/// Mirror of BuddyCore MarketplaceInspection。lastSyncedAt 用 String? 直接匹配
/// BuddyCore writeMeta 的 `.iso8601` dateEncodingStrategy 输出。
struct CLIMarketplaceInspection: Codable {
    let plugins: [PluginInspection]
    let sideloadedPlugins: [SideloadedPlugin]
    let lastSyncedAt: String?
    let consecutiveSyncFailures: Int

    struct PluginInspection: Codable {
        let name: String
        let version: String
        let enabled: Bool
        let source: String
        /// C5 mirror：summary（降级后非空），从插件目录的 plugin.json 运行时解析。
        let summary: String
    }

    struct SideloadedPlugin: Codable {
        let name: String
        let enabled: Bool
        /// C5 mirror：summary（降级后非空）。
        let summary: String
    }
}

/// C5 mirror：从插件目录读 plugin.json → CLIPluginManifestCheck → cliDisplaySummary（降级）。
/// 读失败/无 plugin.json 返回 nil（调用方决定兜底）。
private func cliSummaryForPluginDir(_ dir: URL) -> String? {
    let manifestURL = dir.appending(path: "plugin.json")
    guard let data = try? Data(contentsOf: manifestURL),
          let m = try? JSONDecoder().decode(CLIPluginManifestCheck.self, from: data) else {
        return nil
    }
    return m.cliDisplaySummary
}

// MARK: - sanitize helper (task 007 / task 004 follow-up)

private func sanitizePluginName(_ name: String) -> Bool {
    name.range(of: "^[a-z0-9-]+$", options: .regularExpression) != nil
}

// MARK: - Marketplace cache paths (函数避免 top-level let init order 陷阱)

private func marketplaceCachePath() -> String { "\(launcherConfigDir)/marketplace.json" }
private func marketplaceMetaPath() -> String { "\(launcherConfigDir)/marketplace-meta.json" }
private func reseedPendingPath() -> String { "\(launcherConfigDir)/reseed-pending-disabled.json" }

// MARK: - launcher install / disable / enable / reseed / list --json (task 007)

private func cliSourceLabel(_ source: CLIPluginSourceConfig) -> String {
    switch source {
    case .localSubdir(let path):
        return "local-subdir: \(path)"
    case .file(let path):
        return "file: \(path)"
    case .gitURL(let url, _):
        return "git-url: \(url)"
    case .gitSubdir(let url, let path, _, _):
        return "git-subdir: \(url)/\(path)"
    }
}

private func cmdLauncherDisable(_ name: String) {
    guard !name.isEmpty else {
        fputs("Usage: buddy launcher disable <name>\n", stderr)
        exit(2)
    }
    guard sanitizePluginName(name) else {
        fputs("Invalid name: '\(name)' (allowed: a-z, 0-9, -)\n", stderr)
        exit(2)
    }
    let dir = URL(fileURLWithPath: launcherPluginsDir).appending(path: name)
    guard FileManager.default.fileExists(atPath: dir.path) else {
        fputs("Plugin not found: \(name)\n", stderr)
        exit(3)
    }
    let marker = dir.appending(path: ".disabled")
    if !FileManager.default.fileExists(atPath: marker.path) {
        do {
            try Data().write(to: marker)
        } catch {
            fputs("Failed to write .disabled marker: \(error)\n", stderr)
            exit(1)
        }
    }
    print("Disabled: \(name)")
}

private func cmdLauncherEnable(_ name: String) {
    guard !name.isEmpty else {
        fputs("Usage: buddy launcher enable <name>\n", stderr)
        exit(2)
    }
    guard sanitizePluginName(name) else {
        fputs("Invalid name: '\(name)' (allowed: a-z, 0-9, -)\n", stderr)
        exit(2)
    }
    let dir = URL(fileURLWithPath: launcherPluginsDir).appending(path: name)
    guard FileManager.default.fileExists(atPath: dir.path) else {
        fputs("Plugin not found: \(name)\n", stderr)
        exit(3)
    }
    let marker = dir.appending(path: ".disabled")
    if FileManager.default.fileExists(atPath: marker.path) {
        do {
            try FileManager.default.removeItem(at: marker)
        } catch {
            fputs("Failed to remove .disabled marker: \(error)\n", stderr)
            exit(1)
        }
    }
    print("Enabled: \(name)")
}

private func cmdLauncherReseed() {
    let cacheURL = URL(fileURLWithPath: marketplaceCachePath())
    let metaURL = URL(fileURLWithPath: marketplaceMetaPath())
    let pluginsBase = URL(fileURLWithPath: launcherPluginsDir)

    // Step 1: 读 cache 收集 marketplace 列出的 plugin 名
    var pluginNames: [String] = []
    if let data = try? Data(contentsOf: cacheURL),
       let manifest = try? JSONDecoder().decode(CLIMarketplaceManifest.self, from: data) {
        pluginNames = manifest.plugins.map { $0.name }
    }

    // Step 2: 收集需保留 .disabled 的 plugin
    var disabledNames: [String] = []
    for name in pluginNames {
        let markerPath = pluginsBase.appending(path: name).appending(path: ".disabled").path
        if FileManager.default.fileExists(atPath: markerPath) {
            disabledNames.append(name)
        }
    }

    // Step 3: 删 plugin dirs（仅 marketplace 列出的，保留用户 sideloaded）
    for name in pluginNames {
        let dir = pluginsBase.appending(path: name)
        try? FileManager.default.removeItem(at: dir)
    }

    // Step 4: 删 marketplace.json + marketplace-meta.json
    try? FileManager.default.removeItem(at: cacheURL)
    try? FileManager.default.removeItem(at: metaURL)

    // Step 5: 写 reseed-pending-disabled.json 供 app 下次启动 seedFromBundle 完成后读取恢复 .disabled
    if !disabledNames.isEmpty {
        let sorted = disabledNames.sorted()
        if let encoded = try? JSONEncoder().encode(sorted) {
            try? FileManager.default.createDirectory(
                atPath: launcherConfigDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try? encoded.write(to: URL(fileURLWithPath: reseedPendingPath()))
        }
    } else {
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: reseedPendingPath()))
    }

    print("Reseed staged: cleared cache + \(pluginNames.count) plugin dirs.")
    print("Next app launch will re-seed marketplace and restore disabled markers (\(disabledNames.count) tracked).")
}

private func cliGitCloneFull(url: String, ref: String?, targetDir: URL, pluginName: String) {
    try? FileManager.default.createDirectory(
        atPath: launcherPluginsDir,
        withIntermediateDirectories: true,
        attributes: nil
    )
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("buddy-install-\(UUID().uuidString)")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    var args = ["clone", "--depth", "1"]
    if let ref = ref, !ref.isEmpty {
        args += ["--branch", ref]
    }
    args += [url, tempDir.path]
    process.arguments = args
    process.environment = ProcessInfo.processInfo.environment

    do {
        try process.run()
    } catch {
        fputs("git clone failed to start: \(error)\n", stderr)
        exit(1)
    }
    let timeoutWork = DispatchWorkItem {
        if process.isRunning { process.terminate() }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: timeoutWork)
    process.waitUntilExit()
    timeoutWork.cancel()

    guard process.terminationStatus == 0 else {
        try? FileManager.default.removeItem(at: tempDir)
        fputs("git clone failed (exit \(process.terminationStatus))\n", stderr)
        exit(1)
    }
    do {
        try FileManager.default.moveItem(at: tempDir, to: targetDir)
    } catch {
        try? FileManager.default.removeItem(at: tempDir)
        fputs("Failed to move clone to plugin dir: \(error)\n", stderr)
        exit(1)
    }
    print("Installed: \(pluginName) (from \(url))")
}

private func cliGitCloneSubdir(url: String, path: String, ref: String, targetDir: URL, pluginName: String) {
    try? FileManager.default.createDirectory(
        atPath: launcherPluginsDir,
        withIntermediateDirectories: true,
        attributes: nil
    )
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("buddy-install-\(UUID().uuidString)")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    var args = ["clone", "--depth", "1"]
    if !ref.isEmpty {
        args += ["--branch", ref]
    }
    args += [url, tempDir.path]
    process.arguments = args
    process.environment = ProcessInfo.processInfo.environment

    do {
        try process.run()
    } catch {
        fputs("git clone failed to start: \(error)\n", stderr)
        exit(1)
    }
    let timeoutWork = DispatchWorkItem {
        if process.isRunning { process.terminate() }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: timeoutWork)
    process.waitUntilExit()
    timeoutWork.cancel()

    guard process.terminationStatus == 0 else {
        try? FileManager.default.removeItem(at: tempDir)
        fputs("git clone failed (exit \(process.terminationStatus))\n", stderr)
        exit(1)
    }
    let subdir = tempDir.appending(path: path)
    guard FileManager.default.fileExists(atPath: subdir.path) else {
        try? FileManager.default.removeItem(at: tempDir)
        fputs("Subdir not found in cloned repo: \(path)\n", stderr)
        exit(1)
    }
    do {
        try FileManager.default.moveItem(at: subdir, to: targetDir)
    } catch {
        try? FileManager.default.removeItem(at: tempDir)
        fputs("Failed to move subdir to plugin dir: \(error)\n", stderr)
        exit(1)
    }
    try? FileManager.default.removeItem(at: tempDir)
    print("Installed: \(pluginName) (from \(url):\(path))")
}

private func cmdLauncherInstall(_ name: String) {
    guard !name.isEmpty else {
        fputs("Usage: buddy launcher install <name>\n", stderr)
        exit(2)
    }
    guard sanitizePluginName(name) else {
        fputs("Invalid name: '\(name)' (allowed: a-z, 0-9, -)\n", stderr)
        exit(2)
    }
    // 1. 读 marketplace cache
    let cacheURL = URL(fileURLWithPath: marketplaceCachePath())
    guard let data = try? Data(contentsOf: cacheURL),
          let manifest = try? JSONDecoder().decode(CLIMarketplaceManifest.self, from: data) else {
        fputs("Marketplace cache not found. Run `buddy launcher reseed` then start the app.\n", stderr)
        exit(4)
    }
    guard let plugin = manifest.plugins.first(where: { $0.name == name }) else {
        fputs("Plugin not in marketplace: \(name)\n", stderr)
        exit(3)
    }
    // 2. 检查是否已装
    let targetDir = URL(fileURLWithPath: launcherPluginsDir).appending(path: name)
    if FileManager.default.fileExists(atPath: targetDir.path) {
        fputs("Plugin already installed: \(name)\nUse `buddy launcher remove \(name)` first.\n", stderr)
        exit(5)
    }
    // 3. 按 source 类型分发
    switch plugin.source {
    case .localSubdir(let path):
        fputs("Plugin '\(name)' is bundled with the app (source=\(path)).\nRun `buddy launcher reseed` and restart the app to install.\n", stderr)
        exit(6)
    case .gitURL(let url, _):
        cliGitCloneFull(url: url, ref: nil, targetDir: targetDir, pluginName: name)
    case .gitSubdir(let url, let path, let ref, _):
        cliGitCloneSubdir(url: url, path: path, ref: ref, targetDir: targetDir, pluginName: name)
    case .file(let path):
        do {
            try FileManager.default.createDirectory(
                atPath: launcherPluginsDir,
                withIntermediateDirectories: true,
                attributes: nil
            )
            try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: targetDir)
            print("Installed: \(name) (from file://\(path))")
        } catch {
            fputs("Failed to copy plugin from \(path): \(error)\n", stderr)
            exit(1)
        }
    }
}

private func buildCLIInspection() -> CLIMarketplaceInspection {
    // Step 1: 读 marketplace.json cache，构造 plugins 列表
    let cacheURL = URL(fileURLWithPath: marketplaceCachePath())
    let pluginsBase = URL(fileURLWithPath: launcherPluginsDir)
    var marketPlugins: [CLIMarketplaceInspection.PluginInspection] = []
    var marketNames = Set<String>()
    if let data = try? Data(contentsOf: cacheURL),
       let manifest = try? JSONDecoder().decode(CLIMarketplaceManifest.self, from: data) {
        for p in manifest.plugins {
            let dir = pluginsBase.appending(path: p.name)
            let enabled = !FileManager.default.fileExists(atPath: dir.appending(path: ".disabled").path)
            // C5：读 plugin.json 解析 summary（降级），读失败兜底用 marketplace description 首句或 name
            let summary = cliSummaryForPluginDir(dir) ?? p.description ?? p.name
            marketPlugins.append(.init(
                name: p.name,
                version: p.version,
                enabled: enabled,
                source: cliSourceLabel(p.source),
                summary: summary
            ))
            marketNames.insert(p.name)
        }
    }

    // Step 2: 扫 launcher-plugins/ 找 sideloaded（cache 未声明但 dir 存在且 plugin.json 有效）
    var sideloaded: [CLIMarketplaceInspection.SideloadedPlugin] = []
    if let entries = try? FileManager.default.contentsOfDirectory(
        at: pluginsBase,
        includingPropertiesForKeys: nil
    ) {
        for entry in entries {
            let name = entry.lastPathComponent
            if marketNames.contains(name) { continue }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDir),
                  isDir.boolValue,
                  FileManager.default.fileExists(atPath: entry.appending(path: "plugin.json").path)
            else { continue }
            let enabled = !FileManager.default.fileExists(atPath: entry.appending(path: ".disabled").path)
            // C5：读 plugin.json 解析 summary（降级），读失败兜底用目录名
            let summary = cliSummaryForPluginDir(entry) ?? name
            sideloaded.append(.init(name: name, enabled: enabled, summary: summary))
        }
    }

    // Step 3: 读 marketplace-meta.json（BuddyCore 用 .iso8601 strategy 写出 string）
    struct CLIMeta: Codable {
        let lastSyncedAt: String?
        let consecutiveSyncFailures: Int
    }
    let metaURL = URL(fileURLWithPath: marketplaceMetaPath())
    let meta: CLIMeta
    if let data = try? Data(contentsOf: metaURL),
       let decoded = try? JSONDecoder().decode(CLIMeta.self, from: data) {
        meta = decoded
    } else {
        meta = CLIMeta(lastSyncedAt: nil, consecutiveSyncFailures: 0)
    }

    return CLIMarketplaceInspection(
        plugins: marketPlugins,
        sideloadedPlugins: sideloaded,
        lastSyncedAt: meta.lastSyncedAt,
        consecutiveSyncFailures: meta.consecutiveSyncFailures
    )
}

private func cmdLauncherListJSON() {
    let inspection = buildCLIInspection()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    do {
        let data = try encoder.encode(inspection)
        print(String(data: data, encoding: .utf8) ?? "{}")
    } catch {
        fputs("Failed to encode inspection JSON: \(error)\n", stderr)
        exit(1)
    }
}

private extension JSONDecoder {
    static func iso8601() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

private extension JSONEncoder {
    static func iso8601Pretty() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}
