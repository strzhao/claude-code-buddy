import XCTest
import CryptoKit
@testable import BuddyCore

// MARK: - Fake SecretStore（用于测试 ProviderFactory 等上层逻辑）

final class FakeSecretStore: SecretStore {
    var storage: [String: String] = [:]
    var shouldFailSave = false

    func save(key: String, value: String) throws {
        if shouldFailSave { throw NSError(domain: "Fake", code: -34018) }
        storage[key] = value
    }

    func load(key: String) throws -> String? { storage[key] }

    func delete(key: String) throws { storage.removeValue(forKey: key) }
}

// MARK: - KeychainSecretStore Tests

final class KeychainSecretStoreTests: XCTestCase {
    // 使用测试专用 service，避免污染正式 Keychain
    private let testService = "claude-code-buddy.launcher.test-\(UUID().uuidString)"
    private var store: KeychainSecretStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = KeychainSecretStore(service: testService)
    }

    override func tearDownWithError() throws {
        // 清理可能残留的测试项（忽略错误）
        try? store.delete(key: "testKey")
        try? store.delete(key: "testKey2")
        try super.tearDownWithError()
    }

    func test_save_and_load() throws {
        try store.save(key: "testKey", value: "secretValue")
        let loaded = try store.load(key: "testKey")
        XCTAssertEqual(loaded, "secretValue")
    }

    func test_load_nonexistent_returns_nil() throws {
        let loaded = try store.load(key: "nonexistent-\(UUID().uuidString)")
        XCTAssertNil(loaded)
    }

    func test_save_overwrites_existing() throws {
        try store.save(key: "testKey", value: "v1")
        try store.save(key: "testKey", value: "v2")
        let loaded = try store.load(key: "testKey")
        XCTAssertEqual(loaded, "v2")
    }

    func test_delete_removes_key() throws {
        try store.save(key: "testKey", value: "toDelete")
        try store.delete(key: "testKey")
        let loaded = try store.load(key: "testKey")
        XCTAssertNil(loaded)
    }

    func test_delete_nonexistent_doesNotThrow() throws {
        XCTAssertNoThrow(try store.delete(key: "nonexistent-\(UUID().uuidString)"))
    }
}

// MARK: - EncryptedFileSecretStore Tests

final class EncryptedFileSecretStoreTests: XCTestCase {
    private var tmpDir: URL!
    private var encPath: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        encPath = tmpDir.appendingPathComponent("secrets.enc")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
        try super.tearDownWithError()
    }

    private func makeStore() throws -> EncryptedFileSecretStore {
        let key = try EncryptedFileSecretStore.deriveKey()
        return EncryptedFileSecretStore(path: encPath, key: key, cache: [:])
    }

    func test_save_and_load() throws {
        let store = try makeStore()
        try store.save(key: "apiKey", value: "sk-test-1234567890")
        let loaded = try store.load(key: "apiKey")
        XCTAssertEqual(loaded, "sk-test-1234567890")
    }

    func test_load_nonexistent_returns_nil() throws {
        let store = try makeStore()
        let loaded = try store.load(key: "nonexistent")
        XCTAssertNil(loaded)
    }

    func test_delete_removes_key() throws {
        let store = try makeStore()
        try store.save(key: "k", value: "v")
        try store.delete(key: "k")
        let loaded = try store.load(key: "k")
        XCTAssertNil(loaded)
    }

    func test_file_permissions_are_0600() throws {
        let store = try makeStore()
        try store.save(key: "k", value: "v")
        let attrs = try FileManager.default.attributesOfItem(atPath: encPath.path)
        let perms = attrs[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600, "encrypted secrets file 权限必须为 0600")
    }

    func test_persist_and_reload() throws {
        // 第一个实例写数据
        let key = try EncryptedFileSecretStore.deriveKey()
        let store1 = EncryptedFileSecretStore(path: encPath, key: key, cache: [:])
        try store1.save(key: "a", value: "1")
        try store1.save(key: "b", value: "2")

        // 第二个实例从文件读取
        let store2 = try EncryptedFileSecretStore.makeOrLoad(path: encPath)
        XCTAssertEqual(try store2.load(key: "a"), "1")
        XCTAssertEqual(try store2.load(key: "b"), "2")
    }

    func test_deriveKey_isReproducible() throws {
        let key1 = try EncryptedFileSecretStore.deriveKey()
        let key2 = try EncryptedFileSecretStore.deriveKey()
        // 相同机器上两次派生密钥应相同
        XCTAssertEqual(key1.withUnsafeBytes { Data($0) }, key2.withUnsafeBytes { Data($0) })
    }
}

// MARK: - SecretStoreFactory Tests

final class SecretStoreFactoryTests: XCTestCase {

    func test_factory_create_returns_some_store() throws {
        // 工厂应该能创建某种 store（Keychain 或 EncryptedFile）
        let store = try SecretStoreFactory.create()
        // 简单验证：save/load 往返
        let key = "factory.test.\(UUID().uuidString)"
        try store.save(key: key, value: "testValue")
        let loaded = try store.load(key: key)
        XCTAssertEqual(loaded, "testValue")
        // 清理
        try? store.delete(key: key)
    }
}
