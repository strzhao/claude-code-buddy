import XCTest
import CryptoKit
@testable import BuddyCore

// MARK: - TrustStoreCommandModeTests
//
// 蓝队单测：command mode trustKey 算法（T2 BLOCKER）
//
// 契约引用（state.md ## 契约规约 + 设计文档 §1 BLOCKER）：
//   TrustStore.trustKey switch 无 default，加 .command case 防编译错
//   复用 stdin 算法，前缀 "command:"：
//     "command:" + SHA256(cmd + "\n" + args.joined("\n") + "\n" + sha256(exe_bytes)_hex)
//   引用知识库 2026-05-27-tofu-trust-key-includes-exe-bytes
//
// TDD：先于实现编写，最初编译失败（RED）。

final class TrustStoreCommandModeTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("TrustStoreCommandMode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let dir = tempDir { try? FileManager.default.removeItem(at: dir) }
        tempDir = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func writeExecutable(content: String = "#!/bin/sh\necho cmd") throws -> URL {
        let exe = tempDir.appendingPathComponent("qr-gen")
        try content.write(to: exe, atomically: true, encoding: .utf8)
        return exe
    }

    /// 用 JSON decode 构造 command manifest（契约便利 init 只能造 stdin）
    private func makeCommandManifest(name: String = "qr",
                                     cmd: String = "./qr-gen",
                                     args: [String] = []) -> PluginManifest {
        let argsJSON = args.isEmpty ? "[]" : "[" + args.map { "\"\($0)\"" }.joined(separator: ",") + "]"
        let json = """
        {
            "name": "\(name)",
            "version": "0.1.0",
            "description": "qr plugin",
            "keywords": ["qr"],
            "mode": "command",
            "cmd": "\(cmd)",
            "args": \(argsJSON),
            "env": null,
            "requiredPath": null
        }
        """
        return try! JSONDecoder().decode(PluginManifest.self, from: json.data(using: .utf8)!)
    }

    /// 蓝队独立复现 command trustKey 算法（依据契约规约）
    private func computeExpected(cmd: String, args: [String], exe: URL) throws -> String {
        let exeData = try Data(contentsOf: exe)
        let exeHashHex = SHA256.hash(data: exeData).compactMap { String(format: "%02x", $0) }.joined()
        let combined = "\(cmd)\n\(args.joined(separator: "\n"))\n\(exeHashHex)"
        let digest = SHA256.hash(data: Data(combined.utf8))
        return "command:" + digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    // MARK: - trustKey 算法契约

    func test_trustKey_commandPrefix_andHex() throws {
        let exe = try writeExecutable()
        let manifest = makeCommandManifest()
        let key = try TrustStore.trustKey(for: manifest, executablePath: exe)

        XCTAssertTrue(key.hasPrefix("command:"), "command trustKey 必须以 \"command:\" 开头，实际: \(key)")
        let hexPart = String(key.dropFirst("command:".count))
        XCTAssertEqual(hexPart.count, 64, "hex 部分必须 64 字符，实际: \(hexPart.count)")
        let allowed = CharacterSet(charactersIn: "0123456789abcdef")
        XCTAssertTrue(hexPart.unicodeScalars.allSatisfy { allowed.contains($0) },
                      "hex 必须全 lowercase: \(hexPart)")
    }

    func test_trustKey_matchesIndependentReimplementation() throws {
        let exe = try writeExecutable(content: "#!/bin/sh\necho v1")
        let manifest = makeCommandManifest(cmd: "./qr-gen", args: ["--size", "480"])

        let storeKey = try TrustStore.trustKey(for: manifest, executablePath: exe)
        let expected = try computeExpected(cmd: "./qr-gen", args: ["--size", "480"], exe: exe)
        XCTAssertEqual(storeKey, expected, "command trustKey 必须与契约算法一致")
    }

    func test_trustKey_differsWhenCmdArgsOrExeChanges() throws {
        let exe = try writeExecutable()
        let baseManifest = makeCommandManifest(cmd: "./qr-gen", args: ["--a"])
        let baseKey = try TrustStore.trustKey(for: baseManifest, executablePath: exe)

        // cmd 改变
        let cmdChanged = makeCommandManifest(cmd: "./other", args: ["--a"])
        XCTAssertNotEqual(baseKey, try TrustStore.trustKey(for: cmdChanged, executablePath: exe))

        // args 改变
        let argsChanged = makeCommandManifest(cmd: "./qr-gen", args: ["--b"])
        XCTAssertNotEqual(baseKey, try TrustStore.trustKey(for: argsChanged, executablePath: exe))

        // exe bytes 改变
        try "#!/bin/sh\necho v2".write(to: exe, atomically: true, encoding: .utf8)
        XCTAssertNotEqual(baseKey, try TrustStore.trustKey(for: baseManifest, executablePath: exe))
    }

    // MARK: - mode 隔离：command vs stdin 同 cmd/args/exe，trustKey 不同

    func test_trustKey_commandIsolatedFromStdin() throws {
        let exe = try writeExecutable()
        let cmdManifest = makeCommandManifest(cmd: "./qr-gen", args: [])
        let stdinManifest = PluginManifest(
            name: "qr", version: "0.1.0", description: "x", keywords: ["qr"],
            cmd: "./qr-gen", args: [], env: nil, timeout: 10, requiredPath: nil
        )
        let cmdKey = try TrustStore.trustKey(for: cmdManifest, executablePath: exe)
        let stdinKey = try TrustStore.trustKey(for: stdinManifest, executablePath: exe)
        XCTAssertNotEqual(cmdKey, stdinKey, "command vs stdin trustKey 必须隔离（mode 前缀防伪造）")
    }

    // MARK: - approve/isTrusted 往返

    func test_approve_then_isTrusted_persistsCommandRecord() throws {
        let exe = try writeExecutable()
        let trustFile = tempDir.appendingPathComponent("launcher-trust.json")
        let store = TrustStore(file: trustFile)
        let manifest = makeCommandManifest(name: "qr", cmd: "./qr-gen")

        XCTAssertFalse(store.isTrusted(manifest, executablePath: exe))
        try store.approve(manifest, executablePath: exe)
        XCTAssertTrue(store.isTrusted(manifest, executablePath: exe))

        let records = try store.list()
        let qrRecord = records.first { $0.pluginName == "qr" }
        XCTAssertNotNil(qrRecord)
        XCTAssertTrue(qrRecord?.trustKey.hasPrefix("command:") ?? false)
    }
}
