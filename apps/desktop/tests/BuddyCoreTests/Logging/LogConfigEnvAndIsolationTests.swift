import XCTest
@testable import BuddyCore

/// 日志系统测试隔离与级别解析测试（任务 5/6）。
///
/// 覆盖：
/// - 契约 C2 环境变量（BUDDY_LOG_LEVEL / BUDDY_LOG_DIR）
/// - 测试宿主默认 off（RuntimeEnvironment.isRunningTests → nil）
/// - debug/release 默认级别（通过直接调 resolveMinLevel 在 BUDDY_LOG_LEVEL 下覆盖）
final class LogConfigEnvAndIsolationTests: XCTestCase {

    // MARK: - 测试宿主默认 off（场景隔离）

    func testResolveMinLevel_inTestHost_returnsNil() {
        // 本测试运行在 XCTest 宿主，RuntimeEnvironment.isRunningTests == true，
        // 且无 BUDDY_LOG_LEVEL 环境变量 → resolveMinLevel 应返回 nil（off）
        let prev = ProcessInfo.processInfo.environment["BUDDY_LOG_LEVEL"]
        unsetenv("BUDDY_LOG_LEVEL")
        defer {
            if let prev = prev { setenv("BUDDY_LOG_LEVEL", prev, 1) }
        }
        XCTAssertNil(LogConfig.resolveMinLevel(), "XCTest 宿主无 BUDDY_LOG_LEVEL 应默认 off")
    }

    // MARK: - BUDDY_LOG_LEVEL 覆盖优先级（契约 C2）

    func testResolveMinLevel_envOverridesIsRunningTests() {
        let prev = ProcessInfo.processInfo.environment["BUDDY_LOG_LEVEL"]
        defer {
            if let prev = prev { setenv("BUDDY_LOG_LEVEL", prev, 1) } else { unsetenv("BUDDY_LOG_LEVEL") }
        }

        for levelStr in ["debug", "info", "warn", "error"] {
            setenv("BUDDY_LOG_LEVEL", levelStr, 1)
            XCTAssertEqual(LogConfig.resolveMinLevel()?.rawValue, levelStr,
                           "BUDDY_LOG_LEVEL=\(levelStr) 应覆盖 isRunningTests")
        }
    }

    func testResolveMinLevel_envOff_returnsNil() {
        let prev = ProcessInfo.processInfo.environment["BUDDY_LOG_LEVEL"]
        defer {
            if let prev = prev { setenv("BUDDY_LOG_LEVEL", prev, 1) } else { unsetenv("BUDDY_LOG_LEVEL") }
        }
        setenv("BUDDY_LOG_LEVEL", "off", 1)
        XCTAssertNil(LogConfig.resolveMinLevel(), "BUDDY_LOG_LEVEL=off 应返回 nil")
    }

    func testResolveMinLevel_invalidEnv_fallsBackToIsRunningTests() {
        let prev = ProcessInfo.processInfo.environment["BUDDY_LOG_LEVEL"]
        defer {
            if let prev = prev { setenv("BUDDY_LOG_LEVEL", prev, 1) } else { unsetenv("BUDDY_LOG_LEVEL") }
        }
        setenv("BUDDY_LOG_LEVEL", "garbage", 1)
        // 未知值忽略 → 回到 isRunningTests 判定（测试宿主为 nil）
        XCTAssertNil(LogConfig.resolveMinLevel(), "未知 BUDDY_LOG_LEVEL 应忽略后走默认")
    }

    // MARK: - BUDDY_LOG_DIR 覆盖（契约 C2 / C5 镜像）

    func testLogsDir_buddyLogDirOverridesHome() {
        let prevLogDir = ProcessInfo.processInfo.environment["BUDDY_LOG_DIR"]
        let testPath = "/tmp/buddy-test-isolation-\(UUID().uuidString)"
        setenv("BUDDY_LOG_DIR", testPath, 1)
        defer {
            if let prev = prevLogDir { setenv("BUDDY_LOG_DIR", prev, 1) } else { unsetenv("BUDDY_LOG_DIR") }
        }
        XCTAssertEqual(LogConfig.logsDir, testPath, "BUDDY_LOG_DIR 应覆盖默认目录")
        XCTAssertEqual(LogConfig.currentLogPath, "\(testPath)/buddy.jsonl")
    }

    func testLogsDir_buddyHomeUsesHomeEnv() {
        // 不设 BUDDY_LOG_DIR，logsDir 应回退到 $HOME/.buddy/logs
        let prevLogDir = ProcessInfo.processInfo.environment["BUDDY_LOG_DIR"]
        unsetenv("BUDDY_LOG_DIR")
        defer {
            if let prev = prevLogDir { setenv("BUDDY_LOG_DIR", prev, 1) }
        }
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        XCTAssertEqual(LogConfig.logsDir, "\(home)/.buddy/logs")
    }
}
