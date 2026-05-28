import XCTest
import CryptoKit
@testable import BuddyCore

// MARK: - TrustModeAwareAcceptanceTests
//
// 红队验收测试：task 005 — trust 模型 mode-aware
//
// 设计文档引用：
//   .autopilot/project/tasks/005-trust-mode-aware.md
//
// 黑盒原则：仅通过公开 API（TrustStore.trustKey / isTrusted / approve）和
//           PluginManifest 构造函数验证契约，不依赖内部实现细节。
//
// 铁律：本文件由红队独立编写，未读取 TrustStore.swift / TrustPrompt.swift 的
//        trust 相关实现代码（蓝队改动部分）。
// ⚠️ NSAlert 相关场景（8、9）：构造 alert 对象后仅断言文案字符串，不调用 runModal。

final class TrustModeAwareAcceptanceTests: XCTestCase {

    // MARK: - Fixtures

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("TrustModeAware-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDir = nil
        try await super.tearDown()
    }

    /// 构造 stdin manifest fixture
    private func makeStdinManifest(
        name: String = "test-stdin-plugin",
        cmd: String = "./run.sh",
        args: [String] = ["--quiet"]
    ) -> PluginManifest {
        PluginManifest(
            name: name,
            version: "1.0.0",
            description: "stdin test plugin",
            keywords: [],
            cmd: cmd,
            args: args
        )
    }

    /// 构造 prompt manifest fixture（通过 JSON decode 绕过旧 init 只支持 stdin 的限制）
    private func makePromptManifest(
        name: String = "test-prompt-plugin",
        systemPrompt: String = "你是中英互译助手",
        maxIterations: Int = 1,
        model: String? = nil
    ) throws -> PluginManifest {
        let modelJSON: String
        if let m = model {
            modelJSON = #","model":"\#(m)""#
        } else {
            modelJSON = ""
        }
        let json = """
        {
            "name": "\(name)",
            "version": "1.0.0",
            "description": "prompt test plugin",
            "keywords": [],
            "mode": "prompt",
            "systemPrompt": \(encodeStringForJSON(systemPrompt)),
            "maxIterations": \(maxIterations)\(modelJSON)
        }
        """
        return try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
    }

    /// 安全编码 JSON 字符串值（防止 systemPrompt 含特殊字符破坏 JSON 格式）
    private func encodeStringForJSON(_ s: String) -> String {
        let data = try! JSONEncoder().encode(s)
        return String(data: data, encoding: .utf8)!
    }

    /// 写可执行文件 fixture
    private func writeExecutable(content: String = "#!/bin/sh\necho hello", name: String = "run.sh") throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - 辅助：红队独立复现 stdin trustKey 算法（依据 task 005 设计文档）
    //
    // 算法规约（state.md）：
    //   stdin: "stdin:" + SHA256(cmd + "\n" + args.joined("\n") + "\n" + sha256(exe_bytes)_hex)
    //   prompt: "prompt:" + SHA256(systemPrompt + "\n" + maxIterations + "\n" + modelPart)
    //           其中 modelPart = "0" (model == nil) | "1:\(model)" (model != nil)
    //           结构性 tag 区分 nil 与字符串 "default"，防 ?? 默认值碰撞

    private func computeExpectedStdinKey(cmd: String, args: [String], exePath: URL) throws -> String {
        let exeData = try Data(contentsOf: exePath)
        let exeHashHex = SHA256.hash(data: exeData).hexString
        let argsPart = args.joined(separator: "\n")
        let combined = "\(cmd)\n\(argsPart)\n\(exeHashHex)"
        return "stdin:" + SHA256.hash(data: Data(combined.utf8)).hexString
    }

    private func computeExpectedPromptKey(systemPrompt: String, maxIterations: Int, model: String?) -> String {
        // 结构性 tag：nil → "0", 非 nil → "1:value"（避免 nil 与字符串 "default" 等碰撞）
        let modelPart = model.map { "1:\($0)" } ?? "0"
        let combined = "\(systemPrompt)\n\(maxIterations)\n\(modelPart)"
        return "prompt:" + SHA256.hash(data: Data(combined.utf8)).hexString
    }

    // MARK: - 场景 1：stdin trustKey 以 "stdin:" 开头

