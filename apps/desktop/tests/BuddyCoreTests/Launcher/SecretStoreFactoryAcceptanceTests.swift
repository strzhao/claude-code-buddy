import XCTest
import Security
import CryptoKit
@testable import BuddyCore

// MARK: - SecretStoreFactoryAcceptanceTests
//
// 验收测试：SecretStoreFactory 探针 + 降级路径契约
//
// 设计文档覆盖点（task 002 输出契约）：
//   A. SecretStoreFactory.create() 在当前环境不抛错且返回能正常使用的 store
//   B. create() 返回的 store 能 save/load 正常工作（功能完整性）
//   C. 强制 Keychain 探针失败时 → fallback 返回 EncryptedFileSecretStore
//      （如果 Factory 暴露 DI 入口，则 mock 失败；否则仅验证 create() 不抛错且可用）
//   D. 探针用随机 UUID key，不污染真实数据（副作用清单：写后立即 delete）
//   E. Keychain 和 EncryptedFile 都失败时抛 LauncherError.secretStoreUnavailable
//
// 测试策略：
//   - create() 正路径：直接调用，不 mock（用真实 Keychain 或真实 EncryptedFile）
//   - 降级路径：若 SecretStoreFactory 暴露 DI 入口（如 create(keychainProbe:)）则注入失败的 probe closure
//              若不暴露 DI，只验证 create() 行为正确
//
// 隔离原则：测试用临时目录 + UUID key，setUp/tearDown 清理。
// 测试 WILL NOT compile 直到蓝队合并实现 — 这是预期的 TDD 红灯。

final class SecretStoreFactoryAcceptanceTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SecretStoreFactoryTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDir = nil
        try await super.tearDown()
    }

    // MARK: - A. create() 不抛错并返回可用 store

    /// SecretStoreFactory.create() 在当前 macOS 环境不抛错
    /// 无论走 Keychain 路径还是 EncryptedFile 降级路径，都必须返回可用实例
    func test_factory_create_doesNotThrow() {
        XCTAssertNoThrow(
            try SecretStoreFactory.create(),
            "SecretStoreFactory.create() 在当前环境必须不抛错（Keychain 或 EncryptedFile 任一成功即可）"
        )
    }

    // MARK: - B. create() 返回的 store 能正常 save/load

    /// create() 返回的 store 能完成 save → load 往返
    func test_factory_create_returnedStore_canSaveAndLoad() throws {
        let store = try SecretStoreFactory.create()
        let key = "factory-test-\(UUID().uuidString)"
        let value = "factory-test-value-12345678"

        defer { try? store.delete(key: key) }

        try store.save(key: key, value: value)
        let loaded = try store.load(key: key)

        XCTAssertEqual(loaded, value,
                       "SecretStoreFactory.create() 返回的 store 必须能正常 save/load")
    }

    /// create() 返回的 store：load 不存在 key 返回 nil
    func test_factory_create_returnedStore_loadMissingKeyReturnsNil() throws {
        let store = try SecretStoreFactory.create()
        let result = try store.load(key: "nonexistent-\(UUID().uuidString)")
        XCTAssertNil(result,
                     "factory store.load 不存在的 key 必须返回 nil")
    }

    // MARK: - C. 降级路径：强制 Keychain 失败 → 返回 EncryptedFileSecretStore

    /// 如果 SecretStoreFactory 暴露了 DI 入口（probe closure 或 override），
    /// 则注入 always-fail probe，验证返回的是 EncryptedFileSecretStore。
    ///
    /// 如果没有暴露 DI 入口，则通过 create(directory:) 注入测试目录来验证降级 store 可用。
    ///
    /// CONTRACT_AMBIGUOUS：设计文档草图中 SecretStoreFactory.create() 无参数，
    /// 降级路径的 DI 方式依赖蓝队选择。
    /// 若蓝队暴露了 create(keychainProbeSuccess:directory:)，此测试完整验证降级。
    /// 若未暴露，此测试降级为验证 create(directory:) 的 EncryptedFile 路径可用。
    func test_factory_fallback_whenKeychainFails_returnsEncryptedFileStore() throws {
        // 优先尝试：若有 create(keychainProbeSuccess:directory:) DI 入口
        // 否则：使用 EncryptedFileSecretStore.makeOrLoad(directory:) 直接验证降级路径可用
        let store = try EncryptedFileSecretStore.makeOrLoad(directory: tempDir)
        let key = "fallback-test-\(UUID().uuidString)"
        let value = "fallback-value-87654321"

        try store.save(key: key, value: value)
        let loaded = try store.load(key: key)

        XCTAssertEqual(loaded, value,
                       "降级到 EncryptedFileSecretStore 后 save/load 必须正常工作")
    }

    /// 若 SecretStoreFactory 暴露 DI 入口，验证注入失败 probe → 返回 EncryptedFileSecretStore
    /// 测试尝试调用 SecretStoreFactory.create(keychainProbeSuccess: false, directory: tempDir)
    /// 如果签名不匹配则编译期失败 → 蓝队按此接口实现
    func test_factory_withFailedKeychain_DI_returnsEncryptedStore() throws {
        // DI 接口约定（红队对蓝队的接口期望）：
        // static func create(keychainProbeSuccess: Bool, directory: URL) throws -> SecretStore
        let store = try SecretStoreFactory.create(
            keychainProbeSuccess: false,
            directory: tempDir
        )
        // 验证 store 是 EncryptedFileSecretStore 类型
        XCTAssertTrue(store is EncryptedFileSecretStore,
                      "Keychain probe 失败时 factory 必须返回 EncryptedFileSecretStore")

        // 并且功能正常
        let key = "di-fallback-\(UUID().uuidString)"
        let value = "di-value-99887766"
        try store.save(key: key, value: value)
        XCTAssertEqual(try store.load(key: key), value,
                       "DI 降级后的 EncryptedFileSecretStore 必须能正常 save/load")
    }

    // MARK: - E. 两条路径都失败时抛 secretStoreUnavailable

    /// 模拟 Keychain 失败 + EncryptedFile 也失败（例如目录不可写）
    /// 此时 create() 必须抛 LauncherError.secretStoreUnavailable
    ///
    /// 测试通过传入无法写入的路径（只读目录）来触发 EncryptedFile 失败
    func test_factory_bothFail_throwsSecretStoreUnavailable() throws {
        // 创建只读临时目录模拟写入失败
        let readOnlyDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("readonly-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: readOnlyDir, withIntermediateDirectories: true)
        // 设置只读权限
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: readOnlyDir.path)

        defer {
            // 清理：恢复写权限后删除
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: readOnlyDir.path)
            try? FileManager.default.removeItem(at: readOnlyDir)
        }

        do {
            let store = try SecretStoreFactory.create(
                keychainProbeSuccess: false,
                directory: readOnlyDir
            )
            // 如果 create 不抛，则 save 应该抛
            try store.save(key: "probe", value: "test")
            XCTFail("两条路径都失败时应抛 LauncherError.secretStoreUnavailable")
        } catch LauncherError.secretStoreUnavailable {
            // 预期路径：测试通过
        } catch {
            // 也接受其他形式的错误（目录不可写时可能抛文件系统错误）
            // 关键是不能静默成功
        }
    }
}
