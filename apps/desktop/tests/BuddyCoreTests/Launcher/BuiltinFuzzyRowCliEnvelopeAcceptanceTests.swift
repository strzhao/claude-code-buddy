import AppKit
import XCTest
@testable import BuddyCore

// MARK: - BuiltinFuzzyRowCliEnvelopeAcceptanceTests
//
// 红队验收测试（仅基于设计文档编写，黑盒视角）：debug CLI 信封契约 ——
// source 四值闭集扩展 + 信封结构不变 + CLI 与 UI 数据层一致性（场景 7 + 场景 1/2 信封等价）。
//
// 设计文档引用（state.md ## 设计文档 D7 / ## 契约规约 / ## 验收场景）：
//   C-CLI-SOURCE-EXT：debug candidates 元素 source ∈ 闭集 {"app","builtin","builtin-plugin","plugin"}；
//     builtin: 行 → "builtin-plugin"、app-launcher 条目 → "app"、其余内置条目 → "builtin"、
//     plugin: 行 → "plugin"；信封 {status,data:{query,count,candidates[]}} 结构不变。
//   场景7.P1：status=="ok" ∧ count==len(candidates) ∧ 每元素 source 非空 ∧ 插件行 source != 条目/app source。
//   场景7.P2（in-process 半边）：同 query 下 CLI 通路与 unifiedCandidates 直接调用的
//     插件行四元组一致（真机跨进程对比留 QA Tier 1.5）。
//
// 驱动方式（LauncherDebugUnifiedCandidatesAcceptanceTests 同构）：XCTest 内不拉 CLI 子进程，
//   直调 QueryHandler.handle(query:) async -> Data 断言 JSON 信封；registry 经构造参数注入，
//   社区插件经 LauncherManager.shared.pluginsOverride 注入。

@MainActor
final class BuiltinFuzzyRowCliEnvelopeAcceptanceTests: XCTestCase {

    private var manager: SessionManager!
    private var scene: MockScene!
    private var eventStore: EventStore!
    private var pasteboard: NSPasteboard!

    override func setUp() async throws {
        try await super.setUp()
        scene = MockScene()
        let (m, _) = TestHelpers.makeManager(scene: scene)
        manager = m
        eventStore = manager.eventStore
        pasteboard = NSPasteboard(name: NSPasteboard.Name("ccb-builtin-fuzzy-cli-\(UUID().uuidString)"))
        // 隔离：信封通路经 handler 的 registry: 参数注入；管理器 override 一律复位
        LauncherManager.shared.registryOverride = nil
        LauncherManager.shared.pluginsOverride = []
        LauncherManager.shared.instantDebounceMsOverride = 0
        LauncherManager.shared.clearInstantActions()
        LauncherManager.shared.clearLockedCommand()
    }

    override func tearDown() async throws {
        LauncherManager.shared.registryOverride = nil
        LauncherManager.shared.pluginsOverride = nil
        LauncherManager.shared.instantDebounceMsOverride = nil
        LauncherManager.shared.clearInstantActions()
        LauncherManager.shared.clearLockedCommand()
        try await super.tearDown()
    }

    // MARK: - 构造与解析辅助

    private func makeHandler() -> QueryHandler {
        let registry = BuiltinPluginRegistry(plugins: [
            FuzzyPasteMockPlugin(),
            BuiltinEntryMockPlugin(),
            AppLauncherMockPlugin(),
        ])
        return QueryHandler(
            sessionManager: manager,
            scene: scene,
            eventStore: eventStore,
            registry: registry,
            pasteboard: pasteboard
        )
    }

    private func makePasteOnlyHandler() -> QueryHandler {
        let registry = BuiltinPluginRegistry(plugins: [FuzzyPasteMockPlugin()])
        return QueryHandler(
            sessionManager: manager,
            scene: scene,
            eventStore: eventStore,
            registry: registry,
            pasteboard: pasteboard
        )
    }

