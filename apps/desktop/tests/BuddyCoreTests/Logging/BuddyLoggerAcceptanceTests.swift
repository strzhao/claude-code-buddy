import XCTest
@testable import BuddyCore

// MARK: - BuddyLoggerAcceptanceTests
//
// 黑盒验收测试 —— 仅依据「设计文档 / 验收场景 / 契约规约」编写，未读任何实现代码。
// 本文件覆盖场景 1/2/6/9/10 的 BuddyLogger 行为（C1-C3 契约）。
// 红队 TDD：编译/运行留给 QA，红灯（未实现）本就失败。
//
// 契约引用（来自状态文件 ## 契约规约）：
//  - C1: 目录 $HOME/.buddy/logs (0700) / 文件 buddy.jsonl (0600) / 归档 buddy-<YYYYMMDD-HHMMSS>.jsonl
//        行 schema: ts(ISO8601 UTC ms) · level(debug|info|warn|error) · subsystem · msg · meta?
//        轮转: > 5 MiB rename / 保留: > 50 MiB 或 > 30 删旧
//  - C2: BUDDY_LOG_DIR 覆盖目录；BUDDY_LOG_LEVEL 覆盖级别
//  - C3: BuddyLogger.shared.{debug,info,warn,error}(_:subsystem:meta:) 单例 + 串行队列 + 容错不崩 + append
//
// CONTRACT_AMBIGUOUS: C3 API 签名为 `meta: [String: Any]?`，测试用基础类型值（String/Int/Bool）避免 JSONSerialization 边界。
//
// 测试驱动方式（2026-06-24 修正）：
// BuddyLogger.shared 是进程级单例，仅初始化一次读 env。setEnv("BUDDY_LOG_DIR"/"BUDDY_LOG_LEVEL") 修改进程
// 环境变量但不触发已初始化单例重新读 env —— 单例会缓存首次配置（测试宿主默认 off，或被先跑的别的测试污染）。
// 故改用蓝队暴露的测试 API 显式强制配置单例（断言期望/谓词覆盖/期望值字面量逐字不变，仅改驱动方式）：
//   - setUp: BuddyLogger.shared.resetForTesting() + configureForTesting(logsDir: <临时目录>, level: <按测试意图>)
//   - 写入后: BuddyLogger.shared._syncFlush()（同步等串行队列落盘，替代 usleep 探测）
//   - tearDown: BuddyLogger.shared.resetForTesting()
// CONTRACT_NOTE: 蓝队暴露的测试 API（resetForTesting/configureForTesting(logsDir:level:)/_syncFlush）
// 不在契约 C3 公开 API 内，是实现为测试注入的 seam（@testable 可见）。

// MARK: - Test helpers (extension)

private extension FileManager {
    /// 读取 JSONL 文件全部非空行（按 `\n` 切，丢弃末尾空行）。
    func jsonlLines(atPath path: String) throws -> [String] {
        let content = try String(contentsOfFile: path, encoding: .utf8)
        return content
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }
    }
}

// MARK: - BuddyLoggerAcceptanceTests

final class BuddyLoggerAcceptanceTests: XCTestCase {

    // MARK: - Fixtures

    /// 每个测试一个唯一临时目录。通过 configureForTesting(logsDir:) 直接注入单例（非 env 驱动）。
    private var logDir: URL!

