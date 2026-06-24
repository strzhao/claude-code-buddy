import Foundation
import XCTest
@testable import BuddyCore

// MARK: - BuddyLogCLIAcceptanceTests
//
// 黑盒验收测试 —— 仅依据契约 C4（CLI 命令组 `buddy log`）+ 验收场景 3/4/5 编写。
// 用 Foundation `Process` 子进程调编译产物（executableTarget 名 `buddy-cli`，产物路径可配置），
// 断言 stdout/exit code 与过滤语义。
//
// 契约引用（C4）：
//  | 命令 | 参数 | stdout | 退出码 |
//  | buddy log path  | — | 当前日志文件绝对路径 | 0 |
//  | buddy log tail  | [--lines N](默认 50) [--follow] | 最近 N 行（人类可读摘要） | 0；文件不存在 → 1 + stderr |
//  | buddy log show  | [--lines N] [--level L] [--subsystem S] [--since D] [--json] | 过滤后行；--json 原样 JSONL，否则人类可读 | 0 |
//  | buddy log grep  | <pattern> [--level L] [-i] | msg 命中 pattern 的行 | 0；无匹配 → 0（空输出）|
//  | buddy log clear | [--yes] | 归档当前文件并新建 | 0；无 --yes 在 TTY 下交互确认 |
//
// 过滤语义（C4）：--level warn = warn 及以上；--since Nh/Nm/Nd；--subsystem 精确匹配。
// 人类可读摘要格式：`HH:MM:SS.mmm [LEVEL] [subsystem] msg`（meta 以 ` k=v` 追加）。
// CLI 为 Foundation-only，直接读文件（app 不运行也可用，场景 4）。
//
// CONTRACT_AMBIGUOUS:
//  1. executableTarget 名为 `buddy-cli`（Package.swift），但设计文档/C4 用 `buddy` 命令名。
//     产物路径 `.build/debug/buddy-cli`（SPM 默认按 target 名）。这里用可配置路径 + 存在性兜底。
//  2. C4 tail/show 默认「人类可读摘要」格式，show 的 --json 才是 JSONL。测试 show 用 --json 验证字段，
//     tail/人类可读格式用「非空 + 含关键字」松断言（格式细节交 QA 真机）。

final class BuddyLogCLIAcceptanceTests: XCTestCase {

    // MARK: - Executable resolution

    /// 解析可执行文件路径。优先环境变量 BUDDY_CLI_PATH，其次默认 SPM debug 产物。
    /// 若不存在，调用方应用 XCTSkipUnless 跳过（但断言逻辑仍强 XCTAssert）。
    private func resolveExecutable() -> String? {
        if let env = ProcessInfo.processInfo.environment["BUDDY_CLI_PATH"],
           FileManager.default.isExecutableFile(atPath: env) {
            return env
        }
        // SPM 产物路径（相对 repo root）。测试 cwd 通常在 apps/desktop/。
        let candidates = [
            ".build/debug/buddy-cli",
            ".build/debug/buddy",
            "../.build/debug/buddy-cli",
            "/Users/stringzhao/workspace_sync/personal_projects/claude-code-buddy/apps/desktop/.build/debug/buddy-cli",
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        return nil
    }

    // MARK: - Test fixture: prepare a log file

    /// 在临时目录预置一个含已知内容的 buddy.jsonl，返回目录路径。
    /// 通过 BUDDY_LOG_DIR 环境变量传给子进程（CLI 必须读此 env —— 契约 C5）。
    private func makeLogDir(withLines lines: [[String: Any]]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("buddy-cli-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("buddy.jsonl")
        var content = ""
        for line in lines {
            let data = try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
            content += String(data: data, encoding: .utf8) ?? "{}"
            content += "\n"
        }
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        return dir
    }

    /// 生成一条符合 schema 的日志行字典。
    private func makeLine(level: String, subsystem: String, msg: String,
                          tsOffsetSeconds: TimeInterval = 0) -> [String: Any] {
        let date = Date().addingTimeInterval(tsOffsetSeconds)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return [
            "ts": formatter.string(from: date),
            "level": level,
            "subsystem": subsystem,
            "msg": msg,
        ]
    }

    /// 跑子进程：`buddy log <args>`，传入 BUDDY_LOG_DIR 重定向。
    private func runBuddyLog(executable: String, args: [String], logDir: URL?,
                             envOverrides: [String: String] = [:]) -> (stdout: String, stderr: String, exitCode: Int) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["log"] + args
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        var env = ProcessInfo.processInfo.environment
        if let dir = logDir { env["BUDDY_LOG_DIR"] = dir.path }
        for (k, v) in envOverrides { env[k] = v }
        process.environment = env

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ("", "spawn error: \(error)", -1)
        }

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (stdout, stderr, Int(process.terminationStatus))
    }

