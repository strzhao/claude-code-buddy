import Foundation
import CryptoKit

// MARK: - TrustRecord

struct TrustRecord: Codable, Equatable {
    let trustKey: String      // SHA256 hex lowercase, 64 chars
    let pluginName: String
    let approvedAt: Date
}

// MARK: - TrustStore

final class TrustStore {
    static let shared = TrustStore()

    private let file: URL

    init(file: URL = LauncherConstants.buddyDir.appendingPathComponent("launcher-trust.json")) {
        self.file = file
    }

    // MARK: - trustKey

    /// mode-aware trustKey:
    ///   stdin:    "stdin:"    + SHA256(cmd + "\n" + args.joined("\n") + "\n" + sha256(exe_bytes)_hex)
    ///   command:  "command:"  + SHA256(cmd + "\n" + args.joined("\n") + "\n" + sha256(exe_bytes)_hex)
    ///             （与 stdin 同构，仅 mode 前缀不同 —— command 零 LLM、bypass agent loop，仍需 TOFU）
    ///   prompt:   "prompt:"   + SHA256(systemPrompt + "\n" + maxIterations + "\n" + modelPart)
    ///             其中 modelPart = "0" (nil) | "1:\(model)" (非 nil)
    ///             结构性 tag 区分 nil 与字符串 "default"，避免 ?? 默认值碰撞
    /// mode 前缀防止跨 mode 伪造；任一字段变化 → trustKey 变化 → NSAlert 重弹
    static func trustKey(for plugin: PluginManifest, executablePath: URL) throws -> String {
        switch plugin.modeConfig {
        case .stdin(let cfg):
            let exeData = try Data(contentsOf: executablePath)
            let exeHashHex = SHA256.hash(data: exeData).hexString
            let argsPart = cfg.args.joined(separator: "\n")
            let combined = "\(cfg.cmd)\n\(argsPart)\n\(exeHashHex)"
            return "stdin:" + SHA256.hash(data: Data(combined.utf8)).hexString
        case .command(let cfg):
            // 与 stdin 同构：复用 cmd + args + sha256(exe_bytes) 算法，仅前缀不同
            // 引用知识库 2026-05-27-tofu-trust-key-includes-exe-bytes
            let exeData = try Data(contentsOf: executablePath)
            let exeHashHex = SHA256.hash(data: exeData).hexString
            let argsPart = cfg.args.joined(separator: "\n")
            let combined = "\(cfg.cmd)\n\(argsPart)\n\(exeHashHex)"
            return "command:" + SHA256.hash(data: Data(combined.utf8)).hexString
        case .prompt(let cfg):
            // 结构性 tag：nil → "0", 非 nil → "1:value"，避免 nil 与字符串 "default" 等碰撞
            let modelPart = cfg.model.map { "1:\($0)" } ?? "0"
            let combined = "\(cfg.systemPrompt)\n\(cfg.maxIterations)\n\(modelPart)"
            return "prompt:" + SHA256.hash(data: Data(combined.utf8)).hexString
        }
    }

    // MARK: - Public API

    func isTrusted(_ plugin: PluginManifest, executablePath: URL) -> Bool {
        guard let key = try? Self.trustKey(for: plugin, executablePath: executablePath) else {
            return false
        }
        let records = (try? loadRecords()) ?? []
        return records.contains { $0.pluginName == plugin.name && $0.trustKey == key }
    }

    /// C6：是否曾经信任过该插件（任意记录即 true，不看 exe hash）。
    ///
    /// TOFU 严格首次：首次执行弹框，信任后写入记录；后续更新（exe 变化）不再弹框。
    /// trustKey 仍记录（含 exe hash，用于审计/显示），但不用于「是否重新弹框」的判定。
    /// 官方与第三方插件走同一 codepath（C7），不区分 source —— 签名只接受 pluginName，无 source 参数。
    func isEverTrusted(_ pluginName: String) -> Bool {
        let records = (try? loadRecords()) ?? []
        return records.contains { $0.pluginName == pluginName }
    }

    func approve(_ plugin: PluginManifest, executablePath: URL) throws {
        let key = try Self.trustKey(for: plugin, executablePath: executablePath)
        var records = (try? loadRecords()) ?? []
        // 同名 plugin 旧记录覆盖（防止多条记录）
        records.removeAll { $0.pluginName == plugin.name }
        records.append(TrustRecord(trustKey: key, pluginName: plugin.name, approvedAt: Date()))
        try saveRecords(records)
    }

