import XCTest
import CryptoKit
@testable import BuddyCore

// MARK: - TrustStoreAcceptanceTests
//
// 红队验收测试：基于 task 006 设计文档独立验证 TrustStore 的契约
//
// 设计文档覆盖点（task 006 输出契约）：
//   SC-01: TrustRecord JSON Codable 往返（含 ISO8601 日期）
//   SC-02: trustKey 长度 64 + 全 lowercase hex（SHA256）
//   SC-03: trustKey 变化检测（cmd / args / executable 任一改动 → key 不同）
//   SC-04: TrustStore.approve + isTrusted + 文件权限 0644
//   SC-05: TrustStore.remove 清条目（不影响其他 plugin）
//   SC-06: CLI 与 BuddyCore 共用 trust.json schema：CLI 内联 schema 写入文件，
//          BuddyCore TrustStore 应能正确 load（红队验证 SOURCE-OF-TRUTH 契约）
//   SC-07: trustKey 算法确定性 — 同样 manifest + executable 二次计算应得到相同 key
//   SC-08: list() 文件不存在 / 损坏时应返回空数组，不抛错
//   SC-09: approve 是幂等：同一 plugin approve 两次只有 1 条记录
//   SC-10: TrustStore 与 CLI 内联实现的 trustKey 算法一致（红队复现算法）
//
// 注意：所有测试使用临时目录隔离，不写真实 ~/.buddy/launcher-trust.json
// 红队红线：不读 TrustStore 实现源码，仅依据设计文档复现算法和断言

final class TrustStoreAcceptanceTests: XCTestCase {

    // MARK: - Fixtures

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("TrustStoreAcceptance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDir = nil
        try await super.tearDown()
    }

    private func makeManifest(name: String = "acc-plugin",
                              cmd: String = "./acc.sh",
                              args: [String] = []) -> PluginManifest {
        PluginManifest(
            name: name,
            version: "1.0.0",
            description: "验收测试插件",
            keywords: ["acceptance"],
            cmd: cmd,
            args: args,
            env: nil,
            timeout: 10,
            requiredPath: nil
        )
    }

    private func writeExecutable(content: String = "#!/bin/sh\necho acc", at name: String = "acc.sh") throws -> URL {
        let exe = tempDir.appendingPathComponent(name)
        try content.write(to: exe, atomically: true, encoding: .utf8)
        return exe
    }

    /// 红队独立复现的 trustKey 算法（依据设计文档规约）
    /// 不依赖 TrustStore.trustKey 实现 — 通过对算法的双重独立计算来交叉验证
    /// mode-aware 升级后：stdin 加 "stdin:" 前缀
    private func computeExpectedTrustKey(cmd: String, args: [String], executablePath: URL) throws -> String {
        let exeData = try Data(contentsOf: executablePath)
        let exeHash = SHA256.hash(data: exeData)
        let exeHashHex = exeHash.compactMap { String(format: "%02x", $0) }.joined()
        let combined = "\(cmd)\n\(args.joined(separator: "\n"))\n\(exeHashHex)"
        let digest = SHA256.hash(data: Data(combined.utf8))
        return "stdin:" + digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    // MARK: - SC-01: TrustRecord JSON Codable 往返

    func test_SC01_trustRecord_jsonRoundTrip_iso8601Date() throws {
        let date = Date(timeIntervalSince1970: 1_716_000_000)
        let original = TrustRecord(
            trustKey: String(repeating: "f", count: 64),
            pluginName: "sc01-plugin",
            approvedAt: date
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        // 验证编码 JSON 含期望字段（人类可读 / SOURCE-OF-TRUTH 契约）
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"trustKey\""), "JSON 必须含 trustKey 字段")
        XCTAssertTrue(json.contains("\"pluginName\""), "JSON 必须含 pluginName 字段")
        XCTAssertTrue(json.contains("\"approvedAt\""), "JSON 必须含 approvedAt 字段")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(TrustRecord.self, from: data)
        XCTAssertEqual(decoded, original, "TrustRecord 编/解码必须往返相等")
    }

    // MARK: - SC-02: trustKey 长度 64 + 全 lowercase hex

