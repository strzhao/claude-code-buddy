import AppKit

/// 内置 App 启动插件（C1 BuiltinPlugin 实现）。
/// 通过 AppIndex 内存索引 + AppMatcher fuzzy 搜索 → 生成 LauncherAction 候选。
/// @MainActor：live 管线全程主线程。
@MainActor
final class AppLauncherPlugin: BuiltinPlugin {

    static let shared = AppLauncherPlugin()

    // MARK: - BuiltinPlugin 契约

    let id = "app-launcher"
    let priority: Int = 0
    let sectionTitle = "应用"

    // MARK: - 依赖（可注入，用于测试）

    var index: AppIndex
    var launcher: AppLaunching

    /// 测试注入用 init（不使用默认参数引用 @MainActor 属性，避免 Swift 6 警告）
    init(index: AppIndex? = nil, launcher: AppLaunching? = nil) {
        self.index = index ?? AppIndex.shared
        self.launcher = launcher ?? NSWorkspaceAppLauncher()
    }

    // MARK: - actions(for:)

    /// C4 契约：空 query → []；否则 refreshIfStale + search → map 成 LauncherAction
    func actions(for query: String) async -> [LauncherAction] {
        guard !query.isEmpty else { return [] }

        // 后台刷新（fire-and-forget，不阻塞本次）
        index.refreshIfStale(ttl: LauncherConstants.appIndexTTLSec)

        let entries = index.search(query, limit: LauncherConstants.appSearchLimit)

        return entries.map { entry in
            let url = entry.url
            let name = entry.name
            let launcher = self.launcher

            // 副标题：父目录名（如 "Applications"）
            let parentName = url.deletingLastPathComponent().lastPathComponent

            // 图标：NSWorkspace.shared.icon(forFile:)（主线程，cheap）
            let icon = NSWorkspace.shared.icon(forFile: url.path)

            // 打分（用于 Registry 排序）
            let score = AppMatcher.score(query: query, name: name)

            return LauncherAction(
                id: url.path,
                title: name,
                subtitle: parentName,
                icon: icon,
                pluginId: self.id,
                score: score,
                perform: {
                    try launcher.launch(url)
                }
            )
        }
    }
}
