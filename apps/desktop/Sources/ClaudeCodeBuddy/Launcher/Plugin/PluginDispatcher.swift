import Foundation

final class PluginDispatcher {
    static let shared = PluginDispatcher()
    let stdinExecutor: StdinExecutor

    init(stdinExecutor: StdinExecutor = .shared) {
        self.stdinExecutor = stdinExecutor
    }

    func execute(_ plugin: PluginManifest, pluginDir: URL, input: PluginInput) async throws -> PluginResult {
        switch plugin.modeConfig {
        case .stdin:
            return try await stdinExecutor.execute(plugin, pluginDir: pluginDir, input: input)
        case .prompt:
            throw LauncherError.promptExecutorNotAvailable
        }
    }
}