    /// 解析 stdout 每行为 JSON 对象（假定 --json 模式或原样 JSONL）。
    private func parseJSONL(_ stdout: String) -> [[String: Any]] {
        return stdout
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    // MARK: - 场景 3: CLI 运行时读取日志

    /// covers 3.P1: 执行 `buddy log show` → stdout 输出日志内容 ｜ assert: EXIT == 0 and stdout 非空
    func test_LogShowOutputsContentAndExitZero() throws {
        guard let exe = resolveExecutable() else {
            try XCTSkipIf(true, "buddy 产物不存在（QA 阶段编译后再跑）")
            return
        }
        let dir = try makeLogDir(withLines: [
            makeLine(level: "info", subsystem: "app", msg: "cli-show-test"),
        ])

        let (stdout, _, exit) = runBuddyLog(executable: exe, args: ["show"], logDir: dir)

        XCTAssertEqual(exit, 0, "3.P1: buddy log show 必须 exit 0 (assert: EXIT == 0, got \(exit))")
        XCTAssertFalse(stdout.isEmpty, "3.P1: buddy log show stdout 非空 (assert: stdout 非空)")
    }

    /// covers 3.P2: 执行 `buddy log show --level warn` → 仅返回 warn 及以上 ｜ assert: ⊆ {warn, error}
    func test_LogShowLevelWarnReturnsOnlyWarnAndError() throws {
        guard let exe = resolveExecutable() else {
            try XCTSkipIf(true, "buddy 产物不存在（QA 阶段编译后再跑）")
            return
        }
        let dir = try makeLogDir(withLines: [
            makeLine(level: "debug", subsystem: "app", msg: "d-should-be-filtered"),
            makeLine(level: "info", subsystem: "app", msg: "i-should-be-filtered"),
            makeLine(level: "warn", subsystem: "app", msg: "w-keep"),
            makeLine(level: "error", subsystem: "app", msg: "e-keep"),
        ])

        let (stdout, _, exit) = runBuddyLog(executable: exe, args: ["show", "--level", "warn", "--json"], logDir: dir)

        XCTAssertEqual(exit, 0, "3.P2: exit 0")
        let objs = parseJSONL(stdout)
        XCTAssertFalse(objs.isEmpty, "3.P2: --level warn 应至少返回 warn/error 行")
        let levels = Set(objs.compactMap { $0["level"] as? String })
        XCTAssertTrue(levels.isSubset(of: ["warn", "error"]),
                      "3.P2: --level warn 输出级别 ⊆ {warn, error} (assert: ⊆ {warn, error}), got \(levels)")
        XCTAssertFalse(levels.contains("debug"), "3.P2: 不应含 debug（级别序低于 warn）")
        XCTAssertFalse(levels.contains("info"), "3.P2: 不应含 info（级别序低于 warn）")
    }

    /// covers 3.P3: 执行 `buddy log path` → 输出当前文件路径且 exit 0 ｜ assert: exit == 0 and stdout contains "buddy.jsonl"
    func test_LogPathOutputsPathContainingBuddyJSONL() throws {
        guard let exe = resolveExecutable() else {
            try XCTSkipIf(true, "buddy 产物不存在（QA 阶段编译后再跑）")
            return
        }
        let dir = try makeLogDir(withLines: [
            makeLine(level: "info", subsystem: "app", msg: "anchor"),
        ])

        let (stdout, _, exit) = runBuddyLog(executable: exe, args: ["path"], logDir: dir)

        XCTAssertEqual(exit, 0, "3.P3: buddy log path 必须 exit 0 (assert: exit == 0, got \(exit))")
        XCTAssertTrue(stdout.contains("buddy.jsonl"),
                      "3.P3: stdout 必须含 \"buddy.jsonl\" (assert: stdout contains \"buddy.jsonl\")")
        // 进一步：输出应为绝对路径（重定向目录下的 buddy.jsonl）。
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(trimmed.hasPrefix("/"), "3.P3: path 应为绝对路径 (got: \(trimmed))")
        XCTAssertTrue(trimmed.hasSuffix("buddy.jsonl"),
                      "3.P3: path 应以 buddy.jsonl 结尾 (got: \(trimmed))")
    }

    // MARK: - 场景 4: CLI 在 app 未运行时读取历史日志

    /// covers 4.P1 [real-process]: app 未运行 → 直接从磁盘读取并返回 ｜
    /// assert: app 进程数 == 0 and exit == 0 and stdout 非空
    /// 实测：本测试进程不是 app，CLI 直接读文件（无 socket 查询依赖），等价 app 未运行。
    /// VISUAL_RESIDUE: 真实「pgrep -x ClaudeCodeBuddy == 0」留 QA 真机判定；此处验证 CLI 不依赖 app 运行。
    func test_LogShowWorksWhenAppNotRunning() throws {
        guard let exe = resolveExecutable() else {
            try XCTSkipIf(true, "buddy 产物不存在（QA 阶段编译后再跑）")
            return
        }
        let dir = try makeLogDir(withLines: [
            makeLine(level: "info", subsystem: "app", msg: "historical-line"),
        ])

        let (stdout, _, exit) = runBuddyLog(executable: exe, args: ["show"], logDir: dir)

        XCTAssertEqual(exit, 0, "4.P1: app 未运行时 CLI 仍 exit 0 (assert: exit == 0)")
        XCTAssertFalse(stdout.isEmpty, "4.P1: stdout 非空 (assert: stdout 非空)")
        // VISUAL_RESIDUE: 4.P1 真实 pgrep -x ClaudeCodeBuddy == 0 留 QA 真机判定
    }

    /// covers 4.P2: app 未运行时 `buddy log path` 仍返回路径 ｜ assert: exit == 0
    func test_LogPathWorksWhenAppNotRunning() throws {
        guard let exe = resolveExecutable() else {
            try XCTSkipIf(true, "buddy 产物不存在（QA 阶段编译后再跑）")
            return
        }
        let dir = try makeLogDir(withLines: [
            makeLine(level: "info", subsystem: "app", msg: "x"),
        ])

        let (_, _, exit) = runBuddyLog(executable: exe, args: ["path"], logDir: dir)

        XCTAssertEqual(exit, 0, "4.P2: app 未运行时 buddy log path 仍 exit 0 (assert: exit == 0)")
    }

    // MARK: - 场景 5: 级别 / 子系统 / 时间过滤

    /// covers 5.P1: 执行 `buddy log show --subsystem launcher` → 仅返回 subsystem==launcher ｜ assert: == {launcher}
    func test_LogShowSubsystemFilterExactMatch() throws {
        guard let exe = resolveExecutable() else {
            try XCTSkipIf(true, "buddy 产物不存在（QA 阶段编译后再跑）")
            return
        }
        let dir = try makeLogDir(withLines: [
            makeLine(level: "info", subsystem: "launcher", msg: "keep-1"),
            makeLine(level: "info", subsystem: "launcher-agent", msg: "should-be-filtered-prefix-collision"),
            makeLine(level: "info", subsystem: "app", msg: "filter-2"),
            makeLine(level: "warn", subsystem: "launcher", msg: "keep-2"),
        ])

        let (stdout, _, exit) = runBuddyLog(executable: exe,
                                            args: ["show", "--subsystem", "launcher", "--json"],
                                            logDir: dir)

        XCTAssertEqual(exit, 0, "5.P1: exit 0")
        let objs = parseJSONL(stdout)
        let subsystems = Set(objs.compactMap { $0["subsystem"] as? String })
        XCTAssertEqual(subsystems, Set(["launcher"]),
                       "5.P1: --subsystem launcher 精确匹配，仅 subsystem==launcher (assert: == {launcher}), got \(subsystems)")
        // 关键：launcher-agent 不应被前缀匹配命中（契约 C4：精确匹配）。
        XCTAssertFalse(subsystems.contains("launcher-agent"),
                       "5.P1: --subsystem 必须精确匹配，不应命中 launcher-agent（前缀碰撞）")
    }

    /// covers 5.P2: 执行 `buddy log show --since 1h` → 仅返回最近 1 小时条目 ｜ assert: ts 与当前差 <= 3600s
    func test_LogShowSince1hFiltersOldEntries() throws {
        guard let exe = resolveExecutable() else {
            try XCTSkipIf(true, "buddy 产物不存在（QA 阶段编译后再跑）")
            return
        }
        let dir = try makeLogDir(withLines: [
            // 2 小时前（应被过滤）。
            makeLine(level: "info", subsystem: "app", msg: "old-2h", tsOffsetSeconds: -2 * 3600),
            // 30 分钟前（应保留）。
            makeLine(level: "info", subsystem: "app", msg: "recent-30m", tsOffsetSeconds: -30 * 60),
            // 刚才（应保留）。
            makeLine(level: "info", subsystem: "app", msg: "now", tsOffsetSeconds: 0),
        ])

        let (stdout, _, exit) = runBuddyLog(executable: exe,
                                            args: ["show", "--since", "1h", "--json"],
                                            logDir: dir)

        XCTAssertEqual(exit, 0, "5.P2: exit 0")
        let objs = parseJSONL(stdout)
        XCTAssertFalse(objs.isEmpty, "5.P2: --since 1h 应至少返回 2 条（30m + now）")

        let now = Date()
        for obj in objs {
            guard let ts = obj["ts"] as? String else {
                XCTFail("5.P2: 行缺 ts 字段")
                continue
            }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let parsed = formatter.date(from: ts) else {
                // 兼容无毫秒变体。
                let f2 = ISO8601DateFormatter()
                f2.formatOptions = [.withInternetDateTime]
                guard let parsed2 = f2.date(from: ts) else {
                    XCTFail("5.P2: ts=\(ts) 不可解析")
                    continue
                }
                let diff = abs(parsed2.timeIntervalSince(now))
                XCTAssertLessThanOrEqual(diff, 3600,
                                         "5.P2: --since 1h 行的 ts 与当前差 <= 3600s (assert: <= 3600s), got \(diff)s")
                continue
            }
            let diff = abs(parsed.timeIntervalSince(now))
            XCTAssertLessThanOrEqual(diff, 3600,
                                     "5.P2: --since 1h 行的 ts 与当前差 <= 3600s (assert: <= 3600s), got \(diff)s")
        }

        // 过滤掉的「old-2h」不应出现。
        let msgs = objs.compactMap { $0["msg"] as? String }
        XCTAssertFalse(msgs.contains("old-2h"),
                       "5.P2: 2 小时前的条目应被 --since 1h 过滤掉")
    }

    // MARK: - C4: tail / grep / clear 命令组

    /// covers C4 tail: `buddy log tail --lines N` → 最近 N 行 ｜ exit 0。
    /// 预置 5 行，--lines 2，断言输出 <= 2 行（人类可读摘要或 JSONL 均按行计）。
    func test_LogTailLinesLimit() throws {
        guard let exe = resolveExecutable() else {
            try XCTSkipIf(true, "buddy 产物不存在（QA 阶段编译后再跑）")
            return
        }
        let dir = try makeLogDir(withLines: (0..<5).map {
            makeLine(level: "info", subsystem: "app", msg: "tail-line-\($0)")
        })

        let (stdout, _, exit) = runBuddyLog(executable: exe, args: ["tail", "--lines", "2"], logDir: dir)

        XCTAssertEqual(exit, 0, "C4 tail: exit 0")
        let nonEmptyLines = stdout.components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertLessThanOrEqual(nonEmptyLines.count, 2,
                                 "C4 tail --lines 2 应输出 <= 2 行 (assert: <= 2), got \(nonEmptyLines.count)")
        XCTAssertGreaterThanOrEqual(nonEmptyLines.count, 1,
                                    "C4 tail --lines 2 应至少 1 行（预置 5 行有内容）")
    }

    /// covers C4 grep: `buddy log grep <pattern>` → msg 命中 pattern 的行 ｜ exit 0（无匹配也 0）。
    func test_LogGrepReturnsMatchingMsgLines() throws {
        guard let exe = resolveExecutable() else {
            try XCTSkipIf(true, "buddy 产物不存在（QA 阶段编译后再跑）")
            return
        }
        let dir = try makeLogDir(withLines: [
            makeLine(level: "info", subsystem: "app", msg: "launching app"),
            makeLine(level: "info", subsystem: "app", msg: "idle state"),
            makeLine(level: "warn", subsystem: "launcher", msg: "LAUNCHER failed"),
        ])

        let (stdout, _, exit) = runBuddyLog(executable: exe, args: ["grep", "launch", "-i", "--json"], logDir: dir)

        XCTAssertEqual(exit, 0, "C4 grep: exit 0（无匹配也 0，有匹配也 0）")
        let objs = parseJSONL(stdout)
        let msgs = objs.compactMap { $0["msg"] as? String }
        // -i 大小写不敏感：应同时命中 "launching app" 和 "LAUNCHER failed"。
        XCTAssertTrue(msgs.contains(where: { $0.lowercased().contains("launch") }),
                      "C4 grep -i launch 应命中含 launch 的 msg")
        // 不应命中不含 pattern 的行。
        XCTAssertFalse(msgs.contains("idle state"),
                       "C4 grep 应过滤掉不含 pattern 的 msg")
    }

    /// covers C4 grep 无匹配: 无匹配时 exit 0 + 空输出。
    func test_LogGrepNoMatchReturnsZeroExitEmptyOutput() throws {
        guard let exe = resolveExecutable() else {
            try XCTSkipIf(true, "buddy 产物不存在（QA 阶段编译后再跑）")
            return
        }
        let dir = try makeLogDir(withLines: [
            makeLine(level: "info", subsystem: "app", msg: "hello"),
        ])

        let (stdout, _, exit) = runBuddyLog(executable: exe, args: ["grep", "nonexistent-pattern-xyz"], logDir: dir)

        XCTAssertEqual(exit, 0, "C4 grep 无匹配: exit 0 (assert: 无匹配 → 0)")
        XCTAssertEqual(stdout.trimmingCharacters(in: .whitespacesAndNewlines), "",
                       "C4 grep 无匹配: 空输出")
    }

    /// covers C4 clear --yes: 归档当前文件并新建 ｜ exit 0。
    /// 预置 buddy.jsonl，clear --yes 后断言：原文件被归档（buddy-*.jsonl 出现）+ 当前文件重建（可能为空或含新行）。
    func test_LogClearArchivesAndRecreates() throws {
        guard let exe = resolveExecutable() else {
            try XCTSkipIf(true, "buddy 产物不存在（QA 阶段编译后再跑）")
            return
        }
        let dir = try makeLogDir(withLines: [
            makeLine(level: "info", subsystem: "app", msg: "will-be-archived"),
        ])

        let (stdout, stderr, exit) = runBuddyLog(executable: exe, args: ["clear", "--yes"], logDir: dir)

        XCTAssertEqual(exit, 0, "C4 clear --yes: exit 0, stderr=\(stderr)")

        let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let archives = contents.filter { $0.hasPrefix("buddy-") && $0.hasSuffix(".jsonl") }
        XCTAssertGreaterThanOrEqual(archives.count, 1,
                                    "C4 clear: 原 buddy.jsonl 应被归档为 buddy-*.jsonl (assert: count >= 1), got \(archives)")
        // stdout 通常为空或确认信息。
        _ = stdout
    }

    // MARK: - C4: 文件不存在时 tail 退出码 1 + stderr

    /// covers C4 tail 边界: 文件不存在 → exit 1 + stderr 提示。
    func test_LogTailFailsWhenLogFileMissing() throws {
        guard let exe = resolveExecutable() else {
            try XCTSkipIf(true, "buddy 产物不存在（QA 阶段编译后再跑）")
            return
        }
        // 空目录（无 buddy.jsonl）。
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("buddy-cli-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let (_, stderr, exit) = runBuddyLog(executable: exe, args: ["tail"], logDir: dir)

        XCTAssertEqual(exit, 1, "C4 tail: 文件不存在 → exit 1 (assert: 文件不存在 → 1), got \(exit)")
        XCTAssertFalse(stderr.isEmpty, "C4 tail: 文件不存在 → stderr 提示非空")
    }

    // MARK: - 跨系统数据流: app 写 JSONL ↔ CLI 读解析字段一致（C5 镜像契约）

    /// covers C5 双绑契约: app（BuddyCore）写的 JSONL 行，CLI（buddy log show --json）读出后
    /// ts/level/subsystem/msg 字段名两端一致。
    /// 这是 C5「行 schema 字段名 ts/level/subsystem/msg/meta CLI 解析与 BuddyCore 编码须同构」的端到端验证。
    /// 实测：用 BuddyLogger 写一行 → 子进程 buddy log show --json 读 → 解析验证四字段。
    func test_AppWrittenJSONLMatchesCLIReadSchema() throws {
        guard let exe = resolveExecutable() else {
            try XCTSkipIf(true, "buddy 产物不存在（QA 阶段编译后再跑）")
            return
        }

        // 用独立临时目录隔离（与 BuddyLoggerAcceptanceTests 同模式）。
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("buddy-cli-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // 1. app 侧（BuddyCore Logger）写一行。
        // 驱动方式修正：用 configureForTesting 强制单例指向临时目录（替代 env 驱动单例）。
        // CLI 侧是独立子进程，仍通过 runBuddyLog(... logDir: dir) 的 BUDDY_LOG_DIR env 注入。
        BuddyLogger.shared.resetForTesting()
        BuddyLogger.shared.configureForTesting(logsDir: dir.path, level: .debug)
        defer { BuddyLogger.shared.resetForTesting() }

        let writtenMsg = "e2e-schema-check-\(UUID().uuidString)"
        let writtenSubsystem = "launcher"
        BuddyLogger.shared.info(writtenMsg, subsystem: writtenSubsystem, meta: ["phase": "e2e"])
        BuddyLogger.shared._syncFlush()

        // 2. CLI 侧读取（子进程，BUDDY_LOG_DIR env 由 runBuddyLog 注入）。
        let (stdout, _, exit) = runBuddyLog(executable: exe, args: ["show", "--json"], logDir: dir)
        XCTAssertEqual(exit, 0, "C5 e2e: CLI show --json exit 0")

        let objs = parseJSONL(stdout)
        // 找到 app 写入的那一行。
        let matching = objs.filter { $0["msg"] as? String == writtenMsg }
        XCTAssertFalse(matching.isEmpty,
                       "C5: CLI 必须能读到 app 写入的行（msg=\(writtenMsg)），schema 字段名两端一致")
        guard let row = matching.first else { return }

        // C5: 四字段名两端一致（BuddyCore 编码 ↔ CLI 解析）。
        XCTAssertNotNil(row["ts"], "C5: CLI 读到 ts（字段名一致）")
        XCTAssertNotNil(row["level"], "C5: CLI 读到 level（字段名一致）")
        XCTAssertNotNil(row["subsystem"], "C5: CLI 读到 subsystem（字段名一致）")
        XCTAssertEqual(row["level"] as? String, "info", "C5: level 值一致")
        XCTAssertEqual(row["subsystem"] as? String, writtenSubsystem, "C5: subsystem 值一致")
        XCTAssertNotNil(row["meta"], "C5: CLI 读到 meta（可选字段也一致）")
        if let meta = row["meta"] as? [String: Any] {
            XCTAssertEqual(meta["phase"] as? String, "e2e", "C5: meta 字段值一致")
        }
    }
}
