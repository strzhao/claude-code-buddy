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

        let workTask = Task { () throws -> AgentResponse in
            try await provider.send(messages: messages, tools: [], model: model, system: config.systemPrompt)
        }
        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeoutSec) * 1_000_000_000)
            workTask.cancel()
        }
        do {
            let response = try await workTask.value
            timeoutTask.cancel()
            let text = response.content.compactMap { c -> String? in
                if case .text(let s) = c { return s }
                return nil
            }.joined()
            // 注：新 plugin 均设 autoCopyToClipboard:false，此分支仅保留向后兼容
            if config.autoCopyToClipboard && !text.isEmpty {
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                // D2: 移除 "_(已复制到剪贴板)_" marker
                return PluginResult(
                    stdout: text,
                    stderr: "",
                    exitCode: 0,
                    durationMs: Int(Date().timeIntervalSince(started) * 1000),
                    stdoutTruncated: false
                )
            }
            return PluginResult(stdout: text, stderr: "", exitCode: 0,
                durationMs: Int(Date().timeIntervalSince(started) * 1000), stdoutTruncated: false)
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

        // 超时用 Task + cancel 模式（确保 URLSession 真正释放）
        // provider 是 class（LauncherProvider 协议 impl 均 final class），强引用，生命周期由 Task 管理，无需 capture list
        let workTask = Task { () throws -> AgentResponse in
            try await provider.send(messages: messages, tools: [], model: model, system: cfg.systemPrompt)
        }
        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeoutSec) * 1_000_000_000)
            workTask.cancel()
        }
        do {
            let response = try await workTask.value
            timeoutTask.cancel()
            let text = response.content.compactMap { c -> String? in
                if case .text(let s) = c { return s }
                return nil
            }.joined()

            // 成功译文非空时，根据 autoCopyToClipboard 决定是否复制到剪贴板
            // 注：新 plugin 均设 autoCopyToClipboard:false，此分支仅保留向后兼容
            if cfg.autoCopyToClipboard && !text.isEmpty {
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                // D2: 移除 "_(已复制到剪贴板)_" marker（改用 📋 ActionButton 替代）
                return PluginResult(
                    stdout: text,
                    stderr: "",
                    exitCode: 0,
                    durationMs: Int(Date().timeIntervalSince(started) * 1000),
                    stdoutTruncated: false
                )
            }

            return PluginResult(stdout: text, stderr: "", exitCode: 0,
                durationMs: Int(Date().timeIntervalSince(started) * 1000), stdoutTruncated: false)
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
