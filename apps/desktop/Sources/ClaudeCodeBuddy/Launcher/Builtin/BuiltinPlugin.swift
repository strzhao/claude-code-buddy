/// 内置插件协议：原生 in-process、直接动作（不走 LLM、不走子进程）。
/// @MainActor：live 管线全程在主线程（搜索是内存级 <5ms），规避 NSImage/闭包跨 actor 的 Sendable 问题。
/// C1 契约：新增内置插件只需实现此协议并注册，零侵入 LauncherManager。
@MainActor
protocol BuiltinPlugin {
    /// 稳定唯一 id（如 "app-launcher"），用于候选来源标记与去重 / UI 分组小节
    var id: String { get }

    /// 跨 plugin 仲裁优先级（高=靠前）。解释器型（确定性命中，如 calculator）给高值，
    /// 搜索型（fuzzy，如 app）给默认值 0。决定「都命中」时的分组顺序（C10）。
    var priority: Int { get }

    /// UI 分组小节标题（≥2 个 plugin 有结果时显示，如 "应用"/"计算"）
    var sectionTitle: String { get }

    /// C2：一句话人话摘要（设置页 / debug registry 首屏展示）。非空、面向用户。
    var summary: String { get }

    /// C2：详细说明（设置页详情展开看）。面向用户的人话描述。
    var description: String { get }

    /// 给定 query 返回已按本 plugin 内部 score 降序排序的候选动作。空/无匹配 query 返回 []。
    /// async 仅为未来插件（如剪贴板/网络）预留；AppLauncherPlugin 实现是内存级即时返回。
    func actions(for query: String) async -> [LauncherAction]
}

// MARK: - C2 默认实现（测试 mock 兼容）
//
// 协议声明 `summary`/`description` 为 required，但通过 extension 提供默认值，
// 避免破坏既有测试 mock（17 处实现 BuiltinPlugin 的测试桩无需逐个补字段）。
// 生产 4 个实现各自覆盖为真实人话文案。
extension BuiltinPlugin {
    var summary: String { "" }
    var description: String { "" }
}
