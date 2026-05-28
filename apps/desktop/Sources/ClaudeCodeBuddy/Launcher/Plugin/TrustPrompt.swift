import AppKit

// MARK: - TrustPrompt

enum TrustPrompt {
    /// 弹 NSAlert 询问用户是否信任此 plugin，**必须在 @MainActor**（NSAlert 需主线程）。
    /// mode-aware：stdin 显示命令/路径，prompt 显示 systemPrompt 摘要 + 模型。
    @MainActor
    static func askUser(plugin: PluginManifest, executablePath: URL) async -> Bool {
        let alert = NSAlert()
        alert.messageText = "插件 \(plugin.name) 首次执行"
        switch plugin.modeConfig {
        case .stdin(let cfg):
            let argsStr = cfg.args.joined(separator: " ")
            alert.informativeText = """
            \(plugin.description)

            模式: stdin (subprocess)
            命令: \(cfg.cmd) \(argsStr)
            路径: \(executablePath.path)

            是否允许此插件执行？
            """
        case .prompt(let cfg):
            let summary = String(cfg.systemPrompt.prefix(200))
            let truncated = cfg.systemPrompt.count > 200 ? "...（共 \(cfg.systemPrompt.count) 字符）" : ""
            let modelStr = cfg.model ?? "（用 launcher 激活的 provider 模型）"
            alert.informativeText = """
            \(plugin.description)

            模式: prompt (LLM 直接调用)
            模型: \(modelStr)

            System Prompt 摘要:
            \(summary)\(truncated)

            是否允许此插件执行？
            """
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: "允许")   // .alertFirstButtonReturn
        alert.addButton(withTitle: "拒绝")   // .alertSecondButtonReturn

        // 在 LSUIElement app 中让 alert 窗口获得焦点
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        return response == .alertFirstButtonReturn
    }
}
