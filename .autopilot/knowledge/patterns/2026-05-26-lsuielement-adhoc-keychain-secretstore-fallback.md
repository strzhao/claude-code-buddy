# LSUIElement app + ad-hoc 签名下 Keychain Services 不可用，必须 SecretStore 探针降级

<!-- tags: keychain, ad-hoc, codesign, lsuielement, entitlement, secret-store, cryptokit, chachapoly, secret-key, fallback, iotextservice, errSecMissingEntitlement -->
**Scenario**: claude-code-buddy 用 `codesign --force --deep -s -`（ad-hoc）签名+无 `.entitlements`，macOS 13+ 下 `SecItemAdd` 返回 `errSecMissingEntitlement(-34018)`，导致 BYOK API key 无法存 Keychain。直接报错会让用户配不上 provider；明文存文件又是安全反模式。
**Lesson**: 设计可插拔 `SecretStore` 协议 + 探针自动降级：① `KeychainSecretStore`（生产路径，开发签名应用）② `EncryptedFileSecretStore`（CryptoKit ChaChaPoly + 派生密钥加密 `~/.buddy/launcher-secrets.enc`）③ `SecretStoreFactory.create()` 启动时写一个 `__probe__\(UUID())` key 立即删除，捕获 OSStatus 自动切换。**密钥派生**用 IOPlatformUUID（`kIOMainPortDefault`，不是已废弃的 `kIOMasterPortDefault`）+ 固定 salt 做 SHA256（理想用 HKDF<SHA256>，但 IOPlatformUUID 128-bit 熵足够 MVP）。文件权限统一 0600。
**Evidence**: task 002 落地 `Launcher/Config/{SecretStore,KeychainSecretStore,EncryptedFileSecretStore}.swift`；6 个 SecretStoreFactory acceptance test 覆盖 DI 强制失败路径；真实 `buddy launcher config set` 测试通过 0600 权限验证 + Keychain entry 写入。
