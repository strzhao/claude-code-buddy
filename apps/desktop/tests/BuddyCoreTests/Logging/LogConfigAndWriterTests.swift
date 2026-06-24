import XCTest
@testable import BuddyCore

/// LogConfig（路径/级别解析/环境变量）+ LogWriter（轮转/保留/权限）测试。
final class LogConfigAndWriterTests: XCTestCase {

    var tempDir = ""

    override func setUp() {
        super.setUp()
        let tmp = NSTemporaryDirectory()
        tempDir = "\(tmp)LogConfigTests-\(UUID().uuidString)/"
        try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if !tempDir.isEmpty {
            try? FileManager.default.removeItem(atPath: tempDir)
        }
        tempDir = ""
        super.tearDown()
    }

    // MARK: - LogConfig 路径（契约 C1/C5）

    func testLogsDir_respectsBuddyLogDirEnv() {
        let prev = ProcessInfo.processInfo.environment["BUDDY_LOG_DIR"]
        setenv("BUDDY_LOG_DIR", tempDir, 1)
        defer {
            if let prev = prev { setenv("BUDDY_LOG_DIR", prev, 1) } else { unsetenv("BUDDY_LOG_DIR") }
        }

        XCTAssertEqual(LogConfig.logsDir, tempDir, "BUDDY_LOG_DIR 应覆盖默认目录")
        XCTAssertEqual(LogConfig.currentLogPath, "\(tempDir)/buddy.jsonl")
        XCTAssertEqual(LogConfig.currentLogFileName, "buddy.jsonl")
    }

    func testRotateSizeAndRetainThresholds_matchContract() {
        // 契约 C1 边界值
        XCTAssertEqual(LogConfig.rotateSizeBytes, 5 * 1024 * 1024, "轮转阈值 5 MiB")
        XCTAssertEqual(LogConfig.retainTotalSizeBytes, 50 * 1024 * 1024, "保留总量 50 MiB")
        XCTAssertEqual(LogConfig.retainMaxArchives, 30, "归档上限 30 个")
        XCTAssertEqual(LogConfig.dirPermissions, 0o700)
        XCTAssertEqual(LogConfig.filePermissions, 0o600)
    }

    // MARK: - LogLevel（契约 C1 级别序）

    func testLogLevelOrdering() {
        XCTAssertLessThan(LogLevel.debug, LogLevel.info)
        XCTAssertLessThan(LogLevel.info, LogLevel.warn)
        XCTAssertLessThan(LogLevel.warn, LogLevel.error)
        XCTAssertEqual(LogLevel.warn.rawValue, "warn")
    }

    // MARK: - LogWriter 轮转（场景 6）

    func testRotation_archivesAndCreatesNewFile() {
        let writer = LogWriter(logsDir: tempDir, currentPath: "\(tempDir)/buddy.jsonl")
        writer.ensureCurrentFile()

        // 写入触发轮转：当前文件需 > 5 MiB
        let bigPayload = String(repeating: "x", count: LogConfig.rotateSizeBytes + 1024)
        writer.append(level: .info, subsystem: "test", msg: bigPayload, meta: nil)

        // 校验归档已生成
        let archives = (try? FileManager.default.contentsOfDirectory(atPath: tempDir)) ?? []
        let archiveCount = archives.filter { $0.hasPrefix("buddy-") && $0.hasSuffix(".jsonl") }.count
        XCTAssertGreaterThanOrEqual(archiveCount, 1, "应生成至少 1 个归档（buddy-<ts>.jsonl）")

        // 当前文件应已重建（存在，且为新一轮写入后的内容）
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(tempDir)/buddy.jsonl"))
        writer.close()
    }

    // MARK: - LogWriter 保留清理（场景 6.P2）

    func testRetention_prunesOldestArchives() {
        // 预生成 35 个归档（> retainMaxArchives=30）
        for i in 0..<35 {
            let ts = String(format: "2024010%02d-120000", i)
            let path = "\(tempDir)/buddy-\(ts).jsonl"
            FileManager.default.createFile(atPath: path, contents: "x".data(using: .utf8))
        }

        let writer = LogWriter(logsDir: tempDir, currentPath: "\(tempDir)/buddy.jsonl")
        writer.pruneArchives()

        let archives = ((try? FileManager.default.contentsOfDirectory(atPath: tempDir)) ?? [])
            .filter { $0.hasPrefix("buddy-") && $0.hasSuffix(".jsonl") }
        XCTAssertLessThanOrEqual(archives.count, LogConfig.retainMaxArchives, "归档应 <= 30")
    }

    // MARK: - 文件权限（场景 1.P4）

    func testCurrentFilePermissions_are0600() {
        let writer = LogWriter(logsDir: tempDir, currentPath: "\(tempDir)/buddy.jsonl")
        writer.ensureCurrentFile()
        writer.append(level: .info, subsystem: "test", msg: "perm check", meta: nil)

        let attrs = try? FileManager.default.attributesOfItem(atPath: "\(tempDir)/buddy.jsonl")
        let permissions = attrs?[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.int16Value, 0o600, "当前文件权限应为 0600")
        writer.close()
    }

    // MARK: - 目录权限

    func testLogsDirPermissions_are0700() {
        let writer = LogWriter(logsDir: tempDir, currentPath: "\(tempDir)/buddy.jsonl")
        writer.ensureCurrentFile()

        let attrs = try? FileManager.default.attributesOfItem(atPath: tempDir)
        let permissions = attrs?[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.int16Value, 0o700, "日志目录权限应为 0700")
        writer.close()
    }
}
