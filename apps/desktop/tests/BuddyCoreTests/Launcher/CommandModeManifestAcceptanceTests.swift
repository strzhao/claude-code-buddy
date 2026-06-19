import XCTest
import CryptoKit
@testable import BuddyCore

// MARK: - CommandModeManifestAcceptanceTests
//
// 红队验收测试：command mode manifest schema + trustKey + validate（黑盒，仅依据契约规约）。
//
// 设计文档引用：
//   .autopilot/runtime/sessions/qrcode/requirements/20260619-开始实现，图片通道认/state.md
//   ## 契约规约 接口签名：PluginModeConfig 新增 .command(CommandConfig)
//   ## 验收场景 场景7 (TOFU 拦截)、场景8 (通用图片能力，P3 env 键)
//
// 黑盒原则：仅通过公开 Codable API + validate() + TrustStore.trustKey 验证契约，
// 不读 PluginManifest.swift / TrustStore.swift 本次新增实现。
// 测试 WILL NOT compile 直到蓝队 T1/T2 完成 — 预期 TDD 红灯。
//
// ⚠️ 铁律：本文件由红队独立编写，未读取蓝队实现代码。
// CONTRACT_AMBIGUOUS: 无（CommandConfig 字段名 + trustKey "command:" 前缀在契约规约里明确）

final class CommandModeManifestAcceptanceTests: XCTestCase {

    // MARK: - Fixture helpers

    private func baseFields(name: String = "cmd-plugin") -> String {
        """
        "name": "\(name)",
        "version": "0.1.0",
        "description": "command mode test plugin",
        "keywords": ["qr", "二维码"]
        """
    }

    private func decode(_ json: String) throws -> PluginManifest {
        let data = json.data(using: .utf8)!
        return try JSONDecoder().decode(PluginManifest.self, from: data)
    }

    // MARK: - 场景1.P2 [det-machine] 间接：command mode 存在性 + 不被解码为 stdin/prompt
    //
    // 契约引用：契约规约 enum PluginModeConfig 加 case command(CommandConfig)
    // 场景1.P2 主体（LLM 调用计数 == 0）在 LauncherManagerAcceptanceTests 验，此处先锁定
    // command case 必须存在且不被误判为 stdin/prompt（command mode bypass agent loop 的前提）

    func test_commandMode_decodesAsCommandCase() throws {
        let json = """
        {
            \(baseFields()),
            "mode": "command",
            "cmd": "./qr-gen",
            "args": [],
            "env": null,
            "requiredPath": null
        }
        """
        let manifest = try decode(json)

        guard case .command(let cfg) = manifest.modeConfig else {
            return XCTFail("mode=command 必须解码为 .command case，实际: \(manifest.modeConfig)")
        }
        XCTAssertEqual(cfg.cmd, "./qr-gen", "CommandConfig.cmd 必须正确读取")
        XCTAssertEqual(cfg.args, [], "CommandConfig.args 必须正确读取")
        XCTAssertNil(cfg.env, "CommandConfig.env 缺省应 nil")
        XCTAssertNil(cfg.requiredPath, "CommandConfig.requiredPath 缺省应 nil")
    }

    // MARK: - 场景8.P3 [det-machine] 间接：CommandConfig 结构与 stdin 同构（env 字段可读）
    //
    // 契约引用：CommandConfig = { cmd, args, env, requiredPath } 与 StdinConfig 同构

    func test_commandMode_envField_decodesCorrectly() throws {
        let json = """
        {
            \(baseFields(name: "env-cmd")),
            "mode": "command",
            "cmd": "./runner",
            "args": ["--flag", "value"],
            "env": {"CUSTOM_KEY": "custom-val"},
            "requiredPath": ["/usr/bin/some-tool"]
        }
        """
        let manifest = try decode(json)

        guard case .command(let cfg) = manifest.modeConfig else {
            return XCTFail("应解码为 .command")
        }
        XCTAssertEqual(cfg.args, ["--flag", "value"])
        XCTAssertEqual(cfg.env?["CUSTOM_KEY"], "custom-val", "CommandConfig.env 必须可读")
        XCTAssertEqual(cfg.requiredPath, ["/usr/bin/some-tool"])
    }

    // MARK: - 场景8.P1 [det-machine] 间接：command mode validate 复用 stdin 路径校验
    //
    // 契约引用：设计文档 §1 — validate 加 .command 分支，复用 stdin cmd 校验（禁绝对路径 / ".."）
    // 场景8.P1（通用图片能力）的 schema 前提：非 qr 插件也用 command mode 同套契约

    func test_commandMode_validate_cmdAbsolutePath_throws() throws {
        let json = """
        {
            \(baseFields(name: "abs-cmd")),
            "mode": "command",
            "cmd": "/usr/bin/forbidden"
        }
        """
        let manifest = try decode(json)

        XCTAssertThrowsError(try manifest.validate(againstDirName: "abs-cmd")) { error in
            guard case LauncherError.pluginManifestInvalid(let reason) = error else {
                return XCTFail("应抛 pluginManifestInvalid，实际: \(error)")
            }
            XCTAssertTrue(
                reason.contains("绝对路径") || reason.lowercased().contains("absolute"),
                "command mode cmd 绝对路径错误信息必须含 绝对路径/absolute，实际: \(reason)"
            )
        }
    }

