import XCTest
@testable import BuddyCore

// MARK: - PluginDispatcherAcceptanceTests
//
// 红队验收测试：PluginDispatcher 全契约覆盖（7 个场景）
//
// 设计文档引用：
//   .autopilot/runtime/sessions/translate/requirements/20260529-003-plugin-dispatcher/state.md
//   .autopilot/project/tasks/003-plugin-dispatcher.md
//
// 黑盒原则：通过公开 API 验证契约，不依赖内部实现细节。
// 红队铁律：本文件独立编写，未读取 StdinExecutor.swift / PluginDispatcher.swift 的实现代码。
//
// ⚠️ 字符串字面量：消息里字段名用「」括号（task 002 踩坑教训，避免 ASCII 双引号嵌套）。

// MARK: - Mock StdinExecutor（用于注入验证场景 4）

/// 可记录调用次数的 mock — 继承 StdinExecutor，覆写 execute 返回固定值
final class MockStdinExecutor: StdinExecutor {

    var callCount = 0
    var capturedManifest: PluginManifest?
    var capturedInput: PluginInput?

    /// 固定返回值（不实际 fork 子进程）
    var stubbedResult = PluginResult(
        stdout: "mock-stdout\n",
        stderr: "",
        exitCode: 0,
        durationMs: 1,
        stdoutTruncated: false
    )

    override func execute(
        _ plugin: PluginManifest,
        pluginDir: URL,
        input: PluginInput
    ) async throws -> PluginResult {
        callCount += 1
        capturedManifest = plugin
        capturedInput = input
        return stubbedResult
    }
}

// MARK: - PluginDispatcherAcceptanceTests

final class PluginDispatcherAcceptanceTests: XCTestCase {

    // MARK: - Fixture helpers

