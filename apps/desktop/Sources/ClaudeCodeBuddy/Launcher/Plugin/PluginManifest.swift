import Foundation

struct PluginManifest: Codable, Equatable {
    let name: String
    let version: String
    let description: String
    let keywords: [String]
    let timeout: Int?
    let modeConfig: PluginModeConfig
}

enum PluginModeConfig: Equatable {
    case stdin(StdinConfig)
    case prompt(PromptConfig)
    // 注意：故意不声明 Codable，由 PluginManifest 自定义 init/encode 负责序列化
    // （enum 关联值的 Codable 自动合成会要求特定 case 格式，加上反而引发编译错误）
}

struct StdinConfig: Codable, Equatable {
    let cmd: String
    let args: [String]  // decode 时 decodeIfPresent ?? [] 容旧格式
    let env: [String: String]?
    let requiredPath: [String]?
}

struct PromptConfig: Codable, Equatable {
    let systemPrompt: String
    let maxIterations: Int
    let model: String?
    let autoCopyToClipboard: Bool
}

// MARK: - Codable

extension PluginManifest {
    enum CodingKeys: String, CodingKey {
        case name, version, description, keywords, timeout, mode
        case cmd, args, env, requiredPath
        case systemPrompt, maxIterations, model, autoCopyToClipboard
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        version = try c.decode(String.self, forKey: .version)
        description = try c.decode(String.self, forKey: .description)
        keywords = try c.decode([String].self, forKey: .keywords)
        timeout = try c.decodeIfPresent(Int.self, forKey: .timeout)

        let mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "stdin"
        switch mode {
        case "stdin":
            modeConfig = .stdin(StdinConfig(
                cmd: try c.decode(String.self, forKey: .cmd),
                args: try c.decodeIfPresent([String].self, forKey: .args) ?? [],
                env: try c.decodeIfPresent([String: String].self, forKey: .env),
                requiredPath: try c.decodeIfPresent([String].self, forKey: .requiredPath)
            ))
        case "prompt":
            modeConfig = .prompt(PromptConfig(
                systemPrompt: try c.decode(String.self, forKey: .systemPrompt),
                maxIterations: try c.decodeIfPresent(Int.self, forKey: .maxIterations) ?? 1,
                model: try c.decodeIfPresent(String.self, forKey: .model),
                autoCopyToClipboard: try c.decodeIfPresent(Bool.self, forKey: .autoCopyToClipboard) ?? false
            ))
        default:
            throw LauncherError.pluginManifestInvalid("unknown mode: \(mode)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(version, forKey: .version)
        try c.encode(description, forKey: .description)
        try c.encode(keywords, forKey: .keywords)
        try c.encodeIfPresent(timeout, forKey: .timeout)
        switch modeConfig {
        case .stdin(let cfg):
            try c.encode("stdin", forKey: .mode)
            try c.encode(cfg.cmd, forKey: .cmd)
            try c.encode(cfg.args, forKey: .args)
            try c.encodeIfPresent(cfg.env, forKey: .env)
            try c.encodeIfPresent(cfg.requiredPath, forKey: .requiredPath)
        case .prompt(let cfg):
            try c.encode("prompt", forKey: .mode)
            try c.encode(cfg.systemPrompt, forKey: .systemPrompt)
            try c.encode(cfg.maxIterations, forKey: .maxIterations)
            try c.encodeIfPresent(cfg.model, forKey: .model)
            try c.encode(cfg.autoCopyToClipboard, forKey: .autoCopyToClipboard)
        }
    }
}

// MARK: - Validation (mode-aware)

extension PluginManifest {
    func validate(againstDirName dirName: String) throws {
        let dirNameLastSegment = dirName.split(separator: "-").last.map(String.init) ?? dirName
        guard name == dirName || name == dirNameLastSegment else {
            throw LauncherError.pluginManifestInvalid("name '\(name)' 与目录名 '\(dirName)' 不一致")
        }
        if let t = timeout {
            guard t >= 1, t <= LauncherConstants.pluginMaxTimeoutSec else {
                throw LauncherError.pluginManifestInvalid("timeout \(t) 必须在 [1, \(LauncherConstants.pluginMaxTimeoutSec)]")
            }
        }
        switch modeConfig {
        case .stdin(let cfg):
            guard !cfg.cmd.hasPrefix("/") else {
                throw LauncherError.pluginManifestInvalid("cmd '\(cfg.cmd)' 不能是绝对路径")
            }
            guard !cfg.cmd.contains("/.."), !cfg.cmd.contains("../") else {
                throw LauncherError.pluginManifestInvalid("cmd '\(cfg.cmd)' 不能包含 ..")
            }
            if let paths = cfg.requiredPath, paths.count > LauncherConstants.pluginRequiredPathMaxCount {
                throw LauncherError.pluginManifestInvalid(
                    "requiredPath 数组长度 \(paths.count) 超过上限 \(LauncherConstants.pluginRequiredPathMaxCount)"
                )
            }
        case .prompt(let cfg):
            guard !cfg.systemPrompt.isEmpty else {
                throw LauncherError.pluginManifestInvalid("prompt mode 的 systemPrompt 不能为空")
            }
            guard cfg.systemPrompt.utf8.count <= LauncherConstants.promptMaxSystemPromptBytes else {
                throw LauncherError.pluginManifestInvalid(
                    "systemPrompt 超过 \(LauncherConstants.promptMaxSystemPromptBytes) 字节"
                )
            }
            guard cfg.maxIterations >= 1, cfg.maxIterations <= LauncherConstants.promptMaxIterations else {
                throw LauncherError.pluginManifestInvalid(
                    "maxIterations 必须在 [1, \(LauncherConstants.promptMaxIterations)]"
                )
            }
        }
    }

