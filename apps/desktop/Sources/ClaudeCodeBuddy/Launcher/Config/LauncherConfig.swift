import Foundation

/// 快捷键配置
struct HotkeyConfig: Codable, Equatable {
    let key: String          // "space" / "k" / ...
    let modifiers: [String]  // ["command", "shift"]
}

/// 单个 Provider 的配置（不含密钥真值）
struct ProviderConfig: Codable, Equatable {
    let kind: String         // "anthropic" / "openai-compatible"
    let baseURL: String?
    let model: String
    let keyRef: String       // 在 SecretStore 中的 key（不含真值）
    /// 关闭 LLM thinking 模式（Qwen3 等支持 chat_template_kwargs.enable_thinking）
    let noThinking: Bool?

    /// 自定义 init 保持向后兼容（noThinking 默认 nil）
    init(kind: String, baseURL: String?, model: String, keyRef: String, noThinking: Bool? = nil) {
        self.kind = kind
        self.baseURL = baseURL
        self.model = model
        self.keyRef = keyRef
        self.noThinking = noThinking
    }
}

/// 启动器全局配置，存储于 ~/.buddy/launcher.json（0600 权限）
struct LauncherConfig: Codable, Equatable {
    var activeProvider: String                // 空表示未配置
    var providers: [String: ProviderConfig]
    var hotkey: HotkeyConfig?

    static let empty = LauncherConfig(activeProvider: "", providers: [:], hotkey: nil)

    /// 从指定路径加载配置；文件不存在或解析失败时返回 .empty
    static func load(from path: URL) throws -> LauncherConfig {
        guard FileManager.default.fileExists(atPath: path.path) else {
            return .empty
        }
        guard let data = try? Data(contentsOf: path), !data.isEmpty else {
            return .empty
        }
        return (try? JSONDecoder().decode(LauncherConfig.self, from: data)) ?? .empty
    }

    /// 从 ~/.buddy/launcher.json 加载配置；文件不存在或解析失败时返回 .empty
    static func load() throws -> LauncherConfig {
        return try load(from: LauncherConstants.launcherConfigPath)
    }

    /// 写入指定路径，权限 0600
    func save(to path: URL) throws {
        let parentDir = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parentDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: path, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: path.path
        )
    }

    /// 写入 ~/.buddy/launcher.json，权限 0600
    func save() throws {
        try save(to: LauncherConstants.launcherConfigPath)
    }
}
