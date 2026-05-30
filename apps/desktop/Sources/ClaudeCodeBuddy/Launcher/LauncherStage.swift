/// 启动器执行阶段枚举（task 008：执行中零反馈修复）
/// 集中表达 LauncherManager 的全部执行状态，供 UI binding 使用
enum LauncherStage: Equatable {
    case idle
    case narrowing       // keyword 缩候选（毫秒级）
    case routing         // AI 选 1 中（500ms+ 网络）
    case calling         // agent 调插件/直答中（流式开始前）
    case streaming       // 流式输出中
    case error
}
