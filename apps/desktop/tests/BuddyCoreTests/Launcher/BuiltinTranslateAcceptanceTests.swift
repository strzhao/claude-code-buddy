import XCTest
import AppKit
@testable import BuddyCore

// MARK: - BuiltinTranslateAcceptanceTests
//
// 红队验收测试：Task 006 builtin-translate prompt plugin
//
// 场景覆盖（共 10 个）：
//   SC-1   PromptConfig decode autoCopyToClipboard：缺字段 → false；显式 true/false → 各自
//   SC-2   PromptExecutor 不复制：autoCopyToClipboard=false → stdout 末尾无已复制字样；隔离 pasteboard 不变
//   SC-3   PromptExecutor 复制：autoCopyToClipboard=true + 非空 stdout → 隔离 pasteboard == 响应文本；stdout 末尾含提示
//   SC-4   PromptExecutor 空 stdout 不复制：autoCopyToClipboard=true + provider 返回 .text("") → 隔离 pasteboard 不变
//   SC-5   PromptExecutor 错误时不复制：mock provider 抛错 → exitCode=1 + 隔离 pasteboard 不变
//   SC-6   installBundledPlugins 多 plugin：builtin-hello + builtin-translate 目录均存在
//   SC-7   prompt mode skip chmod：builtin-translate 目录内无可执行文件（仅 plugin.json）
//   SC-8   stdin mode 保留 chmod：builtin-hello/hello.sh 仍有 posix 权限 0o755
//   SC-9   inspect 替代方案：构造 prompt mode manifest，JSON encode 含 mode=prompt 字段不抛错
//   SC-10  TranslatePlugin/plugin.json fixture：decode 为 PluginManifest → modeConfig=.prompt + systemPrompt 含 中英互译 + autoCopyToClipboard==true
//
// 铁律：本文件由红队独立编写，不读取蓝队新写的实现代码。
// ⚠️ 消息字符串不混用 ASCII 双引号包含中文（task 002 教训）。

// MARK: - Mock Provider（隔离 LLM 依赖）

private final class MockTranslateProvider: LauncherProvider {
    var responseToReturn: AgentResponse
    var errorToThrow: Error?

    init(text: String = "hello") {
        responseToReturn = AgentResponse(
            content: [.text(text)],
            stopReason: "end_turn",
            usage: nil
        )
    }

    func send(
        messages: [AgentMessage],
        tools: [AgentTool],
        model: String,
        system: String?
    ) async throws -> AgentResponse {
        if let error = errorToThrow { throw error }
        return responseToReturn
    }
}

// MARK: - BuiltinTranslateAcceptanceTests

final class BuiltinTranslateAcceptanceTests: XCTestCase {

    // MARK: - Helpers

