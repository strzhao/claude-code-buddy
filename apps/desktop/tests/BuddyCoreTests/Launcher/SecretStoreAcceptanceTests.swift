import XCTest
import Security
import CryptoKit
@testable import BuddyCore

// MARK: - SecretStoreAcceptanceTests
//
// 验收测试：KeychainSecretStore 和 EncryptedFileSecretStore 各自的 save/load/delete 契约
//
// 设计文档覆盖点（task 002 输出契约）：
//   A. KeychainSecretStore.save → load 返回原值
//   B. Keychain.load 不存在的 key 返回 nil（不抛错）
//   C. Keychain.delete 后 load 返回 nil
//   D. EncryptedFileSecretStore.save → load 返回原值
//   E. EncryptedFileSecretStore 重新 makeOrLoad（重启模拟）→ 仍能 load（持久化验证）
//   F. EncryptedFileSecretStore 文件权限 == 0600
//   G. Keychain service == "claude-code-buddy.launcher"（常量契约）
//   H. EncryptedFileSecretStore.delete 后 load 返回 nil
//   I. 多 key 互相独立（隔离验证）
//
// 隔离原则：Keychain 测试用 UUID 命名空间 key，EncryptedFile 用 NSTemporaryDirectory + UUID 路径。
// setUp/tearDown 负责清理。
// 测试 WILL NOT compile 直到蓝队合并实现 — 这是预期的 TDD 红灯。

// MARK: - KeychainSecretStore Tests

final class KeychainSecretStoreAcceptanceTests: XCTestCase {

    private var testKeyPrefix: String = ""
    private var store: KeychainSecretStore!

    override func setUp() async throws {
        try await super.setUp()
        testKeyPrefix = "test.\(UUID().uuidString)"
        store = KeychainSecretStore()
    }

    override func tearDown() async throws {
        // 清理测试期间写入的所有 key
        try? store.delete(key: testKeyPrefix + ".a")
        try? store.delete(key: testKeyPrefix + ".b")
        try? store.delete(key: testKeyPrefix + ".save-load")
        try? store.delete(key: testKeyPrefix + ".delete")
        try? store.delete(key: testKeyPrefix + ".unicode")
        store = nil
        try await super.tearDown()
    }

    // MARK: - A. save → load 返回原值

    /// save(key:value:) 后 load(key:) 必须返回原始字符串（精确值断言）
    func test_keychain_saveLoad_returnsOriginalValue() throws {
        let key = testKeyPrefix + ".save-load"
        let value = "sk-ant-api03-test-secret-value-1234567890"

        // When
        try store.save(key: key, value: value)
        let loaded = try store.load(key: key)

        // Then: 精确值断言
        XCTAssertEqual(loaded, value,
                       "load 后必须返回 save 时存入的原始值")
    }

    /// save 后更新同一 key，load 返回新值（覆盖语义）
    func test_keychain_saveOverwrite_returnsNewValue() throws {
        let key = testKeyPrefix + ".save-load"
        try store.save(key: key, value: "original-value")
        try store.save(key: key, value: "updated-value")
        let loaded = try store.load(key: key)
        XCTAssertEqual(loaded, "updated-value",
                       "第二次 save 必须覆盖旧值，load 返回新值")
    }

    // MARK: - B. load 不存在的 key 返回 nil（不抛错）

    /// load 一个从未 save 过的 key 必须返回 nil，不抛错
    func test_keychain_load_nonExistentKey_returnsNil() throws {
        let key = testKeyPrefix + ".nonexistent-\(UUID().uuidString)"
        let result = try store.load(key: key)
        XCTAssertNil(result,
                     "load 不存在的 key 必须返回 nil，不抛 Error")
    }

    // MARK: - C. delete 后 load 返回 nil

    /// save → delete → load 必须返回 nil
    func test_keychain_delete_thenLoadReturnsNil() throws {
        let key = testKeyPrefix + ".delete"
        try store.save(key: key, value: "to-be-deleted")
        // 先验证 save 有效
        XCTAssertEqual(try store.load(key: key), "to-be-deleted",
                       "Precondition: save 后 load 必须返回原值")

        // When
        try store.delete(key: key)

        // Then
        let result = try store.load(key: key)
        XCTAssertNil(result,
                     "delete 后 load 必须返回 nil")
    }

    /// delete 不存在的 key 不应抛错（幂等性）
    func test_keychain_delete_nonExistentKey_doesNotThrow() {
        let key = testKeyPrefix + ".never-existed-\(UUID().uuidString)"
        XCTAssertNoThrow(try store.delete(key: key),
                         "delete 不存在的 key 不应抛错")
    }

    // MARK: - G. Keychain service 常量契约

    /// KeychainSecretStore 使用的 Keychain service 必须是 LauncherConstants.keychainService
    /// 即 "claude-code-buddy.launcher"
    func test_keychain_usesCorrectService() throws {
        let key = testKeyPrefix + ".a"
        let value = "test-service-verify"
        try store.save(key: key, value: value)

        // 直接用 Security 框架查询验证 service 字段
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: LauncherConstants.keychainService,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        XCTAssertEqual(status, errSecSuccess,
                       "用 service=LauncherConstants.keychainService 查询必须成功，" +
                       "说明存储时使用了正确的 service 名称")
        let loaded = (result as? Data).flatMap { String(data: $0, encoding: .utf8) }
        XCTAssertEqual(loaded, value,
                       "查询到的值必须与 save 的值一致")

        try store.delete(key: key)
    }

    // MARK: - I. 多 key 互相独立

