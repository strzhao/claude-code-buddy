import Foundation

struct SessionInfo {
    let sessionId: String
    var label: String
    var color: SessionColor
    var cwd: String?
    var pid: Int?
    var terminalId: String?
    var state: EntityState
    var lastActivity: Date
    var toolDescription: String?
    var model: String?
    var startedAt: Date?
    var totalTokens: Int
    var toolCallCount: Int
    /// 注册表记录的进程启动时间（pid 复用防御，C-HEADLESS-CLEANUP）；CLI/调试会话为 nil
    var procStart: String?
    /// 后台任务判型状态（检测链落定后缓存，每 session 至多检测一次）
    var headlessState: HeadlessCheckState = .pending
}

/// 后台任务判型状态（C-HEADLESS-DETECT）。
/// - `pending`：检测链进行中——不上猫（防闪猫）、terminal_id 暂存不存储
/// - `headless`：`-p`/`--print` 后台任务——不上猫、只在 popover「后台任务」分组展示
/// - `interactive`：交互会话（含 fail-open）——照常上屏
enum HeadlessCheckState: Equatable, Sendable {
    case pending
    case headless
    case interactive
}

extension SessionInfo {
    /// 是否后台任务（C-POPOVER-GROUP 分组依据 / C-INSPECT-FIELD `is_headless`）
    var isHeadless: Bool { headlessState == .headless }
}
