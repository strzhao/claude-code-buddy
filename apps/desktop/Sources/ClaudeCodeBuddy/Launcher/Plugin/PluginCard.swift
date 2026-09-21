import Foundation

// MARK: - PluginCard
//
// 通用卡片输出通道（BUDDY_OUTPUT_CARD）数据模型（W3，2026-09-21）。
// 机制完全仿 BUDDY_OUTPUT_IMAGE / BUDDY_OUTPUT_CANDIDATES：子进程写 JSON 文件，
// 框架 StdinExecutor.readCardOutputSafely 安全读取解码。
//
// 契约（state.md ## 契约规约 数据结构 card JSON schema）：
//   {"title": "gcli 套餐限额 · 2 个",
//    "entries": [{"name": "kimi", "level": "ok", "badge": "使用中",
//      "windows": [{"label": "5h", "percent": 12, "reset": "3h20m"}]}]}
//   - level ∈ {"ok","warn","danger"}（阈值沿用插件 level_dot：<60 / 60-85 / ≥85）
//   - percent: 0 ≤ percent ≤ 100（越界 clamp）
//   - entries 数量 ≤ 32（防御上限）
//   - name / windows[].label / windows[].percent 必填；title / badge / reset 可空
//   - 字段语义通用（无 quota 专有名词），未来插件可复用
//
// clamp/校验归属（双侧防御，安全不依赖插件自觉）：
//   - percent：Python render_card 产出前 clamp；本模型解码侧**再** clamp（第三方插件写
//     越界值时框架侧行为确定）
//   - entries > 32：解码侧截断保留前 32（防御性降级，不弃整卡）

/// 卡片条目单窗进度（label/percent 必填，reset 可空）。
struct CardWindow: Codable, Equatable {
    let label: String
    /// 0...100（解码侧 clamp，越界值收进区间）
    let percent: Int
    let reset: String?

    enum CodingKeys: String, CodingKey {
        case label, percent, reset
    }

    init(label: String, percent: Int, reset: String? = nil) {
        self.label = label
        self.percent = percent
        self.reset = reset
    }

    /// 解码侧 percent clamp（双侧防御的框架侧；缺失必填字段 → 抛错 → 整卡降级 nil）。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decode(String.self, forKey: .label)
        let raw = try c.decode(Int.self, forKey: .percent)
        percent = min(100, max(0, raw))
        reset = try c.decodeIfPresent(String.self, forKey: .reset)
    }
}

/// 卡片条目（name 必填；level/badge 可空；windows 缺失按空数组容错）。
struct CardEntry: Codable, Equatable {
    let name: String
    /// "ok" / "warn" / "danger"；未知/缺失值由 UI 按 ok 色渲染
    let level: String?
    let badge: String?
    let windows: [CardWindow]

    enum CodingKeys: String, CodingKey {
        case name, level, badge, windows
    }

    init(name: String, level: String? = nil, badge: String? = nil, windows: [CardWindow] = []) {
        self.name = name
        self.level = level
        self.badge = badge
        self.windows = windows
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        level = try c.decodeIfPresent(String.self, forKey: .level)
        badge = try c.decodeIfPresent(String.self, forKey: .badge)
        windows = try c.decodeIfPresent([CardWindow].self, forKey: .windows) ?? []
    }
}

/// 卡片根结构（title 可空；entries > maxEntries 解码侧截断保留前 maxEntries）。
struct PluginCard: Codable, Equatable {
    /// entries 防御上限（契约：≤ 32，截断不弃整卡）
    static let maxEntries = 32

    let title: String?
    let entries: [CardEntry]

    enum CodingKeys: String, CodingKey {
        case title, entries
    }

    init(title: String? = nil, entries: [CardEntry]) {
        self.title = title
        self.entries = entries
    }

    /// 解码侧 entries 截断（防御性降级：>32 保留前 32，不弃整卡）。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        let all = try c.decode([CardEntry].self, forKey: .entries)
        entries = Array(all.prefix(PluginCard.maxEntries))
    }
}