    private var fakePluginDir: URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
    }

    private func makeIsolatedPasteboard() -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("buddy-test-\(UUID().uuidString)"))
        pb.clearContents()
        return pb
    }

    private func setPasteboardSentinel(_ pb: NSPasteboard, value: String = "SENTINEL_UNCHANGED") {
        pb.clearContents()
        pb.setString(value, forType: .string)
    }

    private func decodeManifest(_ json: String) throws -> PluginManifest {
        let data = json.data(using: .utf8)!
        return try JSONDecoder().decode(PluginManifest.self, from: data)
    }

    private func makePromptManifest(
        name: String = "test-plugin",
        systemPrompt: String = "你是翻译助手",
        model: String? = nil,
        autoCopyToClipboard: Bool = false,
        timeout: Int? = 5
    ) throws -> PluginManifest {
        let autoCopyStr = autoCopyToClipboard ? "true" : "false"
        let modelStr = model.map { "\"\($0)\"" } ?? "null"
        let json = """
        {
            "name": "\(name)",
            "version": "0.1.0",
            "description": "test plugin",
            "keywords": [],
            "mode": "prompt",
            "systemPrompt": "\(systemPrompt)",
            "maxIterations": 1,
            "model": \(modelStr),
            "autoCopyToClipboard": \(autoCopyStr),
            "timeout": \(timeout ?? 5)
        }
        """
        return try decodeManifest(json)
    }

    private func makeInput(query: String = "hello") -> PluginInput {
        PluginInput(query: query, sessionId: UUID().uuidString, cwd: NSTemporaryDirectory())
    }

    // MARK: - SC-1: PromptConfig decode autoCopyToClipboard

    /// 缺 autoCopyToClipboard 字段 → 默认 false。
    func test_SC1a_promptConfig_missingAutoCopy_defaultsFalse() throws {
        let json = """
        {
            "name": "test-plugin",
            "version": "0.1.0",
            "description": "test",
            "keywords": [],
            "mode": "prompt",
            "systemPrompt": "你是助手",
            "maxIterations": 1
        }
        """
        let manifest = try decodeManifest(json)
        guard case .prompt(let cfg) = manifest.modeConfig else {
            return XCTFail("应 decode 为 .prompt，实际: \(manifest.modeConfig)")
        }
        XCTAssertFalse(cfg.autoCopyToClipboard,
                       "缺 autoCopyToClipboard 字段时默认应为 false")
    }

    /// autoCopyToClipboard=true → decode 后为 true。
    func test_SC1b_promptConfig_explicitTrue_decodesTrue() throws {
        let json = """
        {
            "name": "test-plugin",
            "version": "0.1.0",
            "description": "test",
            "keywords": [],
            "mode": "prompt",
            "systemPrompt": "你是助手",
            "maxIterations": 1,
            "autoCopyToClipboard": true
        }
        """
        let manifest = try decodeManifest(json)
        guard case .prompt(let cfg) = manifest.modeConfig else {
            return XCTFail("应 decode 为 .prompt，实际: \(manifest.modeConfig)")
        }
        XCTAssertTrue(cfg.autoCopyToClipboard,
                      "autoCopyToClipboard=true 时 decode 后应为 true")
    }

    /// autoCopyToClipboard=false → decode 后为 false。
    func test_SC1c_promptConfig_explicitFalse_decodesFalse() throws {
        let json = """
        {
            "name": "test-plugin",
            "version": "0.1.0",
            "description": "test",
            "keywords": [],
            "mode": "prompt",
            "systemPrompt": "你是助手",
            "maxIterations": 1,
            "autoCopyToClipboard": false
        }
        """
        let manifest = try decodeManifest(json)
        guard case .prompt(let cfg) = manifest.modeConfig else {
            return XCTFail("应 decode 为 .prompt，实际: \(manifest.modeConfig)")
        }
        XCTAssertFalse(cfg.autoCopyToClipboard,
                       "autoCopyToClipboard=false 时 decode 后应为 false")
    }

    // MARK: - SC-2: PromptExecutor 不复制（autoCopyToClipboard=false）

    /// autoCopyToClipboard=false → stdout 末尾无已复制字样；隔离 pasteboard 不变。
    func test_SC2_promptExecutor_noCopy_whenAutoCopyFalse() async throws {
        let pb = makeIsolatedPasteboard()
        let sentinel = "SENTINEL_SC2"
        setPasteboardSentinel(pb, value: sentinel)

        let mockProvider = MockTranslateProvider(text: "hello world")
        let executor = PromptExecutor(
            provider: mockProvider,
            activeProviderModel: "test-model",
            pasteboard: pb
        )
        let manifest = try makePromptManifest(autoCopyToClipboard: false)
        let input = makeInput(query: "你好")

        let result = try await executor.execute(manifest, pluginDir: fakePluginDir, input: input)

        XCTAssertFalse(result.stdout.contains("已复制"),
                       "autoCopyToClipboard=false 时 stdout 不应含已复制字样，实际: \(result.stdout)")
        XCTAssertEqual(pb.string(forType: .string), sentinel,
                       "autoCopyToClipboard=false 时隔离 pasteboard 内容应保持 sentinel 不变")
    }

    // MARK: - SC-3: PromptExecutor 复制（autoCopyToClipboard=true + 非空响应）

    /// autoCopyToClipboard=true + provider 返回非空文本 → 隔离 pasteboard == 响应文本；stdout 末尾含已复制提示。
    func test_SC3_promptExecutor_copiesText_andAppendsSuffix_whenAutoCopyTrue() async throws {
        let pb = makeIsolatedPasteboard()
        setPasteboardSentinel(pb, value: "OLD_CONTENT")

        let responseText = "hello world"
        let mockProvider = MockTranslateProvider(text: responseText)
        let executor = PromptExecutor(
            provider: mockProvider,
            activeProviderModel: "test-model",
            pasteboard: pb
        )
        let manifest = try makePromptManifest(autoCopyToClipboard: true)
        let input = makeInput(query: "你好世界")

        let result = try await executor.execute(manifest, pluginDir: fakePluginDir, input: input)

        XCTAssertEqual(pb.string(forType: .string), responseText,
                       "autoCopyToClipboard=true 时隔离 pasteboard 应等于响应文本")
        XCTAssertTrue(result.stdout.contains("已复制到剪贴板"),
                      "stdout 应含已复制到剪贴板提示，实际: \(result.stdout)")
    }

    // MARK: - SC-4: PromptExecutor 空 stdout 不复制

    /// autoCopyToClipboard=true + provider 返回空文本 → 隔离 pasteboard 不变。
    func test_SC4_promptExecutor_doesNotCopy_whenStdoutEmpty() async throws {
        let pb = makeIsolatedPasteboard()
        let sentinel = "SENTINEL_SC4"
        setPasteboardSentinel(pb, value: sentinel)

        let mockProvider = MockTranslateProvider(text: "")
        let executor = PromptExecutor(
            provider: mockProvider,
            activeProviderModel: "test-model",
            pasteboard: pb
        )
        let manifest = try makePromptManifest(autoCopyToClipboard: true)
        let input = makeInput(query: "你好")

        let result = try await executor.execute(manifest, pluginDir: fakePluginDir, input: input)

        XCTAssertEqual(pb.string(forType: .string), sentinel,
                       "provider 返回空文本时隔离 pasteboard 应保持 sentinel 不变，实际: \(pb.string(forType: .string) ?? "nil")")
        XCTAssertFalse(result.stdout.contains("已复制到剪贴板"),
                       "空响应时 stdout 不应含已复制到剪贴板提示")
    }

    // MARK: - SC-5: PromptExecutor 错误时不复制

    /// mock provider 抛错 → exitCode=1 + 隔离 pasteboard 不变。
    func test_SC5_promptExecutor_doesNotCopy_onProviderError() async throws {
        let pb = makeIsolatedPasteboard()
        let sentinel = "SENTINEL_SC5"
        setPasteboardSentinel(pb, value: sentinel)

        let mockProvider = MockTranslateProvider()
        mockProvider.errorToThrow = LauncherError.providerHTTPError(500, "Internal Server Error")
        let executor = PromptExecutor(
            provider: mockProvider,
            activeProviderModel: "test-model",
            pasteboard: pb
        )
        let manifest = try makePromptManifest(autoCopyToClipboard: true)
        let input = makeInput(query: "翻译这个")

        let result = try await executor.execute(manifest, pluginDir: fakePluginDir, input: input)

        XCTAssertEqual(result.exitCode, 1,
                       "provider 抛错时 exitCode 应为 1，实际: \(result.exitCode)")
        XCTAssertEqual(pb.string(forType: .string), sentinel,
                       "provider 抛错时隔离 pasteboard 应保持 sentinel 不变，实际: \(pb.string(forType: .string) ?? "nil")")
    }

    // MARK: - SC-6: installBundledPlugins 多 plugin 部署

    /// 调用 installBundledPlugins 后 builtin-hello 和 builtin-translate 目录均存在。
    func test_SC6_installBundledPlugins_createsBothPluginDirs() throws {
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("BuddyTranslateTest-SC6-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let mgr = PluginManager(rootDir: tmpRoot)
        try mgr.installBundledPlugins()

        let helloDir = tmpRoot.appendingPathComponent("builtin-hello")
        let translateDir = tmpRoot.appendingPathComponent("builtin-translate")

        XCTAssertTrue(FileManager.default.fileExists(atPath: helloDir.path),
                      "installBundledPlugins 后 builtin-hello 目录应存在")
        XCTAssertTrue(FileManager.default.fileExists(atPath: translateDir.path),
                      "installBundledPlugins 后 builtin-translate 目录应存在")
    }

    // MARK: - SC-7: prompt mode skip chmod（builtin-translate 无可执行文件）

    /// builtin-translate 目录内仅有 plugin.json，无可执行文件。
    func test_SC7_builtinTranslate_hasOnlyPluginJson_noExecutable() throws {
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("BuddyTranslateTest-SC7-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let mgr = PluginManager(rootDir: tmpRoot)
        try mgr.installBundledPlugins()

        let translateDir = tmpRoot.appendingPathComponent("builtin-translate")
        let pluginJsonPath = translateDir.appendingPathComponent("plugin.json")

        XCTAssertTrue(FileManager.default.fileExists(atPath: pluginJsonPath.path),
                      "builtin-translate/plugin.json 应存在")

        // 枚举目录内容，确认无可执行文件（无 .sh 或有执行权限的非 json 文件）
        let contents = try FileManager.default.contentsOfDirectory(
            at: translateDir,
            includingPropertiesForKeys: [.isExecutableKey],
            options: []
        )
        let executableFiles = try contents.filter { url in
            guard url.lastPathComponent != "plugin.json" else { return false }
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let perms = (attrs[.posixPermissions] as? Int) ?? 0
            return (perms & 0o111) != 0  // 任意执行位被设置
        }
        XCTAssertTrue(executableFiles.isEmpty,
                      "builtin-translate 目录内不应有可执行文件，实际: \(executableFiles.map(\.lastPathComponent))")
    }

    // MARK: - SC-8: stdin mode 保留 chmod（builtin-hello/hello.sh 仍 0o755）

    /// builtin-hello/hello.sh 安装后 posix permissions 应有执行位（0o755）。
    func test_SC8_builtinHello_shellScript_hasExecutePermissions() throws {
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("BuddyTranslateTest-SC8-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let mgr = PluginManager(rootDir: tmpRoot)
        try mgr.installBundledPlugins()

        let helloDir = tmpRoot.appendingPathComponent("builtin-hello")
        let contents = try FileManager.default.contentsOfDirectory(
            at: helloDir,
            includingPropertiesForKeys: [.isExecutableKey],
            options: []
        )
        let shFiles = contents.filter { $0.pathExtension == "sh" }

        XCTAssertFalse(shFiles.isEmpty,
                       "builtin-hello 目录内应至少有一个 .sh 文件")

        for shFile in shFiles {
            let attrs = try FileManager.default.attributesOfItem(atPath: shFile.path)
            let perms = (attrs[.posixPermissions] as? Int) ?? 0
            XCTAssertEqual(perms & 0o755, 0o755,
                           "builtin-hello/\(shFile.lastPathComponent) 应有 0o755 执行权限，实际: \(String(perms, radix: 8))")
        }
    }

    // MARK: - SC-9: inspect 替代方案（prompt mode manifest JSON encode 含 mode 字段）

    // 注：BuddyCLI.cmdLauncherInspect 是 private 函数无法直接测试。
    // 改为：构造 prompt mode PluginManifest fixture，验证 JSON encode 不抛错 + mode 字段可读。
    // BuddyCLI inspect 命令由 task 005 trust 路径间接覆盖。

    func test_SC9_promptManifest_jsonEncode_containsModeField() throws {
        let json = """
        {
            "name": "builtin-translate",
            "version": "0.1.0",
            "description": "中英互译助手",
            "keywords": ["翻译"],
            "mode": "prompt",
            "systemPrompt": "你是专业中英互译助手",
            "maxIterations": 1,
            "autoCopyToClipboard": true
        }
        """
        let manifest = try decodeManifest(json)
        guard case .prompt(let cfg) = manifest.modeConfig else {
            return XCTFail("应 decode 为 .prompt，实际: \(manifest.modeConfig)")
        }

        // JSON encode 不应抛错
        let encoded = try JSONEncoder().encode(manifest)
        let jsonObj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any],
            "encode 结果应为有效 JSON 对象"
        )

        // 验证 encode 后 mode 字段存在且值为 prompt
        XCTAssertEqual(jsonObj["mode"] as? String, "prompt",
                       "encode 后 JSON 应含 mode=prompt 字段")

        // 验证 systemPrompt 从 cfg 中可访问
        XCTAssertFalse(cfg.systemPrompt.isEmpty,
                       "decode 后 systemPrompt 不应为空")
        XCTAssertTrue(cfg.autoCopyToClipboard,
                      "decode 后 autoCopyToClipboard 应为 true")
    }

    // MARK: - SC-10: TranslatePlugin/plugin.json fixture 解析

    /// 构造 TranslatePlugin/plugin.json 内容（与 task 006 brief 完全一致），
    /// decode 为 PluginManifest → modeConfig=.prompt + systemPrompt 含 中英互译 + autoCopyToClipboard==true。
    func test_SC10_translatePluginJson_decodesCorrectly() throws {
        // 与 Sources/.../Plugins/TranslatePlugin/plugin.json 内容完全一致
        let pluginJson = """
        {
            "name": "builtin-translate",
            "version": "0.1.0",
            "description": "中英互译助手，自动检测语言方向",
            "keywords": ["翻译", "translate", "tr", "中英", "英中", "fy"],
            "timeout": 30,
            "mode": "prompt",
            "systemPrompt": "你是一个专业的中英互译助手。\\n\\n规则：\\n1. 检测输入语言：含中文字符 → 译为英文；纯英文/拉丁字符 → 译为中文\\n2. 输出仅包含译文本身，不要任何解释、引号、Markdown 格式\\n3. 保留原文的换行结构与标点风格\\n4. 对于专有名词、代码片段、URL，保持原样不译\\n5. 译文风格：日常流畅，避免机械直译；商务/技术文本保持正式",
            "maxIterations": 1,
            "model": null,
            "autoCopyToClipboard": true
        }
        """

        let manifest = try decodeManifest(pluginJson)

        // 断言 modeConfig == .prompt
        guard case .prompt(let cfg) = manifest.modeConfig else {
            return XCTFail("TranslatePlugin plugin.json 应 decode 为 .prompt mode，实际: \(manifest.modeConfig)")
        }

        // 断言 systemPrompt 含关键短语
        XCTAssertTrue(cfg.systemPrompt.contains("中英互译"),
                      "systemPrompt 应含关键短语 中英互译，实际: \(cfg.systemPrompt)")

        // 断言 autoCopyToClipboard == true
        XCTAssertTrue(cfg.autoCopyToClipboard,
                      "builtin-translate plugin.json 的 autoCopyToClipboard 应为 true")

        // 断言 name 和基本字段
        XCTAssertEqual(manifest.name, "builtin-translate",
                       "name 字段应为 builtin-translate")
        XCTAssertEqual(manifest.version, "0.1.0",
                       "version 字段应为 0.1.0")

        // 断言 maxIterations == 1
        XCTAssertEqual(cfg.maxIterations, 1,
                       "maxIterations 应为 1")

        // 断言 model == nil
        XCTAssertNil(cfg.model,
                     "model 字段应为 nil")
    }
}
