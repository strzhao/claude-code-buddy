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

    /// trustKey = SHA256(cmd + "\n" + args.joined("\n") + "\n" + sha256(executable_bytes) hex)
    /// 任何 cmd / args / executable 改动都会使旧信任失效
    static func trustKey(for plugin: PluginManifest, executablePath: URL) throws -> String {
        let cmdPart = plugin.cmd
        let argsPart = plugin.args.joined(separator: "\n")
        let exeData = try Data(contentsOf: executablePath)
        let exeHash = SHA256.hash(data: exeData)
        let exeHashHex = exeHash.compactMap { String(format: "%02x", $0) }.joined()
        let combined = "\(cmdPart)\n\(argsPart)\n\(exeHashHex)"
        let digest = SHA256.hash(data: Data(combined.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined()
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
