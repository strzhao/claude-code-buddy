import XCTest
@testable import BuddyCore

// MARK: - UnifiedRoutePromptFilterAcceptanceTests
//
// 红队验收测试（TDD 红灯）：AI 流触发词锚点过滤（D8）——单字 keyword 双通道排除 + AI 兜底保留
//
// 设计文档契约引用（## 设计决策 D8 + ## 契约规约 C-UNIFIED-SCORE/C-NO-REGRESS）：
//   D8：ToolDescription + 路由 system prompt 双通道过滤长度 <2 keyword（经 effectiveTriggerKeywords）；
//       narrowCandidatesScored 内核换 UnifiedPluginScorer
//   场景8.P1：ToolDescription「触发：」段按「、」分词不含「码」条目且含「二维码」；system prompt 同理
//   场景8.P2：无命中自然语言落 AI 兜底
//   场景8.P3：narrowCandidatesScored("密码") qr 不在候选（score==0）
//
// 被测 API（既有 + 设计声明）：
//   - manifest.effectiveTriggerKeywords: [String]（D8 声明）
//   - manifest.toAgentTool().description（既有，「触发：<kws>」按「、」分词）
//   - LauncherRouter(pluginManager:provider:routerModel:) + selectWithTools(query:plugins:)
//     （既有，LauncherRouterSelectWithToolsAcceptanceTests 同构用法）
//   - LauncherRouter.narrowCandidatesScored(query:plugins:)（既有，元素含 .manifest/.score）
//
// CONTRACT_AMBIGUOUS：
//   1. 「路由 system prompt」若由 pickWithAI 通道独立拼接，设计未给可测入口——本文件经
//      selectWithTools 的 provider.send 捕获面（system + messages 文本 + tools descriptions）
//      断言：任何 prompt 表面出现 keyword 锚点时必须是过滤后的（无独立「码」条目）。
//      「二维码」必须在 prompt 表面出现（关键词锚点必须在场），若蓝队路由 prompt 完全不带
//      keywords 段则红灯上报设计 owner 裁决（D8 声明 system prompt 是双通道之一）。
//
// TDD 红灯：effectiveTriggerKeywords 未实现时编译失败，属预期。

@MainActor
final class UnifiedRoutePromptFilterAcceptanceTests: XCTestCase {

    // MARK: - provider 桩（捕获 send 入参；返回纯文本 → selectWithTools 落 .directChat）

    private final class CapturingRouteProvider: LauncherProvider {
        private(set) var callCount = 0
        private(set) var capturedSystems: [String?] = []
        private(set) var capturedMessages: [[AgentMessage]] = []
        private(set) var capturedTools: [[AgentTool]] = []

        func send(messages: [AgentMessage], tools: [AgentTool], model: String,
                  system: String?) async throws -> AgentResponse {
            callCount += 1
            capturedMessages.append(messages)
            capturedTools.append(tools)
            capturedSystems.append(system)
            return AgentResponse(content: [.text("NONE")], stopReason: "end_turn", usage: nil)
        }
    }

    // MARK: - manifest 构造

