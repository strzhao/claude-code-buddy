import XCTest
@testable import BuddyCore

// MARK: - 红队验收测试：PromptExecutor (Task 004)
//
// 本文件由红队独立编写，仅基于设计文档 + brief，不读取蓝队新写的实现代码。
//
// 契约来源：
//   - .autopilot/project/tasks/004-prompt-executor.md
//   - .autopilot/runtime/sessions/translate/requirements/20260529-004-prompt-executor/state.md（## 设计文档）
//
// 测试场景（12 个）：
//   T01  空 query → stdout="（请输入内容）"，provider.callCount=0
//   T02  空白 query "  \n  " → 同上
//   T03  正常成功：mock provider 返 .text("你好") → stdout="你好"，exitCode=0
//   T04  多 content 合并：[.text("你"), .text("好")] → stdout="你好"
//   T05  provider HTTP 500 → exitCode=1，stderr 含 "执行失败:"
//   T06  超时 cancel 传播：mock sleep 60s，effectiveTimeout=2s → exitCode=1，stderr 含 "执行超时"，mock 收到 CancellationError
//   T07  model 字段回退：cfg.model=nil → send 收到的 model == activeProviderModel
//   T08  system 字段传递：mock 验证 send() system == cfg.systemPrompt
//   T09  dispatcher 注入 promptExecutor → callCount=1
//   T10  dispatcher 无 promptExecutor 抛 promptExecutorNotAvailable
//   T11  stdin 路径回归：注入 mockStdin + mockPrompt，执行 stdinPlugin → mockStdin.callCount=1，mockPrompt.callCount=0
//   T12  LauncherManager prompt 端到端（降级版）：PromptExecutor + dispatcher 组合验证
//        (LauncherManager 集成由 task 006 端到端 e2e 验证)
//
// 注意：消息字符串里不混用 ASCII 双引号包含中文（task 002 踩坑）。
// 编译预期：蓝队完成 PromptExecutor + PluginDispatcher 改动后编译通过；
//           蓝队完成前编译失败（PromptExecutor 类不存在），这是预期红灯。

// MARK: - MockPromptProvider

private final class MockPromptProvider: LauncherProvider {
    var responseToReturn: AgentResponse?
    var errorToThrow: Error?
    var sendDelay: TimeInterval = 0
    private(set) var capturedModel: String?
    private(set) var capturedSystem: String?
    private(set) var capturedMessages: [AgentMessage] = []
    private(set) var callCount = 0
    private(set) var receivedCancellation = false

    func send(
        messages: [AgentMessage],
        tools: [AgentTool],
        model: String,
        system: String?
    ) async throws -> AgentResponse {
        callCount += 1
        capturedModel = model
        capturedSystem = system
        capturedMessages = messages

        if sendDelay > 0 {
            do {
                try await Task.sleep(nanoseconds: UInt64(sendDelay * 1_000_000_000))
            } catch is CancellationError {
                receivedCancellation = true
                throw CancellationError()
            }
        }

        if let error = errorToThrow { throw error }
        return responseToReturn ?? AgentResponse(
            content: [.text("default")],
            stopReason: "end_turn",
            usage: nil
        )
    }
}

// MARK: - PromptExecutorProtocol Mock（用于 dispatcher/LauncherManager 注入测试）
//
// 注：PromptExecutor 是 final class，无法直接子类化（蓝队实现后确认）。
// 通过 PromptExecutorProtocol（或注入 wrapping 的 spy provider）验证 dispatcher 委托。
// 此处直接使用带 spy provider 的真实 PromptExecutor 验证 callCount。

// MARK: - SpyProvider（用于 T09/T12 dispatcher 注入验证）

private final class SpyProvider: LauncherProvider {
    private(set) var callCount = 0
    var responseToReturn = AgentResponse(
        content: [.text("spy-result")],
        stopReason: "end_turn",
        usage: nil
    )

    func send(
        messages: [AgentMessage],
        tools: [AgentTool],
        model: String,
        system: String?
    ) async throws -> AgentResponse {
        callCount += 1
        return responseToReturn
    }
}

// MARK: - Helpers

private let pluginDir = URL(fileURLWithPath: NSTemporaryDirectory())

private func makePromptManifest(
    name: String = "test-plugin",
    systemPrompt: String = "你是翻译助手",
    model: String? = nil,
    timeout: Int? = 30
) -> PluginManifest {
    makePromptManifestDirect(name: name, systemPrompt: systemPrompt, model: model, timeout: timeout)
}

private func makeStdinManifest(name: String = "test-stdin") -> PluginManifest {
    PluginManifest(
        name: name,
        version: "1.0.0",
        description: "test stdin plugin",
        keywords: [name],
        cmd: "./run.sh",
        args: [],
        env: nil,
        timeout: 30,
        requiredPath: nil
    )
}