    func test_SC02_trustKey_length64_lowercaseHex() throws {
        let exe = try writeExecutable()
        let manifest = makeManifest()
        let key = try TrustStore.trustKey(for: manifest, executablePath: exe)

        XCTAssertEqual(key.count, 70, "mode-aware trustKey: \"stdin:\" 前缀(6) + SHA256 hex(64) = 70 字符")
        XCTAssertTrue(key.hasPrefix("stdin:"), "stdin mode trustKey 必须以 \"stdin:\" 开头，实际: \(key)")
        let hexPart = String(key.dropFirst(6))
        let allowedSet = CharacterSet(charactersIn: "0123456789abcdef")
        XCTAssertTrue(hexPart.unicodeScalars.allSatisfy { allowedSet.contains($0) },
                      "trustKey hex 部分必须全 lowercase hex，实际: \(hexPart)")
    }

    // MARK: - SC-03: trustKey 变化检测（cmd / args / executable 任一改动）

    func test_SC03_trustKey_differsWhen_cmdOrArgsOrExeChanges() throws {
        let exe = try writeExecutable(content: "#!/bin/sh\necho v1")
        let baseManifest = makeManifest(cmd: "./acc.sh", args: ["--quiet"])
        let baseKey = try TrustStore.trustKey(for: baseManifest, executablePath: exe)

        // 改 cmd
        let cmdChanged = makeManifest(cmd: "./other.sh", args: ["--quiet"])
        let cmdKey = try TrustStore.trustKey(for: cmdChanged, executablePath: exe)
        XCTAssertNotEqual(baseKey, cmdKey, "cmd 改动后 trustKey 应不同")

        // 改 args
        let argsChanged = makeManifest(cmd: "./acc.sh", args: ["--verbose"])
        let argsKey = try TrustStore.trustKey(for: argsChanged, executablePath: exe)
        XCTAssertNotEqual(baseKey, argsKey, "args 改动后 trustKey 应不同")

        // 改 executable
        try "#!/bin/sh\necho v2".write(to: exe, atomically: true, encoding: .utf8)
        let exeKey = try TrustStore.trustKey(for: baseManifest, executablePath: exe)
        XCTAssertNotEqual(baseKey, exeKey, "executable 改动后 trustKey 应不同")
    }

    // MARK: - SC-04: approve + isTrusted + 文件权限 0644

    func test_SC04_approve_then_isTrusted_andFilePermission0644() throws {
        let exe = try writeExecutable()
        let trustFile = tempDir.appendingPathComponent("launcher-trust.json")
        let store = TrustStore(file: trustFile)
        let manifest = makeManifest()

        XCTAssertFalse(store.isTrusted(manifest, executablePath: exe),
                       "approve 前必须 not trusted")
        try store.approve(manifest, executablePath: exe)
        XCTAssertTrue(store.isTrusted(manifest, executablePath: exe),
                      "approve 后必须 trusted")

        let attrs = try FileManager.default.attributesOfItem(atPath: trustFile.path)
        let perm = (attrs[.posixPermissions] as? Int) ?? 0
        XCTAssertEqual(perm, 0o644,
                       "trust.json 权限必须 0644，实际: \(String(perm, radix: 8))")
    }

    // MARK: - SC-05: remove 清条目（不影响其他 plugin）

    func test_SC05_remove_onlyClearsTargetPlugin_keepsOthers() throws {
        let exeA = try writeExecutable(content: "#!/bin/sh\necho A", at: "a.sh")
        let exeB = try writeExecutable(content: "#!/bin/sh\necho B", at: "b.sh")
        let trustFile = tempDir.appendingPathComponent("launcher-trust.json")
        let store = TrustStore(file: trustFile)
        let mA = makeManifest(name: "plugin-a", cmd: "./a.sh")
        let mB = makeManifest(name: "plugin-b", cmd: "./b.sh")

        try store.approve(mA, executablePath: exeA)
        try store.approve(mB, executablePath: exeB)
        XCTAssertEqual(try store.list().count, 2)

        try store.remove(pluginName: "plugin-a")
        let after = try store.list()
        XCTAssertEqual(after.count, 1, "remove plugin-a 后只剩 1 条")
        XCTAssertEqual(after.first?.pluginName, "plugin-b",
                       "保留的应为 plugin-b（remove 不应影响其他 plugin）")
    }

    // MARK: - SC-06: CLI 与 BuddyCore 共用 trust.json schema

