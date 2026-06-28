import Foundation

/// Provider 工厂：根据 ProviderConfig + SecretStore 创建对应 Provider 实例
enum ProviderFactory {

    static func create(_ config: ProviderConfig, store: SecretStore) throws -> LauncherProvider {
        guard let apiKey = try store.load(key: config.keyRef) else {
            BuddyLogger.shared.warn("provider factory: API key missing", subsystem: "launcher", meta: ["keyRef": config.keyRef])
            throw LauncherError.invalidAPIKey("missing")
        }
        guard apiKey.count >= LauncherConstants.minAPIKeyLength else {
            BuddyLogger.shared.warn("provider factory: API key too short", subsystem: "launcher", meta: ["keyRef": config.keyRef, "keyLen": apiKey.count])
            throw LauncherError.invalidAPIKey("too short")
        }

        switch config.kind {
        case "anthropic":
            BuddyLogger.shared.info("provider created", subsystem: "launcher", meta: ["kind": "anthropic", "keyRef": config.keyRef])
            return AnthropicProvider(apiKey: apiKey)
        case "openai-compatible":
            guard let urlStr = config.baseURL,
                  let url = URL(string: urlStr),
                  url.scheme == "http" || url.scheme == "https" else {
                throw LauncherError.providerNotConfigured
            }
            BuddyLogger.shared.info("provider created", subsystem: "launcher", meta: ["kind": "openai-compatible", "baseURL": urlStr, "keyRef": config.keyRef])
            return OpenAICompatibleProvider(
                apiKey: apiKey,
                baseURL: url,
                noThinking: config.noThinking ?? false
            )
        default:
            BuddyLogger.shared.error("provider factory: unsupported kind", subsystem: "launcher", meta: ["kind": config.kind])
            throw LauncherError.providerNotConfigured
        }
    }
}
