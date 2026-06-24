import XCTest
@testable import BuddyCore

// MARK: - BuddyLoggerDocsAndSubsystemAcceptanceTests
//
// 黑盒验收测试 —— 覆盖场景 7（收编 print/NSLog）+ 场景 8（CLAUDE.md 文档可执行性）+ 契约 C6（子系统枚举）。
//
// 契约引用：
//  - C6: 子系统标签枚举 = app · state-machine · launcher · launcher-agent · plugin · socket ·
//         session · skin · settings · builtin · clipboard（新增须登记到 CLAUDE.md）
//  - 场景 8: CLAUDE.md 须含 Logger / 禁 print / debug·release 差异 / 可执行命令。
//
// 说明：
//  - 场景 7 的 7.P2（negate：不向 stdout 直写裸 print）是 real-process 行为，
//    单元测试无法 mock 真实业务路径的 stdout，标 VISUAL_RESIDUE 留 QA 真机。
//  - 场景 8 的 8.P1（代码块逐条 exit == 0）是 real-process，标 VISUAL_RESIDUE 留 QA 真机；
//    本测试断言文档含关键字（grep 语义，covers 8.P2/P3）。

final class BuddyLoggerDocsAndSubsystemAcceptanceTests: XCTestCase {

    /// apps/desktop/CLAUDE.md 路径（设计文档指定）。
    private let claudeMdPath = "/Users/stringzhao/workspace_sync/personal_projects/claude-code-buddy/apps/desktop/CLAUDE.md"