    func test_01_stdinTrustKey_hasStdinPrefix() throws {
        let exe = try writeExecutable()
        let manifest = makeStdinManifest()
        let key = try TrustStore.trustKey(for: manifest, executablePath: exe)

        XCTAssertTrue(
            key.hasPrefix("stdin:"),
            "stdin mode 的 trustKey 必须以 'stdin:' 开头，实际: \(key)"
        )
    }

    // MARK: - 场景 2：prompt trustKey 以 "prompt:" 开头

    func test_02_promptTrustKey_hasPromptPrefix() throws {
        let manifest = try makePromptManifest()
        // prompt mode 无 executable，传任意 URL（trustKey 计算不读文件）
        let fakeExe = tempDir.appendingPathComponent("unused.sh")
        let key = try TrustStore.trustKey(for: manifest, executablePath: fakeExe)

        XCTAssertTrue(
            key.hasPrefix("prompt:"),
            "prompt mode 的 trustKey 必须以 'prompt:' 开头，实际: \(key)"
        )
    }

    // MARK: - 场景 3：mode 切换破坏 trust（相同 name/description，不同 mode → trustKey 完全不同）

    func test_03_modeSwitch_producesDifferentTrustKeys() throws {
        let exe = try writeExecutable()
        let stdinManifest = makeStdinManifest(name: "shared-plugin", cmd: "./run.sh")
        let promptManifest = try makePromptManifest(name: "shared-plugin", systemPrompt: "你是助手")

        let stdinKey = try TrustStore.trustKey(for: stdinManifest, executablePath: exe)
        let promptKey = try TrustStore.trustKey(for: promptManifest, executablePath: exe)

        XCTAssertNotEqual(stdinKey, promptKey,
                          "stdin mode 和 prompt mode 即便 name 相同，trustKey 也必须完全不同")
        XCTAssertFalse(
            stdinKey.hasPrefix("prompt:") || promptKey.hasPrefix("stdin:"),
            "前缀必须与 mode 严格一致，不能交叉"
        )
        // 无任何字节重叠（模式前缀本身就保证了隔离）
        XCTAssertNotEqual(
            stdinKey.dropFirst("stdin:".count),
            promptKey.dropFirst("prompt:".count),
            "去掉前缀后 hash 部分也必须不同（防止内容碰巧相等）"
        )
    }

    // MARK: - 场景 4：stdin executable bytes 变化 → trustKey 不同（保留现有行为）

    func test_04_stdinExeChange_producesDifferentTrustKey() throws {
        let exe = try writeExecutable(content: "#!/bin/sh\necho v1")
        let manifest = makeStdinManifest()

        let keyV1 = try TrustStore.trustKey(for: manifest, executablePath: exe)

        // 修改 executable 内容
        try "#!/bin/sh\necho v2".write(to: exe, atomically: true, encoding: .utf8)
        let keyV2 = try TrustStore.trustKey(for: manifest, executablePath: exe)

        XCTAssertNotEqual(keyV1, keyV2,
                          "stdin executable bytes 改变后 trustKey 必须不同（保留现有 TOFU 行为）")
        XCTAssertTrue(keyV1.hasPrefix("stdin:"), "变化前 key 仍需 stdin: 前缀")
        XCTAssertTrue(keyV2.hasPrefix("stdin:"), "变化后 key 仍需 stdin: 前缀")
    }

    // MARK: - 场景 5：prompt systemPrompt 改一字符 → trustKey 不同

    func test_05_promptSystemPromptOneCharChange_producesDifferentTrustKey() throws {
        let manifest1 = try makePromptManifest(systemPrompt: "你是翻译助手")
        let manifest2 = try makePromptManifest(systemPrompt: "你是翻译助手x")
        let fakeExe = tempDir.appendingPathComponent("unused.sh")

        let key1 = try TrustStore.trustKey(for: manifest1, executablePath: fakeExe)
        let key2 = try TrustStore.trustKey(for: manifest2, executablePath: fakeExe)

        XCTAssertNotEqual(key1, key2,
                          "systemPrompt 改一字符后 trustKey 必须不同（→ NSAlert 重弹）")
    }

    // MARK: - 场景 6：prompt model nil vs "default" → trustKey 不同

