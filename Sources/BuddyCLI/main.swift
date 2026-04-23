import Foundation

// MARK: - Constants

private let socketPath = "/tmp/claude-buddy.sock"
private let colorFilePath = "/tmp/claude-buddy-colors.json"
private let appVersion = "0.5.0"

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
      token <id> <amount>                    Set token count (e.g. 500000, 1.2M, 5M)
      test [--delay N]                       Auto-test: cycle all states
      test-tokens [--delay N]                Auto-test: cycle all token levels
      sizes                                 List all token levels and scale sizes
      status                                Show active sessions
      inspect [--id ID]                      Query session and cat state (JSON)
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
        case "--label":
            i += 1
            if i < args.count { opts.label = args[i] }
        default:
            if opts.command.isEmpty {
                opts.command = arg
            } else if opts.command == "session" && opts.subcommand.isEmpty {
                opts.subcommand = arg
            } else if (opts.command == "label" || opts.command == "token") && opts.positionalArgs.count < 2 {
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
    let levels: [(name: String, threshold: String, scale: String, height: String)] = [
        ("Lv1", "0", "1.00x", "80pt"),
        ("Lv2", "100K", "1.02x", "82pt"),
        ("Lv3", "300K", "1.05x", "84pt"),
        ("Lv4", "500K", "1.07x", "86pt"),
        ("Lv5", "800K", "1.10x", "88pt"),
        ("Lv6", "1.2M", "1.12x", "90pt"),
        ("Lv7", "2M", "1.15x", "92pt"),
        ("Lv8", "3M", "1.17x", "93pt"),
        ("Lv9", "5M", "1.19x", "95pt"),
        ("Lv10", "7M", "1.21x", "97pt"),
        ("Lv11", "10M", "1.23x", "98pt"),
        ("Lv12", "15M", "1.26x", "100pt"),
        ("Lv13", "20M", "1.28x", "102pt"),
        ("Lv14", "30M", "1.30x", "104pt"),
        ("Lv15", "50M", "1.33x", "106pt"),
        ("Lv16", "100M", "1.35x", "108pt"),
    ]

    func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
    }

    print("\(pad("Level", 6)) \(pad("Threshold", 11)) \(pad("Scale", 6)) \(pad("Height", 6))")
    print(String(repeating: "\u{2500}", count: 33))
    for lv in levels {
        print("\(pad(lv.name, 6)) \(pad(lv.threshold, 11)) \(pad(lv.scale, 6)) \(pad(lv.height, 6))")
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
    case "click":
        cmdClick(opts)
    case "events":
        cmdEvents(opts)
    case "health":
        cmdHealth()
    case "help", "--help", "-h", "":
        printHelp()
    default:
        fputs("Unknown command: \(opts.command)\n\n", stderr)
        printHelp()
        exit(2)
    }
}

main()
