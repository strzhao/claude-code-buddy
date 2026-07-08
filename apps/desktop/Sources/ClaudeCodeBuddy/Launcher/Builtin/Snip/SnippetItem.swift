import Foundation

// MARK: - SnippetItem
//
// 片段库数据模型（snip GUI 化用，对齐 buddy-official-plugins/plugins/snip/lib/snippets.sh C9）。
//
// 契约 C2（state.md ## 契约规约）：
//   - 顶级 JSON 是 `[SnippetItem]` 数组（非 `{items:[]}` 包装，对齐 snippets.sh）
//   - 时间戳 **ISO8601 字符串**（"YYYY-MM-DDTHH:MM:SSZ"，非 Unix 秒，对齐 snippets.sh `date -u +%Y-%m-%dT%H:%M:%SZ`）
//   - created_at/updated_at `decodeIfPresent`（向后兼容旧版无时间戳，AC-SNIPGUI-24）
//
// Identifiable.id = keyword（唯一键，校验白名单保证不重复）。
struct SnippetItem: Codable, Identifiable, Equatable, Hashable {
    var keyword: String
    var content: String
    /// ISO8601 字符串（对齐 snippets.sh `date -u +%Y-%m-%dT%H:%M:%SZ`）。decodeIfPresent 向后兼容。
    var created_at: String?
    /// ISO8601 字符串。decodeIfPresent 向后兼容。
    var updated_at: String?

    /// Identifiable 唯一键 = keyword（C2：keyword 唯一，校验保证）。
    var id: String { keyword }

    enum CodingKeys: String, CodingKey {
        case keyword, content
        case created_at, updated_at
    }

    init(keyword: String, content: String, created_at: String? = nil, updated_at: String? = nil) {
        self.keyword = keyword
        self.content = content
        self.created_at = created_at
        self.updated_at = updated_at
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keyword = try c.decode(String.self, forKey: .keyword)
        content = try c.decode(String.self, forKey: .content)
        // 向后兼容旧版无时间戳（AC-SNIPGUI-24）
        created_at = try c.decodeIfPresent(String.self, forKey: .created_at)
        updated_at = try c.decodeIfPresent(String.self, forKey: .updated_at)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(keyword, forKey: .keyword)
        try c.encode(content, forKey: .content)
        // nil 时省略（保持与 legacy 产物一致，对齐 snippets.sh 缺字段场景）
        try c.encodeIfPresent(created_at, forKey: .created_at)
        try c.encodeIfPresent(updated_at, forKey: .updated_at)
    }
}