private func makeInput(query: String = "hello") -> PluginInput {
    PluginInput(query: query, sessionId: UUID().uuidString, cwd: NSTemporaryDirectory())
}

// MARK: - PromptExecutorAcceptanceTests

final class PromptExecutorAcceptanceTests: XCTestCase {

    // MARK: - T01: 空 query → stdout="（请输入内容）"，provider.callCount=0

    /// 空 query 短路：不发 HTTP 请求，返回空输入提示文案，exitCode=0。
    func test_T01_emptyQuery_returnsPromptText_noCalls() async throws {
        let provider = MockPromptProvider()
        let executor = PromptExecutor(provider: provider, activeProviderModel: "any-model")
        let manifest = makePromptManifest()
        let input = makeInput(query: "")

        let result = try await executor.execute(manifest, pluginDir: pluginDir, input: input)

        XCTAssertEqual(result.stdout, "（请输入内容）",
                       "空 query 时 stdout 必须为提示文案")
        XCTAssertEqual(result.exitCode, 0,
                       "空 query 时 exitCode 必须为 0")
        XCTAssertEqual(provider.callCount, 0,
                       "空 query 时 provider.send 不能被调用")
    }

    // MARK: - T02: 空白 query "  \n  " → 同上

    /// 空白（含换行）query 与纯空 query 行为一致：trim 后视为空输入。
    func test_T02_whitespaceOnlyQuery_returnsPromptText_noCalls() async throws {
        let provider = MockPromptProvider()
        let executor = PromptExecutor(provider: provider, activeProviderModel: "any-model")
        let manifest = makePromptManifest()
        let input = makeInput(query: "  \n  ")

        let result = try await executor.execute(manifest, pluginDir: pluginDir, input: input)

        XCTAssertEqual(result.stdout, "（请输入内容）",
                       "空白 query 时 stdout 必须为提示文案")
        XCTAssertEqual(result.exitCode, 0,
                       "空白 query 时 exitCode 必须为 0")
        XCTAssertEqual(provider.callCount, 0,
                       "空白 query 时 provider.send 不能被调用")
    }

    // MARK: - T03: 正常成功路径

    /// mock provider 返回 .text("你好") → stdout="你好"，exitCode=0。
    func test_T03_normalSuccess_returnsProviderText() async throws {
        let provider = MockPromptProvider()
        provider.responseToReturn = AgentResponse(
            content: [.text("你好")],
            stopReason: "end_turn",
            usage: nil
        )
        let executor = PromptExecutor(provider: provider, activeProviderModel: "qwen")
        let manifest = makePromptManifest()
        let input = makeInput(query: "hello")

        let result = try await executor.execute(manifest, pluginDir: pluginDir, input: input)

        XCTAssertEqual(result.stdout, "你好",
                       "成功时 stdout 必须等于 provider 返回的文本")
        XCTAssertEqual(result.exitCode, 0,
                       "成功时 exitCode 必须为 0")
        XCTAssertEqual(provider.callCount, 1,
                       "成功路径 provider.send 应被调用一次")
    }

    // MARK: - T04: 多 content 合并

    /// provider 返回 [.text("你"), .text("好")] → stdout="你好"（拼接）。
    func test_T04_multipleTextContent_joined() async throws {
        let provider = MockPromptProvider()
        provider.responseToReturn = AgentResponse(
            content: [.text("你"), .text("好")],
            stopReason: "end_turn",
            usage: nil
        )
        let executor = PromptExecutor(provider: provider, activeProviderModel: "qwen")
        let manifest = makePromptManifest()
        let input = makeInput(query: "join test")

        let result = try await executor.execute(manifest, pluginDir: pluginDir, input: input)

        XCTAssertEqual(result.stdout, "你好",
                       "多段 .text content 必须拼接为一个完整字符串")
        XCTAssertEqual(result.exitCode, 0)
    }

    // MARK: - T05: provider HTTP 500 → exitCode=1，stderr 含 "执行失败:"

    /// provider 抛 LauncherError.providerHTTPError → exitCode=1，stderr 含 "执行失败:" 前缀。
    func test_T05_providerHTTP500_exitCode1_stderrContainsPrefix() async throws {
        let provider = MockPromptProvider()
        provider.errorToThrow = LauncherError.providerHTTPError(500, "Internal Server Error")
        let executor = PromptExecutor(provider: provider, activeProviderModel: "qwen")
        let manifest = makePromptManifest()
        let input = makeInput(query: "trigger error")

        let result = try await executor.execute(manifest, pluginDir: pluginDir, input: input)

        XCTAssertEqual(result.exitCode, 1,
                       "provider 抛错时 exitCode 必须为 1")
        XCTAssertTrue(result.stderr.contains("执行失败:"),
                      "stderr 必须以 '执行失败:' 开头，实际: \(result.stderr)")
    }

