import Foundation

/// 剪贴板历史条目类型（契约规约：4 类型，判别字段 `type`）。
///
/// 参考 .autopilot/knowledge/patterns/2026-05-29-swift-enum-polymorphic-json-codable.md：
/// 本场景 type 是简单 String-keyed enum（无 associated value），直接用合成 Codable 即可
/// round-trip；显式 rawValue 保证 JSON 稳定（防 Swift 重命名 case 导致旧持久化失效）。
enum ClipboardItemType: String, Codable {
    case text
    case image
    case file
    case html
}

/// 剪贴板历史条目模型（契约数据结构 SSOT）。
///
/// 字段语义（契约规约 ## 数据结构）：
/// - `id`: UUID 字符串，条目身份
/// - `type`: 内容类型枚举（见 ClipboardItemType）
/// - `content`: text 纯文本 / file 文件路径 / html 纯文本 fallback；image 为空字符串
/// - `html`: 仅 `.html` 类型携带原始 HTML；其他类型为 nil
/// - `imagePath`: 仅 `.image` 类型携带 `~/.buddy/clipboard-images/<sha8>.png`；其他类型为 nil
/// - `sourceApp`: NSWorkspace.frontmostApplication.bundleIdentifier（可为 nil）
/// - `ts`: Unix 秒
/// - `hash`: sha256 前 8 字符（去重键）
struct ClipboardHistoryItem: Codable, Identifiable, Equatable {
    let id: String
    let type: ClipboardItemType
    let content: String
    let html: String?
    let imagePath: String?
    let sourceApp: String?
    let ts: Int
    let hash: String

    /// 显式 CodingKeys 锁定 JSON 字段名（防持久化 schema 漂移）。
    private enum CodingKeys: String, CodingKey {
        case id, type, content, html, imagePath, sourceApp, ts, hash
    }
}
