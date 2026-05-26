import Foundation
import CryptoKit
import IOKit

/// 加密文件-backed SecretStore（CryptoKit ChaChaPoly + IOPlatformUUID 派生密钥）
/// 文件路径：~/.buddy/launcher-secrets.enc（0600 权限）
final class EncryptedFileSecretStore: SecretStore {
    private let path: URL
    private let key: SymmetricKey
    private var cache: [String: String]

    init(path: URL = LauncherConstants.encryptedSecretsPath, key: SymmetricKey, cache: [String: String]) {
        self.path = path
        self.key = key
        self.cache = cache
    }

    /// 工厂方法：注入路径（供测试使用）
    static func makeOrLoad(path: URL) throws -> EncryptedFileSecretStore {
        let symKey = try deriveKey()
        let cache: [String: String]
        if FileManager.default.fileExists(atPath: path.path) {
            let encrypted = try Data(contentsOf: path)
            let sealed = try ChaChaPoly.SealedBox(combined: encrypted)
            let decrypted = try ChaChaPoly.open(sealed, using: symKey)
            cache = try JSONDecoder().decode([String: String].self, from: decrypted)
        } else {
            cache = [:]
        }
        return EncryptedFileSecretStore(path: path, key: symKey, cache: cache)
    }

    /// 工厂方法：注入目录（供测试使用），文件名固定为 launcher-secrets.enc
    static func makeOrLoad(directory: URL) throws -> EncryptedFileSecretStore {
        let path = directory.appendingPathComponent("launcher-secrets.enc")
        return try makeOrLoad(path: path)
    }

    /// 工厂方法：使用默认路径 ~/.buddy/launcher-secrets.enc
    static func makeOrLoad() throws -> EncryptedFileSecretStore {
        return try makeOrLoad(path: LauncherConstants.encryptedSecretsPath)
    }

    /// 派生密钥：IOPlatformUUID + 固定 salt → SHA256 → SymmetricKey（32 bytes）
    static func deriveKey() throws -> SymmetricKey {
        let uuid = try ioPlatformUUID()
        let salt = "claude-code-buddy.launcher.v1"
        let material = Data((uuid + salt).utf8)
        let hash = SHA256.hash(data: material)
        return SymmetricKey(data: Data(hash))
    }

    /// 获取 IOPlatformUUID（macOS 机器标识符）
    private static func ioPlatformUUID() throws -> String {
        let platformExpert = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        defer { IOObjectRelease(platformExpert) }
        guard let cfValue = IORegistryEntryCreateCFProperty(
            platformExpert,
            kIOPlatformUUIDKey as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue(),
              let uuid = cfValue as? String else {
            throw LauncherError.secretStoreUnavailable
        }
        return uuid
    }

    func save(key: String, value: String) throws {
        cache[key] = value
        try persist()
    }

    func load(key: String) throws -> String? {
        return cache[key]
    }

    func delete(key: String) throws {
        cache.removeValue(forKey: key)
        try persist()
    }

    private func persist() throws {
        let parentDir = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parentDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let plaintext = try JSONEncoder().encode(cache)
        let sealed = try ChaChaPoly.seal(plaintext, using: key)
        try sealed.combined.write(to: path, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: path.path
        )
    }
}
