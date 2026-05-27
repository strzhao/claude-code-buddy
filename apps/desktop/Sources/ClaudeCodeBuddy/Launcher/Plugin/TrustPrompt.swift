import AppKit

// MARK: - TrustPrompt

enum TrustPrompt {
    /// 弹 NSAlert 询问用户是否信任此 plugin，**必须在 @MainActor**（NSAlert 需主线程）。
    @MainActor
    static func askUser(plugin: PluginManifest, executablePath: URL) async -> Bool {
        let alert = NSAlert()
        alert.messageText = "插件 \(plugin.name) 首次执行"
        let argsStr = plugin.args.joined(separator: " ")
        alert.informativeText = """
        \(plugin.description)

        命令: \(plugin.cmd) \(argsStr)
        路径: \(executablePath.path)

        是否允许此插件执行？
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "允许")   // .alertFirstButtonReturn
        alert.addButton(withTitle: "拒绝")   // .alertSecondButtonReturn

        // 在 LSUIElement app 中让 alert 窗口获得焦点
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        return response == .alertFirstButtonReturn
    }
}
