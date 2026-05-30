import AppKit

/// 内置插件直接动作（不走 LLM、不走子进程）。
/// @MainActor：live 管线全程主线程，规避 NSImage/闭包跨 actor 的 Sendable 问题。
/// C2 契约：含 id/title/subtitle/icon/pluginId/score/perform，Identifiable 身份取 id。
@MainActor
struct LauncherAction: Identifiable {
    /// 稳定标识（如 app bundle URL.path），供 SwiftUI diff + selectedIndex 定位
    let id: String
    /// 主标题（app 名）
    let title: String
    /// 副标题（如所在目录 / 类别）
    let subtitle: String?
    /// 图标（仅 Top-N 可见候选加载，NSImage cheap）
    let icon: NSImage?
    /// 来源插件 id（供 UI 分组小节）
    let pluginId: String
    /// 本 plugin 内相关度（仅同 plugin 内可比；跨 plugin 用 priority 分组）
    let score: Int
    /// 执行动作（启动 app 等）。可抛错 → 失败由 LauncherManager 捕获呈现
    let perform: () throws -> Void
}
