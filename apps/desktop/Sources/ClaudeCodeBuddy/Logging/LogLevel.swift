import Foundation

/// 日志级别枚举。
///
/// 契约 C1：级别序 debug(0) < info(1) < warn(2) < error(3)。
/// `off` 不属于运行时级别（仅作为 `BUDDY_LOG_LEVEL` 环境变量值，表示完全关闭日志），
/// 不在此枚举中建模；LogConfig 负责解析 `off` 为「禁用日志」标志。
public enum LogLevel: String, Codable, Comparable, CaseIterable {
    case debug
    case info
    case warn
    case error

    /// 数字序，用于 Comparable 与级别过滤（`--level warn` = warn 及以上）。
    public var order: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .warn: return 2
        case .error: return 3
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.order < rhs.order
    }
}
