/// 内置插件注册表（C10 契约）。
/// 聚合所有注册的 BuiltinPlugin 候选，按跨 plugin 仲裁算法合并排序截断。
///
/// C10 仲裁算法：
/// 1. 对每个 plugin 调 actions(for:)，得到已按内部 score 降序的候选组。
/// 2. 全局排序键 = (plugin.priority 降序, action.score 降序, action.title 字典序)。
/// 3. 全局截断到 builtinActionsLimit（默认 8）。
/// 4. 不硬抑制任何 plugin（多 plugin 命中时高 priority 组在上，互不淹没）。
@MainActor
final class BuiltinPluginRegistry {

    static let shared = BuiltinPluginRegistry()

    /// 注册的插件列表（可测试注入）
    private(set) var plugins: [any BuiltinPlugin]

    /// 测试用：可覆盖全局上限
    var limitOverride: Int?

    init(plugins: [any BuiltinPlugin]? = nil) {
        self.plugins = plugins ?? [AppLauncherPlugin.shared]
    }

    // MARK: - 聚合仲裁（C10）

    /// 聚合并仲裁所有内置插件候选。
    func actions(for query: String) async -> [LauncherAction] {
        guard !query.isEmpty else { return [] }

        // 按 priority 降序遍历（高 priority 先查询，保持原有顺序语义）
        let sortedPlugins = plugins.sorted { $0.priority > $1.priority }

        // 收集每个 plugin 的候选（含 plugin priority，用于后续排序）
        struct ScoredAction {
            let action: LauncherAction
            let pluginPriority: Int
        }

        var allActions: [ScoredAction] = []
        for plugin in sortedPlugins {
            let acts = await plugin.actions(for: query)
            for action in acts {
                allActions.append(ScoredAction(action: action, pluginPriority: plugin.priority))
            }
        }

        // C10 全局排序：(plugin.priority 降序, action.score 降序, action.title 字典序)
        allActions.sort { lhs, rhs in
            if lhs.pluginPriority != rhs.pluginPriority {
                return lhs.pluginPriority > rhs.pluginPriority
            }
            if lhs.action.score != rhs.action.score {
                return lhs.action.score > rhs.action.score
            }
            return lhs.action.title < rhs.action.title
        }

        let limit = limitOverride ?? LauncherConstants.builtinActionsLimit
        return Array(allActions.prefix(limit).map(\.action))
    }

    // MARK: - 注册管理

    /// 注册新插件（用于测试 / 未来扩展）
    func register(_ plugin: any BuiltinPlugin) {
        plugins.append(plugin)
    }

    /// 清空所有插件（用于测试）
    func reset(to plugins: [any BuiltinPlugin]? = nil) {
        self.plugins = plugins ?? [AppLauncherPlugin.shared]
    }
}
