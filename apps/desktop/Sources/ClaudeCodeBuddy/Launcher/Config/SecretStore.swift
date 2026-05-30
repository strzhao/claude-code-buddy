import Foundation
import Security

/// 可插拔密钥存储协议
protocol SecretStore {
    func save(key: String, value: String) throws
    func load(key: String) throws -> String?
    func delete(key: String) throws
}

/// 探针 + 降级工厂
/// 优先：ad-hoc/无 TeamID 签名 → 直接走 EncryptedFile（避免每次 rebuild Keychain ACL 提示）
/// 否则：试 Keychain.save 探针，失败 fallback EncryptedFile，都失败抛 secretStoreUnavailable
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
        // ad-hoc 签名时 SecItemAdd 永远成功（写新条目不需 ACL），
        // 但 SecItemCopyMatching 读旧签名留下的条目会触发"输入登录钥匙串密码"弹框。
        // 探针无法覆盖这条路径，所以在探针前先 inspect 当前进程签名直接绕过。
        if keychainProbeSuccess == nil && isAdHocSigned() {
            do {
                return try EncryptedFileSecretStore.makeOrLoad(directory: directory)
            } catch {
                throw LauncherError.secretStoreUnavailable
            }
        }

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

    /// 当前进程是否 ad-hoc 签名（dev/未签名 build）。
    /// 失败时保守返回 true（降级到文件，安全侧）。
    private static func isAdHocSigned() -> Bool {
        var codeRef: SecCode?
        guard SecCodeCopySelf([], &codeRef) == errSecSuccess, let code = codeRef else {
            return true
        }
        var infoCF: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        // SecCode 和 SecStaticCode 底层是同一个 CF type（C 头里两者 typedef 一致），
        // Swift 强制把它们看作不同类型，unsafeBitCast 是社区实践里的标准做法。
        let staticCode = unsafeBitCast(code, to: SecStaticCode.self)
        guard SecCodeCopySigningInformation(staticCode, flags, &infoCF) == errSecSuccess,
              let info = infoCF as? [String: Any] else {
            return true
        }
        // codesign flag 0x2 = adhoc（与 `codesign -dvvv` 输出 `flags=0x2(adhoc)` 对应）。
        // 注：dict value 是 NSNumber，直接 `as? UInt32` 会失败，必须经 NSNumber 桥接。
        if let csFlagsNum = info[kSecCodeInfoFlags as String] as? NSNumber,
           (csFlagsNum.uint32Value & 0x2) != 0 {
            return true
        }
        // 兜底：没 TeamIdentifier 也视作 ad-hoc / 未签名
        let teamID = (info[kSecCodeInfoTeamIdentifier as String] as? String) ?? ""
        return teamID.isEmpty
    }
}