    private func parseResponse(_ data: Data) -> [String: Any] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("响应必须是合法 JSON dict（信封可解析）")
            return [:]
        }
        return json
    }

    private func envelopePayload(_ json: [String: Any]) -> [String: Any] {
        guard let payload = json["data"] as? [String: Any] else {
            XCTFail("信封必须含 data 字段，实际=\(json)")
            return [:]
        }
        return payload
    }

    private func candidatesArray(_ payload: [String: Any]) -> [[String: Any]] {
        guard let candidates = payload["candidates"] as? [[String: Any]] else {
            XCTFail("data.candidates 必须是单数组，实际=\(payload)")
            return []
        }
        return candidates
    }

    private func scoreValue(_ element: [String: Any]) -> Int {
        (element["score"] as? NSNumber)?.intValue ?? Int.min
    }

    private static let legalSources: Set<String> = ["app", "builtin", "builtin-plugin", "plugin"]

    // MARK: - 场景7.P1 [det-machine] + C-CLI-SOURCE-EXT：信封结构合法、source 闭集可区分

    /// 场景7.P1：query「pas」混排信封（builtin-plugin 行 + builtin 条目 + app 结果 + plugin 行）
    /// → status ok、count==len、每元素 source 非空且 ∈ 四值闭集、四类来源齐备（可区分）、
    /// score 全局非升序、截断 ≤8。信封 {status,data:{query,count,candidates[]}} 结构不变。
    func test_scenario7_P1_envelope_sourceClosedSet_distinguishable() async throws {
        LauncherManager.shared.pluginsOverride = [
            decodeManifest(name: "pagelug", keywords: ["pastrami"], mode: "command")
        ]
        let handler = makeHandler()

        let data = await handler.handle(query: [
            "action": "launcher_debug_candidates",
            "query": "pas"
        ])
        let json = parseResponse(data)

        XCTAssertEqual(json["status"] as? String, "ok",
            "场景7.P1: 信封 status 必须 ok，实际=\(json)")
        let payload = envelopePayload(json)
        XCTAssertEqual(payload["query"] as? String, "pas",
            "C-CLI-SOURCE-EXT: 信封 data.query 回显不变")
        let candidates = candidatesArray(payload)

        XCTAssertGreaterThanOrEqual(candidates.count, 4,
            "场景7.P1 前置: 四类来源混排至少 4 项，实际=\(candidates)")
        XCTAssertLessThanOrEqual(candidates.count, 8, "截断 ≤8（场景1.P3 信封等价）")
        XCTAssertEqual(payload["count"] as? Int, candidates.count,
            "场景7.P1: data.count == len(data.candidates)")

        let sources = candidates.compactMap { $0["source"] as? String }
        XCTAssertEqual(sources.count, candidates.count,
            "场景7.P1: 每元素 source 非空，实际=\(candidates)")
        XCTAssertTrue(sources.allSatisfy { Self.legalSources.contains($0) },
            "C-CLI-SOURCE-EXT: source ∈ {app,builtin,builtin-plugin,plugin}，实际=\(sources)")
        XCTAssertEqual(Set(sources), Self.legalSources,
            "场景7.P1: 插件行 source 必须与条目/app 结果可区分（四类齐备），实际=\(sources)")

        for i in 0..<(candidates.count - 1) {
            XCTAssertGreaterThanOrEqual(scoreValue(candidates[i]), scoreValue(candidates[i + 1]),
                "场景1.P3 信封等价: score 全局非升序，index \(i) < \(i+1)")
        }
    }

    // MARK: - 场景1.P1 [det-machine]（信封等价）：恰一条 builtin-plugin 行且 subtitle 非空

    /// 场景1.P1 信封等价：「pas」→ 恰一条 paste 插件行元素（source=="builtin-plugin"、
    /// pluginId=="paste"、subtitle 非空）。
    func test_scenario1_P1_envelope_singleBuiltinPluginRow() async throws {
        LauncherManager.shared.registryOverride = nil
        let handler = makePasteOnlyHandler()

        let data = await handler.handle(query: [
            "action": "launcher_debug_candidates",
            "query": "pas"
        ])
        let json = parseResponse(data)
        XCTAssertEqual(json["status"] as? String, "ok", "信封 status ok")
        let candidates = candidatesArray(envelopePayload(json))

        let rows = candidates.filter { ($0["source"] as? String) == "builtin-plugin" }
        XCTAssertEqual(rows.count, 1,
            "场景1.P1: 恰一条插件行类别元素，实际=\(candidates)")

        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row["pluginId"] as? String, "paste",
            "场景1.P1: 插件行 pluginId==paste，实际=\(row)")
        let subtitle = row["subtitle"] as? String
        XCTAssertNotNil(subtitle)
        XCTAssertFalse(subtitle!.isEmpty,
            "场景1.P1: 插件行 subtitle 非空（一句话描述），实际=\(row)")
    }

    // MARK: - 场景7.P2 [det-machine]（in-process 半边）：CLI 通路与 unifiedCandidates 一致

    /// 场景7.P2 in-process 半边：同 query「pas」下，QueryHandler 信封的插件行四元组
    /// (pluginId,title,score) 与直调 LauncherManager.unifiedCandidates 的 builtin: 行一致，
    /// score 序列前缀一致（真机跨进程时序子集差异由 QA Tier 1.5 处理）。
    func test_scenario7_P2_inProcess_cliEnvelopeMatchesUnifiedCandidates() async throws {
        let registry = BuiltinPluginRegistry(plugins: [
            FuzzyPasteMockPlugin(),
            AppLauncherMockPlugin(),
        ])
        let handler = QueryHandler(
            sessionManager: manager,
            scene: scene,
            eventStore: eventStore,
            registry: registry,
            pasteboard: pasteboard
        )

        let data = await handler.handle(query: [
            "action": "launcher_debug_candidates",
            "query": "pas"
        ])
        let envelopeRows = candidatesArray(envelopePayload(parseResponse(data)))

        let acts = await LauncherManager.shared.unifiedCandidates(
            for: "pas",
            externalRegistry: registry
        )

        // 插件行严格一致：(pluginId, title, score, source) 逐条相等
        let envelopePaste = try XCTUnwrap(
            envelopeRows.first { ($0["source"] as? String) == "builtin-plugin" },
            "信封必须含 builtin-plugin 行，实际=\(envelopeRows)")
        let uiPaste = try XCTUnwrap(
            acts.first { $0.id == "builtin:paste" },
            "unifiedCandidates 必须含 builtin:paste 行，实际=\(acts.map(\.id))")
        XCTAssertEqual(envelopePaste["pluginId"] as? String, uiPaste.pluginId)
        XCTAssertEqual(envelopePaste["title"] as? String, uiPaste.title)
        XCTAssertEqual(scoreValue(envelopePaste), uiPaste.score,
            "场景7.P2: 插件行 score 两侧一致")

        // 排序前缀一致：score 序列逐位相等（同进程同输入，无时序子集差异）
        let envelopeScores = envelopeRows.map(scoreValue)
        let uiScores = acts.map(\.score)
        XCTAssertEqual(envelopeScores, uiScores,
            "场景7.P2: 两侧 score 序列前缀一致，信封=\(envelopeScores) vs UI=\(uiScores)")
    }

    // MARK: - C-CLI-SOURCE-EXT 负例：无命中时不伪造 builtin-plugin 行（场景2.P1 信封等价）

    /// 场景2.P1 信封等价：「zzqq」→ 无插件行类别元素（source 不含 builtin-plugin）、信封仍 ok。
    func test_scenario2_P1_envelope_unrelatedQuery_noBuiltinPluginSource() async {
        let handler = makePasteOnlyHandler()

        let data = await handler.handle(query: [
            "action": "launcher_debug_candidates",
            "query": "zzqq"
        ])
        let json = parseResponse(data)
        XCTAssertEqual(json["status"] as? String, "ok",
            "无命中时信封仍 ok（不崩），实际=\(json)")
        let candidates = candidatesArray(envelopePayload(json))
        let sources = candidates.compactMap { $0["source"] as? String }
        XCTAssertFalse(sources.contains("builtin-plugin"),
            "场景2.P1: 无关词不得出现插件行类别元素，实际=\(candidates)")
        XCTAssertTrue(candidates.isEmpty,
            "场景2.P1: mock registry 下无关词无任何 paste 内容")
    }

    // MARK: - 辅助

    private func decodeManifest(name: String, keywords: [String], mode: String) -> PluginManifest {
        let json: [String: Any] = [
            "name": name,
            "version": "0.1.0",
            "description": "test command plugin \(name)",
            "keywords": keywords,
            "mode": mode,
            "cmd": "echo",
            "args": [] as [String]
        ]
        return try! JSONDecoder().decode(PluginManifest.self, from: try JSONSerialization.data(withJSONObject: json))
    }
}