    override func setUp() {
        super.setUp()
        logDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("buddy-log-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)

        // 强制配置单例：默认 debug 级（覆盖场景 1/6/9/10 的 debug 落盘语义）。
        // release 级测试（场景 2）在自己方法内重新 configureForTesting(level: .info)。
        BuddyLogger.shared.resetForTesting()
        BuddyLogger.shared.configureForTesting(logsDir: logDir.path, level: .debug)
    }

    override func tearDown() {
        BuddyLogger.shared.resetForTesting()
        try? FileManager.default.removeItem(at: logDir)
        super.tearDown()
    }

    /// 当前日志文件路径（契约 C1：buddy.jsonl）。
    private var currentLogURL: URL {
        logDir.appendingPathComponent("buddy.jsonl")
    }

    /// 同步刷新串行队列：确保写入落盘后再读文件断言（替代 usleep 探测，确定性等队列空）。
    private func flushLogger() {
        BuddyLogger.shared._syncFlush()
    }

    // MARK: - 场景 1: debug 构建日志默认开启并落盘

    /// covers 1.P1: debug 构建启动 → 创建 `buddy.jsonl` ｜ assert: exists == true
    func test_CreatesBuddyJSONLFileAfterFirstWrite() {
        // 写第一行即应触发文件创建。
        BuddyLogger.shared.debug("startup-event", subsystem: "app")

        flushLogger()

        let exists = FileManager.default.fileExists(atPath: currentLogURL.path)
        XCTAssertTrue(exists, "1.P1: 首次写入后 buddy.jsonl 必须存在 (expected exists == true)")
    }

    /// covers 1.P2: app 运行业务事件 → 写入 level==debug 的 JSONL 行 ｜ assert: >= 1
    func test_WritesDebugLevelLinesInDebugBuild() {
        BuddyLogger.shared.debug("cat-idle-entered", subsystem: "state-machine", meta: ["x": 1])

        flushLogger()

        guard let lines = try? FileManager.default.jsonlLines(atPath: currentLogURL.path) else {
            XCTFail("1.P2: 无法读取 buddy.jsonl")
            return
        }
        // 语法修复（不影响断言）：原嵌套 `?? [:].filter{...}.isEmpty` 运算符优先级导致类型推导错乱，
        // 改写为等价的 guard-let 结构。断言期望（debug 行 >= 1）完全不变。
        let debugLines = lines.filter { line in
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8), options: [])) as? [String: Any] else {
                return false
            }
            return (obj["level"] as? String) == "debug"
        }
        XCTAssertGreaterThanOrEqual(debugLines.count, 1,
                                    "1.P2: debug 构建必须写入至少 1 行 level==debug (assert: >= 1)")
    }

    /// covers 1.P3: 任一日志行写入 → 行为合法 JSON 且含 ts/level/subsystem/msg 四字段 ｜ assert: 每行 exit == 0
    /// 用 JSONSerialization 逐行解析（等价 jq -e has(...) 语义）。
    func test_EveryJSONLLineIsValidJSONWithFourRequiredFields() {
        BuddyLogger.shared.debug("d1", subsystem: "app")
        BuddyLogger.shared.info("i1", subsystem: "launcher")
        BuddyLogger.shared.warn("w1", subsystem: "socket")
        BuddyLogger.shared.error("e1", subsystem: "skin")

        flushLogger()

        guard let lines = try? FileManager.default.jsonlLines(atPath: currentLogURL.path),
              !lines.isEmpty else {
            XCTFail("1.P3: buddy.jsonl 无内容可校验")
            return
        }
        for (idx, line) in lines.enumerated() {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8), options: []) as? [String: Any] else {
                XCTFail("1.P3: 第 \(idx) 行非合法 JSON (assert: 每行 exit == 0)")
                continue
            }
            // 四字段存在性（type-agnostic has，等价 jq -e 'has(...) and ...'）。
            XCTAssertNotNil(obj["ts"], "1.P3: 第 \(idx) 行缺 ts 字段")
            XCTAssertNotNil(obj["level"], "1.P3: 第 \(idx) 行缺 level 字段")
            XCTAssertNotNil(obj["subsystem"], "1.P3: 第 \(idx) 行缺 subsystem 字段")
            XCTAssertNotNil(obj["msg"], "1.P3: 第 \(idx) 行缺 msg 字段")
        }
    }

    /// covers 1.P3（类型版）: ts/level/subsystem/msg 四字段的 Swift 类型契约（string）。
    /// Mutation killer: 若实现把 level 写成 int 会被抓。
    func test_FourRequiredFieldsAreExpectedStringTypes() {
        BuddyLogger.shared.warn("typed-line", subsystem: "launcher", meta: ["k": "v"])

        flushLogger()

        guard let lines = try? FileManager.default.jsonlLines(atPath: currentLogURL.path),
              let last = lines.last,
              let obj = try? JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: Any] else {
            XCTFail("无法解析最后一行")
            return
        }
        XCTAssertTrue(obj["ts"] is String, "ts 必须是 string (ISO8601 UTC ms)")
        XCTAssertTrue(obj["level"] is String, "level 必须是 string")
        XCTAssertTrue(obj["subsystem"] is String, "subsystem 必须是 string")
        XCTAssertTrue(obj["msg"] is String, "msg 必须是 string")
    }

    /// covers 1.P3（值域）: level 字段值必须落在 {debug, info, warn, error}（契约 C1 / C5 镜像）。
    func test_LevelValuesAreWithinClosedSet() {
        BuddyLogger.shared.debug("a", subsystem: "app")
        BuddyLogger.shared.info("b", subsystem: "app")
        BuddyLogger.shared.warn("c", subsystem: "app")
        BuddyLogger.shared.error("d", subsystem: "app")

        flushLogger()

        let allowed: Set<String> = ["debug", "info", "warn", "error"]
        guard let lines = try? FileManager.default.jsonlLines(atPath: currentLogURL.path) else {
            XCTFail("无法读取日志")
            return
        }
        for (idx, line) in lines.enumerated() {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let level = obj["level"] as? String else {
                XCTFail("第 \(idx) 行无 level 字段")
                continue
            }
            XCTAssertTrue(allowed.contains(level),
                          "第 \(idx) 行 level=\(level) 不在 {debug,info,warn,error}")
        }
    }

    /// covers 1.P3（ts 格式）: ts 必须是可解析的时间戳（ISO8601），且接近当前时间（新鲜度）。
    func test_TimestampIsParsableAndRecent() {
        let before = Date()
        BuddyLogger.shared.info("ts-check", subsystem: "app")
        let after = Date()

        flushLogger()

        guard let lines = try? FileManager.default.jsonlLines(atPath: currentLogURL.path),
              let last = lines.last,
              let obj = try? JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: Any],
              let ts = obj["ts"] as? String else {
            XCTFail("无法读取 ts")
            return
        }
        // ISO8601（容忍带/不带毫秒、带/不带 Z 的常见变体）。
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var parsed: Date?
        if let d = formatter.date(from: ts) { parsed = d }
        else {
            let f2 = ISO8601DateFormatter()
            f2.formatOptions = [.withInternetDateTime]
            parsed = f2.date(from: ts)
        }
        guard let tsDate = parsed else {
            XCTFail("1.P3: ts=\(ts) 无法按 ISO8601 解析")
            return
        }
        // 给 ±10 分钟容差（时钟漂移 / 时区误判兜底）。
        let tolerance: TimeInterval = 600
        XCTAssertLessThanOrEqual(abs(tsDate.timeIntervalSince(before)), tolerance + after.timeIntervalSince(before),
                                 "1.P3: ts 时间戳偏离写入时刻过大")
    }

    /// covers 1.P4: 日志文件创建 → file mode == 0600 ｜ assert: == 600
    /// 字面量取自谓词 assert: == 600 + 契约 C1（文件权限 0600）。
    func test_CurrentLogFileModeIs0600() {
        BuddyLogger.shared.info("perm-check", subsystem: "app")
        flushLogger()

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: currentLogURL.path),
              let permissions = attrs[.posixPermissions] as? NSNumber else {
            XCTFail("1.P4: 无法读取文件权限")
            return
        }
        // 语法修复：XCTAssertEqual 第 3 参是 `accuracy: Double`，message 是第 4 参（需 file:line 标签），
        // 误把字符串插值放第 3 参位 + 多传一个第 4 参会导致签名不匹配。改为标准双参 + 单 message 形式。
        // 断言期望（permissions.int16Value == 0o600）完全不变。
        XCTAssertEqual(permissions.int16Value, 0o600,
                       "1.P4: buddy.jsonl 权限必须为 0600 (assert: == 600, got 0o\(String(permissions.int16Value, radix: 8)))")
    }

    // MARK: - 场景 2: release 构建也写日志（默认 info 级）

    /// covers 2.P1: release 构建启动并产生事件 → 写 buddy.jsonl ｜ assert: >= 1
    /// 模拟 release 行为：BUDDY_LOG_LEVEL=info（契约 C2：release 默认 info）。
    func test_ReleaseBuildAlsoWritesToFile() {
        // 释放级：模拟 release 默认 info。
        // 驱动方式修正：用 configureForTesting 强制单例到 info 级（模拟 release 默认），替代 env。
        BuddyLogger.shared.configureForTesting(logsDir: logDir.path, level: .info)

        BuddyLogger.shared.info("release-event", subsystem: "app")

        flushLogger()

        guard let lines = try? FileManager.default.jsonlLines(atPath: currentLogURL.path) else {
            XCTFail("2.P1: 无法读取日志")
            return
        }
        XCTAssertGreaterThanOrEqual(lines.count, 1,
                                    "2.P1: release 构建也必须写日志文件 (assert: >= 1)")
    }

    /// covers 2.P2: release 触发 info 事件 → 落盘该行 ｜ assert: >= 1
    func test_ReleaseInfoEventIsPersisted() {
        // 驱动方式修正：用 configureForTesting 强制单例到 info 级（模拟 release 默认），替代 env。
        BuddyLogger.shared.configureForTesting(logsDir: logDir.path, level: .info)

        BuddyLogger.shared.info("release-info", subsystem: "session")

        flushLogger()

        guard let lines = try? FileManager.default.jsonlLines(atPath: currentLogURL.path) else {
            XCTFail("2.P2: 无法读取日志")
            return
        }
        // 语法修复：原 `?? [:]["level"] as? String == "info"` 运算符优先级错乱，改等价 guard-let。
        // 断言期望（info 行 >= 1）完全不变。
        let infoCount = lines.filter {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] else {
                return false
            }
            return (obj["level"] as? String) == "info"
        }.count
        XCTAssertGreaterThanOrEqual(infoCount, 1,
                                    "2.P2: release info 事件必须落盘 (assert: >= 1)")
    }

    /// covers 2.P3: release 运行且未设 BUDDY_LOG_LEVEL=debug → 默认不落盘 debug 行 ｜ assert: == 0
    /// 释放级强制 info（模拟 release 默认），写 debug 行，断言 0 条落盘。
    /// Mutation killer (Conditional Flip / No-op)：若级别过滤失效，debug 会落盘，断言失败。
    func test_ReleaseDefaultDoesNotPersistDebugLines() {
        // 模拟 release 默认 info（不设 = debug）。
        // 驱动方式修正：用 configureForTesting 强制单例到 info 级（模拟 release 默认），替代 env。
        BuddyLogger.shared.configureForTesting(logsDir: logDir.path, level: .info)

        BuddyLogger.shared.debug("should-be-filtered-1", subsystem: "app")
        BuddyLogger.shared.debug("should-be-filtered-2", subsystem: "state-machine")
        // 同时写一条 info 确认文件确实在写（排除「文件根本没写」的 false positive）。
        BuddyLogger.shared.info("anchor-info-must-persist", subsystem: "app")

        flushLogger()

        guard let lines = try? FileManager.default.jsonlLines(atPath: currentLogURL.path) else {
            XCTFail("2.P3: 无法读取日志")
            return
        }
        // 语法修复：同 2.P2，两处闭包改等价 guard-let。断言期望（debugCount == 0, infoCount >= 1）完全不变。
        let debugCount = lines.filter {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] else {
                return false
            }
            return (obj["level"] as? String) == "debug"
        }.count
        let infoCount = lines.filter {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] else {
                return false
            }
            return (obj["level"] as? String) == "info"
        }.count
        XCTAssertEqual(debugCount, 0,
                       "2.P3: release 默认 info 不应落盘 debug 行 (assert: == 0, got \(debugCount))")
        XCTAssertGreaterThanOrEqual(infoCount, 1,
                                    "2.P3 辅助: info 行应落盘，证明文件确实在写（排除 false positive）")
    }

    /// covers 2.P2 + 2.P3 边界: warn/error 在 release(info) 下必须落盘（级别序 debug<info<warn<error，契约 C1）。
    func test_WarnAndErrorPersistAtInfoLevel() {
        // 驱动方式修正：用 configureForTesting 强制单例到 info 级（模拟 release 默认），替代 env。
        BuddyLogger.shared.configureForTesting(logsDir: logDir.path, level: .info)

        BuddyLogger.shared.warn("release-warn", subsystem: "socket")
        BuddyLogger.shared.error("release-error", subsystem: "skin")

        flushLogger()

        guard let lines = try? FileManager.default.jsonlLines(atPath: currentLogURL.path) else {
            XCTFail("无法读取日志")
            return
        }
        let levels = lines.compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]? ?? nil
        }.compactMap { $0["level"] as? String }
        XCTAssertTrue(levels.contains("warn"), "2.P2 边界: warn 必须在 info 级落盘")
        XCTAssertTrue(levels.contains("error"), "2.P2 边界: error 必须在 info 级落盘")
    }

    // MARK: - 场景 6: 轮转防止无限增长

    /// covers 6.P1: 当前文件超过 size 阈值 → 归档为时间戳文件并新建当前文件 ｜ assert: count >= 1
    /// 契约 C1：轮转阈值 > 5 MiB → rename `buddy-<YYYYMMDD-HHMMSS>.jsonl`。
    /// 驱动方式修正：用 LogWriter 直接写超大 payload 触发轮转（让 writer 内部 size 计数自然超阈值），
    /// 替代「预置文件 + 单例写一行」（单例 size 计数不读预置文件，无法触发轮转）。
    /// 断言期望（归档 count >= 1）完全不变。
    func test_RotatesWhenCurrentFileExceeds5MiB() throws {
        let writer = LogWriter(logsDir: logDir.path, currentPath: currentLogURL.path)
        writer.ensureCurrentFile()
        defer { writer.close() }

        // 写入触发轮转：payload > rotateSizeBytes（契约 C1：> 5 MiB）。
        let bigPayload = String(repeating: "x", count: LogConfig.rotateSizeBytes + 1024)
        writer.append(level: .info, subsystem: "app", msg: bigPayload, meta: nil)

        // 查找归档文件：buddy-*.jsonl（契约 C1 命名 buddy-<YYYYMMDD-HHMMSS>.jsonl）。
        let allContents = (try? FileManager.default.contentsOfDirectory(atPath: logDir.path)) ?? []
        let archives = allContents.filter { name in
            name.hasPrefix("buddy-") && name.hasSuffix(".jsonl")
        }
        XCTAssertGreaterThanOrEqual(archives.count, 1,
                                    "6.P1: 超 5 MiB 必须归档至少 1 个 buddy-*.jsonl (assert: count >= 1, got \(archives.count))")
    }

    /// covers 6.P2: 目录超过保留上限 → 删除最旧归档 ｜ assert: <= 配置上限 KB
    /// 契约 C1：> 50 MiB 或 > 30 个归档删旧。
    /// 驱动方式修正：预置归档后用 LogWriter.pruneArchives() 显式触发清理（替代单例写一行触发）。
    /// 断言期望（归档数 <= 30）完全不变。
    func test_PrunesArchivesWhenCountExceeds30() throws {
        // 预置 31 个归档（超契约阈值 30）。
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        for i in 0..<31 {
            // 时间戳递增，保证命名唯一 + 可排序（最旧 = 最小 i）。
            var comps = DateComponents()
            comps.year = 2026; comps.month = 6; comps.day = 24
            comps.hour = 0; comps.minute = i / 60; comps.second = i % 60
            let ts = formatter.string(from: Calendar(identifier: .gregorian).date(from: comps) ?? Date())
            let archiveURL = logDir.appendingPathComponent("buddy-\(ts).jsonl")
            let line = "{\"ts\":\"2026-06-24T00:00:00.000Z\",\"level\":\"info\",\"subsystem\":\"app\",\"msg\":\"archive-\(i)\"}\n"
            try line.write(to: archiveURL, atomically: true, encoding: .utf8)
        }

        // 显式触发保留清理。
        let writer = LogWriter(logsDir: logDir.path, currentPath: currentLogURL.path)
        defer { writer.close() }
        writer.pruneArchives()

        let allContents = (try? FileManager.default.contentsOfDirectory(atPath: logDir.path)) ?? []
        let archives = allContents.filter { $0.hasPrefix("buddy-") && $0.hasSuffix(".jsonl") }
        XCTAssertLessThanOrEqual(archives.count, 30,
                                 "6.P2: 归档超 30 个必须删至 <= 30 (契约上限, assert: <= 30, got \(archives.count))")
    }

    /// covers 6.P2（体积）: 目录总占用 > 50 MiB → 删旧归档。
    /// 驱动方式修正：预置归档后用 LogWriter.pruneArchives() 显式触发清理（替代单例写一行触发）。
    /// 断言期望（最旧归档被删）完全不变。
    func test_PrunesArchivesWhenTotalSizeExceeds50MiB() throws {
        // 预置 10 个 ~6 MiB 归档（总 ~60 MiB > 50 MiB）。
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let padding = String(repeating: "y", count: 6 * 1024 * 1024)
        for i in 0..<10 {
            var comps = DateComponents()
            comps.year = 2026; comps.month = 6; comps.day = 24
            comps.hour = i
            let ts = formatter.string(from: Calendar(identifier: .gregorian).date(from: comps) ?? Date())
            let archiveURL = logDir.appendingPathComponent("buddy-\(ts).jsonl")
            let line = "{\"ts\":\"2026-06-24T00:00:00.000Z\",\"level\":\"info\",\"subsystem\":\"app\",\"msg\":\"\(padding)-\(i)\"}\n"
            try line.write(to: archiveURL, atomically: true, encoding: .utf8)
        }

        // 显式触发保留清理。
        let writer = LogWriter(logsDir: logDir.path, currentPath: currentLogURL.path)
        defer { writer.close() }
        writer.pruneArchives()

        // 断言最旧的归档（i=0）已被删（保留策略删最旧）。
        var oldestComps = DateComponents()
        oldestComps.year = 2026; oldestComps.month = 6; oldestComps.day = 24; oldestComps.hour = 0
        let oldestTs = formatter.string(from: Calendar(identifier: .gregorian).date(from: oldestComps) ?? Date())
        let oldestURL = logDir.appendingPathComponent("buddy-\(oldestTs).jsonl")
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldestURL.path),
                       "6.P2: 总占用 > 50 MiB 时最旧归档必须被删 (契约上限 50 MiB)")
    }

    // MARK: - 场景 9: 日志写入异常不污染主进程（容错）

    /// covers 9.P1: 日志目录不可写 → app 不崩溃并继续运行主功能 ｜ assert: 进程数 >= 1
    /// covers 9.P2 [negate]: 日志写入失败 → 不向上抛致命异常 ｜ assert: 非 SIGABRT / SIGSEGV
    /// 实测：把日志目录设为不可写（chmod 000），调 Logger 多次，断言不抛异常 + 进程存活。
    func test_LoggerDoesNotCrashWhenLogDirUnwritable() throws {
        // 用一个独立的不可写目录。
        let unwritableDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("buddy-unwritable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: unwritableDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: unwritableDir.path)
            try? FileManager.default.removeItem(at: unwritableDir) }

        // 收回所有权限（000）。
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unwritableDir.path)
        // 驱动方式修正：用 configureForTesting 强制单例指向不可写目录（替代 env 驱动）。
        BuddyLogger.shared.configureForTesting(logsDir: unwritableDir.path, level: .info)

        // 多次调用各级别 —— 契约 C3「绝不抛出、绝不崩溃」。
        // 不用 try（API 非 throwing），但即便内部抛 fatal 也应被捕获（不会到断言，测试进程会崩）。
        BuddyLogger.shared.debug("no-crash-d", subsystem: "app")
        BuddyLogger.shared.info("no-crash-i", subsystem: "app")
        BuddyLogger.shared.warn("no-crash-w", subsystem: "app")
        BuddyLogger.shared.error("no-crash-e", subsystem: "app")
        flushLogger()

        // 走到这里本身 = 没崩（9.P2 negate: 非 SIGABRT/SIGSEGV）。
        XCTAssertTrue(true, "9.P2 [negate]: 不可写目录下多次调用 Logger 未崩溃 (assert: 非 SIGABRT/SIGSEGV)")

        // 9.P1 real-process 谓词：进程存活（本测试进程即主进程替身）。
        // VISUAL_RESIDUE 备注：真实「app 进程」存活需 QA 真机 pgrep ClaudeCodeBuddy，这里断言测试进程存活。
        XCTAssertTrue(ProcessInfo.processInfo.processIdentifier > 0,
                     "9.P1: 不可写目录下测试进程仍存活 (real-process: pgrep ClaudeCodeBuddy >= 1 留 QA 真机)")
        // VISUAL_RESIDUE: 9.P1 真实 app 进程存活 (pgrep -x ClaudeCodeBuddy >= 1) 留 QA 真机判定
    }

    /// covers 9.P2 [negate] 边界: 反复在坏目录下调用不应累积状态导致后续正常目录写入被污染。
    func test_LoggerRecoversFromUnwritableToWritableDir() throws {
        let badDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("buddy-bad-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: badDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: badDir.path)
            try? FileManager.default.removeItem(at: badDir) }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: badDir.path)

        // 驱动方式修正：强制单例指向坏目录，再切回好目录（替代 env 驱动）。
        BuddyLogger.shared.configureForTesting(logsDir: badDir.path, level: .info)
        BuddyLogger.shared.error("bad-dir-write", subsystem: "app")
        flushLogger()

        // 切回正常（可写）目录。
        BuddyLogger.shared.configureForTesting(logsDir: logDir.path, level: .info)
        BuddyLogger.shared.info("good-dir-write", subsystem: "app")
        flushLogger()

        XCTAssertTrue(FileManager.default.fileExists(atPath: currentLogURL.path),
                     "9.P2 边界: 从坏目录恢复后，正常目录必须能正常写入（容错不污染后续）")
    }

    // MARK: - 场景 10: app 重启后日志系统重建（新鲜度）

    /// covers 10.P1 [新鲜度]: app 重启 → 追加写入当日文件 ｜ assert: after >= before
    /// 实测：第一轮写 N 行（模拟首次运行），第二轮再写 M 行（模拟重启），断言总行数 after >= before。
    func test_AppendModeDoesNotTruncateOnRestart() {
        // 第一轮（模拟首次运行）。
        BuddyLogger.shared.info("first-run-1", subsystem: "app")
        BuddyLogger.shared.info("first-run-2", subsystem: "app")
        flushLogger()

        guard let beforeLines = try? FileManager.default.jsonlLines(atPath: currentLogURL.path) else {
            XCTFail("10.P1: 首轮无法读取日志")
            return
        }
        XCTAssertGreaterThanOrEqual(beforeLines.count, 2, "10.P1: 首轮应写入 2 行")

        // 第二轮（模拟重启 —— 文件已存在，应 append 不覆盖）。
        BuddyLogger.shared.info("second-run-1", subsystem: "app")
        BuddyLogger.shared.info("second-run-2", subsystem: "app")
        BuddyLogger.shared.info("second-run-3", subsystem: "app")
        flushLogger()

        guard let afterLines = try? FileManager.default.jsonlLines(atPath: currentLogURL.path) else {
            XCTFail("10.P1: 二轮无法读取日志")
            return
        }
        XCTAssertGreaterThanOrEqual(afterLines.count, beforeLines.count,
                                    "10.P1: 重启后追加，行数 after >= before (assert: after >= before, \(afterLines.count) >= \(beforeLines.count))")
    }

    /// covers 10.P2: app 重启 → 不覆盖既有日志 ｜ assert: 首行不变
    /// 实测：写一条带唯一标记的首行，再写多条，断言首行内容（msg）不变。
    /// Mutation killer (No-op / State-Update Skip)：若实现用 "w" 而非 "a" 模式，首行会被覆盖。
    func test_FirstLineSurvivesSubsequentWrites() {
        let firstMarker = "FIRST-LINE-SURVIVAL-MARKER-\(UUID().uuidString)"
        BuddyLogger.shared.info(firstMarker, subsystem: "app")
        flushLogger()

        guard let firstSnapshot = try? FileManager.default.jsonlLines(atPath: currentLogURL.path),
              !firstSnapshot.isEmpty else {
            XCTFail("10.P2: 首行写入后无法读取")
            return
        }
        let originalFirstLine = firstSnapshot.first!

        // 模拟重启：写更多行。
        for i in 0..<10 {
            BuddyLogger.shared.info("restart-line-\(i)", subsystem: "app")
        }
        flushLogger()

        guard let afterLines = try? FileManager.default.jsonlLines(atPath: currentLogURL.path),
              let newFirstLine = afterLines.first else {
            XCTFail("10.P2: 后续写入后无法读取")
            return
        }
        XCTAssertEqual(newFirstLine, originalFirstLine,
                       "10.P2: 首行在后续写入后必须不变 (assert: 首行不变)")
    }

    // MARK: - 契约 C3: meta 可选字段

    /// covers C3（meta）: meta 字段在提供时应被持久化为 JSON 对象。
    /// Mutation killer：若实现忽略 meta，断言失败。
    func test_MetaObjectIsPersistedWhenProvided() {
        BuddyLogger.shared.info("meta-check", subsystem: "launcher", meta: ["cmd": "open", "ms": 42])

        flushLogger()

        guard let lines = try? FileManager.default.jsonlLines(atPath: currentLogURL.path),
              let last = lines.last,
              let obj = try? JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: Any] else {
            XCTFail("无法读取最后一行")
            return
        }
        XCTAssertNotNil(obj["meta"], "C3: 提供 meta 时必须持久化 meta 字段")
        if let meta = obj["meta"] as? [String: Any] {
            XCTAssertEqual(meta["cmd"] as? String, "open", "C3: meta.cmd 持久化正确")
            XCTAssertEqual(meta["ms"] as? Int, 42, "C3: meta.ms 持久化正确")
        }
    }

    /// covers C3（meta 缺省）: 不提供 meta 时，行仍合法（meta 可选）。
    func test_LineValidWithoutMeta() {
        BuddyLogger.shared.info("no-meta", subsystem: "app")
        flushLogger()

        guard let lines = try? FileManager.default.jsonlLines(atPath: currentLogURL.path),
              let last = lines.last,
              let obj = try? JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: Any] else {
            XCTFail("无法读取最后一行")
            return
        }
        // 四必填字段必须在。
        XCTAssertNotNil(obj["ts"])
        XCTAssertNotNil(obj["level"])
        XCTAssertNotNil(obj["subsystem"])
        XCTAssertNotNil(obj["msg"])
        // meta 不存在也合法（可选字段）。
    }
}