    private func makeQrManifest(keywords: [String] = ["qr", "二维码", "码"]) throws -> PluginManifest {
        let json: [String: Any] = [
            "name": "qr",
            "version": "0.1.0-test",
            "description": "生成二维码图片",
            "keywords": keywords,
            "mode": "command",
            "cmd": "echo",
            "args": [String]()
        ]
        return try JSONDecoder().decode(PluginManifest.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func makeRouter(provider: CapturingRouteProvider) -> LauncherRouter {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RouteFilter-\(UUID().uuidString)")
        return LauncherRouter(pluginManager: PluginManager(rootDir: tmpDir),
                              provider: provider, routerModel: "test-model")
    }

    /// 从 AgentMessage 数组提取全部 .text 文本（黑盒：公开 content 结构）
    private func textOf(_ messages: [AgentMessage]) -> String {
        messages.flatMap { msg in
            msg.content.compactMap { content -> String? in
                if case .text(let t) = content { return t }
                return nil
            }
        }.joined(separator: "\n")
    }

    /// 提取 ToolDescription「触发：」段并按「、」分词
    private func triggerEntries(of description: String) -> [String] {
        guard let triggerRange = description.range(of: "触发：") else { return [] }
        let tail = description[triggerRange.upperBound...]
        let end = tail.firstIndex(where: { $0 == "。" || $0 == "\n" }) ?? tail.endIndex
        return tail[..<end]
            .components(separatedBy: "、")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: - 场景8.P1a [det-machine]：effectiveTriggerKeywords 过滤单字 keyword

    /// 场景8.P1：effectiveTriggerKeywords 必须排除长度 <2 的 keyword。
    /// assert: == ["qr", "二维码"]（count==2，含「二维码」，不含「码」）。
    /// Mutation kill：过滤 no-op（原样返回 3 个）→ count/含码断言挂。
    func test_scenario8_P1_effectiveTriggerKeywords_excludesSingleChar() throws {
        let qr = try makeQrManifest()
        let effective = qr.effectiveTriggerKeywords
        XCTAssertEqual(effective.count, 2,
            "场景8.P1: effectiveTriggerKeywords 必须滤掉单字「码」（count==2），实际=\(effective)")
        XCTAssertTrue(effective.contains("二维码"), "场景8.P1: 必须保留「二维码」，实际=\(effective)")
        XCTAssertTrue(effective.contains("qr"), "场景8.P1: 必须保留「qr」，实际=\(effective)")
        XCTAssertFalse(effective.contains("码"),
            "场景8.P1: 单字 keyword「码」必须被排除，实际=\(effective)")
    }

    // MARK: - 场景8.P1b [det-machine]：ToolDescription「触发：」段逐词断言

    /// 场景8.P1：「触发：」段按「、」分词——含「二维码」条目、不含独立「码」条目、
    /// 且所有条目长度 >=2（通用过滤不变量）。
    func test_scenario8_P1_toolDescription_triggerSection_filtered() throws {
        let qr = try makeQrManifest()
        let description = qr.toAgentTool().description

        let entries = triggerEntries(of: description)
        XCTAssertFalse(entries.isEmpty,
            "场景8.P1: ToolDescription 必须含「触发：」段（按「、」分词），实际描述：\(description)")
        XCTAssertTrue(entries.contains("二维码"),
            "场景8.P1: 「触发：」段必须含「二维码」条目，实际=\(entries)")
        XCTAssertFalse(entries.contains("码"),
            "场景8.P1: 「触发：」段不得含独立「码」条目（单字 keyword 过滤），实际=\(entries)")
        XCTAssertTrue(entries.allSatisfy { $0.count >= 2 },
            "场景8.P1: 「触发：」段所有条目长度必须 >=2，实际=\(entries)")
    }

    // MARK: - 场景8.P1c [det-machine]：路由 prompt 表面（selectWithTools 捕获）无独立「码」

    /// 场景8.P1：经 selectWithTools 的 provider.send 捕获面断言路由 prompt 双通道过滤：
    ///   - prompt 文本表面（system + messages）去掉「二维码」后不含「码」
    ///   - tools[].description 同理（ToolDescription 通道经真实路径）
    ///   - provider 必须被调用恰 1 次（AI 流路由活着）
    func test_scenario8_P1_routePromptSurfaces_noStandaloneSingleCharKeyword() async throws {
        let provider = CapturingRouteProvider()
        let qr = try makeQrManifest()
        let router = makeRouter(provider: provider)

        _ = try await router.selectWithTools(query: "生成二维码", plugins: [qr])

        XCTAssertEqual(provider.callCount, 1,
            "场景8.P1: selectWithTools 必须调用 provider.send 恰 1 次，实际=\(provider.callCount)")

        let systemText = provider.capturedSystems.first.flatMap { $0 } ?? ""
        let promptText = systemText + "\n"
            + provider.capturedMessages.map(textOf).joined(separator: "\n")
        XCTAssertTrue(promptText.contains("二维码"),
            "场景8.P1: 路由 prompt 表面必须携带过滤后的关键词锚点「二维码」（D8 system prompt 通道）")
        let sanitizedPrompt = promptText.replacingOccurrences(of: "二维码", with: "")
        XCTAssertFalse(sanitizedPrompt.contains("码"),
            "场景8.P1: 路由 prompt 表面（system+messages）去掉「二维码」后不得残留独立「码」条目")

        let toolText = provider.capturedTools.flatMap { $0 }.map(\.description).joined(separator: "\n")
        let sanitizedTools = toolText.replacingOccurrences(of: "二维码", with: "")
        XCTAssertFalse(sanitizedTools.contains("码"),
            "场景8.P1: tools[].description 去掉「二维码」后不得残留独立「码」条目")
    }

    // MARK: - 场景8.P3 [det-machine]：narrowCandidatesScored 内核换 UnifiedPluginScorer

    /// 场景8.P3：narrowCandidatesScored("密码") → qr 不在候选（score==0 不进列表）；
    /// 正对照：narrowCandidatesScored("二维码") → qr 在候选且 score==1000（新内核档位）。
    /// Mutation kill：内核未换（旧 contains 语义）→ 「密码」白拿分 → qr 出现在结果 → 挂。
    func test_scenario8_P3_narrowCandidatesScored_mimaExcludesQr_erweimaIncludes() throws {
        let qr = try makeQrManifest()

        let negative = LauncherRouter.narrowCandidatesScored(query: "密码", plugins: [qr])
        XCTAssertFalse(negative.contains { $0.manifest.name == "qr" },
            "场景8.P3: narrowCandidatesScored(\"密码\") 不得包含 qr（score==0 不进列表），实际=\(negative.map { ($0.manifest.name, $0.score) })")

        let positive = LauncherRouter.narrowCandidatesScored(query: "二维码", plugins: [qr])
        let qrEntry = positive.first { $0.manifest.name == "qr" }
        let entry = try XCTUnwrap(qrEntry, "场景8.P3 正对照: narrowCandidatesScored(\"二维码\") 必须包含 qr")
        XCTAssertEqual(entry.score, 1000,
            "场景8.P3 正对照: 内核换 UnifiedPluginScorer 后完全档必须精确 1000，实际=\(entry.score)")
    }

    // MARK: - 场景8.P2 [det-machine]：无命中自然语言落 AI 兜底

    /// 场景8.P2：自然语言（无 keyword 命中）→ updateQuery 无插件行；Enter fallback →
    /// submit(q) 走 AI 流（mock provider 产生 .text + .done），且不触发任何插件子进程执行。
    /// Mutation kill：若自然语言仍误路由到插件（旧 contains 残留），spy>0 或无 .text → 挂。
    func test_scenario8_P2_naturalLanguage_fallsBackToAIStream_notPlugin() async throws {
        let qr = try makeQrManifest()
        LauncherManager.shared.registryOverride = BuiltinPluginRegistry(plugins: [EmptyActionsPluginForRouteTest()])
        LauncherManager.shared.instantDebounceMsOverride = 0
        LauncherManager.shared.pluginsOverride = [qr]
        let spy = RecordingStdinExecutorSpy()
        LauncherManager.shared.stdinExecutorOverride = spy
        LauncherManager.shared.resetSubmittingStateForTesting()
        LauncherManager.shared.configOverride = LauncherConfig(
            activeProvider: "mock",
            providers: ["mock": ProviderConfig(kind: "anthropic", baseURL: nil, model: "test", keyRef: "test")]
        )
        let provider = CapturingRouteProvider()

        // typing 阶段：自然语言不产出插件行
        LauncherManager.shared.updateQuery("今天天气怎么样")
        try? await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertFalse(LauncherManager.shared.instantActions.contains { $0.pluginId == "qr" },
            "场景8.P2 前置: 自然语言不得产出 qr 插件行")

        // Enter fallback：AI 流（selectWithTools 空 tool 候选 → directChat 单轮）
        LauncherManager.shared.providerFactoryOverride = { _, _ in provider }
        var sawText = false
        var sawDone = false
        for await event in LauncherManager.shared.submit("今天天气怎么样") {
            if case .text = event { sawText = true }
            if case .done = event { sawDone = true }
        }

        XCTAssertTrue(sawText, "场景8.P2: AI 兜底流必须含 .text（mock provider 文本）")
        XCTAssertTrue(sawDone, "场景8.P2: AI 兜底流必须含 .done")
        XCTAssertGreaterThanOrEqual(provider.callCount, 1,
            "场景8.P2: 必须真实调用 provider（AI 兜底），实际=\(provider.callCount)")
        XCTAssertEqual(spy.executeCallCount, 0,
            "场景8.P2: 自然语言不得触发插件子进程执行（spy==0），实际=\(spy.executeCallCount)")

        LauncherManager.shared.providerFactoryOverride = nil
        LauncherManager.shared.configOverride = nil
        LauncherManager.shared.pluginsOverride = nil
        LauncherManager.shared.stdinExecutorOverride = nil
        LauncherManager.shared.registryOverride = nil
    }
}

// MARK: - Mock 空内置插件

private struct EmptyActionsPluginForRouteTest: BuiltinPlugin {
    let id = "empty-route-test"
    let priority = 0
    let sectionTitle = "Empty"
    func actions(for query: String) async -> [LauncherAction] { [] }
}
