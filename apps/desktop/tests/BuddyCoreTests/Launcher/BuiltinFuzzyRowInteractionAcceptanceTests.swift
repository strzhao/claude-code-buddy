import XCTest
@testable import BuddyCore

// MARK: - BuiltinFuzzyRowInteractionAcceptanceTests
//
// 红队验收测试（仅基于设计文档编写，黑盒视角）：内置插件行（builtin:paste）的交互路径 ——
// Enter 展开 / 点击展开 / Tab 不锁定 / 社区插件行为不变（场景 4/5，UI 路径 in-process）。
//
// 设计文档引用（state.md ## 设计文档 D5/D6 / ## 契约规约 / ## 验收场景）：
//   C-BUILTIN-EXPAND：submitInstantSelection 选中 builtin: 行 → .expandBuiltin(trigger)，
//     trigger ∈ pluginKeywords ∧ 对 query 档位分最高（pas→paste、剪→剪贴板；同分取最短）。
//     builtin: 前缀守卫优先级最高（防社区插件重名 paste 误分流）。
//     View 消费（query = trigger → onChange → updateQuery → debounce 刷出具体候选）。
//   C-BUILTIN-TAB-NOLOCK：builtin: 行 handleTabLock() → false ∧ lockedCommand==nil；
//     社区插件行 Tab 仍 true（既有行为零变化）。守卫防重名场景误锁定。
//   D6：onRowTap 对 builtin: 行走 submit()（与 Enter 同义）→ manager 层汇于同一分流 seam。
//
// 驱动方式（验证方案「红队」行）：@MainActor 直调 LauncherManager.shared：
//   updateQuery("pas") + Task.yield 等 debounce 落地（instantDebounceMsOverride=0）
//   → setInstantSelectedIndex 选中 builtin: 行 → submitInstantSelection / handleTabLock。
//   剪贴板历史非空前置由 mock 固定候选保证（不依赖真实剪贴板，红队工作规则 5）。

