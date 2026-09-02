import AppKit
import XCTest
@testable import BuddyCore

// MARK: - LauncherDebugUnifiedCandidatesAcceptanceTests
//
// 红队验收测试（TDD 红灯）：`buddy launcher debug candidates` 统一单列表信封契约
//
// 设计文档契约引用（## 关键现状事实 CLI 行 + ## 契约规约 C-DEBUG-CLI + 场景1.P3/12）：
//   CLI：`buddy launcher debug candidates <query>`（位置参数）输出信封
//        {status, data:{candidates:[...]}}，元素含 source(∈app/builtin/plugin)/score，score 降序
//   C-DEBUG-CLI：data.candidates 单数组、source∈{app,builtin,plugin}、score 降序
//   场景1.P3：CLI debug candidates 二维码 → parsed.data.candidates[0].source=="plugin"
//   场景12.P1：混合查询信封可解析、source 枚举合法
//   场景12.P2：score 全局降序 ∀ i<j: score[i]>=score[j]
//
// 驱动方式（工作规则 3）：XCTest 内不拉 CLI 子进程，直调 QueryHandler.handle(query:) async -> Data
//   （既有可测入口，LauncherDebugQueryHandlerAcceptanceTests 同构）。
//
// CONTRACT_AMBIGUOUS：QueryHandler 侧插件候选来源未显式声明（PluginManager live 扫描 vs 注入）。
//   本测试用「物理落地 stub 插件到 PluginManager.shared.rootDir」保证两种机制下都可见
//   （makeCommandPluginInRoot 同构：目录名 hasSuffix("-\(name)") 稳定命中）。
//   debug candidates 为只读列表，不做 TrustStore.approve（listing 无 TOFU 语义）。
//
// TDD 红灯：source 字段未实现时断言挂（元素缺 source 键 → nil != "plugin"），属预期。

@MainActor
final class LauncherDebugUnifiedCandidatesAcceptanceTests: XCTestCase {

    private var manager: SessionManager!
    private var scene: MockScene!
    private var eventStore: EventStore!
    private var pasteboard: NSPasteboard!
    private var installedPluginDirs: [URL] = []

    override func setUp() async throws {
        try await super.setUp()
        scene = MockScene()
        let (m, _) = TestHelpers.makeManager(scene: scene)
        manager = m
        eventStore = manager.eventStore
        pasteboard = NSPasteboard(name: NSPasteboard.Name("ccb-debug-unified-test-\(UUID().uuidString)"))
        installedPluginDirs = []
        // 隔离：不注入 pluginsOverride（物理落地 stub 走 PluginManager live 扫描路径）
        LauncherManager.shared.pluginsOverride = nil
    }

    override func tearDown() async throws {
        for dir in installedPluginDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        installedPluginDirs = []
        LauncherManager.shared.pluginsOverride = nil
        try await super.tearDown()
    }

    // MARK: - stub 插件物理落地（PluginManager.shared.rootDir）

    private func installStubPlugin(name: String, keywords: [String]) throws -> PluginManifest {
        let rootDir = PluginManager.shared.rootDir
        try? FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        let pluginDir = rootDir.appendingPathComponent("stub-dbg-\(UUID().uuidString.prefix(8))-\(name)")
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        installedPluginDirs.append(pluginDir)

        let scriptURL = pluginDir.appendingPathComponent("run.sh")
        let script = "#!/bin/bash\necho \"spy ok\"\nexit 0\n"
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let keywordsJSON = "[\"" + keywords.joined(separator: "\",\"") + "\"]"
        let manifestJSON = """
        {
          "name": "\(name)",
          "version": "0.1.0",
          "description": "debug candidates stub",
          "keywords": \(keywordsJSON),
          "mode": "command",
          "cmd": "./run.sh",
          "args": [],
          "env": null,
          "timeout": 10,
          "requiredPath": null
        }
        """
        try manifestJSON.write(to: pluginDir.appendingPathComponent("plugin.json"),
                               atomically: true, encoding: .utf8)
        let data = try Data(contentsOf: pluginDir.appendingPathComponent("plugin.json"))
        return try JSONDecoder().decode(PluginManifest.self, from: data)
    }

