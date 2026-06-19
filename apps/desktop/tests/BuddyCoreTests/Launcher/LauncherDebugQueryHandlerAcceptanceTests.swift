import AppKit
import XCTest
@testable import BuddyCore

// MARK: - LauncherDebugQueryHandlerAcceptanceTests
//
// 红队验收测试：launcher debug CLI 的三个 socket action 契约
//   - launcher_debug_candidates：查询候选（Registry 直驱，不走 LauncherManager）
//   - launcher_debug_perform：执行候选（perform 闭包副作用 + pasteboard 回读）
//   - launcher_debug_registry：列出已注册插件（按 priority 降序）
//
// 设计契约（launcher-debug-cli state.md）：
//   请求：
//     - launcher_debug_candidates  : query:String（必填）
//     - launcher_debug_perform     : query:String（必填） + index:Int（可选，默认 0）
//     - launcher_debug_registry    : 无
//   响应（成功）：
//     - candidates : {status:"ok", data:{query:String, count:Int, candidates:[{pluginId,title,subtitle,score}]}}
//     - perform    : {status:"ok", data:{pluginId:String, performed:true, copied:String?}}
//                    （copied 仅当注入 pasteboard 非空时存在）
//     - registry   : {status:"ok", data:{plugins:[{id,priority,sectionTitle}]}}
//                    （plugins 按 priority 降序）
//   响应（失败）：{status:"error", message:String}
//
// 边界值（逐字断言）：
//   - candidates 缺 query / 空 query → error
//   - perform 缺 query / index 越界 / perform 抛错 → error
//   - candidates/registry 只读无副作用
//
// 测试策略（红队信息隔离）：
//   - 注入 mock BuiltinPlugin（自定义 id/priority/sectionTitle/actions(for:)，perform 写注入 pasteboard）
//   - 注入具名 NSPasteboard（NSPasteboard.Name("ccb-launcher-debug-test-<uuid>")）隔离系统剪贴板
//   - 注入 mock registry（BuiltinPluginRegistry(plugins:)）—— 不依赖 .shared 单例污染
//   - 强断言：perform 读注入 pasteboard 验证 copied 字面量；candidates 断言 title 字面量；registry 断言 priority 降序序列
//
// 注：本测试 WILL NOT compile 直到蓝队：
//   1. QueryHandler.handle 改 async（`func handle(query:) async -> Data`）
//   2. QueryHandler.init 增加 registry: BuiltinPluginRegistry + pasteboard: NSPasteboard 注入参数
//   3. 合并 launcher_debug_candidates / launcher_debug_perform / launcher_debug_registry 分支
//   —— 这是预期的 TDD 红灯。

@MainActor
final class LauncherDebugQueryHandlerAcceptanceTests: XCTestCase {

    private var manager: SessionManager!
    private var scene: MockScene!
    private var eventStore: EventStore!
    private var pasteboard: NSPasteboard!
    private var handler: QueryHandler!

    override func setUp() async throws {
        try await super.setUp()
        scene = MockScene()
        let (m, _) = TestHelpers.makeManager(scene: scene)
        manager = m
        eventStore = manager.eventStore
        // 具名隔离 pasteboard：绝不污染系统 .general（与 CopyService 注入约定一致）
        pasteboard = NSPasteboard(name: NSPasteboard.Name("ccb-launcher-debug-test-\(UUID().uuidString)"))
    }

    // MARK: - 响应解析辅助