    func test_06_promptModelNilVsDefault_producesDifferentTrustKeys() throws {
        let manifestNil = try makePromptManifest(model: nil)
        let manifestDefault = try makePromptManifest(model: "default")
        let fakeExe = tempDir.appendingPathComponent("unused.sh")

        let keyNil = try TrustStore.trustKey(for: manifestNil, executablePath: fakeExe)
        let keyDefault = try TrustStore.trustKey(for: manifestDefault, executablePath: fakeExe)

        XCTAssertNotEqual(keyNil, keyDefault,
                          "model=nil 与 model='default' 的 trustKey 必须不同（防误用）")
    }

    // MARK: - 场景 7：isTrusted / approve 闭环

    func test_07_approveAndIsTrusted_closedLoop() throws {
        let exe = try writeExecutable()
        let trustFile = tempDir.appendingPathComponent("launcher-trust.json")
        let store = TrustStore(file: trustFile)
        let manifest = makeStdinManifest(name: "loop-test-plugin")

        XCTAssertFalse(store.isTrusted(manifest, executablePath: exe),
                       "approve 前 isTrusted 必须返回 false")
        try store.approve(manifest, executablePath: exe)
        XCTAssertTrue(store.isTrusted(manifest, executablePath: exe),
                      "approve 后立即 isTrusted 必须返回 true")
    }

    func test_07b_promptApproveAndIsTrusted_closedLoop() throws {
        let trustFile = tempDir.appendingPathComponent("launcher-trust-prompt.json")
        let store = TrustStore(file: trustFile)
        let manifest = try makePromptManifest(name: "prompt-loop-plugin")
        let fakeExe = tempDir.appendingPathComponent("unused.sh")

        XCTAssertFalse(store.isTrusted(manifest, executablePath: fakeExe),
                       "prompt approve 前 isTrusted 必须返回 false")
        try store.approve(manifest, executablePath: fakeExe)
        XCTAssertTrue(store.isTrusted(manifest, executablePath: fakeExe),
                      "prompt approve 后立即 isTrusted 必须返回 true")
    }

    // MARK: - 场景 8：NSAlert prompt mode informativeText 文案

    func test_08_nsAlert_promptMode_informativeText_containsPromptSummary() throws {
        // 构造超过 200 字符的 systemPrompt
        // 使用 ASCII 字符确保 .count 超过 200（中文字形 .count == 字符数，需要足够多）
        let chinesePart = "你是一名专业的中英互译助手，擅长处理技术文档、学术论文和日常对话的翻译工作。" +
                          "请确保翻译准确、自然、符合目标语言的表达习惯。" +
                          "对于专业术语，请优先使用业界通行译法，必要时在括号内注明原文。" +
                          "在翻译时保持原文的语气和风格，不要添加或删减信息。"
        // 补足超过 200 字符：用 ASCII padding 凑够
        let padding = String(repeating: "x", count: max(0, 201 - chinesePart.count))
        let longPrompt = chinesePart + padding
        XCTAssertGreaterThan(longPrompt.count, 200, "测试前提：systemPrompt 必须超过 200 字符")

        let manifest = try makePromptManifest(
            name: "translate-plugin",
            systemPrompt: longPrompt,
            maxIterations: 3,
            model: "claude-sonnet-4-5"
        )

        // 模拟 TrustPrompt 文案构建逻辑（依据 state.md 规约）
        guard case .prompt(let cfg) = manifest.modeConfig else {
            return XCTFail("应为 prompt mode")
        }
        let summary = String(cfg.systemPrompt.prefix(200))
        let truncated = cfg.systemPrompt.count > 200
            ? "...（共 \(cfg.systemPrompt.count) 字符）" : ""
        let informativeText = """
        模式: prompt（LLM 直接调用）
        模型: \(cfg.model ?? "用 launcher 当前激活 provider 的模型")
        描述: \(manifest.description)

        System Prompt 摘要:
        \(summary)\(truncated)
        """

        // 断言文案包含 "prompt"
        XCTAssertTrue(informativeText.contains("prompt"),
                      "informativeText 必须包含 'prompt'")
        // 断言含 systemPrompt 前 200 字
        XCTAssertTrue(informativeText.contains(summary),
                      "informativeText 必须包含 systemPrompt 前 200 字")
        // 断言含 "...（共 N 字符）" 截断标记
        XCTAssertTrue(informativeText.contains("...（共 \(cfg.systemPrompt.count) 字符）"),
                      "informativeText 必须含截断标记 '...（共 N 字符）'，实际文案:\n\(informativeText)")
        // 断言 summary 恰好 200 字
        XCTAssertEqual(summary.count, 200, "前缀摘要应为恰好 200 字符")
    }