    // MARK: - T06: 超时 cancel 传播

    /// mock provider sleep 60s，manifest.timeout=2s → ≤3s 返回，exitCode=1，
    /// stderr 含 "执行超时"，mock provider 收到 CancellationError。
    func test_T06_timeout_cancelPropagates_exitCode1_stderrContainsTimeout() async throws {
        let provider = MockPromptProvider()
        provider.sendDelay = 60  // 假装执行 60s
        let executor = PromptExecutor(provider: provider, activeProviderModel: "qwen")
        let manifest = makePromptManifest(timeout: 2)  // effectiveTimeout = 2s
        let input = makeInput(query: "long running")

        let start = Date()
        let result = try await executor.execute(manifest, pluginDir: pluginDir, input: input)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(result.exitCode, 1,
                       "超时时 exitCode 必须为 1")
        XCTAssertTrue(result.stderr.contains("执行超时"),
                      "超时时 stderr 必须含 '执行超时'，实际: \(result.stderr)")
        XCTAssertLessThanOrEqual(elapsed, 3.5,
                                 "超时应在 2s 内触发（测试宽限 3.5s），实际耗时: \(elapsed)s")
        XCTAssertTrue(provider.receivedCancellation,
                      "provider.send 必须收到 CancellationError（cancel 真传播）")
    }

    // MARK: - T07: model 字段回退

    /// cfg.model=nil → send 收到的 model 参数等于 activeProviderModel。
    func test_T07_modelNil_fallsBackToActiveProviderModel() async throws {
        let provider = MockPromptProvider()
        provider.responseToReturn = AgentResponse(
            content: [.text("ok")],
            stopReason: "end_turn",
            usage: nil
        )
        let activeModel = "qwen2.5:7b"
        let executor = PromptExecutor(provider: provider, activeProviderModel: activeModel)
        let manifest = makePromptManifest(model: nil)  // cfg.model == nil
        let input = makeInput(query: "model test")

        _ = try await executor.execute(manifest, pluginDir: pluginDir, input: input)

        XCTAssertEqual(provider.capturedModel, activeModel,
                       "cfg.model=nil 时应使用 activeProviderModel，实际传入: \(provider.capturedModel ?? "nil")")
    }

    // MARK: - T08: system 字段传递

    /// mock 验证 send() 的 system 参数 == cfg.systemPrompt。
    func test_T08_systemPrompt_passedToProvider() async throws {
        let provider = MockPromptProvider()
        provider.responseToReturn = AgentResponse(
            content: [.text("ok")],
            stopReason: "end_turn",
            usage: nil
        )
        let expectedSystem = "你是专业的中英翻译助手，只输出译文"
        let executor = PromptExecutor(provider: provider, activeProviderModel: "qwen")
        let manifest = makePromptManifest(systemPrompt: expectedSystem)
        let input = makeInput(query: "system test")

        _ = try await executor.execute(manifest, pluginDir: pluginDir, input: input)

        XCTAssertEqual(provider.capturedSystem, expectedSystem,
                       "provider.send 的 system 参数必须等于 cfg.systemPrompt")
    }

    // MARK: - T09: dispatcher 注入 promptExecutor → provider 被调用（callCount=1）

    /// PluginDispatcher 注入真实 PromptExecutor（带 spy provider），
    /// 执行 prompt plugin → spy provider callCount=1，验证 dispatcher 正确委托。
    func test_T09_dispatcherWithPromptExecutor_delegatesExecution() async throws {
        let spy = SpyProvider()
        let promptExecutor = PromptExecutor(provider: spy, activeProviderModel: "qwen")
        let dispatcher = PluginDispatcher(
            stdinExecutor: StdinExecutor.shared,
            promptExecutor: promptExecutor
        )
        let manifest = makePromptManifest()
        let input = makeInput(query: "dispatch test")

        _ = try await dispatcher.execute(manifest, pluginDir: pluginDir, input: input)

        XCTAssertEqual(spy.callCount, 1,
                       "dispatcher 注入 promptExecutor 后，prompt plugin 必须委托给 promptExecutor（spy provider callCount=1）")
    }

    // MARK: - T10: dispatcher 无 promptExecutor 抛 promptExecutorNotAvailable

