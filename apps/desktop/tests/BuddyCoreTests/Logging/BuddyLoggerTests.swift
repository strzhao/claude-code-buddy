import XCTest
@testable import BuddyCore

/// BuddyLogger 核心行为测试（写入 / 级别过滤 / 新鲜度 / 容错）。
final class BuddyLoggerTests: XCTestCase {

    private var tempDir = ""

    override func setUp() {
        super.setUp()
        let tmp = NSTemporaryDirectory()
        tempDir = "\(tmp)BuddyLoggerTests-\(UUID().uuidString)/"
        try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        BuddyLogger.shared.resetForTesting()
    }

    override func tearDown() {
        BuddyLogger.shared.resetForTesting()
        if !tempDir.isEmpty {
            try? FileManager.default.removeItem(atPath: tempDir)
        }
        tempDir = ""
        super.tearDown()
    }

    // MARK: - 场景 1 / 契约 C3：写入与 schema

    func testInfoLevelWritesValidJSONLLine() {
        BuddyLogger.shared.configureForTesting(logsDir: tempDir, level: .info)
        BuddyLogger.shared.info("启动完成", subsystem: "app", meta: ["pid": 1234])
        BuddyLogger.shared._syncFlush()

        let logPath = "\(tempDir)/buddy.jsonl"
        let content = try? String(contentsOfFile: logPath, encoding: .utf8)
        XCTAssertNotNil(content, "日志文件应已创建")
        XCTAssertTrue(content?.contains("启动完成") == true, "应包含消息")

        // 解析 JSON，校验 schema 四字段（契约 C1 行 schema）
        let line = content?.trimmingCharacters(in: .whitespacesAndNewlines)
        let data = line?.data(using: .utf8) ?? Data()
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(json, "行应为合法 JSON")
        XCTAssertNotNil(json?["ts"] as? String, "应含 ts 字段")
        XCTAssertEqual(json?["level"] as? String, "info")
        XCTAssertEqual(json?["subsystem"] as? String, "app")
        XCTAssertEqual(json?["msg"] as? String, "启动完成")
        XCTAssertEqual((json?["meta"] as? [String: Any])?["pid"] as? Int, 1234)
    }

    // MARK: - 级别过滤（契约 C1 级别序）

    func testLevelFiltering_infoMinSkipsDebug() {
        BuddyLogger.shared.configureForTesting(logsDir: tempDir, level: .info)
        BuddyLogger.shared.debug("dbg", subsystem: "app")
        BuddyLogger.shared.info("inf", subsystem: "app")
        BuddyLogger.shared._syncFlush()

        let lines = readLines()
        XCTAssertEqual(lines.count, 1, "info 级别应过滤掉 debug，只写 info")
        XCTAssertTrue(lines.first?.contains("\"inf\"") == true)
    }

    func testLevelFiltering_warnMinKeepsOnlyWarnAndAbove() {
        BuddyLogger.shared.configureForTesting(logsDir: tempDir, level: .warn)
        BuddyLogger.shared.debug("dbg", subsystem: "app")
        BuddyLogger.shared.info("inf", subsystem: "app")
        BuddyLogger.shared.warn("wn", subsystem: "app")
        BuddyLogger.shared.error("err", subsystem: "app")
        BuddyLogger.shared._syncFlush()

        let levels = readLines().compactMap { line -> String? in
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return json["level"] as? String
        }
        XCTAssertEqual(levels, ["warn", "error"], "warn 最小级别应只保留 warn + error")
    }

    func testLevelOff_writesNothing() {
        BuddyLogger.shared.configureForTesting(logsDir: tempDir, level: nil)
        BuddyLogger.shared.error("err", subsystem: "app")
        BuddyLogger.shared._syncFlush()

        let lines = readLines()
        XCTAssertTrue(lines.isEmpty, "off 级别不应写任何日志")
    }

    // MARK: - 场景 10：新鲜度（append，跨重启不覆盖）

    func testAppendAcrossRestarts_doesNotOverwrite() {
        BuddyLogger.shared.configureForTesting(logsDir: tempDir, level: .info)
        BuddyLogger.shared.info("第一行", subsystem: "app")
        BuddyLogger.shared._syncFlush()

        let logPath = "\(tempDir)/buddy.jsonl"
        let firstHead = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""

        // 模拟重启：reset + 重新 configure
        BuddyLogger.shared.resetForTesting()
        BuddyLogger.shared.configureForTesting(logsDir: tempDir, level: .info)
        BuddyLogger.shared.info("第二行", subsystem: "app")
        BuddyLogger.shared._syncFlush()

        let afterContent = try? String(contentsOfFile: logPath, encoding: .utf8)
        XCTAssertEqual(afterContent?.split(separator: "\n").count, 2, "重启后应追加，不覆盖")
        XCTAssertTrue(afterContent?.hasPrefix(firstHead) == true, "首行应不变")
    }

    // MARK: - 场景 9：容错不崩（目录不可写）

    func testUnwritableDirectory_doesNotCrash() {
        // 不可写目录（chmod 000 的子目录）
        let unwritable = "\(tempDir)locked/"
        try? FileManager.default.createDirectory(atPath: unwritable, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o000)], ofItemAtPath: unwritable)

        BuddyLogger.shared.configureForTesting(logsDir: unwritable, level: .info)
        // 多次写都不应崩
        BuddyLogger.shared.info("不应崩", subsystem: "app")
        BuddyLogger.shared.error("也不应崩", subsystem: "app")
        BuddyLogger.shared._syncFlush()

        // 恢复权限以便 tearDown 清理
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: unwritable)
        // 测试通过即表示未崩（XCTest 默认无信号即通过）
        XCTAssertTrue(true)
    }

    // MARK: - 辅助

    private func readLines() -> [String] {
        let logPath = "\(tempDir)/buddy.jsonl"
        guard let content = try? String(contentsOfFile: logPath, encoding: .utf8) else { return [] }
        return content.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }
}