    /// 将 QueryHandler 返回的 Data 解析为 JSON dict。
    private func parseResponse(_ data: Data) -> [String: Any] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("响应必须是合法 JSON dict")
            return [:]
        }
        return json
    }

    /// 构造注入 mock registry + 注入 pasteboard 的 QueryHandler。
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

    // MARK: - 场景1：launcher_debug_registry 按 priority 降序

    /// 场景1：registry 返回 plugins[]，每元素含 id/priority/sectionTitle，且按 priority 降序。
    /// 注入 3 个 mock（priority 100/200/0），期望响应顺序 [200, 100, 0]。
    func test_scenario1_registry_returnsPluginsSortedByPriorityDesc() async {
        let low = MockPlugin(id: "p-low", priority: 0, sectionTitle: "低")
        let mid = MockPlugin(id: "p-mid", priority: 100, sectionTitle: "中")
        let high = MockPlugin(id: "p-high", priority: 200, sectionTitle: "高")
        handler = makeHandler(registryPlugins: [low, mid, high])

        let data = await handler.handle(query: ["action": "launcher_debug_registry"])
        let json = parseResponse(data)

        XCTAssertEqual(json["status"] as? String, "ok",
                       "场景1: launcher_debug_registry 必须返回 status:\"ok\"，actual=\(json)")

        guard let payload = json["data"] as? [String: Any] else {
            XCTFail("场景1: 响应必须含 data 字段（dict）")
            return
        }
        guard let plugins = payload["plugins"] as? [[String: Any]] else {
            XCTFail("场景1: data.plugins 必须是 dict 数组")
            return
        }

        XCTAssertEqual(plugins.count, 3,
                       "场景1: plugins.count 必须等于注入插件数 3")
        // 按 priority 降序序列断言（强断言：不仅 count，逐元素 priority）
        XCTAssertEqual(plugins[0]["priority"] as? Int, 200,
                       "场景1: plugins[0].priority 必须为 200（降序最高），actual=\(plugins[0])")
        XCTAssertEqual(plugins[1]["priority"] as? Int, 100,
                       "场景1: plugins[1].priority 必须为 100，actual=\(plugins[1])")
        XCTAssertEqual(plugins[2]["priority"] as? Int, 0,
                       "场景1: plugins[2].priority 必须为 0（降序最低），actual=\(plugins[2])")
        // 每元素含 id / sectionTitle 字段（id 字面量断言）
        XCTAssertEqual(plugins[0]["id"] as? String, "p-high")
        XCTAssertEqual(plugins[1]["id"] as? String, "p-mid")
        XCTAssertEqual(plugins[2]["id"] as? String, "p-low")
        XCTAssertNotNil(plugins[0]["sectionTitle"], "场景1: plugins[0] 必须含 sectionTitle")
        XCTAssertNotNil(plugins[1]["sectionTitle"], "场景1: plugins[1] 必须含 sectionTitle")
        XCTAssertNotNil(plugins[2]["sectionTitle"], "场景1: plugins[2] 必须含 sectionTitle")
    }

    // MARK: - 场景2：launcher_debug_candidates 返回候选列表

    /// 场景2：candidates 返回 candidates[]，每元素含 pluginId/title/subtitle/score，count 正确。
    /// 强断言：title 字面量断言（不仅 count > 0）。
    func test_scenario2_candidates_returnsCandidatesWithFields() async {
        let plugin = MockPlugin(id: "calc-debug", priority: 200, sectionTitle: "计算") { query in
            [
                LauncherAction(
                    id: "\(query)-a",
                    title: "= 42",
                    subtitle: "1+2*3+35",
                    icon: nil,
                    pluginId: "calc-debug",
                    score: 1000,
                    perform: { }
                ),
                LauncherAction(
                    id: "\(query)-b",
                    title: "= 7",
                    subtitle: "1+2*3",
                    icon: nil,
                    pluginId: "calc-debug",
                    score: 900,
                    perform: { }
                ),
            ]
        }
        handler = makeHandler(registryPlugins: [plugin])

        let data = await handler.handle(query: [
            "action": "launcher_debug_candidates",
            "query": "1+2",
        ])
        let json = parseResponse(data)

        XCTAssertEqual(json["status"] as? String, "ok",
                       "场景2: launcher_debug_candidates 必须返回 status:\"ok\"，actual=\(json)")

        guard let payload = json["data"] as? [String: Any] else {
            XCTFail("场景2: 响应必须含 data 字段")
            return
        }
        XCTAssertEqual(payload["query"] as? String, "1+2",
                       "场景2: data.query 必须回显请求 query")
        XCTAssertEqual(payload["count"] as? Int, 2,
                       "场景2: data.count 必须等于候选数 2")

        guard let candidates = payload["candidates"] as? [[String: Any]] else {
            XCTFail("场景2: data.candidates 必须是 dict 数组")
            return
        }
        XCTAssertEqual(candidates.count, 2, "场景2: candidates.count 必须为 2")

        // 候选 0：四字段强断言 + title 字面量
        let first = candidates[0]
        XCTAssertEqual(first["pluginId"] as? String, "calc-debug",
                       "场景2: candidates[0].pluginId 必须为来源插件 id")
        XCTAssertEqual(first["title"] as? String, "= 42",
                       "场景2: candidates[0].title 必须为字面量 \"= 42\"（mutation-survival：不仅 count）")
        XCTAssertEqual(first["subtitle"] as? String, "1+2*3+35",
                       "场景2: candidates[0].subtitle 必须为字面量")
        XCTAssertEqual(first["score"] as? Int, 1000,
                       "场景2: candidates[0].score 必须为 1000")
    }

    // MARK: - 场景5：candidates 对无候选 query 返回空数组（不崩）

    /// 场景5：query 无匹配候选时，candidates 返回 count==0 + candidates==[]（不崩，不报错）。
    func test_scenario5_candidates_noMatch_returnsEmptyArrayNotError() async {
        let plugin = MockPlugin(id: "empty-debug", priority: 100, sectionTitle: "空") { _ in
            [] // 永远无候选
        }
        handler = makeHandler(registryPlugins: [plugin])

        let data = await handler.handle(query: [
            "action": "launcher_debug_candidates",
            "query": "zzz-no-match",
        ])
        let json = parseResponse(data)

        XCTAssertEqual(json["status"] as? String, "ok",
                       "场景5: 无候选的 query 必须返回 status:\"ok\"（非 error，非崩溃），actual=\(json)")
        let payload = json["data"] as? [String: Any] ?? [:]
        XCTAssertEqual(payload["count"] as? Int, 0,
                       "场景5: 无候选时 data.count 必须为 0")
        let candidates = payload["candidates"] as? [Any] ?? ["non-empty"]
        XCTAssertEqual(candidates.count, 0,
                       "场景5: 无候选时 data.candidates 必须是空数组 []")
    }

    // MARK: - 边界：candidates 缺 query / 空 query → error

    /// candidates 缺 query 字段必须返回 error。
    func test_boundary_candidates_missingQuery_returnsError() async {
        let plugin = MockPlugin(id: "any", priority: 0, sectionTitle: "x") { _ in [] }
        handler = makeHandler(registryPlugins: [plugin])

        let data = await handler.handle(query: ["action": "launcher_debug_candidates"])
        let json = parseResponse(data)

        XCTAssertEqual(json["status"] as? String, "error",
                       "边界: candidates 缺 query 必须返回 status:\"error\"，actual=\(json)")
        XCTAssertNotNil(json["message"], "边界: error 响应必须含 message 字段")
    }

    /// candidates 空 query（""）必须返回 error。
    func test_boundary_candidates_emptyQuery_returnsError() async {
        let plugin = MockPlugin(id: "any", priority: 0, sectionTitle: "x") { _ in [] }
        handler = makeHandler(registryPlugins: [plugin])

        let data = await handler.handle(query: [
            "action": "launcher_debug_candidates",
            "query": "",
        ])
        let json = parseResponse(data)

        XCTAssertEqual(json["status"] as? String, "error",
                       "边界: candidates 空 query 必须返回 status:\"error\"，actual=\(json)")
    }

    // MARK: - 场景3：launcher_debug_perform 执行候选 + copied 字段

    /// 场景3：perform 执行候选 perform 闭包（写注入 pasteboard），响应 performed==true + copied==字面量。
    /// 强断言（mutation-survival）：copied 值通过读注入 pasteboard 回读验证，不仅「performed==true」。
    func test_scenario3_perform_executesClosureAndReturnsCopiedFromPasteboard() async {
        let plugin = MockPlugin(id: "calc-perform", priority: 200, sectionTitle: "计算") { query in
            [
                LauncherAction(
                    id: "\(query)-result",
                    title: "= 42",
                    subtitle: nil,
                    icon: nil,
                    pluginId: "calc-perform",
                    score: 1000,
                    perform: { [self] in
                        // 模拟 CalculatorPlugin 的 CopyService.copy 行为：
                        // 直接写注入 pasteboard（生产由 CopyService.shared 写 .general）
                        self.pasteboard.clearContents()
                        self.pasteboard.setString("42", forType: .string)
                    }
                ),
            ]
        }
        handler = makeHandler(registryPlugins: [plugin])

        let data = await handler.handle(query: [
            "action": "launcher_debug_perform",
            "query": "40+2",
        ])
        let json = parseResponse(data)

        XCTAssertEqual(json["status"] as? String, "ok",
                       "场景3: launcher_debug_perform 必须返回 status:\"ok\"，actual=\(json)")
        guard let payload = json["data"] as? [String: Any] else {
            XCTFail("场景3: 响应必须含 data 字段")
            return
        }
        XCTAssertEqual(payload["pluginId"] as? String, "calc-perform",
                       "场景3: data.pluginId 必须为执行候选的来源插件 id")
        XCTAssertEqual(payload["performed"] as? Bool, true,
                       "场景3: data.performed 必须为 true")

        // 关键强断言：copied 字段必须等于 perform 写入 pasteboard 的字面量
        XCTAssertEqual(payload["copied"] as? String, "42",
                       "场景3: data.copied 必须为注入 pasteboard 回读的字面量 \"42\"" +
                       "（mutation-survival：验证 perform 真执行 + pasteboard 真写入 + 回读）")

        // 双重验证：直接读注入 pasteboard 确认副作用落地
        let pasteboardValue = pasteboard.string(forType: .string)
        XCTAssertEqual(pasteboardValue, "42",
                       "场景3: 注入 pasteboard 必须被 perform 写入 \"42\"（副作用落地验证）")
    }

    // MARK: - 场景4：perform index=0 显式与默认一致

    /// 场景4：perform 带 index:0 与不传 index（默认 0）结果一致。
    func test_scenario4_perform_index0Explicit_matchesDefault() async {
        let plugin = MockPlugin(id: "idx-debug", priority: 100, sectionTitle: "x") { query in
            [
                LauncherAction(
                    id: "\(query)-0",
                    title: "候选零",
                    subtitle: nil,
                    icon: nil,
                    pluginId: "idx-debug",
                    score: 1000,
                    perform: { [self] in
                        self.pasteboard.clearContents()
                        self.pasteboard.setString("ZERO", forType: .string)
                    }
                ),
            ]
        }
        handler = makeHandler(registryPlugins: [plugin])

        // 不传 index（默认 0）
        let dataDefault = await handler.handle(query: [
            "action": "launcher_debug_perform",
            "query": "q",
        ])
        let jsonDefault = parseResponse(dataDefault)

        // 显式 index:0
        // 清空 pasteboard 以区分两次调用
        pasteboard.clearContents()
        let dataExplicit = await handler.handle(query: [
            "action": "launcher_debug_perform",
            "query": "q",
            "index": 0,
        ])
        let jsonExplicit = parseResponse(dataExplicit)

        XCTAssertEqual(jsonDefault["status"] as? String, "ok",
                       "场景4: 默认 index perform 必须成功")
        XCTAssertEqual(jsonExplicit["status"] as? String, "ok",
                       "场景4: 显式 index:0 perform 必须成功")

        let payloadDefault = jsonDefault["data"] as? [String: Any] ?? [:]
        let payloadExplicit = jsonExplicit["data"] as? [String: Any] ?? [:]
        XCTAssertEqual(payloadDefault["performed"] as? Bool, true)
        XCTAssertEqual(payloadExplicit["performed"] as? Bool, true)
        XCTAssertEqual(payloadExplicit["copied"] as? String, "ZERO",
                       "场景4: 显式 index:0 的 copied 必须与默认一致（同一候选）")
    }

    // MARK: - 场景7：perform index 越界 → error

    /// 场景7：候选 1 个但 index=5，perform 必须返回 error（不崩，不执行越界候选）。
    func test_scenario7_perform_indexOutOfBounds_returnsError() async {
        var performCalled = false
        let plugin = MockPlugin(id: "oob-debug", priority: 100, sectionTitle: "x") { query in
            [
                LauncherAction(
                    id: "\(query)-only",
                    title: "唯一候选",
                    subtitle: nil,
                    icon: nil,
                    pluginId: "oob-debug",
                    score: 1000,
                    perform: { performCalled = true }
                ),
            ]
        }
        handler = makeHandler(registryPlugins: [plugin])

        let data = await handler.handle(query: [
            "action": "launcher_debug_perform",
            "query": "q",
            "index": 5,
        ])
        let json = parseResponse(data)

        XCTAssertEqual(json["status"] as? String, "error",
                       "场景7: index 越界（5 > 候选数 1）必须返回 status:\"error\"，actual=\(json)")
        XCTAssertNotNil(json["message"], "场景7: 越界 error 必须含 message")
        XCTAssertFalse(performCalled,
                       "场景7: index 越界时 perform 闭包必须不被调用（不应执行越界候选）")
    }

    // MARK: - 边界：perform 缺 query → error

    /// perform 缺 query 必须返回 error。
    func test_boundary_perform_missingQuery_returnsError() async {
        let plugin = MockPlugin(id: "any", priority: 0, sectionTitle: "x") { _ in [] }
        handler = makeHandler(registryPlugins: [plugin])

        let data = await handler.handle(query: [
            "action": "launcher_debug_perform",
            "index": 0,
        ])
        let json = parseResponse(data)

        XCTAssertEqual(json["status"] as? String, "error",
                       "边界: perform 缺 query 必须返回 status:\"error\"，actual=\(json)")
    }

    // MARK: - 边界：perform perform 闭包抛错 → error

    /// perform 候选的 perform 闭包抛 LauncherError 时，响应必须为 error，message 含失败信息。
    func test_boundary_perform_performThrows_returnsErrorWithMessage() async {
        let plugin = MockPlugin(id: "throw-debug", priority: 100, sectionTitle: "x") { query in
            [
                LauncherAction(
                    id: "\(query)-throw",
                    title: "会失败",
                    subtitle: nil,
                    icon: nil,
                    pluginId: "throw-debug",
                    score: 1000,
                    perform: {
                        throw LauncherError.appLaunchFailed("boom-debug")
                    }
                ),
            ]
        }
        handler = makeHandler(registryPlugins: [plugin])

        let data = await handler.handle(query: [
            "action": "launcher_debug_perform",
            "query": "q",
        ])
        let json = parseResponse(data)

        XCTAssertEqual(json["status"] as? String, "error",
                       "边界: perform 闭包抛错必须返回 status:\"error\"，actual=\(json)")
        let message = json["message"] as? String ?? ""
        XCTAssertFalse(message.isEmpty,
                       "边界: perform 抛错的 error 必须含非空 message")
        XCTAssertTrue(message.contains("boom") || message.contains("启动") || message.contains("应用"),
                      "边界: perform 抛错的 message 应含失败上下文（appLaunchFailed 关联文案），actual=\(message)")
    }

    // MARK: - 副作用隔离：candidates / registry 只读无副作用

    /// candidates 是只读查询：调用后注入 pasteboard 必须保持空（perform 副作用未触发）。
    func test_sideEffect_candidates_isReadOnly_noPasteboardMutation() async {
        var performCalled = false
        let plugin = MockPlugin(id: "ro-debug", priority: 100, sectionTitle: "x") { query in
            [
                LauncherAction(
                    id: "\(query)-ro",
                    title: "只读候选",
                    subtitle: nil,
                    icon: nil,
                    pluginId: "ro-debug",
                    score: 1000,
                    perform: {
                        performCalled = true
                        self.pasteboard.clearContents()
                        self.pasteboard.setString("SHOULD-NOT-HAPPEN", forType: .string)
                    }
                ),
            ]
        }
        handler = makeHandler(registryPlugins: [plugin])

        _ = await handler.handle(query: [
            "action": "launcher_debug_candidates",
            "query": "ro",
        ])

        XCTAssertFalse(performCalled,
                       "副作用隔离: candidates 必须只读，perform 闭包不应被调用")
        XCTAssertNil(pasteboard.string(forType: .string),
                     "副作用隔离: candidates 后注入 pasteboard 必须保持空（无 perform 副作用）")
    }

    /// registry 是只读查询：调用后注入 pasteboard 必须保持空。
    func test_sideEffect_registry_isReadOnly_noPasteboardMutation() async {
        var performCalled = false
        let plugin = MockPlugin(id: "ro-reg", priority: 100, sectionTitle: "x") { _ in
            [
                LauncherAction(
                    id: "ro-reg-1",
                    title: "x",
                    subtitle: nil,
                    icon: nil,
                    pluginId: "ro-reg",
                    score: 1000,
                    perform: {
                        performCalled = true
                        self.pasteboard.clearContents()
                        self.pasteboard.setString("SHOULD-NOT-HAPPEN", forType: .string)
                    }
                ),
            ]
        }
        handler = makeHandler(registryPlugins: [plugin])

        _ = await handler.handle(query: ["action": "launcher_debug_registry"])

        XCTAssertFalse(performCalled,
                       "副作用隔离: registry 必须只读，perform 闭包不应被调用")
        XCTAssertNil(pasteboard.string(forType: .string),
                     "副作用隔离: registry 后注入 pasteboard 必须保持空")
    }

    // MARK: - 未知 action

    /// launcher_debug_* 前缀下的未知 action 必须返回 error（不与 launcher_debug 命名空间外冲突）。
    func test_unknownLauncherDebugAction_returnsError() async {
        let plugin = MockPlugin(id: "any", priority: 0, sectionTitle: "x") { _ in [] }
        handler = makeHandler(registryPlugins: [plugin])

        let data = await handler.handle(query: ["action": "launcher_debug_bogus"])
        let json = parseResponse(data)

        XCTAssertEqual(json["status"] as? String, "error",
                       "未知 action launcher_debug_bogus 必须返回 status:\"error\"，actual=\(json)")
    }
}

// MARK: - MockPlugin（mock BuiltinPlugin）

/// 测试用 mock BuiltinPlugin。
/// - 固定 id / priority / sectionTitle（由测试注入控制 registry 顺序）
/// - actions(for:) 返回测试提供的固定候选列表（闭包注入，方便每例定制）
@MainActor
private final class MockPlugin: BuiltinPlugin {
    let id: String
    let priority: Int
    let sectionTitle: String
    private let actionsProvider: @MainActor (String) async -> [LauncherAction]

    init(
        id: String,
        priority: Int,
        sectionTitle: String,
        actions: @escaping @MainActor (String) async -> [LauncherAction] = { _ in [] }
    ) {
        self.id = id
        self.priority = priority
        self.sectionTitle = sectionTitle
        self.actionsProvider = actions
    }

    func actions(for query: String) async -> [LauncherAction] {
        await actionsProvider(query)
    }
}