    func remove(pluginName: String) throws {
        var records = (try? loadRecords()) ?? []
        records.removeAll { $0.pluginName == pluginName }
        try saveRecords(records)
    }

    func list() throws -> [TrustRecord] {
        return (try? loadRecords()) ?? []
    }

    /// trust check 入口（M5 改造 + M4 弹框内修订：信任 + 依赖合并，五分支）。
    ///
    /// **真实签名不变**：`@MainActor func checkAndPrompt(_ plugin:, executablePath: URL) async -> Bool`
    /// seam 参数（missingProvider/installer/prompter/brewAvailability/brewMissingPrompter）均有默认值，
    /// 6 调用点（LauncherManager:443/615/819/920/1019 + QueryHandler:406）无需改动。
    ///
    /// M4 弹框内修订（revise，去 DependencyProgressWindow 新页面）：
    /// - installAll 触发时机移到 prompter accessoryView 内（用户点「一键安装」按钮）
    /// - checkAndPrompt 拿到 approved 后，collectMissing 再确认空（用户装完了）→ 空 approve + 执行；非空兜底 return false
    /// - installer seam 退化回直接 `installAll`（去 DependencyProgressWindow show/close 两阶段）
    /// - 「允许并运行」按钮依赖全装才 enable（按钮 disabled 防用户未装就允许；兜底 missing 非空 return false）
    ///
    /// 行为契约（state.md ## 契约规约 checkAndPrompt 行为契约）：
    /// - 放行短路：`isEverTrusted(plugin.name) && collectMissing(plugin).isEmpty` → return true（不弹）
    /// - 弹框条件：`collectMissing(plugin).isEmpty == false`（有缺失依赖，不管信任状态）→ 弹框
    /// - 首次（!trusted）：信任授权 + 依赖区（若有缺失）
    /// - 已信任（trusted && missing 非空）：依赖安装，不重复授权动作
    /// - approve 仅 `!trusted`；已信任重弹不重复写信任记录
    /// - brew 缺失 + 有 brew 依赖 → 弹引导框（M6）→ return false（不执行）
    /// - installAll 失败/cancelled/manualRequired → return false（不执行）
    ///
    /// 返回 true = 允许执行；false = 用户拒绝/依赖未就绪。
    /// **必须在 @MainActor**（NSAlert 需主线程）
    @MainActor
    func checkAndPrompt(
        _ plugin: PluginManifest,
        executablePath: URL,
        // seam：依赖缺失查询（默认 DependencyResolver.shared.collectMissing）
        missingProvider: @escaping (PluginManifest) -> [DependencyStatus] = { DependencyResolver.shared.collectMissing($0) },
        // seam：依赖安装（M4 弹框内修订：退化回直接 installAll，去 DependencyProgressWindow show/close）
        // 注：installAll 触发时机在 prompter accessoryView 内（用户点一键安装），checkAndPrompt 拿 approved 后
        //   collectMissing 再确认空；此 seam 作为兜底（approved 但 missing 非空时调一次，理论上按钮 disabled 防住）。
        installer: @escaping ([DependencyStatus]) async -> InstallResult = { missing in
            await DependencyInstaller.shared.installAll(missing)
        },
        // seam：信任+依赖弹框（默认 TrustPrompt.askUserWithDeps）
        // 参数：(plugin, exe, hasDeps, isAlreadyTrusted, missing) → Bool（true=允许）
        // M4 弹框内：prompter 内 accessoryView 一键安装按钮触发 installAll（@Published 刷新进度）
        prompter: @escaping (PluginManifest, URL, Bool, Bool, [DependencyStatus]) async -> Bool = { plugin, exe, hasDeps, isAlreadyTrusted, missing in
            await TrustPrompt.askUserWithDeps(plugin: plugin, executablePath: exe, hasDeps: hasDeps, isAlreadyTrusted: isAlreadyTrusted, missing: missing)
        },
        // seam：brew 可用性（默认 DependencyResolver.shared.brewAvailability）
        brewAvailability: @escaping () -> BrewAvailability = { DependencyResolver.shared.brewAvailability() },
        // seam：brew 缺失引导框（默认 TrustPrompt.showBrewMissingGuide）
        // 参数：missing（缺失依赖列表，供引导框展示）
        brewMissingPrompter: @escaping ([DependencyStatus]) async -> Void = { missing in
            await TrustPrompt.showBrewMissingGuide(missing: missing)
        }
    ) async -> Bool {
        let trusted = isEverTrusted(plugin.name)
        let missing = missingProvider(plugin)

        // 分支 1：放行短路（已信任 + 无缺失）→ TOFU 免打扰
        if trusted && missing.isEmpty {
            return true
        }

        // 分支 5：brew 缺失 + 有 brew 映射依赖 → 弹引导框 → return false（不执行）
        let hasBrewDep = missing.contains { $0.brewPackage != nil }
        if !missing.isEmpty && hasBrewDep && brewAvailability() == .missing {
            BuddyLogger.shared.warn("checkAndPrompt: brew missing, show guide", subsystem: "plugin", meta: ["plugin": plugin.name, "deps": missing.map(\.check)])
            await brewMissingPrompter(missing)
            return false
        }

        // 分支 2/3/4：弹框（首次纯信任 / 首次信任+依赖 / 已信任+缺失重弹）
        // M4 弹框内：prompter accessoryView 内一键安装按钮触发 installAll（@Published 刷新进度）
        let hasDeps = !missing.isEmpty
        let approved = await prompter(plugin, executablePath, hasDeps, trusted, missing)
        guard approved else { return false }

        // M4 弹框内修订：approved 后 collectMissing 再确认空（用户在弹框内装完了）
        // 「允许并运行」按钮依赖全装才 enable（按钮 disabled 防用户未装就允许），此处为兜底：
        // 若 approved 但 missing 仍非空（按钮 disabled 失效或用户绕过），调 installer seam 兜底
        if !missing.isEmpty {
            // 重新 collectMissing（用户在弹框内点一键安装后，依赖应已装好）
            let postMissing = missingProvider(plugin)
            if !postMissing.isEmpty {
                // 兜底：approved 但 missing 仍非空 → 调 installer seam（理论按钮 disabled 防住，此为安全网）
                BuddyLogger.shared.warn("checkAndPrompt: approved but missing not empty, fallback install", subsystem: "plugin", meta: ["plugin": plugin.name, "missing": postMissing.map(\.check)])
                let installResult = await installer(postMissing)
                switch installResult {
                case .success:
                    break  // 兜底装好，继续 approve
                case .partialFailure(let failed):
                    BuddyLogger.shared.warn("checkAndPrompt: install partial failure", subsystem: "plugin", meta: ["plugin": plugin.name, "failed": failed])
                    return false
                case .cancelled:
                    BuddyLogger.shared.info("checkAndPrompt: install cancelled", subsystem: "plugin", meta: ["plugin": plugin.name])
                    return false
                case .brewMissing:
                    BuddyLogger.shared.warn("checkAndPrompt: brew missing during install", subsystem: "plugin", meta: ["plugin": plugin.name])
                    return false
                case .manualRequired:
                    BuddyLogger.shared.info("checkAndPrompt: manual required (autoInstall off)", subsystem: "plugin", meta: ["plugin": plugin.name])
                    return false
                }
            }
        }

        // approve：仅 !trusted（已信任重弹不重复写信任记录）
        if !trusted {
            try? approve(plugin, executablePath: executablePath)
        }
        return true
    }

    // MARK: - Private Helpers

    private struct TrustFileSchema: Codable {
        var records: [TrustRecord]
    }

    private func loadRecords() throws -> [TrustRecord] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let data = try Data(contentsOf: file)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let schema = try decoder.decode(TrustFileSchema.self, from: data)
        return schema.records
    }

    private func saveRecords(_ records: [TrustRecord]) throws {
        let dir = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let schema = TrustFileSchema(records: records)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(schema)
        try data.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
    }
}

// MARK: - addRecord（B2 修复：必须同文件 extension 才能访问 private loadRecords/saveRecords）

extension TrustStore {
    /// 直接追加 TrustRecord（用于 MarketplaceManager.migrateLegacy 时保留旧 trustKey + approvedAt）。
    ///
    /// 同名 pluginName 旧记录覆盖（与 approve 行为一致）。
    func addRecord(_ record: TrustRecord) throws {
        var records = (try? loadRecords()) ?? []
        records.removeAll { $0.pluginName == record.pluginName }
        records.append(record)
        try saveRecords(records)
    }
}
