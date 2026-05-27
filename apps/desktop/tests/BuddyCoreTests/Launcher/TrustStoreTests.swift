import XCTest
@testable import BuddyCore

final class TrustStoreTests: XCTestCase {

    // MARK: - Fixtures

    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrustStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeManifest(name: String = "test-plugin",
                               cmd: String = "./run.sh",
                               args: [String] = []) -> PluginManifest {
        PluginManifest(
            name: name,
            version: "0.1.0",
            description: "测试插件",
            keywords: ["test"],
            cmd: cmd,
            args: args,
            env: nil,
            timeout: 10,
            requiredPath: nil
        )
    }

    private func makeExecutable(in dir: URL, content: String = "#!/bin/sh\necho hello") throws -> URL {
        let exe = dir.appendingPathComponent("run.sh")
        try content.write(to: exe, atomically: true, encoding: .utf8)
        return exe
    }

    // MARK: - SC-01: TrustRecord JSON Codable 往返

    func test_trustRecord_codable_roundTrip() throws {
        let date = Date(timeIntervalSince1970: 1_716_000_000)
        let record = TrustRecord(trustKey: String(repeating: "a", count: 64),
                                 pluginName: "my-plugin",
                                 approvedAt: date)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(TrustRecord.self, from: data)
        XCTAssertEqual(record, decoded)
    }

    // MARK: - SC-02: trustKey 长度 64 + 全 lowercase hex

    func test_trustKey_length64_lowercaseHex() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let exe = try makeExecutable(in: tmpDir)
        let manifest = makeManifest()
        let key = try TrustStore.trustKey(for: manifest, executablePath: exe)

        XCTAssertEqual(key.count, 64, "trustKey 应为 64 字节 SHA256 hex")
        XCTAssertTrue(key.allSatisfy { "0123456789abcdef".contains($0) },
                      "trustKey 应为全 lowercase hex")
    }

    // MARK: - SC-03: trustKey 变化检测（cmd / args / executable 任一改动 → key 不同）

    func test_trustKey_changesWhenCmdChanges() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let exe = try makeExecutable(in: tmpDir)
        let m1 = makeManifest(cmd: "./run.sh")
        let m2 = makeManifest(cmd: "./other.sh")
        let k1 = try TrustStore.trustKey(for: m1, executablePath: exe)
        let k2 = try TrustStore.trustKey(for: m2, executablePath: exe)
        XCTAssertNotEqual(k1, k2, "cmd 改动后 trustKey 应变化")
    }

    func test_trustKey_changesWhenArgsChange() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let exe = try makeExecutable(in: tmpDir)
        let m1 = makeManifest(args: [])
        let m2 = makeManifest(args: ["--verbose"])
        let k1 = try TrustStore.trustKey(for: m1, executablePath: exe)
        let k2 = try TrustStore.trustKey(for: m2, executablePath: exe)
        XCTAssertNotEqual(k1, k2, "args 改动后 trustKey 应变化")
    }

    func test_trustKey_changesWhenExecutableChanges() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let exe = try makeExecutable(in: tmpDir, content: "#!/bin/sh\necho v1")
        let manifest = makeManifest()
        let k1 = try TrustStore.trustKey(for: manifest, executablePath: exe)

        // 修改 executable 内容
        try "#!/bin/sh\necho v2".write(to: exe, atomically: true, encoding: .utf8)
        let k2 = try TrustStore.trustKey(for: manifest, executablePath: exe)

        XCTAssertNotEqual(k1, k2, "executable 改动后 trustKey 应变化")
    }

    // MARK: - SC-04: approve + isTrusted + 文件权限 0644

    func test_approve_thenIsTrusted_returnTrue() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let exe = try makeExecutable(in: tmpDir)
        let trustFile = tmpDir.appendingPathComponent("launcher-trust.json")
        let store = TrustStore(file: trustFile)
        let manifest = makeManifest()

        XCTAssertFalse(store.isTrusted(manifest, executablePath: exe),
                       "approve 前应为 not trusted")
        try store.approve(manifest, executablePath: exe)
        XCTAssertTrue(store.isTrusted(manifest, executablePath: exe),
                      "approve 后应为 trusted")
    }

    func test_approve_filePermission0644() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let exe = try makeExecutable(in: tmpDir)
        let trustFile = tmpDir.appendingPathComponent("launcher-trust.json")
        let store = TrustStore(file: trustFile)
        let manifest = makeManifest()

        try store.approve(manifest, executablePath: exe)

        let attrs = try FileManager.default.attributesOfItem(atPath: trustFile.path)
        let perm = (attrs[.posixPermissions] as? Int) ?? 0
        XCTAssertEqual(perm, 0o644, "launcher-trust.json 权限应为 0644，实际: \(String(perm, radix: 8))")
    }

    func test_approve_twice_samePlugin_onlyOneRecord() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let exe = try makeExecutable(in: tmpDir)
        let trustFile = tmpDir.appendingPathComponent("launcher-trust.json")
        let store = TrustStore(file: trustFile)
        let manifest = makeManifest()

        try store.approve(manifest, executablePath: exe)
        try store.approve(manifest, executablePath: exe)
        let records = try store.list()
        let count = records.filter { $0.pluginName == manifest.name }.count
        XCTAssertEqual(count, 1, "同一 plugin approve 两次，trust.json 中应只有 1 条")
    }

    // MARK: - SC-05: remove 清条目

    func test_remove_clearsRecord() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let exe = try makeExecutable(in: tmpDir)
        let trustFile = tmpDir.appendingPathComponent("launcher-trust.json")
        let store = TrustStore(file: trustFile)
        let manifest = makeManifest()

        try store.approve(manifest, executablePath: exe)
        XCTAssertTrue(store.isTrusted(manifest, executablePath: exe))

        try store.remove(pluginName: manifest.name)
        XCTAssertFalse(store.isTrusted(manifest, executablePath: exe),
                       "remove 后不应再 trusted")
        let records = try store.list()
        XCTAssertFalse(records.contains { $0.pluginName == manifest.name },
                       "remove 后 trust.json 中不应有该条目")
    }

    // MARK: - SC-06 (bonus): executable 改动后旧 trust 失效

    func test_isTrusted_falseAfterExecutableModified() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let exe = try makeExecutable(in: tmpDir, content: "#!/bin/sh\necho v1")
        let trustFile = tmpDir.appendingPathComponent("launcher-trust.json")
        let store = TrustStore(file: trustFile)
        let manifest = makeManifest()

        try store.approve(manifest, executablePath: exe)
        XCTAssertTrue(store.isTrusted(manifest, executablePath: exe))

        // 修改 executable
        try "#!/bin/sh\necho v2".write(to: exe, atomically: true, encoding: .utf8)
        XCTAssertFalse(store.isTrusted(manifest, executablePath: exe),
                       "executable 改动后旧 trust 应失效")
    }

    // MARK: - list() when empty

    func test_list_emptyWhenNoFile() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = TrustStore(file: tmpDir.appendingPathComponent("no-such.json"))
        let records = try store.list()
        XCTAssertTrue(records.isEmpty, "文件不存在时 list() 应返回空数组")
    }
}
