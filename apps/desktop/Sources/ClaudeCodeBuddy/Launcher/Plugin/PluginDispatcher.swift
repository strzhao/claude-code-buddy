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
        case .prompt:
            guard let executor = promptExecutor else {
                throw LauncherError.promptExecutorNotAvailable
            }
            return try await executor.execute(plugin, pluginDir: pluginDir, input: input)
        }
    }
}
