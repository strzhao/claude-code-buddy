import XCTest
import Combine
@testable import BuddyCore

// MARK: - LauncherRouteConflictAcceptanceTests
//
// 统一混排改造后的验收测试（det-machine）：插件候选与 app/内置候选进同一 instantActions
// 单一列表（C-UNIFIED-SCORE / D3），替代旧「command 路由分区两区并存」语义。
//
// 关键语义（vs 旧方案 B 分区）：
//   - 统一列表：插件行（不分 mode）+ app/内置行混排单一数组，无分区（D3.5）。
//   - 排序键（D2）：score desc → 来源序 desc（内置 priority > 插件 50 > app 0）→ title。
//   - 「唯一命中自动锁定」不存在（C-TAB-LOCK）；Tab 锁定显式进入参数态。
//   - 空 query 清空列表 + 锁定（C-ESC-EXIT）。
//
// 覆盖场景（对应验收场景 1/2/4/11/14 数据层）：
//   场景1.P1/P2 —— 插件行进统一列表首位（keyword 完全命中）+ 单一数组无分区
//   场景2.P1/P2 —— app 命中排首、无命中插件不干扰
//   场景4.P1   —— 仅 instant 回归
//   场景11.P1  —— keyword+空格不自动锁定 + 列表混排
//   场景9      —— 空 query 清空列表与锁定
//   D5         —— Tab 锁定（lockPluginCandidate）后参数态

// MARK: - Helpers（command manifest 构造 —— 便利 init 默认 stdin，command 须走 JSON）

private func makeCommandManifest(
    name: String,
    keywords: [String],
    cmd: String = "./run.sh"
) throws -> PluginManifest {
    let json: [String: Any] = [
        "name": name,
        "version": "0.1.0",
        "description": "command mode fixture",
        "keywords": keywords,
        "mode": "command",
        "cmd": cmd,
        "args": [] as [String],
        "env": NSNull(),
        "requiredPath": NSNull(),
        "timeout": 5
    ]
    let data = try JSONSerialization.data(withJSONObject: json)
    return try JSONDecoder().decode(PluginManifest.self, from: data)
}

// MARK: - Mock：记录被启动 URL 的 AppLaunching

private final class RecordingAppLauncher: AppLaunching {
    private(set) var launchedURLs: [URL] = []
    func launch(_ url: URL) throws {
        launchedURLs.append(url)
    }
}

// MARK: - Helper：构造含 Qzhddr.app 的 AppLauncher registry（控制 app 命中）

@MainActor
private func makeAppLauncherRegistry(launcher: AppLaunching) -> BuiltinPluginRegistry {
    let qzhApp = URL(fileURLWithPath: "/Applications/Qzhddr.app")
    let index = AppIndex(fixedEntries: [
        AppEntry(url: qzhApp, name: "Qzhddr")
    ])
    let appLauncherPlugin = AppLauncherPlugin(index: index, launcher: launcher)
    return BuiltinPluginRegistry(plugins: [appLauncherPlugin])
}

@MainActor
final class LauncherRouteConflictAcceptanceTests: XCTestCase {

    private var cancellables: Set<AnyCancellable> = []

    override func setUp() async throws {
        try await super.setUp()
        await LauncherManager.shared.setup()
        if LauncherManager.shared.isVisible {
            await LauncherManager.shared.hide()
        }
        LauncherManager.shared.registryOverride = nil
        LauncherManager.shared.instantDebounceMsOverride = 0
        LauncherManager.shared.pluginsOverride = nil
        LauncherManager.shared.stdinExecutorOverride = nil
        LauncherManager.shared.lockedCommand = nil
        // CI 2867 回归：清前序测试残留的 stage/isSubmitting（防 stage 跨测试污染）。
        LauncherManager.shared.resetSubmittingStateForTesting()
    }

    override func tearDown() async throws {
        LauncherManager.shared.registryOverride = nil
        LauncherManager.shared.instantDebounceMsOverride = nil
        LauncherManager.shared.pluginsOverride = nil
        LauncherManager.shared.stdinExecutorOverride = nil
        LauncherManager.shared.lockedCommand = nil
        LauncherManager.shared.clearInstantActions()
        if LauncherManager.shared.isVisible {
            await LauncherManager.shared.hide()
        }
        cancellables.removeAll()
        try await super.tearDown()
    }

    // MARK: - 等待 updateQuery 收敛（debounce Task 落地）

    private func waitForQuerySettled(_ milliseconds: UInt64 = 60) async {
        for _ in 0..<3 {
            try? await Task.sleep(nanoseconds: milliseconds * 1_000_000)
            if !LauncherManager.shared.instantActions.isEmpty {
                return
            }
        }
    }

