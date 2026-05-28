import Foundation

final class PromptExecutor {
    let provider: LauncherProvider
    let activeProviderModel: String

    init(provider: LauncherProvider, activeProviderModel: String) {
        self.provider = provider
        self.activeProviderModel = activeProviderModel
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
