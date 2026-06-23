import AppKit
import Foundation

final class PromptExecutor {
    let provider: LauncherProvider
    let activeProviderModel: String
    let pasteboard: NSPasteboard

    init(provider: LauncherProvider, activeProviderModel: String, pasteboard: NSPasteboard = .general) {
        self.provider = provider
        self.activeProviderModel = activeProviderModel
        self.pasteboard = pasteboard
    }

    /// 便利重载：直接传 query + config（供测试隔离使用）
    func execute(query: String, config: PromptConfig) async throws -> PluginResult {
        let started = Date()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return PluginResult(stdout: "（请输入内容）", stderr: "",
                                exitCode: 0, durationMs: Int(Date().timeIntervalSince(started) * 1000), stdoutTruncated: false)
        }
        let model = config.model ?? activeProviderModel
        let messages = [AgentMessage(role: "user", content: [.text(query)])]
        let timeoutSec = LauncherConstants.pluginDefaultTimeoutSec

        // P1：走 sendStream（累积 chunks → PluginResult）
        // 注入框架 meta tools：模型可声明 attach_action 按钮（render-only，由 .action chunk 回传）
        let workTask = Task { () throws -> (String, [LauncherActionButton]) in
            let stream = try await self.provider.sendStream(
                messages: messages, tools: MetaTools.all, model: model, system: config.systemPrompt
            )
            var accumulated = ""
            var actions: [LauncherActionButton] = []
            for try await chunk in stream {
                switch chunk {
                case .text(let s):
                    accumulated += s
                case .action(let button):
                    actions.append(button)
                case .done:
                    break
                }
            }
            return (accumulated, actions)
        }
        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeoutSec) * 1_000_000_000)
            workTask.cancel()
        }
        do {
            let (text, actions) = try await workTask.value
            timeoutTask.cancel()
            let durationMs = Int(Date().timeIntervalSince(started) * 1000)
            NSLog("[Translate] llm_durationMs=\(durationMs)")
            // 注：新 plugin 均设 autoCopyToClipboard:false，此分支仅保留向后兼容
            if config.autoCopyToClipboard && !text.isEmpty {
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                // D2: 移除 "_(已复制到剪贴板)_" marker
                return PluginResult(
                    stdout: text,
                    stderr: "",
                    exitCode: 0,
                    durationMs: durationMs,
                    stdoutTruncated: false,
                    actions: actions
                )
            }
            return PluginResult(stdout: text, stderr: "", exitCode: 0,
                                durationMs: durationMs, stdoutTruncated: false, actions: actions)
        } catch is CancellationError {
            return PluginResult(stdout: "", stderr: "执行超时（\(timeoutSec)s）",
                                exitCode: 1, durationMs: Int(Date().timeIntervalSince(started) * 1000), stdoutTruncated: false)
        } catch {
            timeoutTask.cancel()
            return PluginResult(stdout: "", stderr: "执行失败: \(error.localizedDescription)",
                                exitCode: 1, durationMs: Int(Date().timeIntervalSince(started) * 1000), stdoutTruncated: false)
        }
    }

    func execute(_ plugin: PluginManifest, pluginDir: URL, input: PluginInput) async throws -> PluginResult {
        guard case .prompt(let cfg) = plugin.modeConfig else {
            throw LauncherError.promptExecutorNotAvailable
        }
        let started = Date()
        let query = input.query
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return PluginResult(stdout: "（请输入内容）", stderr: "",
                                exitCode: 0, durationMs: Int(Date().timeIntervalSince(started) * 1000), stdoutTruncated: false)
        }
        let model = cfg.model ?? activeProviderModel
        let messages = [AgentMessage(role: "user", content: [.text(query)])]
        let timeoutSec = plugin.effectiveTimeout

        // P1：走 sendStream（累积 chunks → PluginResult）
        // 超时用 Task + cancel 模式（确保 URLSession 真正释放）
        // 注入框架 meta tools：模型可声明 attach_action 按钮（render-only）
        let workTask = Task { () throws -> (String, [LauncherActionButton]) in
            let stream = try await self.provider.sendStream(
                messages: messages, tools: MetaTools.all, model: model, system: cfg.systemPrompt
            )
            var accumulated = ""
            var actions: [LauncherActionButton] = []
            for try await chunk in stream {
                switch chunk {
                case .text(let s):
                    accumulated += s
                case .action(let button):
                    actions.append(button)
                case .done:
                    break
                }
            }
            return (accumulated, actions)
        }
        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeoutSec) * 1_000_000_000)
            workTask.cancel()
        }
        do {
            let (text, actions) = try await workTask.value
            timeoutTask.cancel()
            let durationMs = Int(Date().timeIntervalSince(started) * 1000)
            // P1 仪表：wall-clock 可在 Console.app 观察
            NSLog("[Translate] llm_durationMs=\(durationMs)")

            // 成功译文非空时，根据 autoCopyToClipboard 决定是否复制到剪贴板
            // 注：新 plugin 均设 autoCopyToClipboard:false，此分支仅保留向后兼容
            if cfg.autoCopyToClipboard && !text.isEmpty {
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                // D2: 移除 "_(已复制到剪贴板)_" marker（改用 attach_action 按钮替代）
                return PluginResult(
                    stdout: text,
                    stderr: "",
                    exitCode: 0,
                    durationMs: durationMs,
                    stdoutTruncated: false,
                    actions: actions
                )
            }

            return PluginResult(stdout: text, stderr: "", exitCode: 0,
                                durationMs: durationMs, stdoutTruncated: false, actions: actions)
        } catch is CancellationError {
            // CancellationError 分支：timeout 已 fire，不调 timeoutTask.cancel()
            return PluginResult(stdout: "", stderr: "执行超时（\(timeoutSec)s）",
                                exitCode: 1, durationMs: Int(Date().timeIntervalSince(started) * 1000), stdoutTruncated: false)
        } catch {
            // 普通 error 分支：显式 cancel timeoutTask 防泄漏
            timeoutTask.cancel()
            return PluginResult(stdout: "", stderr: "执行失败: \(error.localizedDescription)",
                                exitCode: 1, durationMs: Int(Date().timeIntervalSince(started) * 1000), stdoutTruncated: false)
        }
    }
}