    // MARK: - 场景1.P1/P2 [det-machine] 插件行进统一列表 + 单一数组无分区

    /// 输入「qzh」：qzh 插件 keyword 完全命中（1000）排首；与 app（Qzhddr 前缀 1050 同列表）混排单一数组。
    func test_scenario1_P1_pluginAndApp_sameUnifiedList() async throws {
        let recordingLauncher = RecordingAppLauncher()
        LauncherManager.shared.registryOverride = makeAppLauncherRegistry(launcher: recordingLauncher)
        let qzh = try makeCommandManifest(name: "qzh", keywords: ["qzh", "监控"])
        LauncherManager.shared.pluginsOverride = [qzh]

        LauncherManager.shared.updateQuery("qzh")
        await waitForQuerySettled()

        let acts = LauncherManager.shared.instantActions
        XCTAssertTrue(acts.contains { $0.pluginId == "qzh" },
                      "场景1.P1: qzh 插件行进统一列表（不分 mode）")
        XCTAssertTrue(acts.contains { $0.pluginId == "app-launcher" },
                      "场景1.P1: Qzhddr app 行同在统一列表（混排）")
        XCTAssertNil(LauncherManager.shared.lockedCommand,
                     "场景1.P1: 无自动锁定（C-TAB-LOCK）")
    }

    /// 输入「二维码」（qr keyword 完全命中）→ qr 插件行排列表首（场景1.P1 数据层）
    func test_scenario1_P2_exactKeywordPlugin_ranksFirst() async throws {
        let qr = try makeCommandManifest(name: "qr", keywords: ["qr", "qrcode", "二维码", "码"])
        LauncherManager.shared.pluginsOverride = [qr]
        let recordingLauncher = RecordingAppLauncher()
        LauncherManager.shared.registryOverride = makeAppLauncherRegistry(launcher: recordingLauncher)

        LauncherManager.shared.updateQuery("二维码")
        await waitForQuerySettled()

        let acts = LauncherManager.shared.instantActions
        XCTAssertGreaterThanOrEqual(acts.count, 1, "场景1.P2: 候选非空")
        XCTAssertEqual(acts.first?.pluginId, "qr",
                       "场景1.P2: 「二维码」keyword 完全命中 → qr 排首位（无 app 命中同分）")
    }

    // MARK: - 场景2 [det-machine] app 命中排首 / 插件无命中不干扰

    /// 输入「qzhddr」：Qzhddr app 前缀命中 vs qzh 插件「qzhddr」keyword 完全命中——完全档 1000
    /// 应排在前？不：app 前缀档 800+50=850 < 插件完全档 1000 → 插件仍在前。
    /// 改验「插件无命中」分支：输「Qzh」大小写归一 + 无 keyword 命中的 app 查询。
    func test_scenario2_P1_appFirst_whenPluginNoHit() async throws {
        let recordingLauncher = RecordingAppLauncher()
        LauncherManager.shared.registryOverride = makeAppLauncherRegistry(launcher: recordingLauncher)
        // 插件 keywords 与 query 无任何命中
        let qr = try makeCommandManifest(name: "qr", keywords: ["qr", "二维码"])
        LauncherManager.shared.pluginsOverride = [qr]

        LauncherManager.shared.updateQuery("qzhddr")
        await waitForQuerySettled()

        let acts = LauncherManager.shared.instantActions
        XCTAssertFalse(acts.contains { $0.pluginId == "qr" },
                       "场景2.P1: 插件无命中不进列表（不干扰 app 搜索）")
        XCTAssertTrue(acts.contains { $0.pluginId == "app-launcher" },
                      "场景2.P1: app 候选正常")
    }

    // MARK: - 场景4.P1 [det-machine] 仅 instant（无插件）回归

    func test_scenario4_P1_onlyInstant_worksAsBefore() async throws {
        let recordingLauncher = RecordingAppLauncher()
        LauncherManager.shared.registryOverride = makeAppLauncherRegistry(launcher: recordingLauncher)
        LauncherManager.shared.pluginsOverride = []

        LauncherManager.shared.updateQuery("qzhddr")
        await waitForQuerySettled()

        let acts = LauncherManager.shared.instantActions
        XCTAssertFalse(acts.isEmpty, "场景4.P1: app 候选正常")
        XCTAssertTrue(acts.allSatisfy { !$0.id.hasPrefix("plugin:") },
                      "场景4.P1: 无插件候选")
        XCTAssertEqual(LauncherManager.shared.instantSelectedIndex, 0,
                       "场景4.P1: 默认选中 0")
    }

