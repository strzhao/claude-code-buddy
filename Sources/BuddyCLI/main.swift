import Foundation

// MARK: - Constants

private let socketPath = "/tmp/claude-buddy.sock"
private let colorFilePath = "/tmp/claude-buddy-colors.json"
private let appVersion = "0.5.0"

// MARK: - Message Types

private let validEvents = [
    "thinking", "tool_start", "tool_end", "idle",
    "session_start", "session_end", "set_label",
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

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case event, tool, timestamp, cwd, label, pid
        case terminalId = "terminal_id"
        case description
    }
}

// MARK: - Socket Client

private enum SocketError: Error, CustomStringConvertible {
    case notRunning
    case connectFailed(String)
    case sendFailed(String)

    var description: String {
        switch self {
        case .notRunning:
            return "Buddy app is not running. Start the app first."
        case .connectFailed(let reason):
            return "Cannot connect to socket: \(reason)"
        case .sendFailed(let reason):
            return "Failed to send message: \(reason)"
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
    var positionalArgs: [String] = []
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
      test [--delay N]                       Auto-test: cycle all states
      status                                Show active sessions
      help                                  Show this help

    Events: \(validEvents.joined(separator: ", "))

    Options:
      --id <ID>       Session ID (default: auto-generated debug-<timestamp>)
      --cwd <PATH>    Working directory
      --tool <NAME>   Tool name (for tool_start/tool_end)
      --desc <TEXT>   Description text
      --delay <N>     Delay between states in seconds (default: 1)

    Examples:
      buddy session start --id debug-A --cwd ~/myproject
      buddy emit thinking --id debug-A
      buddy emit tool_start --id debug-A --tool Read --desc "Reading file"
      buddy label debug-A "My Project"
      buddy test --delay 2
      buddy session end --id debug-A
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
        case "--label":
            i += 1
            if i < args.count { opts.label = args[i] }
        default:
            if opts.command.isEmpty {
                opts.command = arg
            } else if opts.command == "session" && opts.subcommand.isEmpty {
                opts.subcommand = arg
            } else if opts.command == "label" && opts.positionalArgs.count < 2 {
                opts.positionalArgs.append(arg)
            } else if opts.command == "emit" && opts.subcommand.isEmpty {
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
        description: nil
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
        description: nil
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
        description: opts.desc
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
        description: nil
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
            cwd: "/tmp", label: nil, pid: nil, terminalId: nil, description: nil
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
                cwd: nil, label: nil, pid: nil, terminalId: nil, description: step.desc
            ))
            let toolInfo = step.tool.map { " (\($0))" } ?? ""
            print("  ✓ \(step.event)\(toolInfo)")
            Thread.sleep(forTimeInterval: Double(opts.delay))
        }

        // Set label
        try sendMessage(BuddyMessage(
            sessionId: sid, event: "set_label", tool: nil,
            timestamp: Date().timeIntervalSince1970,
            cwd: nil, label: "Test Cat", pid: nil, terminalId: nil, description: nil
        ))
        print("  ✓ set_label -> Test Cat")
        Thread.sleep(forTimeInterval: 1)

        // End session
        try sendMessage(BuddyMessage(
            sessionId: sid, event: "session_end", tool: nil,
            timestamp: Date().timeIntervalSince1970,
            cwd: nil, label: nil, pid: nil, terminalId: nil, description: nil
        ))
        print("  ✓ session_end")
        print("Test complete!")

    } catch {
        fputs("Test failed: \(error)\n", stderr)
        exit(1)
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
    case "test":
        cmdTest(opts)
    case "status":
        cmdStatus()
    case "help", "--help", "-h", "":
        printHelp()
    default:
        fputs("Unknown command: \(opts.command)\n\n", stderr)
        printHelp()
        exit(2)
    }
}

main()