// MARK: - Mock（本文件私有，与 BuiltinFuzzyRowAcceptanceTests 同构）

/// paste 形 mock（D1 触发词闭集 + 固定历史候选，不依赖真实剪贴板）。
@MainActor
private struct FuzzyPasteMockPlugin: BuiltinPlugin {
    static let keywords = ["cb", "clipboard", "剪贴板", "paste"]
    static let summaryLiteral = "剪贴板历史：输入「cb」查看并粘贴近期复制内容"
    let id = "paste"
    let priority = 150
    let sectionTitle = "剪贴板"
    let summary = FuzzyPasteMockPlugin.summaryLiteral
    var pluginKeywords: [String] { Self.keywords }

    func actions(for query: String) async -> [LauncherAction] {
        let lower = query.lowercased()
        guard Self.keywords.contains(where: { lower.hasPrefix($0) }) else { return [] }
        return [
            LauncherAction(id: "paste://seed-0", title: "buddy-acceptance-seed", subtitle: "文本",
                           icon: nil, iconEmoji: nil, pluginId: "paste", score: 1000, perform: {}),
            LauncherAction(id: "paste://seed-1", title: "older-entry", subtitle: "文本",
                           icon: nil, iconEmoji: nil, pluginId: "paste", score: 990, perform: {}),
        ]
    }
}

/// 通用内置条目 mock（无 pluginKeywords；pluginId=sysmock → source "builtin" 对照）。
@MainActor
private struct BuiltinEntryMockPlugin: BuiltinPlugin {
    let id = "sysmock"
    let priority = 100
    let sectionTitle = "系统"

    func actions(for query: String) async -> [LauncherAction] {
        guard !query.isEmpty else { return [] }
        return [
            LauncherAction(id: "sysmock://lock", title: "锁定屏幕", subtitle: nil,
                           icon: nil, iconEmoji: nil, pluginId: "sysmock", score: 830, perform: {})
        ]
    }
}

/// app 形 mock（无 pluginKeywords；pluginId=app-launcher → source "app" 对照）。
@MainActor
private struct AppLauncherMockPlugin: BuiltinPlugin {
    let id = "app-launcher"
    let priority = 0
    let sectionTitle = "应用"

    func actions(for query: String) async -> [LauncherAction] {
        guard !query.isEmpty else { return [] }
        return [
            LauncherAction(id: "/Applications/Pages.app", title: "Pages", subtitle: nil,
                           icon: nil, iconEmoji: nil, pluginId: "app-launcher", score: 830, perform: {})
        ]
    }
}