    /// 红队验证 CLI 内联 schema 与 BuddyCore TrustRecord 完全一致：
    /// CLI 直接以 records 数组 JSON 写入文件，BuddyCore TrustStore 应能正常 load
    func test_SC06_cliInlineSchema_compatibleWith_buddyCoreLoad() throws {
        let exe = try writeExecutable()
        let trustFile = tempDir.appendingPathComponent("launcher-trust.json")
        let manifest = makeManifest()

        // CLI 内联视角：手工构造完全匹配 schema 的 JSON
        let key = try TrustStore.trustKey(for: manifest, executablePath: exe)
        let date = ISO8601DateFormatter().string(from: Date())
        let json = """
        {
          "records": [
            {
              "approvedAt": "\(date)",
              "pluginName": "\(manifest.name)",
              "trustKey": "\(key)"
            }
          ]
        }
        """
        try json.write(to: trustFile, atomically: true, encoding: .utf8)

        let store = TrustStore(file: trustFile)
        XCTAssertTrue(store.isTrusted(manifest, executablePath: exe),
                      "CLI 写入的 JSON 应能被 BuddyCore TrustStore 识别为 trusted（schema 兼容契约）")
    }

    // MARK: - SC-07: trustKey 算法确定性

    func test_SC07_trustKey_deterministic_acrossInvocations() throws {
        let exe = try writeExecutable()
        let manifest = makeManifest()
        let k1 = try TrustStore.trustKey(for: manifest, executablePath: exe)
        let k2 = try TrustStore.trustKey(for: manifest, executablePath: exe)
        let k3 = try TrustStore.trustKey(for: manifest, executablePath: exe)
        XCTAssertEqual(k1, k2, "同 input trustKey 必须确定性（同一进程内）")
        XCTAssertEqual(k2, k3, "同 input trustKey 必须确定性（多次调用）")
    }

    // MARK: - SC-08: list() 文件不存在 / 损坏

    func test_SC08_list_fileNotExist_returnsEmpty_noThrow() throws {
        let trustFile = tempDir.appendingPathComponent("no-such.json")
        let store = TrustStore(file: trustFile)
        let records = try store.list()
        XCTAssertTrue(records.isEmpty, "文件不存在 list() 必须返回空数组")
    }

    func test_SC08_list_invalidJSON_returnsEmpty_noThrow() throws {
        let trustFile = tempDir.appendingPathComponent("invalid.json")
        try "not valid json }{".write(to: trustFile, atomically: true, encoding: .utf8)
        let store = TrustStore(file: trustFile)
        let records = try store.list()
        XCTAssertTrue(records.isEmpty, "损坏 JSON list() 必须返回空数组（容错）")
    }

    // MARK: - SC-09: approve 幂等

    func test_SC09_approve_idempotent_samePlugin() throws {
        let exe = try writeExecutable()
        let trustFile = tempDir.appendingPathComponent("launcher-trust.json")
        let store = TrustStore(file: trustFile)
        let manifest = makeManifest()

        try store.approve(manifest, executablePath: exe)
        try store.approve(manifest, executablePath: exe)
        try store.approve(manifest, executablePath: exe)
        let records = try store.list()
        XCTAssertEqual(records.count, 1, "同一 plugin approve 多次必须只有 1 条记录")
        XCTAssertEqual(records.first?.pluginName, manifest.name)
    }

    // MARK: - SC-10: TrustStore 与红队独立复现算法一致

    /// 红队独立计算 trustKey 算法，与 TrustStore.trustKey 比对必须完全一致
    /// 这道题验证设计文档中的算法规约是无歧义的
    func test_SC10_trustKey_matchesIndependentReimplementation() throws {
        let exe = try writeExecutable(content: "#!/bin/sh\necho cross-verify")
        let manifest = makeManifest(cmd: "./acc.sh", args: ["arg1", "arg2"])

        let storeKey = try TrustStore.trustKey(for: manifest, executablePath: exe)
        let independentKey = try computeExpectedTrustKey(
            cmd: manifest.cmd,
            args: manifest.args,
            executablePath: exe
        )
        XCTAssertEqual(storeKey, independentKey,
                       "TrustStore.trustKey 必须与设计文档算法（红队独立复现）一致")
    }
}
