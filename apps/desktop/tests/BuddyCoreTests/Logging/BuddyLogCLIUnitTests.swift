import XCTest
@testable import BuddyCore

/// `buddy log` CLI 命令组的单元测试（解析/过滤/边界）。
///
/// 注：CLI 是独立 executable target（Foundation-only），无法直接 import 其内部函数。
/// 这里通过子进程调用 `buddy log` 二进制验证端到端行为，覆盖契约 C4 命令/参数/退出码/输出。
final class BuddyLogCLIUnitTests: XCTestCase {

    private var tempDir = ""
    private var buddyBinary: String!

    override func setUp() {
        super.setUp()
        let tmp = NSTemporaryDirectory()
        tempDir = "\(tmp)BuddyLogCLI-\(UUID().uuidString)/"
        try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        // 定位已编译的 buddy-cli 二进制
        let possiblePaths = [
            "\(packageRoot())/.build/debug/buddy-cli",
            "\(packageRoot())/.build/arm64-apple-macosx/debug/buddy-cli"
        ]
        buddyBinary = possiblePaths.first { FileManager.default.fileExists(atPath: $0) }
    }

    override func tearDown() {
        if !tempDir.isEmpty {
            try? FileManager.default.removeItem(atPath: tempDir)
        }
        tempDir = ""
        super.tearDown()
    }

    // MARK: - 辅助