    var effectiveTimeout: Int { timeout ?? LauncherConstants.pluginDefaultTimeoutSec }
}

// MARK: - Back-compat accessors（task 003/005 完成后逐步淘汰）

extension PluginManifest {
    /// 仅 stdin mode 返回非 nil
    var stdinConfig: StdinConfig? {
        if case .stdin(let c) = modeConfig { return c }
        return nil
    }
    /// 仅 prompt mode 返回非 nil
    var promptConfig: PromptConfig? {
        if case .prompt(let c) = modeConfig { return c }
        return nil
    }

    // ⚠️ 现有消费者 back-compat（stdin 时正常，prompt 时空值兜底）
    // ⚠️ prompt mode 时 .cmd == "" 是已知临时状态（task 003 修复 inspect/trust 路径前）
    // ⚠️ 勿用 accessor 做 mode 判断！应用 `stdinConfig != nil` 或 switch `modeConfig`
    // ⚠️ 已知问题：BuddyCLI/main.swift:1167-1168 的 cliComputeTrustKey 会对 prompt mode
    //    的 manifest.cmd="" 计算错误 trust key —— 由 task 003 修复
    var cmd: String { stdinConfig?.cmd ?? "" }
    var args: [String] { stdinConfig?.args ?? [] }
    var env: [String: String]? { stdinConfig?.env }
    var requiredPath: [String]? { stdinConfig?.requiredPath }
}

// MARK: - 便利 init（兼容旧调用方式，仅供测试使用）

extension PluginManifest {
    init(
        name: String,
        version: String,
        description: String,
        keywords: [String],
        cmd: String,
        args: [String] = [],
        env: [String: String]? = nil,
        timeout: Int? = nil,
        requiredPath: [String]? = nil
    ) {
        self.name = name
        self.version = version
        self.description = description
        self.keywords = keywords
        self.timeout = timeout
        self.modeConfig = .stdin(StdinConfig(cmd: cmd, args: args, env: env, requiredPath: requiredPath))
    }
}
