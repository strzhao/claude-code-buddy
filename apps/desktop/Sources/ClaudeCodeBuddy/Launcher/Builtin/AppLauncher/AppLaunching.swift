import AppKit

/// App 启动 seam 协议（C6 契约）。
/// 生产实现用 NSWorkspace，测试注入 Mock（绝不真启动 app）。
protocol AppLaunching {
    /// 启动指定 URL 的 app bundle。
    /// - Throws: `LauncherError.appLaunchFailed` 如果启动失败
    func launch(_ url: URL) throws
}

// MARK: - 生产实现

/// NSWorkspace 生产启动器（C6 契约）
struct NSWorkspaceAppLauncher: AppLaunching {
    func launch(_ url: URL) throws {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true

        // NSWorkspace.open 同步版本（不等待 completion）
        // 若 bundle 不存在/无法启动，open 返回 false 或 URL 不可达
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            throw LauncherError.appLaunchFailed(url.deletingLastPathComponent().lastPathComponent)
        }

        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            if let error = error {
                BuddyLogger.shared.error("启动 app 失败", subsystem: "builtin", meta: ["url": url.path, "error": "\(error)"])
            }
        }
    }
}
