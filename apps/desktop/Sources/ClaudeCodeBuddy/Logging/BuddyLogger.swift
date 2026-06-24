import Foundation

/// 统一日志器（单例）。
///
/// 契约 C3：
/// - 单例 `BuddyLogger.shared`。
/// - 方法（`subsystem` 必填、`meta` 可选）：`debug/info/warn/error`。
/// - 线程安全：内部串行 `DispatchQueue` 保护文件 IO；可从任意线程/actor 调用。
/// - 容错：任何 IO 失败静默降级（关闭句柄、下次重试），绝不抛出、绝不崩溃、绝不阻塞调用方超过单行 append 耗时。
/// - 新鲜度：以 append 模式打开当前文件，跨重启不覆盖。
///
/// 用法：
/// ```swift
/// BuddyLogger.shared.info("启动完成", subsystem: "app")
/// BuddyLogger.shared.warn("provider 降级", subsystem: "launcher", meta: ["provider": "ollama", "reason": "timeout"])
/// ```
public final class BuddyLogger {
    public static let shared = BuddyLogger()

    private let queue = DispatchQueue(label: "buddy.logger.serial")
    private var writer: LogWriter
    private var minLevel: LogLevel?
    private var configured = false

    private init() {
        self.writer = LogWriter()
    }

    // MARK: - 配置（AppDelegate 启动调用）

    /// 配置日志器：解析级别、创建目录、打开当前文件、启动清理。
    /// 幂等（重复调用安全）。
    public func configure() {
        queue.sync {
            guard !configured else { return }
            minLevel = LogConfig.resolveMinLevel()
            if minLevel != nil {
                writer.ensureCurrentFile()
                writer.pruneArchives()
            }
            configured = true
        }
    }

    /// 仅供测试：注入指定目录与级别（不走环境变量 / isRunningTests）。
    public func configureForTesting(logsDir: String, level: LogLevel?) {
        queue.sync {
            writer.close()
            let currentPath = "\(logsDir)/\(LogConfig.currentLogFileName)"
            writer = LogWriter(logsDir: logsDir, currentPath: currentPath)
            minLevel = level
            if level != nil {
                writer.ensureCurrentFile()
            }
            configured = true
        }
    }

    /// 仅供测试：重置到未配置状态（测试间隔离）。
    public func resetForTesting() {
        queue.sync {
            writer.close()
            minLevel = nil
            configured = false
            writer = LogWriter()
        }
    }

    // MARK: - 日志 API（契约 C3）

    public func debug(_ msg: String, subsystem: String, meta: [String: Any]? = nil) {
        log(.debug, msg: msg, subsystem: subsystem, meta: meta)
    }

    public func info(_ msg: String, subsystem: String, meta: [String: Any]? = nil) {
        log(.info, msg: msg, subsystem: subsystem, meta: meta)
    }

    public func warn(_ msg: String, subsystem: String, meta: [String: Any]? = nil) {
        log(.warn, msg: msg, subsystem: subsystem, meta: meta)
    }

    public func error(_ msg: String, subsystem: String, meta: [String: Any]? = nil) {
        log(.error, msg: msg, subsystem: subsystem, meta: meta)
    }

    // MARK: - 核心

    private func log(_ level: LogLevel, msg: String, subsystem: String, meta: [String: Any]?) {
        // 级别过滤（双检：未配置或 off 则不写）
        guard let min = minLevel, level >= min else { return }
        // 串行队列保护文件 IO（异步，不阻塞调用方超过 dispatch 开销）
        queue.async {
            self.writer.append(level: level, subsystem: subsystem, msg: msg, meta: meta)
        }
    }

    // MARK: - 仅测试用查询

    /// 仅供测试：当前最小级别。
    var _currentMinLevel: LogLevel? {
        queue.sync { minLevel }
    }

    /// 仅供测试：同步 flush（等待队列里所有待写落盘）。
    func _syncFlush() {
        queue.sync { /* 空操作，借 sync 屏障排空队列 */ }
    }
}