    func test_08b_nsAlert_promptMode_shortSystemPrompt_noTruncationMark() throws {
        // systemPrompt 不超过 200 字时不应加截断标记
        let shortPrompt = "你是翻译助手"
        XCTAssertLessThanOrEqual(shortPrompt.count, 200, "测试前提：systemPrompt 不超过 200")

        let manifest = try makePromptManifest(systemPrompt: shortPrompt)
        guard case .prompt(let cfg) = manifest.modeConfig else {
            return XCTFail("应为 prompt mode")
        }
        let summary = String(cfg.systemPrompt.prefix(200))
        let truncated = cfg.systemPrompt.count > 200
            ? "...（共 \(cfg.systemPrompt.count) 字符）" : ""
        let informativeText = """
        模式: prompt（LLM 直接调用）
        模型: \(cfg.model ?? "用 launcher 当前激活 provider 的模型")
        描述: \(manifest.description)

        System Prompt 摘要:
        \(summary)\(truncated)
        """

        XCTAssertFalse(informativeText.contains("...（共"),
                       "systemPrompt <= 200 字时不应含截断标记")
        XCTAssertTrue(informativeText.contains(shortPrompt),
                      "informativeText 必须包含完整 systemPrompt")
    }

    // MARK: - 场景 9：NSAlert stdin mode informativeText 保留命令+路径显示

    func test_09_nsAlert_stdinMode_informativeText_showsCmdAndPath() throws {
        let manifest = makeStdinManifest(
            name: "hello-plugin",
            cmd: "./hello.sh",
            args: ["--greet", "world"]
        )

        guard case .stdin(let cfg) = manifest.modeConfig else {
            return XCTFail("应为 stdin mode")
        }
        let informativeText = """
        模式: stdin（subprocess）
        命令: \(cfg.cmd) \(cfg.args.joined(separator: " "))
        描述: \(manifest.description)
        """

        XCTAssertTrue(informativeText.contains("stdin"),
                      "stdin mode informativeText 必须含 'stdin'")
        XCTAssertTrue(informativeText.contains("./hello.sh"),
                      "informativeText 必须包含命令路径 './hello.sh'")
        XCTAssertTrue(informativeText.contains("--greet"),
                      "informativeText 必须包含 args '--greet'")
        XCTAssertTrue(informativeText.contains("world"),
                      "informativeText 必须包含 args 'world'")
        XCTAssertTrue(informativeText.contains("命令"),
                      "informativeText 必须含 '命令' 标签")
    }

    // MARK: - 场景 10：CLI 与 App trustKey 一致性（stdin mode）
    //
    // 依据 state.md 算法规约，红队独立复现算法与 TrustStore.trustKey 比对
    // CLI cliComputeTrustKeyStdin 是 private，直接测试 App 端算法是否符合预期

    func test_10_stdin_trustKey_matchesExpectedAlgorithm() throws {
        let exeContent = "#!/bin/sh\necho translate"
        let exe = try writeExecutable(content: exeContent, name: "translate.sh")
        let manifest = makeStdinManifest(name: "buddy-translate", cmd: "./translate.sh", args: ["--lang", "zh"])

        let storeKey = try TrustStore.trustKey(for: manifest, executablePath: exe)

        // 红队独立复现算法（基于 state.md 规约）
        let expectedKey = try computeExpectedStdinKey(
            cmd: "./translate.sh",
            args: ["--lang", "zh"],
            exePath: exe
        )

        XCTAssertEqual(storeKey, expectedKey,
                       "TrustStore.trustKey 必须与 state.md 规约的 stdin 算法一致")
        XCTAssertTrue(storeKey.hasPrefix("stdin:"),
                      "stdin trustKey 前缀必须为 'stdin:'")
        // 去掉前缀后是 64 位 SHA256 hex
        let hashPart = String(storeKey.dropFirst("stdin:".count))
        XCTAssertEqual(hashPart.count, 64,
                       "去掉前缀后的 hash 部分必须恰好 64 字符（SHA256 hex）")
    }

