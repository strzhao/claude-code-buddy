import Foundation

final class PluginDispatcher {
    static let shared = PluginDispatcher()
    let stdinExecutor: StdinExecutor
    let promptExecutor: PromptExecutor?

    init(stdinExecutor: StdinExecutor = .shared, promptExecutor: PromptExecutor? = nil) {
        self.stdinExecutor = stdinExecutor
        self.promptExecutor = promptExecutor
    }

    func execute(_ plugin: PluginManifest, pluginDir: URL, input: PluginInput) async throws -> PluginResult {
        switch plugin.modeConfig {
        case .stdin:
            return try await stdinExecutor.execute(plugin, pluginDir: pluginDir, input: input)
        case .command:
            // command mode 执行路径与 stdin 相同（复用 StdinExecutor，含 BUDDY_OUTPUT_IMAGE 图片通道）
            // 区别在编排层（LauncherManager）：command bypass agent loop，直接产 .image/.text
            return try await stdinExecutor.execute(plugin, pluginDir: pluginDir, input: input)
        case .prompt:
            guard let executor = promptExecutor else {
                throw LauncherError.promptExecutorNotAvailable
            }
            return try await executor.execute(plugin, pluginDir: pluginDir, input: input)
        }
    }
}