    /// 两个不同 key 的值互相独立，delete 一个不影响另一个
    func test_keychain_multipleKeys_areIndependent() throws {
        let key1 = testKeyPrefix + ".a"
        let key2 = testKeyPrefix + ".b"

        try store.save(key: key1, value: "value-for-a")
        try store.save(key: key2, value: "value-for-b")

        // 验证互相独立
        XCTAssertEqual(try store.load(key: key1), "value-for-a")
        XCTAssertEqual(try store.load(key: key2), "value-for-b")

        // delete key1 不影响 key2
        try store.delete(key: key1)
        XCTAssertNil(try store.load(key: key1),
                     "delete key1 后 load key1 必须返回 nil")
        XCTAssertEqual(try store.load(key: key2), "value-for-b",
                       "delete key1 不应影响 key2 的值")

        try store.delete(key: key2)
    }
}

// MARK: - EncryptedFileSecretStore Tests

final class EncryptedFileSecretStoreAcceptanceTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        // 每个测试用独立的临时目录
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDir = nil
        try await super.tearDown()
    }

    /// 创建一个使用临时目录的 EncryptedFileSecretStore（注入测试路径）
    private func makeStore() throws -> EncryptedFileSecretStore {
        return try EncryptedFileSecretStore.makeOrLoad(directory: tempDir)
    }

    // MARK: - D. save → load 返回原值

    /// save(key:value:) 后 load(key:) 必须返回原始字符串
    func test_encryptedFile_saveLoad_returnsOriginalValue() throws {
        let store = try makeStore()
        let value = "api-key-test-12345678"

        try store.save(key: "myKey", value: value)
        let loaded = try store.load(key: "myKey")

        XCTAssertEqual(loaded, value,
                       "EncryptedFileSecretStore load 后必须返回 save 时存入的原始值")
    }

    /// load 不存在的 key 返回 nil（不抛错）
    func test_encryptedFile_load_nonExistentKey_returnsNil() throws {
        let store = try makeStore()
        let result = try store.load(key: "does-not-exist")
        XCTAssertNil(result,
                     "EncryptedFileSecretStore load 不存在的 key 必须返回 nil")
    }

    // MARK: - E. 重启模拟：重新 makeOrLoad 仍能 load（持久化验证）

    /// save 后重新初始化 store（模拟应用重启），仍能 load 到相同值
    func test_encryptedFile_persistence_surviveReinit() throws {
        // Given: 第一次 store 写入
        let store1 = try makeStore()
        try store1.save(key: "persistent-key", value: "secret-value-xyz")

        // When: 模拟重启 — 重新创建 store（相同路径）
        let store2 = try makeStore()
        let loaded = try store2.load(key: "persistent-key")

        // Then
        XCTAssertEqual(loaded, "secret-value-xyz",
                       "重新初始化 EncryptedFileSecretStore 后必须仍能读到持久化的值")
    }

    /// 多次 save 后重启，所有 key 均能正确读取
    func test_encryptedFile_persistence_multipleKeys_surviveReinit() throws {
        let store1 = try makeStore()
        try store1.save(key: "k1", value: "v1")
        try store1.save(key: "k2", value: "v2")
        try store1.save(key: "k3", value: "v3")

        let store2 = try makeStore()
        XCTAssertEqual(try store2.load(key: "k1"), "v1")
        XCTAssertEqual(try store2.load(key: "k2"), "v2")
        XCTAssertEqual(try store2.load(key: "k3"), "v3")
    }

    // MARK: - F. 文件权限 == 0600

    /// EncryptedFileSecretStore persist 后文件权限必须是 0600
    func test_encryptedFile_filePermission_is0600() throws {
        let store = try makeStore()
        try store.save(key: "perm-test", value: "check-permissions")

        // 找到加密文件路径
        let encPath = tempDir.appendingPathComponent("launcher-secrets.enc")
        let attrs = try FileManager.default.attributesOfItem(atPath: encPath.path)
        let permissions = attrs[.posixPermissions] as? Int

        XCTAssertEqual(permissions, 0o600,
                       "launcher-secrets.enc 文件权限必须精确为 0600（-rw-------）")
    }

    // MARK: - H. delete 后 load 返回 nil

    /// save → delete → load 必须返回 nil
    func test_encryptedFile_delete_thenLoadReturnsNil() throws {
        let store = try makeStore()
        try store.save(key: "del-key", value: "del-value")
        XCTAssertEqual(try store.load(key: "del-key"), "del-value",
                       "Precondition: save 后 load 必须有值")

        try store.delete(key: "del-key")

        XCTAssertNil(try store.load(key: "del-key"),
                     "EncryptedFileSecretStore delete 后 load 必须返回 nil")
    }

    /// delete 后持久化到文件（重启后仍然为 nil）
    func test_encryptedFile_delete_persistedAfterReinit() throws {
        let store1 = try makeStore()
        try store1.save(key: "temp-key", value: "temp-val")
        try store1.delete(key: "temp-key")

        let store2 = try makeStore()
        XCTAssertNil(try store2.load(key: "temp-key"),
                     "delete 操作必须持久化：重启后 load 仍返回 nil")
    }

    // MARK: - I. 多 key 互相独立

    /// 两个 key 独立存储，delete 一个不影响另一个
    func test_encryptedFile_multipleKeys_areIndependent() throws {
        let store = try makeStore()
        try store.save(key: "key-a", value: "val-a")
        try store.save(key: "key-b", value: "val-b")

        try store.delete(key: "key-a")
        XCTAssertNil(try store.load(key: "key-a"),
                     "delete key-a 后必须返回 nil")
        XCTAssertEqual(try store.load(key: "key-b"), "val-b",
                       "delete key-a 不应影响 key-b")
    }
}
