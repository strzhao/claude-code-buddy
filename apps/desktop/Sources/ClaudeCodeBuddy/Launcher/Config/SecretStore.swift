import Foundation

/// 可插拔密钥存储协议
protocol SecretStore {
    func save(key: String, value: String) throws
    func load(key: String) throws -> String?
    func delete(key: String) throws
}

/// 探针 + 降级工厂
/// 先试 Keychain.save("__probe__","test")，失败 fallback EncryptedFile，都失败抛 secretStoreUnavailable
enum SecretStoreFactory {

    /// 正路径：自动探针 Keychain，失败降级到默认目录的 EncryptedFile
    static func create() throws -> SecretStore {
        return try create(
            keychainProbeSuccess: nil,
            directory: LauncherConstants.buddyDir
        )
    }

    /// DI 入口（供测试注入）
    /// - keychainProbeSuccess: nil 表示真实探针；true/false 强制覆盖探针结果
    /// - directory: EncryptedFile 的存储目录（测试时注入临时目录）
    static func create(
        keychainProbeSuccess: Bool?,
        directory: URL
    ) throws -> SecretStore {
        let probeResult: Bool
        if let forced = keychainProbeSuccess {
            probeResult = forced
        } else {
            probeResult = probeKeychain(KeychainSecretStore())
        }

        if probeResult {
            return KeychainSecretStore()
        }

        // Keychain 探针失败 → 降级到 EncryptedFile
        do {
            return try EncryptedFileSecretStore.makeOrLoad(directory: directory)
        } catch {
            throw LauncherError.secretStoreUnavailable
        }
    }

    private static func probeKeychain(_ keychain: KeychainSecretStore) -> Bool {
        let probeKey = "__probe__\(UUID().uuidString)"
        do {
            try keychain.save(key: probeKey, value: "ok")
            try? keychain.delete(key: probeKey)
            return true
        } catch {
            return false
        }
    }
}