    /// PluginDispatcher(promptExecutor: nil) 执行 prompt plugin → 抛 promptExecutorNotAvailable。
    func test_T10_dispatcherWithoutPromptExecutor_throwsNotAvailable() async throws {
        let dispatcher = PluginDispatcher(
            stdinExecutor: StdinExecutor.shared,
            promptExecutor: nil
        )
        let manifest = makePromptManifest()
        let input = makeInput(query: "no executor test")

        do {
            _ = try await dispatcher.execute(manifest, pluginDir: pluginDir, input: input)
            XCTFail("应抛出 promptExecutorNotAvailable，但未抛出任何错误")
        } catch let err as LauncherError {
            if case .promptExecutorNotAvailable = err {
                // 期望行为，pass
            } else {
                XCTFail("应抛出 promptExecutorNotAvailable，实际抛出: \(err)")
            }
        } catch {
            XCTFail("应抛出 LauncherError.promptExecutorNotAvailable，实际: \(error)")
        }
    }

    // MARK: - T11: stdin 路径回归

    /// 注入 MockStdinExecutor + spy promptProvider，执行 stdin plugin。
    /// 预期：MockStdinExecutor.callCount=1，promptExecutor 内的 spy provider callCount=0。
    func test_T11_stdinPlugin_routesToStdinExecutor_notPromptExecutor() async throws {
        // MockStdinExecutor 来自 PluginDispatcherAcceptanceTests.swift（同 test target，非 private）
        let mockStdin = MockStdinExecutor()
        let spyPromptProvider = SpyProvider()
        let promptExecutor = PromptExecutor(provider: spyPromptProvider, activeProviderModel: "qwen")
        let dispatcher = PluginDispatcher(
            stdinExecutor: mockStdin,
            promptExecutor: promptExecutor
        )
        let manifest = makeStdinManifest()
        let input = makeInput(query: "stdin test")

        _ = try await dispatcher.execute(manifest, pluginDir: pluginDir, input: input)

        XCTAssertEqual(mockStdin.callCount, 1,
                       "stdin plugin 必须路由到 stdinExecutor（callCount=1）")
        XCTAssertEqual(spyPromptProvider.callCount, 0,
                       "stdin plugin 不能调用 promptExecutor 内的 provider（callCount 必须为 0）")
    }

    // MARK: - T12: PromptExecutor + dispatcher 组合端到端

    /// 构造真实 PromptExecutor（注入 mock provider）+ PluginDispatcher，
    /// 通过 dispatcher 执行 prompt manifest → 验证 provider 被调用，stdout 正确。
    ///
    /// 注：LauncherManager 端到端集成由 task 006 e2e 验证。
    func test_T12_promptExecutorDispatcherCombination_endToEnd() async throws {
        let provider = MockPromptProvider()
        provider.responseToReturn = AgentResponse(
            content: [.text("世界你好")],
            stopReason: "end_turn",
            usage: nil
        )
        let executor = PromptExecutor(provider: provider, activeProviderModel: "qwen2.5:7b")
        let dispatcher = PluginDispatcher(
            stdinExecutor: StdinExecutor.shared,
            promptExecutor: executor
        )
        let manifest = makePromptManifest(
            systemPrompt: "你是翻译助手",
            model: nil,
            timeout: 30
        )
        let input = makeInput(query: "hello world")

        let result = try await dispatcher.execute(manifest, pluginDir: pluginDir, input: input)

        // 验证 provider 被调用（end-to-end 链路打通）
        XCTAssertEqual(provider.callCount, 1,
                       "dispatcher → PromptExecutor → provider.send 链路：provider 应被调用一次")
        // 验证 stdout 正确返回
        XCTAssertEqual(result.stdout, "世界你好",
                       "dispatcher → PromptExecutor → provider 组合：stdout 必须等于 provider 返回文本")
        XCTAssertEqual(result.exitCode, 0,
                       "正常路径 exitCode 必须为 0")
        // 验证 model 回退：cfg.model=nil 时用 activeProviderModel
        XCTAssertEqual(provider.capturedModel, "qwen2.5:7b",
                       "model 回退：cfg.model=nil 应使用 activeProviderModel")
    }
}

// MARK: - PluginManifest prompt mode 便利构造（通过 JSON decode 绕过 struct 直接赋值限制）

private func makePromptManifestDirect(
    name: String,
    systemPrompt: String,
    model: String?,
    timeout: Int?
) -> PluginManifest {
    var json = """
    {
        "name": "\(name)",
        "version": "1.0.0",
        "description": "test prompt plugin",
        "keywords": ["\(name)"],
        "mode": "prompt",
        "systemPrompt": "\(systemPrompt)",
        "maxIterations": 1
    """
    if let m = model {
        json += ",\n        \"model\": \"\(m)\""
    }
    if let t = timeout {
        json += ",\n        \"timeout\": \(t)"
    }
    json += "\n    }"
    return try! JSONDecoder().decode(PluginManifest.self, from: json.data(using: .utf8)!)
}