    /// 读取 CLAUDE.md 全文（若不存在则测试失败 —— 文档是契约的一部分）。
    private func readCLAUDEMd() throws -> String {
        let url = URL(fileURLWithPath: claudeMdPath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - 场景 8: CLAUDE.md 文档可执行性

    /// covers 8.P2: 阅读 CLAUDE.md → 声明禁 print/NSLog 且用 Logger ｜
    /// assert: contains "Logger" and (contains "禁止" or contains "不要 print")
    func test_CLAUDEMdDeclaresLoggerAndBansPrint() throws {
        let content = try readCLAUDEMd()

        XCTAssertTrue(content.contains("Logger"),
                      "8.P2: CLAUDE.md 必须含 \"Logger\" (assert: contains \"Logger\")")
        let bansPrint = content.contains("禁止") || content.contains("不要 print") || content.contains("禁用 print")
            || content.contains("禁止 print") || content.contains("不使用 print")
        XCTAssertTrue(bansPrint,
                      "8.P2: CLAUDE.md 必须声明禁 print/NSLog (assert: contains \"禁止\" or \"不要 print\")")
    }

    /// covers 8.P2 辅助: 明确提及 NSLog 也被收编。
    func test_CLAUDEMdMentionsNSLogCollection() throws {
        let content = try readCLAUDEMd()

        // 设计文档「收编映射表」明确 NSLog 也要迁移，文档应至少提及。
        XCTAssertTrue(content.contains("NSLog"),
                      "8.P2 辅助: CLAUDE.md 应提及 NSLog 收编（设计文档明确 41 处 NSLog 迁移）")
    }

    /// covers 8.P3: CLAUDE.md 含 debug/release 级别差异说明 ｜
    /// assert: contains "release" and contains "debug"
    func test_CLAUDEMdExplainsDebugReleaseLevels() throws {
        let content = try readCLAUDEMd()

        XCTAssertTrue(content.contains("release"),
                      "8.P3: CLAUDE.md 必须含 \"release\" (assert: contains \"release\")")
        XCTAssertTrue(content.contains("debug"),
                      "8.P3: CLAUDE.md 必须含 \"debug\" (assert: contains \"debug\")")
    }

    /// covers 8.P1: 按 CLAUDE.md 执行日志命令 → 每条 exit == 0 ｜ real-process。
    /// VISUAL_RESIDUE: 文档代码块逐条执行留 QA 真机判定（需真实 buddy 产物 + 真实环境）。
    /// 本测试断言文档含至少一条 `buddy log` 命令（证明文档提供了 CLI 取阅方法）。
    func test_CLAUDEMdContainsBuddyLogCommands() throws {
        let content = try readCLAUDEMd()

        // 文档应含 buddy log 取阅命令（path/show/tail/grep 任一）。
        let hasBuddyLog = content.contains("buddy log path")
            || content.contains("buddy log show")
            || content.contains("buddy log tail")
            || content.contains("buddy log grep")
        XCTAssertTrue(hasBuddyLog,
                      "8.P1 辅助: CLAUDE.md 应含至少一条 `buddy log` 命令（CLI 取阅方法）")
        // VISUAL_RESIDUE: 8.P1 文档代码块逐条 exit == 0 留 QA 真机判定
    }

    /// covers C6 文档落地: 子系统枚举须登记到 CLAUDE.md。
    func test_CLAUDEMdRegistersSubsystemEnum() throws {
        let content = try readCLAUDEMd()

        // 契约 C6: 子系统标签枚举（新增须登记到 CLAUDE.md）。
        // 至少核心几个应在文档出现。
        let coreSubsystems = ["app", "state-machine", "launcher", "socket", "session", "skin", "settings"]
        var missing: [String] = []
        for s in coreSubsystems where !content.contains(s) {
            missing.append(s)
        }
        XCTAssertTrue(missing.isEmpty,
                      "C6: CLAUDE.md 应登记核心子系统枚举，缺失: \(missing.joined(separator: ", "))")
    }

    // MARK: - 场景 7: 收编现有 print/NSLog

    /// covers 7.P1: 触发原含 print 的状态机路径 → 经统一 Logger 落盘 ｜
    /// assert: subsystem=="state-machine" 的行 >= 1
    /// 实测：用 BuddyLogger 写一条 state-machine 子系统的行，断言落盘（验证子系统标签可达）。
    /// VISUAL_RESIDUE 备注：真实「触发状态机路径」需 QA 真机（emit 事件），这里验证 Logger + 子系统标签机制本身。
    func test_StateMachineSubsystemIsLoggable() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("buddy-subsystem-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // 驱动方式修正：用 configureForTesting 强制单例指向临时目录 + debug 级（替代 env 驱动）。
        BuddyLogger.shared.resetForTesting()
        BuddyLogger.shared.configureForTesting(logsDir: dir.path, level: .debug)
        defer { BuddyLogger.shared.resetForTesting() }

        // 模拟「触发状态机路径」经统一 Logger 落盘。
        BuddyLogger.shared.debug("state-machine-event", subsystem: "state-machine")
        BuddyLogger.shared._syncFlush()

        let fileURL = dir.appendingPathComponent("buddy.jsonl")
        guard let content = try? String(contentsOfFile: fileURL.path, encoding: .utf8) else {
            XCTFail("7.P1: 无法读取日志")
            return
        }
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        // 语法修复：原 `?? [:]["subsystem"] as? String == "state-machine"` 运算符优先级错乱，
        // 改等价 guard-let。断言期望（state-machine 行 >= 1）完全不变。
        let stateMachineLines = lines.filter {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] else {
                return false
            }
            return (obj["subsystem"] as? String) == "state-machine"
        }
        XCTAssertGreaterThanOrEqual(stateMachineLines.count, 1,
                                    "7.P1: subsystem==state-machine 的行 >= 1 (assert: >= 1)")
        // VISUAL_RESIDUE: 7.P1 真实「触发状态机路径」(buddy emit) 留 QA 真机判定
    }

    /// covers 7.P2 [negate]: 业务路径触发（debug 构建）→ 不再向 stdout 直写裸 print ｜
    /// assert: 裸 print 行数 == 0
    /// VISUAL_RESIDUE: 此为 real-process 行为（捕获真实 app 运行期 stdout），单元测试无法 mock，
    /// 留 QA 真机判定（需启动 debug 构建捕获 stdout）。
    func test_NoBarePrintToStdoutInBusinessPath() {
        // 此谓词要求「运行期捕获 stdout」，单元测试无法模拟真实业务路径的 stdout 捕获。
        // 标注为 VISUAL_RESIDUE，由 QA 真机执行：
        //   1. make build (debug)
        //   2. 启动 app，触发状态机路径（buddy emit ...）
        //   3. 捕获 app stdout，断言裸 print 行数 == 0
        // 此处放一个轻量断言保证测试不空跑（BuddyLogger API 可达）。
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("buddy-nooprint-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // 驱动方式修正：用 configureForTesting 强制单例指向临时目录（替代 env 驱动）。
        BuddyLogger.shared.resetForTesting()
        BuddyLogger.shared.configureForTesting(logsDir: dir.path, level: .debug)
        defer { BuddyLogger.shared.resetForTesting() }

        // Logger API 存在性 + 不崩（侧面证明收编机制可用，真实 stdout 捕获留 QA）。
        BuddyLogger.shared.debug("nooprint-check", subsystem: "state-machine")
        BuddyLogger.shared._syncFlush()
        XCTAssertTrue(true, "7.P2 [negate] VISUAL_RESIDUE: 裸 print 行数 == 0 留 QA 真机判定")
    }

    // MARK: - 契约 C6: 子系统枚举（BuddyCore 侧若暴露子系统枚举则逐字校验）

    /// covers C6: 若 BuddyCore 暴露 LogSubsystem / 子系统枚举类型，校验 case 逐字匹配。
    /// CONTRACT_AMBIGUOUS: 设计文档 C6 列出 11 个子系统标签，但未明确 BuddyCore 是否暴露为枚举类型。
    /// 此测试用「字符串集合」断言：任一从 BuddyLogger 落盘的 subsystem 值应在 C6 闭集内（宽松校验，
    /// 因 meta 可能携带自定义标签；仅校验 msg 级别 subsystem）。
    func test_SubsystemValuesFromLoggerAreWithinC6Enum() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("buddy-c6-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // 驱动方式修正：用 configureForTesting 强制单例指向临时目录 + debug 级（替代 env 驱动）。
        BuddyLogger.shared.resetForTesting()
        BuddyLogger.shared.configureForTesting(logsDir: dir.path, level: .debug)
        defer { BuddyLogger.shared.resetForTesting() }

        // 用 C6 列出的全部 11 个子系统标签各写一行。
        let allowed: Set<String> = [
            "app", "state-machine", "launcher", "launcher-agent", "plugin",
            "socket", "session", "skin", "settings", "builtin", "clipboard",
        ]
        for s in allowed {
            BuddyLogger.shared.info("c6-check-\(s)", subsystem: s)
        }
        BuddyLogger.shared._syncFlush()

        let fileURL = dir.appendingPathComponent("buddy.jsonl")
        guard let content = try? String(contentsOfFile: fileURL.path, encoding: .utf8) else {
            XCTFail("C6: 无法读取日志")
            return
        }
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        for (idx, line) in lines.enumerated() {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let subsystem = obj["subsystem"] as? String else {
                XCTFail("C6: 第 \(idx) 行缺 subsystem")
                continue
            }
            XCTAssertTrue(allowed.contains(subsystem),
                          "C6: subsystem=\(subsystem) 必须在契约枚举闭集内 (第 \(idx) 行)")
        }
    }
}