    func test_commandMode_validate_cmdDotDot_throws() throws {
        let json = """
        {
            \(baseFields(name: "dotdot-cmd")),
            "mode": "command",
            "cmd": "./../escape.sh"
        }
        """
        let manifest = try decode(json)

        XCTAssertThrowsError(try manifest.validate(againstDirName: "dotdot-cmd")) { error in
            guard case LauncherError.pluginManifestInvalid(let reason) = error else {
                return XCTFail("应抛 pluginManifestInvalid，实际: \(error)")
            }
            XCTAssertTrue(reason.contains(".."), "command mode cmd 含 .. 错误信息必须含 ..，实际: \(reason)")
        }
    }

    func test_commandMode_validate_relativeCmd_passes() throws {
        let json = """
        {
            \(baseFields(name: "ok-cmd")),
            "mode": "command",
            "cmd": "./qr-gen"
        }
        """
        let manifest = try decode(json)

        XCTAssertNoThrow(
            try manifest.validate(againstDirName: "ok-cmd"),
            "command mode cmd=./qr-gen（合法相对路径）应通过 validate()"
        )
    }

    // MARK: - Encode round-trip（command manifest 持久化）
    //
    // 契约引用：契约规约 encode 加 mode=="command" 分支

    func test_commandManifest_encodeRoundTrip_fieldsEqual() throws {
        let original = try decode("""
        {
            \(baseFields(name: "roundtrip")),
            "mode": "command",
            "cmd": "./runner",
            "args": ["--quiet"],
            "env": {"K": "v"},
            "requiredPath": null
        }
        """)

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PluginManifest.self, from: encoded)