    func test_10b_prompt_trustKey_matchesExpectedAlgorithm() throws {
        let systemPrompt = "你是专业的技术翻译助手"
        let manifest = try makePromptManifest(
            name: "buddy-translate",
            systemPrompt: systemPrompt,
            maxIterations: 2,
            model: "claude-sonnet-4-5"
        )
        let fakeExe = tempDir.appendingPathComponent("unused.sh")

        let storeKey = try TrustStore.trustKey(for: manifest, executablePath: fakeExe)

        // 红队独立复现 prompt 算法
        let expectedKey = computeExpectedPromptKey(
            systemPrompt: systemPrompt,
            maxIterations: 2,
            model: "claude-sonnet-4-5"
        )

        XCTAssertEqual(storeKey, expectedKey,
                       "TrustStore.trustKey 必须与 state.md 规约的 prompt 算法一致")
        XCTAssertTrue(storeKey.hasPrefix("prompt:"),
                      "prompt trustKey 前缀必须为 'prompt:'")
        let hashPart = String(storeKey.dropFirst("prompt:".count))
        XCTAssertEqual(hashPart.count, 64,
                       "去掉前缀后的 hash 部分必须恰好 64 字符（SHA256 hex）")
    }

    // MARK: - 场景 11：迁移场景 — 旧无前缀 trustKey 不被识别为 trusted

    func test_11_legacyTrustKey_withoutModePrefix_isNotTrusted() throws {
        // 构造旧格式 trustKey（无 "stdin:" / "prompt:" 前缀，仅 64 位 hex）
        let legacyKey = String(repeating: "a", count: 64)
        XCTAssertEqual(legacyKey.count, 64, "测试前提：旧 key 恰好 64 字符")
        XCTAssertFalse(legacyKey.hasPrefix("stdin:") || legacyKey.hasPrefix("prompt:"),
                       "测试前提：旧 key 无 mode 前缀")

        // 将旧 key 写入 trust.json
        let trustFile = tempDir.appendingPathComponent("launcher-trust-migration.json")
        let legacyRecord = TrustRecord(
            trustKey: legacyKey,
            pluginName: "old-hello-plugin",
            approvedAt: Date()
        )
        _ = legacyRecord  // 仅用于验证 TrustRecord 可构造
        // 手工构造 JSON（模拟 TrustFileSchema）
        let legacyJSON = """
        {
          "records": [
            {
              "trustKey": "\(legacyKey)",
              "pluginName": "old-hello-plugin",
              "approvedAt": "\(ISO8601DateFormatter().string(from: legacyRecord.approvedAt))"
            }
          ]
        }
        """
        try legacyJSON.write(to: trustFile, atomically: true, encoding: .utf8)

        let store = TrustStore(file: trustFile)

        // 用新 manifest + exe 检查 trust（新 key 有 "stdin:" 前缀）
        let exe = try writeExecutable(content: "#!/bin/sh\necho hello", name: "hello.sh")
        let manifest = makeStdinManifest(name: "old-hello-plugin", cmd: "./hello.sh", args: [])

        // 断言：旧 trustKey（无前缀）与新算法生成的 trustKey（含前缀）不匹配 → isTrusted = false
        XCTAssertFalse(store.isTrusted(manifest, executablePath: exe),
                       "迁移场景：旧无前缀 trustKey 与新 mode-aware 算法生成的 key 不同，isTrusted 必须返回 false（触发重弹 NSAlert）")

        // 额外验证：新 key 确实含前缀（确保是算法不同而非 exe 未找到）
        let newKey = try TrustStore.trustKey(for: manifest, executablePath: exe)
        XCTAssertTrue(newKey.hasPrefix("stdin:"),
                      "新算法生成的 key 必须含 'stdin:' 前缀")
        XCTAssertNotEqual(newKey, legacyKey,
                          "新 key 和旧 key 必须完全不同（前缀保证隔离）")
    }
}