@MainActor
final class BuiltinFuzzyRowInteractionAcceptanceTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        LauncherManager.shared.resetSubmittingStateForTesting()
        LauncherManager.shared.instantDebounceMsOverride = 0
        LauncherManager.shared.registryOverride = makeRegistry([FuzzyPasteMockPlugin()])
        LauncherManager.shared.pluginsOverride = []
        LauncherManager.shared.stdinExecutorOverride = nil
        LauncherManager.shared.clearInstantActions()
        LauncherManager.shared.clearLockedCommand()
        if LauncherManager.shared.isVisible {
            LauncherManager.shared.hide()
        }
    }

    override func tearDown() async throws {
        LauncherManager.shared.pluginsOverride = nil
        LauncherManager.shared.stdinExecutorOverride = nil
        LauncherManager.shared.instantDebounceMsOverride = nil
        LauncherManager.shared.registryOverride = nil
        LauncherManager.shared.clearInstantActions()
        LauncherManager.shared.clearLockedCommand()
        try await super.tearDown()
    }

    // MARK: - 场景4.P1 [det-machine]：选中插件行 Enter → 内置展开路由 → 就地展开历史条目

    /// 场景4.P1：`pas` 列表中选中 paste 插件行 + Enter 确认 →
    /// 路由 case==内置展开 && trigger ∈ 触发词闭集 && trigger=="paste"（pas 前缀档语义）→
    /// View 消费等效（updateQuery(trigger) 落地）后候选非空、含 paste 条目、无 builtin:/plugin: 行。
    /// Mutation kill：无分流守卫（落 .performed/.stream）或 trigger 计算错 → 红。
    func test_scenario4_P1_enterOnBuiltinRow_expandsViaPasteTrigger() async throws {
        LauncherManager.shared.updateQuery("pas")
        await Task.yield()

        // 前置：builtin:paste 行已在 instantActions（部分词命中已落地）
        let rowIdx = try XCTUnwrap(
            LauncherManager.shared.instantActions.firstIndex { $0.id == "builtin:paste" },
            "场景4.P1 前置: 「pas」列表必须含 builtin:paste 行，实际=\(LauncherManager.shared.instantActions.map(\.id))")
        LauncherManager.shared.setInstantSelectedIndex(rowIdx)

        let route = LauncherManager.shared.submitInstantSelection(query: "pas")
        guard case .expandBuiltin(let trigger) = route else {
            XCTFail("场景4.P1: 必须返回 .expandBuiltin，实际=\(route)")
            return
        }
        XCTAssertTrue(["cb", "clipboard", "剪贴板", "paste"].contains(trigger),
            "场景4.P1: trigger 必须 ∈ {cb,clipboard,剪贴板,paste}，实际=\(trigger)")
        XCTAssertEqual(trigger, "paste",
            "场景4.P1: pas 前缀档语义 → trigger==\"paste\"，实际=\(trigger)")

        // View 消费等效（D6：query = trigger → onChange → updateQuery → debounce 刷具体候选）
        LauncherManager.shared.updateQuery(trigger)
        await Task.yield()

        let acts = LauncherManager.shared.instantActions
        XCTAssertFalse(acts.isEmpty, "场景4.P1: 展开后候选非空")
        XCTAssertTrue(acts.contains { $0.pluginId == "paste" && !$0.id.hasPrefix("builtin:") },
            "场景4.P1: 展开后存在 paste 具体条目（剪贴板历史），实际=\(acts.map(\.id))")
        XCTAssertTrue(acts.allSatisfy { !$0.id.hasPrefix("builtin:") },
            "场景4.P1: 展开后列表不含 builtin: 前缀行，实际=\(acts.map(\.id))")
        XCTAssertTrue(acts.allSatisfy { !$0.id.hasPrefix("plugin:") },
            "场景4.P1: 展开后列表不含 plugin: 前缀行，实际=\(acts.map(\.id))")
    }

    // MARK: - 场景4.P2 [det-machine]：点击激活与 Enter 结果一致

    /// 场景4.P2：点击路径（D6：onRowTap → submit() → submitInstantSelection，与 Enter 同一
    /// manager 分流 seam；View 内 query 赋值为 private，enum 穷尽性编译守卫 + 真机 Tier 1.5 兜底）
    /// —— 同一起始态重放，断言同一触发词、同一候选列表形态。
    func test_scenario4_P2_clickPath_sameTriggerAndSameListAsEnter() async throws {
        // 第一遍（Enter 等效分流）
        LauncherManager.shared.updateQuery("pas")
        await Task.yield()
        let enterIdx = try XCTUnwrap(
            LauncherManager.shared.instantActions.firstIndex { $0.id == "builtin:paste" })
        LauncherManager.shared.setInstantSelectedIndex(enterIdx)
        guard case .expandBuiltin(let enterTrigger) = LauncherManager.shared.submitInstantSelection(query: "pas") else {
            XCTFail("场景4.P2: Enter 路径必须返回 .expandBuiltin")
            return
        }
        LauncherManager.shared.updateQuery(enterTrigger)
        await Task.yield()
        let enterIds = LauncherManager.shared.instantActions.map(\.id)
        let enterScores = LauncherManager.shared.instantActions.map(\.score)

        // 第二遍（点击等效分流：同一起始态重放同一 seam）
        LauncherManager.shared.updateQuery("pas")
        await Task.yield()
        let clickIdx = try XCTUnwrap(
            LauncherManager.shared.instantActions.firstIndex { $0.id == "builtin:paste" },
            "场景4.P2 前置: 重放时 builtin:paste 行必须重新出现")
        LauncherManager.shared.setInstantSelectedIndex(clickIdx)
        guard case .expandBuiltin(let clickTrigger) = LauncherManager.shared.submitInstantSelection(query: "pas") else {
            XCTFail("场景4.P2: 点击路径必须返回 .expandBuiltin")
            return
        }
        LauncherManager.shared.updateQuery(clickTrigger)
        await Task.yield()
        let clickIds = LauncherManager.shared.instantActions.map(\.id)
        let clickScores = LauncherManager.shared.instantActions.map(\.score)

        XCTAssertEqual(clickTrigger, enterTrigger, "场景4.P2: 点击与 Enter 同一触发词")
        XCTAssertEqual(clickTrigger, "paste", "场景4.P2: trigger==\"paste\"")
        XCTAssertEqual(clickIds, enterIds, "场景4.P2: 点击与 Enter 展开后列表形态一致（id 序列）")
        XCTAssertEqual(clickScores, enterScores, "场景4.P2: 点击与 Enter 展开后列表形态一致（score 序列）")
        XCTAssertFalse(clickIds.isEmpty, "场景4.P2: 展开后候选非空")
    }

    // MARK: - 场景5.P1 [det-machine]：内置插件行 Tab 不进入参数锁定

    /// 场景5.P1：选中 paste 插件行触发 Tab → 不进入参数锁定态（lockedCommand 保持 nil）。
    /// Mutation kill：D5 忘加 builtin: 前缀守卫 → false 预期失败或误锁。
    func test_scenario5_P1_tabOnBuiltinRow_noParamLock() async throws {
        LauncherManager.shared.updateQuery("pas")
        await Task.yield()
        let rowIdx = try XCTUnwrap(
            LauncherManager.shared.instantActions.firstIndex { $0.id == "builtin:paste" },
            "场景5.P1 前置: 「pas」列表必须含 builtin:paste 行，实际=\(LauncherManager.shared.instantActions.map(\.id))")
        LauncherManager.shared.setInstantSelectedIndex(rowIdx)

        let locked = LauncherManager.shared.handleTabLock()

        XCTAssertFalse(locked, "场景5.P1/C-BUILTIN-TAB-NOLOCK: 内置插件行 Tab 必须返回 false（不锁定）")
        XCTAssertNil(LauncherManager.shared.lockedCommand,
            "场景5.P1: 未产生参数锁定提示态（lockedCommand 必须为 nil）")
    }

    // MARK: - 场景5.P2 [det-machine]：社区插件行 Tab 仍进入参数锁定（现有行为零变化）

    /// 场景5.P2：同一安装环境下社区插件候选行 Tab → 参数锁定态（lockedCommand 非 nil）。
    /// 回归保护：D5 改造不得波及社区插件 Tab 语义（C-BUILTIN-TAB-NOLOCK 后半句）。
    func test_scenario5_P2_tabOnCommunityRow_stillLocks() async throws {
        let manifest = decodeManifest(name: "cmdplug", keywords: ["qrkw"], mode: "command")
        LauncherManager.shared.pluginsOverride = [manifest]
        LauncherManager.shared.registryOverride = makeRegistry([EmptyActionsMockPlugin()])

        LauncherManager.shared.updateQuery("qrkw")
        await Task.yield()
        let rowIdx = try XCTUnwrap(
            LauncherManager.shared.instantActions.firstIndex { $0.pluginId == "cmdplug" },
            "场景5.P2 前置: 社区插件行必须进统一列表，实际=\(LauncherManager.shared.instantActions.map(\.id))")
        LauncherManager.shared.setInstantSelectedIndex(rowIdx)

        let locked = LauncherManager.shared.handleTabLock()

        XCTAssertTrue(locked, "场景5.P2: 社区插件行 Tab 必须仍进入参数锁定（返回 true）")
        XCTAssertEqual(LauncherManager.shared.lockedCommand?.name, "cmdplug",
            "场景5.P2: 参数锁定态==true（lockedCommand == 该插件 manifest）")
    }

    // MARK: - C-BUILTIN-EXPAND 守卫优先级：社区重名 paste 下 builtin 行 Enter 不误分流

    /// D5「前缀守卫优先级最高（防社区插件重名 paste 时误分流）」：
    /// 已装名为 paste 的社区插件时，选中 builtin:paste 行 Enter 必须仍返回 .expandBuiltin，
    /// 不得解析到社区 manifest 走 .stream/.performed。
    /// Mutation kill：分流守卫放在 resolvePluginCandidate 之后 → 命中社区 manifest → .stream → 红。
    func test_cbuiltinexpand_namesakeCommunity_notMisrouted() async throws {
        LauncherManager.shared.pluginsOverride = [
            decodeManifest(name: "paste", keywords: ["pastekw"], mode: "command")
        ]

        LauncherManager.shared.updateQuery("pas")
        await Task.yield()
        let rowIdx = try XCTUnwrap(
            LauncherManager.shared.instantActions.firstIndex { $0.id == "builtin:paste" },
            "前置: 重名场景下 builtin:paste 行仍须出现，实际=\(LauncherManager.shared.instantActions.map(\.id))")
        LauncherManager.shared.setInstantSelectedIndex(rowIdx)

        let route = LauncherManager.shared.submitInstantSelection(query: "pas")
        guard case .expandBuiltin(let trigger) = route else {
            XCTFail("C-BUILTIN-EXPAND: 重名场景必须仍返回 .expandBuiltin，实际=\(route)")
            return
        }
        XCTAssertEqual(trigger, "paste", "C-BUILTIN-EXPAND: trigger==\"paste\"")
    }

    // MARK: - C-BUILTIN-TAB-NOLOCK 守卫：社区重名 paste 下 builtin 行 Tab 不误锁

    /// D5「不加固守则重名场景下 resolvePluginCandidate 命中社区插件会误锁定」：
    /// 重名场景选中 builtin:paste 行 Tab → 必须 false ∧ lockedCommand==nil。
    /// Mutation kill：handleTabLock 缺 builtin: 守卫 → resolvePluginCandidate("paste") 命中社区
    /// manifest → 锁定返回 true → 红。
    func test_cbuiltintabnolock_namesakeCommunity_noMislock() async throws {
        LauncherManager.shared.pluginsOverride = [
            decodeManifest(name: "paste", keywords: ["pastekw"], mode: "command")
        ]

        LauncherManager.shared.updateQuery("pas")
        await Task.yield()
        let rowIdx = try XCTUnwrap(
            LauncherManager.shared.instantActions.firstIndex { $0.id == "builtin:paste" })
        LauncherManager.shared.setInstantSelectedIndex(rowIdx)

        let locked = LauncherManager.shared.handleTabLock()

        XCTAssertFalse(locked, "C-BUILTIN-TAB-NOLOCK: 重名场景 builtin 行 Tab 仍必须 false")
        XCTAssertNil(LauncherManager.shared.lockedCommand,
            "C-BUILTIN-TAB-NOLOCK: 不得误锁到重名社区插件")
    }

    // MARK: - C-BUILTIN-EXPAND 触发词语义：剪 → 剪贴板

    /// 契约锚点「剪→剪贴板」：query「剪」对 keyword「剪贴板」前缀档最高 → trigger=="剪贴板"。
    func test_cbuiltinexpand_jian_expandsToClipboardTrigger() async throws {
        LauncherManager.shared.updateQuery("剪")
        await Task.yield()
        let rowIdx = try XCTUnwrap(
            LauncherManager.shared.instantActions.firstIndex { $0.id == "builtin:paste" },
            "前置: 「剪」必须出 builtin:paste 行（场景1.P2），实际=\(LauncherManager.shared.instantActions.map(\.id))")
        LauncherManager.shared.setInstantSelectedIndex(rowIdx)

        guard case .expandBuiltin(let trigger) = LauncherManager.shared.submitInstantSelection(query: "剪") else {
            XCTFail("C-BUILTIN-EXPAND: 「剪」必须返回 .expandBuiltin")
            return
        }
        XCTAssertEqual(trigger, "剪贴板",
            "C-BUILTIN-EXPAND: 「剪」展开触发词必须为「剪贴板」（档位分最高），实际=\(trigger)")
    }

    // MARK: - C-BUILTIN-EXPAND 同分取最短

    /// 触发词选择「同分取最短」：keywords [pastrami, paste] 对「pa」均前缀档 800 → 取最短 "paste"。
    /// Mutation kill：按 keyword 数组序取第一 → "pastrami" → 红。
    func test_cbuiltinexpand_tieBreak_takesShortestTrigger() async throws {
        LauncherManager.shared.registryOverride = makeRegistry([PastramiTieMockPlugin()])

        LauncherManager.shared.updateQuery("pa")
        await Task.yield()
        let rowIdx = try XCTUnwrap(
            LauncherManager.shared.instantActions.firstIndex { $0.id == "builtin:paste" },
            "前置: 「pa」必须出 builtin:paste 行，实际=\(LauncherManager.shared.instantActions.map(\.id))")
        LauncherManager.shared.setInstantSelectedIndex(rowIdx)

        guard case .expandBuiltin(let trigger) = LauncherManager.shared.submitInstantSelection(query: "pa") else {
            XCTFail("C-BUILTIN-EXPAND: 「pa」必须返回 .expandBuiltin")
            return
        }
        XCTAssertEqual(trigger, "paste",
            "C-BUILTIN-EXPAND: 同分（均前缀档 800）取最短触发词 → \"paste\"，实际=\(trigger)")
    }

    // MARK: - 错误边界：instantSelectedIndex 越界 → .notInstant（既有行为不变）

    /// 错误边界（契约规约「错误边界」段）：无有效选中（清空后哨兵 -1）时
    /// submitInstantSelection 仍返回 .notInstant——D5 新增 builtin: 守卫不得破坏既有边界。
    func test_errorBoundary_outOfRangeSelection_notInstant() async {
        LauncherManager.shared.updateQuery("pas")
        await Task.yield()
        // 模拟越界选中态（清空语义：instantActions 空 + index 哨兵 -1）
        LauncherManager.shared.clearInstantActions()

        let route = LauncherManager.shared.submitInstantSelection(query: "pas")

        guard case .notInstant = route else {
            XCTFail("错误边界: 无有效选中必须返回 .notInstant，实际=\(route)")
            return
        }
    }

    // MARK: - 辅助

    private func makeRegistry(_ plugins: [any BuiltinPlugin]) -> BuiltinPluginRegistry {
        BuiltinPluginRegistry(plugins: plugins)
    }

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

