import Foundation
import Security
import CryptoKit
import IOKit

// MARK: - Constants

private let socketPath = "/tmp/claude-buddy.sock"
private let colorFilePath = "/tmp/claude-buddy-colors.json"
private let appVersion = "0.5.0"

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
private func sendQuery(_ query: [String: Any]) throws -> Data {
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

    // Read response with timeout (2 seconds)
    var response = Data()
    var buf = [UInt8](repeating: 0, count: 4096)
    let deadline = Date().addingTimeInterval(2.0)

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
        default:
            fputs("Usage: buddy launcher <config|add|install|list|disable|enable|reseed|remove|inspect> ...\n", stderr)
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

// MARK: - Launcher Config (Inline Implementation)
// ⚠️ 不依赖 BuddyCore：CLI 不引入 AppKit/SwiftUI/SpriteKit 以保持低启动延迟
// JSON schema 与 BuddyCore LauncherConfig / ProviderConfig 保持一致

private struct CLIProviderConfig: Codable {
    let kind: String
    let baseURL: String?
    let model: String
    let keyRef: String
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
        keyRef: keyRef
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
        print("\(opts.providerId): kind=\(p.kind), model=\(p.model)\(baseURLStr)\(activeStr)")
    } else {
        for (id, p) in cfg.providers.sorted(by: { $0.key < $1.key }) {
            let baseURLStr = p.baseURL.map { ", base_url=\($0)" } ?? ""
            let activeStr = cfg.activeProvider == id ? " [active]" : ""
            print("\(id): kind=\(p.kind), model=\(p.model)\(baseURLStr)\(activeStr)")
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
    let keywords: [String]
    let mode: String?              // nil 默认 "stdin"
    // stdin 字段
    let cmd: String?
    let args: [String]?
    // prompt 字段
    let systemPrompt: String?
    let maxIterations: Int?
    let model: String?
    let autoCopyToClipboard: Bool?
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
        print("\(m.name)\(suffix) (v\(m.version)) [\(status)] - \(m.description)")
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
    default:
        break
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
    case gitSubdir(url: String, path: String, ref: String, sha: String)
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
                sha: try container.decode(String.self, forKey: .sha)
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
            try container.encode(sha, forKey: .sha)
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
    }

    struct SideloadedPlugin: Codable {
        let name: String
        let enabled: Bool
    }
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
            marketPlugins.append(.init(
                name: p.name,
                version: p.version,
                enabled: enabled,
                source: cliSourceLabel(p.source)
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
            sideloaded.append(.init(name: name, enabled: enabled))
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
