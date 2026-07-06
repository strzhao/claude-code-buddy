import AppKit

// MARK: - AIToolItem

/// AI 工具列表的只读数据模型（T6 重构，2026-07-02）。
///
/// 弃用旧 `toolItems: [String]` + NSTableView 文本展示，改为人话化分组数据模型：
/// - `symbol`：SF Symbol 或 emoji 图标（如 "🔊.sfsymbol" / "🔊"）
/// - `title`：功能名（如「朗读回复」）
/// - `summary`：一句话说明（人话，禁 stdin/command/prompt mode 黑话）
/// - `source`：来源徽标（「内置」/ 插件 name）
///
/// 契约 C4：本轮工具列表仅展示，不增编辑/开关/启用能力（只读）。
struct AIToolItem {
    let symbol: String
    let title: String
    let summary: String
    let source: String
}

// MARK: - AIToolItem 黑话检测（AC-TOOLS-NO-JARGON）

extension AIToolItem {

    /// 工具列表文案禁用的内部黑话词（AC-TOOLS-NO-JARGON 守护）。
    /// 命中任一词即违反「人话化」契约。
    static let forbiddenJargon: [String] = [
        "stdin", "stdout", "command", "prompt", "mode",
        "attach_action", "chat_template_kwargs",
    ]

    /// 检查本项的 title/summary/source 是否含禁用黑话。
    /// - Returns: 命中的黑话词（空数组表示合规）。
    func jargonHits() -> [String] {
        let combined = "\(title) \(summary) \(source)".lowercased()
        return Self.forbiddenJargon.filter { combined.contains($0.lowercased()) }
    }
}
