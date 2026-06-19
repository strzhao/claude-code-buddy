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

    /// trust check 入口：已信任直接返回 true；首次执行弹 NSAlert 确认。
    /// 返回 true = 允许执行；false = 用户拒绝
    /// **必须在 @MainActor**（NSAlert 需主线程）
    @MainActor
    func checkAndPrompt(_ plugin: PluginManifest, executablePath: URL) async -> Bool {
        if isTrusted(plugin, executablePath: executablePath) { return true }
        let approved = await TrustPrompt.askUser(plugin: plugin, executablePath: executablePath)
        guard approved else { return false }
        try? approve(plugin, executablePath: executablePath)
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