    private var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "PluginDispatcherAcceptanceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let dir = tmpDir {
            try? FileManager.default.removeItem(at: dir)
        }
        tmpDir = nil
        try await super.tearDown()
    }

    /// 构造 builtin-hello 风格的 stdin plugin 目录，含 hello.sh + plugin.json
    private func makeStdinPluginDir(
        dirName: String = "test-hello",
        script: String = "#!/bin/bash\necho \"## Hello, world!\"\nexit 0\n"
    ) throws -> (pluginDir: URL, manifest: PluginManifest) {
        let pluginDir = tmpDir.appending(path: dirName)
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)

        // 写 hello.sh（0o755 权限）
        let scriptURL = pluginDir.appending(path: "hello.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )

        // 写 plugin.json（mode: "stdin"，与 builtin-hello 格式一致）
        let pluginJSON = """
        {
          "name": "\(dirName)",
          "version": "0.1.0",
          "description": "dispatcher acceptance test fixture",
          "keywords": [],
          "mode": "stdin",
          "cmd": "./hello.sh",
          "args": [],
          "env": null,
          "timeout": 5,
          "requiredPath": null
        }
        """
        try pluginJSON.write(
            to: pluginDir.appending(path: "plugin.json"),
            atomically: true, encoding: .utf8
        )

        let data = try Data(contentsOf: pluginDir.appending(path: "plugin.json"))
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        return (pluginDir, manifest)
    }

    /// 构造 prompt mode PluginManifest（纯内存，不需要脚本文件）
    private func makePromptManifest(name: String = "test-translate") -> PluginManifest {
        let json = """
        {
          "name": "\(name)",
          "version": "0.1.0",
          "description": "prompt mode fixture",
          "keywords": [],
          "mode": "prompt",
          "systemPrompt": "你是中英互译助手",
          "maxIterations": 1
        }
        """
        let data = json.data(using: .utf8)!
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(PluginManifest.self, from: data)
    }

    private func makeInput(query: String = "hello") -> PluginInput {
        PluginInput(
            query: query,
            sessionId: UUID().uuidString,
            cwd: "/tmp"
        )
    }

    // MARK: - 场景 1：stdin manifest 走 dispatcher 等价直调 StdinExecutor
    //
    // 契约引用：state.md 验证方案场景 1；brief 验收标准 Tier 1 第 1 条
    // 核心断言：dispatcher.execute(stdin) 与 StdinExecutor().execute() 直调返回相同 exitCode/stdout/stderr/stdoutTruncated

    func test_StdinManifest_DispatcherResult_EquivalentToDirectExecutorCall() async throws {
        let (pluginDir, manifest) = try makeStdinPluginDir()
        let input = makeInput(query: "world")

        // 直调 StdinExecutor（蓝队重命名后的 executor）
        let directExecutor = StdinExecutor()
        let directResult = try await directExecutor.execute(manifest, pluginDir: pluginDir, input: input)

        // 通过 dispatcher（注入同类型 executor）调用
        let dispatcher = PluginDispatcher(stdinExecutor: StdinExecutor())
        let dispatchedResult = try await dispatcher.execute(manifest, pluginDir: pluginDir, input: input)

        XCTAssertEqual(dispatchedResult.exitCode, directResult.exitCode,
                       "dispatcher 路由 stdin 后 exitCode 必须与直调等价")
        XCTAssertEqual(dispatchedResult.stdout, directResult.stdout,
                       "dispatcher 路由 stdin 后 stdout 必须与直调等价")
        XCTAssertEqual(dispatchedResult.stderr, directResult.stderr,
                       "dispatcher 路由 stdin 后 stderr 必须与直调等价")
        XCTAssertEqual(dispatchedResult.stdoutTruncated, directResult.stdoutTruncated,
                       "dispatcher 路由 stdin 后 stdoutTruncated 必须与直调等价")
    }

    // MARK: - 场景 2：prompt manifest 走 dispatcher 抛 promptExecutorNotAvailable
    //
    // 契约引用：state.md 验证方案场景 2；state.md 决策 2 错误路径；brief 验收标准 Tier 1 第 2 条
    // 核心断言：dispatcher.execute(prompt manifest) 抛 LauncherError.promptExecutorNotAvailable

    func test_PromptManifest_DispatcherThrows_PromptExecutorNotAvailable() async throws {
        let manifest = makePromptManifest()
        let dispatcher = PluginDispatcher(stdinExecutor: StdinExecutor())
        let pluginDir = tmpDir.appending(path: "prompt-plugin")
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)

        do {
            _ = try await dispatcher.execute(manifest, pluginDir: pluginDir, input: makeInput())
            XCTFail("prompt mode plugin 应抛 LauncherError.promptExecutorNotAvailable")
        } catch LauncherError.promptExecutorNotAvailable {
            // 期望路径：正确抛出此错误
        } catch {
            XCTFail("应抛 LauncherError.promptExecutorNotAvailable，实际: \(error)")
        }
    }

    // MARK: - 场景 3：dispatcher singleton 同一实例
    //
    // 契约引用：state.md 决策 2「static let shared = PluginDispatcher()」；验证方案场景 3
    // 核心断言：PluginDispatcher.shared === PluginDispatcher.shared（引用相等）

    func test_PluginDispatcherShared_IsSingleton() {
        let instance1 = PluginDispatcher.shared
        let instance2 = PluginDispatcher.shared

        XCTAssertTrue(
            instance1 === instance2,
            "PluginDispatcher.shared 每次访问必须返回同一实例（singleton），实际是两个不同对象"
        )
    }

    // MARK: - 场景 4：dispatcher 注入 custom executor 时调用 custom executor
    //
    // 契约引用：state.md 决策 2「init(stdinExecutor: StdinExecutor = .shared)」；brief 验收标准 Tier 1 第 3 条
    // 核心断言：PluginDispatcher(stdinExecutor: mock) 执行 stdin manifest 时 mock.callCount == 1

    func test_DispatcherInjectsCustomExecutor_CallsCustomExecutorForStdin() async throws {
        let (pluginDir, manifest) = try makeStdinPluginDir(dirName: "inject-test")
        let mockExecutor = MockStdinExecutor()
        let dispatcher = PluginDispatcher(stdinExecutor: mockExecutor)

        let result = try await dispatcher.execute(manifest, pluginDir: pluginDir, input: makeInput())

        XCTAssertEqual(mockExecutor.callCount, 1,
                       "注入 custom executor 后 stdin manifest 必须调 custom executor 一次，实际 callCount=\(mockExecutor.callCount)")
        XCTAssertEqual(result.stdout, mockExecutor.stubbedResult.stdout,
                       "dispatcher 返回值必须来自 custom executor，而不是另行执行子进程")
        XCTAssertEqual(mockExecutor.capturedManifest, manifest,
                       "custom executor 收到的 manifest 必须与传入的一致")
    }

    // MARK: - 场景 5：CLIPluginManifestCheck prompt mode decode 不崩溃
    //
    // 契约引用：state.md 决策 4「CLIPluginManifestCheck 加 mode 字段 + cmd/args 改 Optional」；验证方案场景 5
    // 核心断言：prompt mode plugin.json 通过 PluginManifest Codable decode 不抛错（验证 schema 向前兼容）
    //
    // 注：BuddyCLI 是 executable target，无法直接测其函数；本测试通过 PluginManifest decode
    //     验证 prompt mode schema（含无 cmd/args 字段）能被正确解析，作为 CLIPluginManifestCheck
    //     Optional cmd/args 改动的间接覆盖。

    func test_CLIPluginManifestCheck_promptMode_decodesOptionalCmdArgs() throws {
        // 构造典型的 prompt mode plugin.json（无 cmd / args 字段）
        let promptPluginJSON = """
        {
          "name": "test-translate",
          "version": "0.1.0",
          "description": "翻译插件（prompt mode）",
          "keywords": ["translate"],
          "mode": "prompt",
          "systemPrompt": "你是中英互译助手，请将输入内容翻译为目标语言",
          "maxIterations": 1
        }
        """
        let data = promptPluginJSON.data(using: .utf8)!

        // prompt mode plugin.json 不含 cmd/args，decode 应成功（不抛 DecodingError）
        XCTAssertNoThrow(
            try JSONDecoder().decode(PluginManifest.self, from: data),
            "prompt mode plugin.json（无 cmd/args 字段）应 decode 成功，不抛 DecodingError"
        )

        let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        // prompt mode 的 modeConfig 必须是 .prompt
        guard case .prompt(let cfg) = manifest.modeConfig else {
            return XCTFail("prompt mode plugin.json 应 decode 为 .prompt，实际: \(manifest.modeConfig)")
        }
        XCTAssertFalse(cfg.systemPrompt.isEmpty,
                       "「systemPrompt」不能为空字符串")
    }

    // MARK: - 场景 6：CLIPluginManifestCheck stdin manifest（旧格式）行为不变
    //
    // 契约引用：state.md 决策 4「旧 plugin.json（无 mode 字段）→ 走 stdin 分支」；验证方案场景 6
    // 核心断言：旧格式 plugin.json（无 mode 字段）decode 成功，「cmd」/「args」字段值正确

    func test_CLIPluginManifestCheck_stdinManifest_legacyFormatDecodesCorrectly() throws {
        // 典型旧格式：无 mode 字段（向后兼容，应默认 stdin）
        let legacyJSON = """
        {
          "name": "my-plugin",
          "version": "1.0.0",
          "description": "旧格式插件",
          "keywords": [],
          "cmd": "./run.sh",
          "args": ["--flag"],
          "env": null,
          "timeout": 10
        }
        """
        let data = legacyJSON.data(using: .utf8)!
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)

        // 旧格式无 mode 字段 → 应 decode 为 stdin
        guard case .stdin(let cfg) = manifest.modeConfig else {
            return XCTFail("无 mode 字段的旧格式应 decode 为 .stdin，实际: \(manifest.modeConfig)")
        }

        XCTAssertEqual(cfg.cmd, "./run.sh",
                       "旧格式「cmd」字段值必须正确读取，实际: \(cfg.cmd)")
        XCTAssertEqual(cfg.args, ["--flag"],
                       "旧格式「args」字段值必须正确读取，实际: \(cfg.args)")
    }

    // MARK: - 场景 7：StdinExecutor singleton 同一实例
    //
    // 契约引用：state.md 决策 1「保持 static let shared = StdinExecutor()」；验证方案场景 7
    // 核心断言：StdinExecutor.shared === StdinExecutor.shared（引用相等）

    func test_StdinExecutorShared_IsSingleton() {
        let instance1 = StdinExecutor.shared
        let instance2 = StdinExecutor.shared

        XCTAssertTrue(
            instance1 === instance2,
            "StdinExecutor.shared 每次访问必须返回同一实例（singleton），实际是两个不同对象"
        )
    }
}
