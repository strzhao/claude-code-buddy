import AppKit

/// 系统命令内置插件（SC1 契约）。
/// 首批仅实现 lock（锁定屏幕）命令；结构为未来命令预留但不预写（YAGNI）。
/// @MainActor：live 管线全程主线程，规避 NSImage/闭包跨 actor 的 Sendable 问题。
@MainActor
final class SystemCommandPlugin: BuiltinPlugin {

    static let shared = SystemCommandPlugin()

    // MARK: - BuiltinPlugin 契约（SC1）

    let id = "system-command"
    let priority: Int = 100
    let sectionTitle = "系统"

    // MARK: - 执行 seam（可注入，用于测试）

    var locker: ScreenLocking

    /// 测试注入用 init（不使用默认参数引用 @MainActor 属性）
    init(locker: ScreenLocking? = nil) {
        self.locker = locker ?? LoginFrameworkScreenLocker()
    }

    // MARK: - 命令表

    /// 系统命令模型（内部结构）
    private struct SystemCommand {
        let id: String
        let title: String
        let subtitle: String
        let keywords: [String]
        let icon: NSImage?
        let run: (ScreenLocking) throws -> Void
    }

    /// 首批命令：仅 lock（锁定屏幕）
    private let commands: [SystemCommand] = [
        SystemCommand(
            id: "system.lock",
            title: "锁定屏幕",
            subtitle: "锁屏",
            keywords: ["lock", "锁屏"],
            icon: NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "锁屏"),
            run: { locker in try locker.lock() }
        )
    ]

    // MARK: - actions(for:)（SC2–SC5）

    /// 空 query → []；否则对每条命令做关键词前缀匹配（SC3：大小写不敏感）。
    /// 评分：完全匹配 1000，前缀匹配 800（SC5：确定性命中稳定置顶）。
    func actions(for query: String) async -> [LauncherAction] {
        let normalized = query.trimmingCharacters(in: .whitespaces)
        guard !normalized.isEmpty else { return [] }

        let queryLower = normalized.lowercased()

        var results: [LauncherAction] = []

        for command in commands {
            var bestScore = 0

            for keyword in command.keywords {
                let kwLower = keyword.lowercased()
                if kwLower == queryLower {
                    bestScore = max(bestScore, 1000)  // 完全匹配
                } else if kwLower.hasPrefix(queryLower) {
                    bestScore = max(bestScore, 800)   // 前缀匹配
                }
            }

            guard bestScore > 0 else { continue }

            let locker = self.locker
            let commandTitle = command.title
            let action = LauncherAction(
                id: command.id,
                title: command.title,
                subtitle: command.subtitle,
                icon: command.icon,
                pluginId: self.id,
                score: bestScore,
                perform: {
                    do {
                        try command.run(locker)
                    } catch let error as LauncherError {
                        // 已是 LauncherError，直接向上抛（如 LoginFrameworkScreenLocker 产生的）
                        throw error
                    } catch {
                        // 非 LauncherError（如 mock stub 的 NSError）统一包装为 systemCommandFailed
                        _ = error  // 忽略底层原始错误，以中文文案替代
                        throw LauncherError.systemCommandFailed(commandTitle)
                    }
                }
            )
            results.append(action)
        }

        // 按 score 降序、title 字典序排序（同 AppLauncherPlugin 风格）
        results.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.title < rhs.title
        }

        return results
    }
}