    private func makeHandler(registryPlugins: [any BuiltinPlugin]) -> QueryHandler {
        let registry = BuiltinPluginRegistry(plugins: registryPlugins)
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
            XCTFail("响应必须是合法 JSON dict（信封可解析，场景12.P1）")
            return [:]
        }
        return json
    }

    private func candidatesArray(from json: [String: Any]) -> [[String: Any]] {
        guard let payload = json["data"] as? [String: Any] else {
            XCTFail("信封必须含 data 字段，实际=\(json)")
            return []
        }
        guard let candidates = payload["candidates"] as? [[String: Any]] else {
            XCTFail("data.candidates 必须是单数组（dict 数组），实际=\(payload)")
            return []
        }
        return candidates
    }

    private func scoreValue(_ element: [String: Any]) -> Int {
        (element["score"] as? NSNumber)?.intValue ?? Int.min
    }

    // MARK: - Mock 内置插件（builtin source 对照行）

    private final class MockBuiltinSourcePlugin: BuiltinPlugin {
        let id = "dbg-builtin-mock"
        let priority = 200
        let sectionTitle = "调试"
        func actions(for query: String) async -> [LauncherAction] {
            guard !query.isEmpty else { return [] }
            return [
                LauncherAction(
                    id: "dbg-builtin-row",
                    title: "内置对照行",
                    subtitle: nil,
                    icon: nil,
                    iconEmoji: nil,
                    pluginId: "dbg-builtin-mock",
                    score: 300,
                    perform: {}
                )
            ]
        }
    }

    // MARK: - 场景1.P3 [det-machine]：debug candidates「二维码」→ [0].source == "plugin"

    /// 场景1.P3：qr stub（keyword「二维码」完全档 1000）+ builtin 对照行（300）→
    /// 信封 data.candidates[0].source == "plugin"。
    func test_scenario1_P3_debugCandidates_erweima_firstSourceIsPlugin() async throws {
        _ = try installStubPlugin(name: "qr", keywords: ["qr", "二维码", "码"])
        let handler = makeHandler(registryPlugins: [MockBuiltinSourcePlugin()])

        let data = await handler.handle(query: [
            "action": "launcher_debug_candidates",
            "query": "二维码"
        ])
        let json = parseResponse(data)

        XCTAssertEqual(json["status"] as? String, "ok",
            "场景1.P3: 信封 status 必须 ok，实际=\(json)")
        let candidates = candidatesArray(from: json)
        XCTAssertFalse(candidates.isEmpty, "场景1.P3: 「二维码」必须产出候选")
        XCTAssertEqual(candidates[0]["source"] as? String, "plugin",
            "场景1.P3: data.candidates[0].source 必须精确为 \"plugin\"，实际=\(candidates[0])")
        XCTAssertEqual(candidates[0]["pluginId"] as? String, "qr",
            "场景1.P3: [0] 必须是 qr 插件行，实际=\(candidates[0])")
    }

    // MARK: - 场景12.P1 [det-machine]：混合查询信封可解析、source 枚举合法

    /// 场景12.P1：plugin（1000）+ builtin（300）同列单数组，每个元素 source ∈ {app,builtin,plugin}。
    /// Mutation kill：分区双数组 mutation（candidates 只剩 builtin）→ plugin 行缺失 → 挂。
    func test_scenario12_P1_mixedQuery_envelopeParsable_sourceEnumLegal() async throws {
        _ = try installStubPlugin(name: "qr", keywords: ["qr", "二维码", "码"])
        let handler = makeHandler(registryPlugins: [MockBuiltinSourcePlugin()])

        let data = await handler.handle(query: [
            "action": "launcher_debug_candidates",
            "query": "二维码"
        ])
        let json = parseResponse(data)
        let candidates = candidatesArray(from: json)

        let sources = candidates.compactMap { $0["source"] as? String }
        XCTAssertEqual(sources.count, candidates.count,
            "场景12.P1: 每个元素必须含 source 字段，实际=\(candidates)")
        let legalSources: Set<String> = ["app", "builtin", "plugin"]
        XCTAssertTrue(sources.allSatisfy { legalSources.contains($0) },
            "场景12.P1: source 必须 ∈ {app,builtin,plugin}，实际=\(sources)")
        XCTAssertTrue(sources.contains("plugin"), "场景12.P1: 混合列表必须含 plugin 来源行，实际=\(sources)")
        XCTAssertTrue(sources.contains("builtin"), "场景12.P1: 混合列表必须含 builtin 来源行（单数组混排），实际=\(sources)")
    }

    // MARK: - 场景12.P2 [det-machine]：score 全局降序 ∀ i<j: score[i]>=score[j]

    /// 场景12.P2：混合列表 score 严格非升序（1000 → 300）。
    func test_scenario12_P2_mixedQuery_scoresGloballyDescending() async throws {
        _ = try installStubPlugin(name: "qr", keywords: ["qr", "二维码", "码"])
        let handler = makeHandler(registryPlugins: [MockBuiltinSourcePlugin()])

        let data = await handler.handle(query: [
            "action": "launcher_debug_candidates",
            "query": "二维码"
        ])
        let json = parseResponse(data)
        let candidates = candidatesArray(from: json)

        XCTAssertGreaterThanOrEqual(candidates.count, 2, "场景12.P2 前置: 混合列表至少 2 项")
        for i in 0..<(candidates.count - 1) {
            let si = scoreValue(candidates[i])
            let sj = scoreValue(candidates[i + 1])
            XCTAssertGreaterThanOrEqual(si, sj,
                "场景12.P2: score 必须全局降序（∀ i<j: score[i]>=score[j]），index \(i)(\(si)) < index \(i+1)(\(sj))")
        }
        XCTAssertEqual(scoreValue(candidates[0]), 1000,
            "场景12.P2: 首位必须是完全档 1000（qr），实际=\(candidates[0])")
    }

    // MARK: - 场景12 边界：无插件安装 → source 只来自 app/builtin，不崩

    /// 空插件集：信封仍 ok，source 全部 ∈ {app,builtin}（无 plugin 行），不崩。
    func test_scenario12_edge_noPluginsInstalled_sourcesFromAppOrBuiltinOnly() async {
        let handler = makeHandler(registryPlugins: [MockBuiltinSourcePlugin()])

        let data = await handler.handle(query: [
            "action": "launcher_debug_candidates",
            "query": "任意查询"
        ])
        let json = parseResponse(data)
        XCTAssertEqual(json["status"] as? String, "ok",
            "无插件安装时信封必须仍 ok（不崩），实际=\(json)")
        let sources = candidatesArray(from: json).compactMap { $0["source"] as? String }
        XCTAssertFalse(sources.contains("plugin"),
            "空插件集不得出现 plugin 来源行，实际=\(sources)")
    }
}
