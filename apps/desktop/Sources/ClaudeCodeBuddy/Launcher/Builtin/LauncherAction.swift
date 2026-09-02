import AppKit

/// 内置插件直接动作（不走 LLM、不走子进程）。
/// @MainActor：live 管线全程主线程，规避 NSImage/闭包跨 actor 的 Sendable 问题。
/// C2 契约：含 id/title/subtitle/icon/pluginId/score/perform，Identifiable 身份取 id。
/// D1（统一混排）：社区插件候选桥接为本类型（icon: nil + iconEmoji: manifest.icon）。
@MainActor
struct LauncherAction: Identifiable {
    /// 稳定标识（如 app bundle URL.path；插件候选 = "plugin:<manifest.name>"），供 SwiftUI diff + selectedIndex 定位
    let id: String
    /// 主标题（app 名 / 插件名）
    let title: String
    /// 副标题（如所在目录 / 类别 / 插件 displaySummary）
    let subtitle: String?
    /// 图标（仅 Top-N 可见候选加载，NSImage cheap；app/内置用）
    let icon: NSImage?
    /// C-ICON-FIELD / D1：emoji 图标（插件候选用，SwiftUI Text 渲染最干净）。
    /// 行渲染优先级：icon(NSImage) → iconEmoji(Text) → SF Symbol fallback。
    let iconEmoji: String?
    /// 来源插件 id（供 UI 分组小节；插件候选 == manifest.name，D4 分流据此解析 manifest）
    let pluginId: String
    /// 相关度（C-UNIFIED-SCORE 统一量纲后跨源可比）
    let score: Int
    /// 执行动作（启动 app 等）。可抛错 → 失败由 LauncherManager 捕获呈现
    let perform: () throws -> Void
}
