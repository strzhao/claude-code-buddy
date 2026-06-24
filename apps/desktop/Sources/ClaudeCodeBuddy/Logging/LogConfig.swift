import Foundation

/// 日志系统配置 + 环境变量解析 + 路径常量（SOURCE OF TRUTH）。
///
/// 契约 C1（路径/格式/轮转/保留边界值）+ C2（环境变量）+ C5（CLI/BuddyCore 镜像双绑）。
///
/// **SOURCE OF TRUTH**: 本文件定义日志路径三常量 + 级别字符串集合 + 行 schema 字段名。
/// CLI 侧（`Sources/BuddyCLI/main.swift`）必须 mirror，契约变更须同步三方。
public struct LogConfig {
    // MARK: - 路径常量（SOURCE OF TRUTH，契约 C1/C5）

    /// `$HOME/.buddy`。
    /// 读 `$HOME` 环境变量优先（对齐 CLI `buddyHomeDir` main.swift:19 的
    /// `ProcessInfo...environment["HOME"] ?? NSHomeDirectory()`），便于测试隔离重定向。
    /// 契约 C5：现状 BuddyCore `LauncherConstants.buddyDir` 仅用 `NSHomeDirectory()` 无 env fallback，
    /// 本处对齐 CLI 语义；目录解析优先级 `BUDDY_LOG_DIR` > `$HOME/.buddy/logs`。
    public static var buddyHomeDir: String {
        ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    }

    /// `$HOME/.buddy/logs`（目录权限 0700）。
    /// 优先级：`BUDDY_LOG_DIR` 环境变量（测试隔离 / 自定义）> `$HOME/.buddy/logs`。
    /// 契约 C5：app 侧也必须识别 `BUDDY_LOG_DIR`，否则测试隔离下 app 写真实 home、
    /// CLI 读 `$HOME` 重定向目录，CLI 读不到 app 的日志。
    public static var logsDir: String {
        if let env = ProcessInfo.processInfo.environment["BUDDY_LOG_DIR"], !env.isEmpty {
            return env
        }
        return "\(buddyHomeDir)/.buddy/logs"
    }

    /// 当前日志文件名（永不带时间戳；轮转后归档为 `buddy-<ts>.jsonl`）。
    public static let currentLogFileName = "buddy.jsonl"

    /// 当前日志文件绝对路径（`$HOME/.buddy/logs/buddy.jsonl` 或 `BUDDY_LOG_DIR/buddy.jsonl`）。
    public static var currentLogPath: String {
        "\(logsDir)/\(currentLogFileName)"
    }

    // MARK: - 轮转 / 保留边界值（契约 C1）

    /// 当前文件 > 此阈值时 rename → `buddy-<ts>.jsonl` 并新建当前文件。
    public static let rotateSizeBytes: Int = 5 * 1024 * 1024   // 5 MiB

    /// 目录总占用 > 此阈值时删除最旧归档。
    public static let retainTotalSizeBytes: Int = 50 * 1024 * 1024   // 50 MiB

    /// 归档数 > 此阈值时删除最旧归档。
    public static let retainMaxArchives: Int = 30

    // MARK: - 文件权限（契约 C1）
    // 用 UInt / NSNumber 兼容旧工具链（FileManager.PosixPermissions 是 macOS 11+）；
    // 设 attributes 时用 .posixPermissions: NSNumber(value: ...)。

    /// 目录权限 0700（owner rwx）。
    public static let dirPermissions: UInt = 0o700

    /// 文件权限 0600（owner rw）。
    public static let filePermissions: UInt = 0o600

    // MARK: - 行 schema 字段名（契约 C1/C5，CLI 解析须同构）

    public static let fieldTimestamp = "ts"
    public static let fieldLevel = "level"
    public static let fieldSubsystem = "subsystem"
    public static let fieldMessage = "msg"
    public static let fieldMeta = "meta"

    // MARK: - 环境变量解析（契约 C2）

    /// 解析最小级别。
    ///
    /// 优先级（契约 C2 + 设计文档「级别解析优先级」）：
    /// 1. `BUDDY_LOG_LEVEL` 环境变量（`debug|info|warn|error|off`）—— 一律覆盖
    /// 2. `#if DEBUG` → debug / release → info
    /// 3. `RuntimeEnvironment.isRunningTests` → nil（表示关闭日志，XCTest 宿主默认 off）
    ///
    /// - Returns: 最小级别；nil 表示完全关闭日志（`off` 或测试宿主）。
    public static func resolveMinLevel() -> LogLevel? {
        if let env = ProcessInfo.processInfo.environment["BUDDY_LOG_LEVEL"] {
            switch env.lowercased() {
            case "off": return nil
            case "debug": return .debug
            case "info": return .info
            case "warn": return .warn
            case "error": return .error
            default:
                // 未知值忽略，落到默认逻辑（不崩）
                break
            }
        }
        if RuntimeEnvironment.isRunningTests { return nil }
        #if DEBUG
        return .debug
        #else
        return .info
        #endif
    }
}