// MARK: - Mock（本文件私有）

/// paste 形 mock（同 BuiltinFuzzyRowAcceptanceTests：触发词闭集 + 固定历史候选）。
@MainActor
private struct FuzzyPasteMockPlugin: BuiltinPlugin {
    static let keywords = ["cb", "clipboard", "剪贴板", "paste"]
    let id = "paste"
    let priority = 150
    let sectionTitle = "剪贴板"
    let summary = "剪贴板历史：输入「cb」查看并粘贴近期复制内容"
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

/// 同分取最短触发词的 mock（keywords 均含「pa」前缀）。
@MainActor
private struct PastramiTieMockPlugin: BuiltinPlugin {
    static let keywords = ["pastrami", "paste"]
    let id = "paste"
    let priority = 150
    let sectionTitle = "剪贴板"
    let summary = "同分取最短触发词验证"
    var pluginKeywords: [String] { Self.keywords }

    func actions(for query: String) async -> [LauncherAction] {
        let lower = query.lowercased()
        guard Self.keywords.contains(where: { lower.hasPrefix($0) }) else { return [] }
        return [
            LauncherAction(id: "paste://tie-0", title: "tie-entry", subtitle: "文本",
                           icon: nil, iconEmoji: nil, pluginId: "paste", score: 1000, perform: {})
        ]
    }
}

/// 空候选 mock（隔离社区 Tab 场景的内置噪声）。
@MainActor
private struct EmptyActionsMockPlugin: BuiltinPlugin {
    let id = "empty-interaction-test"
    let priority = 0
    let sectionTitle = "空"

    func actions(for query: String) async -> [LauncherAction] { [] }
}