    private func packageRoot() -> String {
        // 测试运行目录为 .build，Package.swift 在上两级
        let here = URL(fileURLWithPath: #file).path
        // tests/BuddyCoreTests/Logging/X.swift → 回到 apps/desktop
        return (here as NSString)
            .deletingLastPathComponent   // Logging
            .components(separatedBy: "/").dropLast(3).joined(separator: "/")
    }

    /// 写入测试日志文件。
    private func writeTestLog(_ lines: [String]) {
        let content = lines.joined(separator: "\n") + "\n"
        try? content.write(toFile: "\(tempDir)/buddy.jsonl", atomically: true, encoding: .utf8)
    }

    /// 调用 buddy log <args>，返回 (exitCode, stdout, stderr)。
    private func runBuddyLog(_ subcommandArgs: [String]) -> (Int, String, String) {
        guard let binary = buddyBinary else {
            XCTFail("buddy-cli binary not found")
            return (-1, "", "")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["log"] + subcommandArgs
        let env = ProcessInfo.processInfo.environment
        process.environment = NSMutableDictionary(dictionary: env) as? [String: String]
        process.environment?["BUDDY_LOG_DIR"] = tempDir

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (-1, "", "\(error)")
        }

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (Int(process.terminationStatus), stdout, stderr)
    }

    // MARK: - 场景 3.P3：buddy log path

    func testLogPath_outputsCurrentLogPath() {
        writeTestLog([sampleLine(level: "info", subsystem: "app", msg: "x")])
        let (code, out, _) = runBuddyLog(["path"])
        XCTAssertEqual(code, 0)
        XCTAssertTrue(out.contains("buddy.jsonl"), "path 输出应含 buddy.jsonl")
        XCTAssertTrue(out.contains(tempDir), "path 应是绝对路径")
    }

    // MARK: - 场景 3.P1：buddy log show 默认输出

    func testLogShow_outputsLines() {
        writeTestLog([
            sampleLine(level: "info", subsystem: "app", msg: "first"),
            sampleLine(level: "warn", subsystem: "launcher", msg: "second")
        ])
        let (code, out, _) = runBuddyLog(["show"])
        XCTAssertEqual(code, 0)
        XCTAssertFalse(out.isEmpty, "show 应有输出")
        XCTAssertTrue(out.contains("first"))
        XCTAssertTrue(out.contains("second"))
    }

    // MARK: - 场景 3.P2：--level warn 仅返回 warn 及以上

    func testLogShow_levelFilter_returnsWarnAndAbove() {
        writeTestLog([
            sampleLine(level: "debug", subsystem: "app", msg: "dbg"),
            sampleLine(level: "info", subsystem: "app", msg: "inf"),
            sampleLine(level: "warn", subsystem: "app", msg: "wn"),
            sampleLine(level: "error", subsystem: "app", msg: "err")
        ])
        let (code, out, _) = runBuddyLog(["show", "--level", "warn", "--json"])
        XCTAssertEqual(code, 0)
        let levels = out.split(separator: "\n").compactMap { line -> String? in
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return json["level"] as? String
        }
        XCTAssertTrue(levels.allSatisfy { $0 == "warn" || $0 == "error" }, "应仅含 warn/error")
    }

    // MARK: - 场景 5.P1：--subsystem 精确过滤

    func testLogShow_subsystemFilter_exactMatch() {
        writeTestLog([
            sampleLine(level: "info", subsystem: "app", msg: "a"),
            sampleLine(level: "info", subsystem: "launcher", msg: "b"),
            sampleLine(level: "info", subsystem: "launcher-agent", msg: "c")
        ])
        let (code, out, _) = runBuddyLog(["show", "--subsystem", "launcher", "--json"])
        XCTAssertEqual(code, 0)
        let subsystems = Set(out.split(separator: "\n").compactMap { line -> String? in
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return json["subsystem"] as? String
        })
        XCTAssertEqual(subsystems, ["launcher"], "应仅含精确匹配 launcher，不含 launcher-agent")
    }

    // MARK: - 场景 5.P2：--since 时间过滤

    func testLogShow_sinceFilter_recentOnly() {
        // 写一行 1 秒前的日志 + 一行很旧的
        let now = ISO8601DateFormatter()
        now.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let recent = now.string(from: Date().addingTimeInterval(-10))
        let old = now.string(from: Date().addingTimeInterval(-3600 * 24))   // 1 天前
        writeTestLog([
            "{\"ts\":\"\(recent)\",\"level\":\"info\",\"subsystem\":\"app\",\"msg\":\"recent\"}",
            "{\"ts\":\"\(old)\",\"level\":\"info\",\"subsystem\":\"app\",\"msg\":\"old\"}"
        ])
        let (code, out, _) = runBuddyLog(["show", "--since", "1h", "--json"])
        XCTAssertEqual(code, 0)
        XCTAssertTrue(out.contains("recent"))
        XCTAssertFalse(out.contains("\"old\""), "1 天前的日志应被 since 1h 过滤")
    }

    // MARK: - grep

    func testLogGrep_patternMatch() {
        writeTestLog([
            sampleLine(level: "info", subsystem: "app", msg: "启动完成"),
            sampleLine(level: "info", subsystem: "app", msg: "shutdown")
        ])
        let (code, out, _) = runBuddyLog(["grep", "启动"])
        XCTAssertEqual(code, 0)
        XCTAssertTrue(out.contains("启动完成"))
        XCTAssertFalse(out.contains("shutdown"))
    }

    func testLogGrep_noMatch_exitZeroEmptyOutput() {
        writeTestLog([sampleLine(level: "info", subsystem: "app", msg: "hello")])
        let (code, out, _) = runBuddyLog(["grep", "nonexistent_pattern_xyz"])
        XCTAssertEqual(code, 0, "无匹配应 exit 0（契约 C4）")
        XCTAssertTrue(out.isEmpty)
    }

    // MARK: - 场景 4：app 未运行时读取历史日志

    func testLogShow_worksWithoutAppRunning() {
        writeTestLog([sampleLine(level: "info", subsystem: "app", msg: "historical")])
        // CLI 直接读文件，不依赖 app 进程；这里本身就是子进程调用，天然验证
        let (code, out, _) = runBuddyLog(["show"])
        XCTAssertEqual(code, 0)
        XCTAssertTrue(out.contains("historical"))
    }

    // MARK: - clear

    func testLogClear_archivesCurrentFile() {
        writeTestLog([sampleLine(level: "info", subsystem: "app", msg: "to be cleared")])
        let (code, out, _) = runBuddyLog(["clear", "--yes"])
        XCTAssertEqual(code, 0)
        XCTAssertTrue(out.contains("cleared"))
        // 归档应存在
        let archives = (try? FileManager.default.contentsOfDirectory(atPath: tempDir)) ?? []
        XCTAssertTrue(archives.contains { $0.hasPrefix("buddy-") && $0.hasSuffix(".jsonl") }, "应生成归档")
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(tempDir)/buddy.jsonl"), "应新建空当前文件")
    }

    // MARK: - tail

    func testLogTail_lastNLines() {
        var lines: [String] = []
        for i in 0..<10 {
            lines.append(sampleLine(level: "info", subsystem: "app", msg: "line\(i)"))
        }
        writeTestLog(lines)
        let (code, out, _) = runBuddyLog(["tail", "--lines", "3"])
        XCTAssertEqual(code, 0)
        XCTAssertTrue(out.contains("line7"))
        XCTAssertTrue(out.contains("line8"))
        XCTAssertTrue(out.contains("line9"))
        XCTAssertFalse(out.contains("line6"), "应只含最后 3 行")
    }

    // MARK: - 文件不存在

    func testLogShow_fileNotExists_emptyOutput() {
        let (code, out, _) = runBuddyLog(["show"])
        XCTAssertEqual(code, 0, "文件不存在 show 应 exit 0（空输出，契约 C4 show 退出码）")
        XCTAssertTrue(out.isEmpty)
    }

    // MARK: - 辅助构造

    private func sampleLine(level: String, subsystem: String, msg: String) -> String {
        let tz = TimeZone(identifier: "UTC")!
        let ts = ISO8601DateFormatter.string(from: Date(), timeZone: tz, formatOptions: [.withInternetDateTime])
        return "{\"ts\":\"\(ts)\",\"level\":\"\(level)\",\"subsystem\":\"\(subsystem)\",\"msg\":\"\(msg)\"}"
    }
}
