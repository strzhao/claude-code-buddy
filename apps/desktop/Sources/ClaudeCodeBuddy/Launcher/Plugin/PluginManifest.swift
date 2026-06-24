import Foundation

struct PluginManifest: Codable, Equatable {
    let name: String
    let version: String
    let description: String
    /// C1：一句话人话摘要（可选）。展示层经 `displaySummary` 降级，永不拿到空值。
    /// 加载层不拒绝无 summary 的插件（向后兼容，不破坏用户现有插件）。
    let summary: String?
    let keywords: [String]
    let timeout: Int?
    let modeConfig: PluginModeConfig
}

enum PluginModeConfig: Equatable {
    case stdin(StdinConfig)
    case prompt(PromptConfig)
    case command(CommandConfig)
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

/// command mode：零 LLM、bypass agent loop，子进程直接产出（含可选图片通道）。
/// 与 StdinConfig 同构（cmd/args/env/requiredPath），复用 cmd 路径校验。
struct CommandConfig: Codable, Equatable {
    let cmd: String
    let args: [String]              // decode 时 decodeIfPresent ?? [] 容旧格式
    let env: [String: String]?
    let requiredPath: [String]?
}

// MARK: - Codable

extension PluginManifest {
    enum CodingKeys: String, CodingKey {
        case name, version, description, summary, keywords, timeout, mode
        case cmd, args, env, requiredPath
        case systemPrompt, maxIterations, model, autoCopyToClipboard
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        version = try c.decode(String.self, forKey: .version)
        description = try c.decode(String.self, forKey: .description)
        // C1：summary 可选，缺失返回 nil（向后兼容旧 plugin.json）
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        keywords = try c.decodeIfPresent([String].self, forKey: .keywords) ?? []
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
        case "command":
            modeConfig = .command(CommandConfig(
                cmd: try c.decode(String.self, forKey: .cmd),
                args: try c.decodeIfPresent([String].self, forKey: .args) ?? [],
                env: try c.decodeIfPresent([String: String].self, forKey: .env),
                requiredPath: try c.decodeIfPresent([String].self, forKey: .requiredPath)
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
        try c.encodeIfPresent(summary, forKey: .summary)
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
        case .command(let cfg):
            try c.encode("command", forKey: .mode)
            try c.encode(cfg.cmd, forKey: .cmd)
            try c.encode(cfg.args, forKey: .args)
            try c.encodeIfPresent(cfg.env, forKey: .env)
            try c.encodeIfPresent(cfg.requiredPath, forKey: .requiredPath)
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
        case .command(let cfg):
            // 复用 stdin cmd 校验（禁绝对路径 / ..，参考 patterns/2026-05-26-plugin-manifest-validation-path-traversal）
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
        }
    }

    var effectiveTimeout: Int { timeout ?? LauncherConstants.pluginDefaultTimeoutSec }
}

// MARK: - C1 displaySummary 降级（SOURCE OF TRUTH: PluginManifest.displaySummary）
extension PluginManifest {
    /// 展示用 summary 取值优先级（C1 契约）：
    /// 1. `summary` 非空（trim 后）→ 用 summary
    /// 2. 否则取 `description` 首句（按中文句号 `。` / 英文句号 `.` / 换行切第一段，trim）
    /// 3. 都空 → 用 `name`
    /// **展示层永远拿到非空 summary**。CLI mirror `cliDisplaySummary`（main.swift）须与此同语义（C5 双绑）。
    var displaySummary: String {
        if let s = summary?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            return s
        }
        let descFirst = firstSentence(of: description)
        if !descFirst.isEmpty { return descFirst }
        return name
    }

    /// 取字符串首句：按 `。`/`.`/换行切第一段并 trim。
    /// 与 CLI mirror `cliFirstSentence` 同切分语义（C5）。
    private func firstSentence(of text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        // 按首次出现的分隔符切第一段
        var cutIndex: String.Index?
        for sep in ["。", "\n", ". "] {
            if let range = trimmed.range(of: sep) {
                if let existing = cutIndex {
                    if range.lowerBound < existing { cutIndex = range.lowerBound }
                } else {
                    cutIndex = range.lowerBound
                }
            }
        }
        // 单字符句号 "." 仅在它后跟空格/换行/结尾时算句末（避免切 "3.14" 这类小数）；
        // 上面已处理 ". "（带空格），这里处理句末单独 "." 的情况
        if trimmed.hasSuffix(".") {
            let suffixIdx = trimmed.index(before: trimmed.endIndex)
            if let existing = cutIndex {
                if suffixIdx < existing { cutIndex = suffixIdx }
            } else {
                cutIndex = suffixIdx
            }
        }
        if let idx = cutIndex {
            return String(trimmed[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }
}

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
    /// 仅 command mode 返回非 nil
    var commandConfig: CommandConfig? {
        if case .command(let c) = modeConfig { return c }
        return nil
    }

    /// 便利访问 autoCopyToClipboard（prompt mode only；stdin mode 返回 false）
    var autoCopyToClipboard: Bool { promptConfig?.autoCopyToClipboard ?? false }

    // ⚠️ 现有消费者 back-compat（stdin/command 时正常，prompt 时空值兜底）
    // ⚠️ prompt mode 时 .cmd == "" 是已知临时状态（task 003 修复 inspect/trust 路径前）
    // ⚠️ 勿用 accessor 做 mode 判断！应用 `stdinConfig != nil` / `commandConfig != nil` 或 switch `modeConfig`
    // ⚠️ 已知问题：BuddyCLI/main.swift:1167-1168 的 cliComputeTrustKey 会对 prompt mode
    //    的 manifest.cmd="" 计算错误 trust key —— 由 task 003 修复
    var cmd: String { stdinConfig?.cmd ?? commandConfig?.cmd ?? "" }
    var args: [String] { stdinConfig?.args ?? commandConfig?.args ?? [] }
    var env: [String: String]? { stdinConfig?.env ?? commandConfig?.env }
    var requiredPath: [String]? { stdinConfig?.requiredPath ?? commandConfig?.requiredPath }
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
        requiredPath: [String]? = nil,
        summary: String? = nil
    ) {
        self.name = name
        self.version = version
        self.description = description
        self.summary = summary
        self.keywords = keywords
        self.timeout = timeout
        self.modeConfig = .stdin(StdinConfig(cmd: cmd, args: args, env: env, requiredPath: requiredPath))
    }
}