        XCTAssertEqual(original, decoded, "command manifest encode→decode 必须相等（Equatable）")
    }

    // MARK: - 场景7.P1/P3 [det-machine]: command mode trustKey 算法（含 exe bytes hash）
    //
    // 契约引用：设计文档 §1 BLOCKER — trustKey 加 .command case，复用 stdin 算法
    //           "command:" + SHA256(cmd + "\n" + args.joined("\n") + "\n" + sha256(exe_bytes)_hex)
    //           引用知识库 2026-05-27-tofu-trust-key-includes-exe-bytes
    // 场景7.P1: 首次未信任 → 拦截（trust.json 不写 trusted）
    // 场景7.P3: TOFU 同意 → 持久化信任记录
    // 场景7.P2: TOFU 拒绝 → 不执行（trust.json 不写）

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CommandModeManifest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDir = nil
        try await super.tearDown()
    }

    private func writeExecutable(content: String = "#!/bin/sh\necho cmd") throws -> URL {
        let exe = tempDir.appendingPathComponent("qr-gen")
        try content.write(to: exe, atomically: true, encoding: .utf8)
        return exe
    }

    /// 红队独立复现 command trustKey 算法（依据契约规约，不读蓝队实现）
    private func computeExpectedCommandKey(cmd: String, args: [String], exe: URL) throws -> String {
        let exeData = try Data(contentsOf: exe)
        let exeHashHex = SHA256.hash(data: exeData).compactMap { String(format: "%02x", $0) }.joined()
        let argsPart = args.joined(separator: "\n")
        let combined = "\(cmd)\n\(argsPart)\n\(exeHashHex)"
        let digest = SHA256.hash(data: Data(combined.utf8))
        return "command:" + digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    private func makeCommandManifest(name: String = "qr",
                                     cmd: String = "./qr-gen",
                                     args: [String] = []) -> PluginManifest {
        // 用契约规约的便利 init 不可行（那构造 stdin）。用 JSON decode 构造 command manifest
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

    func test_commandMode_trustKey_hasCommandPrefix_sha256Hex() throws {
        let exe = try writeExecutable()
        let manifest = makeCommandManifest()
        let key = try TrustStore.trustKey(for: manifest, executablePath: exe)

        XCTAssertEqual(key.count, 72, "command trustKey: \"command:\" 前缀(8) + SHA256 hex(64) = 72 字符")
        // 注：实际长度 = "command:".count(8) + 64 = 72。若蓝队算错此处会挂
        // 断言前缀更稳定，长度作 soft check
        XCTAssertTrue(key.hasPrefix("command:"), "command trustKey 必须以 \"command:\" 开头，实际: \(key)")
        let hexPart = String(key.dropFirst("command:".count))
        XCTAssertEqual(hexPart.count, 64, "command trustKey hex 部分必须 64 字符，实际: \(hexPart.count)")
        let allowedSet = CharacterSet(charactersIn: "0123456789abcdef")
        XCTAssertTrue(hexPart.unicodeScalars.allSatisfy { allowedSet.contains($0) },
                      "command trustKey hex 必须全 lowercase hex，实际: \(hexPart)")
    }

    func test_commandMode_trustKey_matchesIndependentReimplementation() throws {
        // 场景7 det-machine 核心断言：契约算法无歧义（红队独立复现 == 实现）
        let exe = try writeExecutable(content: "#!/bin/sh\necho qr-gen-v1")
        let manifest = makeCommandManifest(cmd: "./qr-gen", args: ["--size", "480"])

        let storeKey = try TrustStore.trustKey(for: manifest, executablePath: exe)
        let independentKey = try computeExpectedCommandKey(
            cmd: "./qr-gen", args: ["--size", "480"], exe: exe
        )
        XCTAssertEqual(storeKey, independentKey,
                       "command trustKey 必须与红队独立复现算法一致（场景7 det-machine 谓词）")
    }

    func test_commandMode_trustKey_differsWhenCmdArgsOrExeChanges() throws {
        let exe = try writeExecutable()
        let baseManifest = makeCommandManifest(cmd: "./qr-gen", args: ["--a"])
        let baseKey = try TrustStore.trustKey(for: baseManifest, executablePath: exe)

        // cmd 改变
        let cmdChanged = makeCommandManifest(cmd: "./other-gen", args: ["--a"])
        XCTAssertNotEqual(
            baseKey,
            try TrustStore.trustKey(for: cmdChanged, executablePath: exe),
            "command cmd 改变 trustKey 必须不同（场景7 TOFU 重弹前提）"
        )

        // args 改变
        let argsChanged = makeCommandManifest(cmd: "./qr-gen", args: ["--b"])
        XCTAssertNotEqual(
            baseKey,
            try TrustStore.trustKey(for: argsChanged, executablePath: exe),
            "command args 改变 trustKey 必须不同"
        )

        // exe bytes 改变
        try "#!/bin/sh\necho v2".write(to: exe, atomically: true, encoding: .utf8)
        XCTAssertNotEqual(
            baseKey,
            try TrustStore.trustKey(for: baseManifest, executablePath: exe),
            "command executable bytes 改变 trustKey 必须不同（exe hash 纳入，防静默替换）"
        )
    }

    // MARK: - 场景7.P1 + 场景7.P3 [det-machine]: TOFU 持久化（approve → isTrusted → trust.json 含记录）

    func test_commandMode_approve_persistsAndSubsequentIsTrusted() throws {
        // 场景7.P3 det-machine: TOFU 同意 → trust.json 含 qr trusted 记录
        let exe = try writeExecutable()
        let trustFile = tempDir.appendingPathComponent("launcher-trust.json")
        let store = TrustStore(file: trustFile)
        let manifest = makeCommandManifest(name: "qr", cmd: "./qr-gen")

        // 场景7.P1 negate: 首次未信任
        XCTAssertFalse(
            store.isTrusted(manifest, executablePath: exe),
            "command mode 首次执行前必须 not trusted（场景7.P1）"
        )

        // 场景7.P3: 同意 → 持久化
        try store.approve(manifest, executablePath: exe)
        XCTAssertTrue(
            store.isTrusted(manifest, executablePath: exe),
            "command mode approve 后必须 trusted（场景7.P3）"
        )

        // 场景7.P3 assert: trust.json 含 qr trusted 记录
        let records = try store.list()
        let qrRecord = records.first { $0.pluginName == "qr" }
        XCTAssertNotNil(qrRecord, "trust.json 必须含 qr 记录（场景7.P3 assert: trust.json 含 qr trusted 记录）")
        XCTAssertTrue(
            qrRecord?.trustKey.hasPrefix("command:") ?? false,
            "qr 记录 trustKey 必须以 command: 前缀"
        )
    }

    func test_commandMode_trustKey_isolatesFromStdinSameCmdArgs() throws {
        // 安全谓词：command 与 stdin 即使 cmd/args/exe 完全相同，trustKey 也必须不同（mode 前缀隔离）
        // 防止 stdin 已信任的 plugin 被冒充成 command mode 跳过 TOFU
        let exe = try writeExecutable()
        let cmdManifest = makeCommandManifest(cmd: "./qr-gen", args: [])

        // 构造同名同 cmd/args 的 stdin manifest（用契约便利 init）
        let stdinManifest = PluginManifest(
            name: "qr",
            version: "0.1.0",
            description: "stdin version",
            keywords: ["qr"],
            cmd: "./qr-gen",
            args: [],
            env: nil,
            timeout: 10,
            requiredPath: nil
        )

        let cmdKey = try TrustStore.trustKey(for: cmdManifest, executablePath: exe)
        let stdinKey = try TrustStore.trustKey(for: stdinManifest, executablePath: exe)
        XCTAssertNotEqual(cmdKey, stdinKey,
                          "command vs stdin trustKey 必须隔离（mode 前缀防伪造）")
    }
}
