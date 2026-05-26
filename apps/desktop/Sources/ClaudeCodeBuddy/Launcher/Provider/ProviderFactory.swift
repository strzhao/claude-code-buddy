import Foundation

/// Provider 工厂：根据 ProviderConfig + SecretStore 创建对应 Provider 实例
enum ProviderFactory {

    static func create(_ config: ProviderConfig, store: SecretStore) throws -> LauncherProvider {
        guard let apiKey = try store.load(key: config.keyRef) else {
            throw LauncherError.invalidAPIKey("missing")
        }
        guard apiKey.count >= LauncherConstants.minAPIKeyLength else {
            throw LauncherError.invalidAPIKey("too short")
        }

        switch config.kind {
        case "anthropic":
            return AnthropicProvider(apiKey: apiKey)
        case "openai-compatible":
            guard let urlStr = config.baseURL,
                  let url = URL(string: urlStr),
                  url.scheme == "http" || url.scheme == "https" else {
                throw LauncherError.providerNotConfigured
            }
            return OpenAICompatibleProvider(apiKey: apiKey, baseURL: url)
        default:
            throw LauncherError.providerNotConfigured
        }
    }
}