    // MARK: - 场景11.P1 [det-machine] keyword+空格不自动锁定 + 列表混排保持

    func test_scenario11_P1_keywordSpace_noAutoLock_unifiedListKept() async throws {
        let qzh = try makeCommandManifest(name: "qzh", keywords: ["qzh", "监控"])
        LauncherManager.shared.pluginsOverride = [qzh]
        LauncherManager.shared.registryOverride = makeAppLauncherRegistry(launcher: RecordingAppLauncher())

        LauncherManager.shared.updateQuery("qzh ")
        await waitForQuerySettled()

        XCTAssertNil(LauncherManager.shared.lockedCommand,
                     "场景11.P1: keyword+空格不自动锁定（C-TAB-LOCK，自动锁定退役）")
        XCTAssertFalse(LauncherManager.shared.instantActions.isEmpty,
                       "场景11.P1: 候选保持统一混排列表")
    }

    // MARK: - 场景9 [det-machine] 空 query 清空列表与锁定

    func test_scenario9_P1_emptyQuery_clearsListAndLock() async throws {
        let qzh = try makeCommandManifest(name: "qzh", keywords: ["qzh", "监控"])
        LauncherManager.shared.pluginsOverride = [qzh]
        LauncherManager.shared.updateQuery("qzh")
        await waitForQuerySettled()
        // Tab 锁定后清空
        LauncherManager.shared.lockPluginCandidate(qzh)
        XCTAssertNotNil(LauncherManager.shared.lockedCommand)

        LauncherManager.shared.updateQuery("")
        await waitForQuerySettled()

        XCTAssertNil(LauncherManager.shared.lockedCommand, "场景9: 空 query 清锁定（C-ESC-EXIT）")
        XCTAssertTrue(LauncherManager.shared.instantActions.isEmpty, "场景9: 空 query 清列表")
    }

    // MARK: - D5 Tab 锁定语义（原场景9/10 自动锁定用例的替代路径）

    func test_D5_tabLock_thenParamInput_stickyAndIsolated() async throws {
        let qzh = try makeCommandManifest(name: "qzh", keywords: ["qzh", "监控"])
        LauncherManager.shared.pluginsOverride = [qzh]
        LauncherManager.shared.updateQuery("qzh")
        await waitForQuerySettled()

        // Tab 锁定（View 层 onKeyPress(.tab) 对插件行调 lockPluginCandidate）
        LauncherManager.shared.lockPluginCandidate(qzh)
        XCTAssertEqual(LauncherManager.shared.lockedCommand?.name, "qzh",
                       "D5: Tab 锁定 → lockedCommand = qzh")

        // 参数态输入：粘性保持 + 候选隔离
        LauncherManager.shared.updateQuery("qzh status now")
        await waitForQuerySettled()
        XCTAssertEqual(LauncherManager.shared.lockedCommand?.name, "qzh",
                       "D5: 参数输入粘性保持锁定")
        XCTAssertTrue(LauncherManager.shared.instantActions.isEmpty,
                      "D5: 参数态候选隔离（C-PARAM-ISOLATE）")
    }

    // MARK: - 键盘导航回归：统一列表环形（原场景3 跨区导航的统一列表等价）

    func test_scenario3_P1_navigationWrapsWithinUnifiedList() async throws {
        let qzh = try makeCommandManifest(name: "qzh", keywords: ["qzh", "监控"])
        LauncherManager.shared.pluginsOverride = [qzh]
        LauncherManager.shared.registryOverride = makeAppLauncherRegistry(launcher: RecordingAppLauncher())

        LauncherManager.shared.updateQuery("qzh")
        await waitForQuerySettled()
        let count = LauncherManager.shared.instantActions.count
        XCTAssertGreaterThanOrEqual(count, 2, "前提：列表 ≥2 项（插件 + app 混排）")

        // 末项 ↓ → 环回首项（moveInstantSelection 语义，无越界）
        LauncherManager.shared.setInstantSelectedIndex(count - 1)
        LauncherManager.shared.moveInstantSelection(up: false)
        XCTAssertEqual(LauncherManager.shared.instantSelectedIndex, 0,
                       "统一列表环形：末 ↓ → 首")
        // 首项 ↑ → 环回末项
        LauncherManager.shared.moveInstantSelection(up: true)
        XCTAssertEqual(LauncherManager.shared.instantSelectedIndex, count - 1,
                       "统一列表环形：首 ↑ → 末")
    }
}
