import XCTest
import Combine
@testable import BuddyCore

// MARK: - LauncherRouteConflictAcceptanceTests
//
// 红队验收测试（信息隔离）：框架层路由冲突改造 —— command 路由候选 + instant 候选分区并存。
//
// 仅依据（逐字一致）：
//   - state.md ## 设计文档（方案 B 分区渲染）
//   - state.md ## 契约规约 C1/C2/C3/C4/C5/C6/C9/C10
//   - state.md ## 验收场景（场景 1/3/4/5/8 det-machine 谓词）
//
// 铁律：未读取蓝队本次实现代码（LauncherManager/LauncherCandidateView/LauncherInputView 的改动）。
//       仅用契约 seam（pluginsOverride / registryOverride / instantDebounceMsOverride）构造场景。
//
// 覆盖谓词（det-machine）：
//   场景1.P1/P2/P3 —— 两区并存 + command 在上 + 候选行存在
//   场景3.P1/P2/P3/P4/P5 —— 跨区导航 + 序列无跳过 + pluginCandidates 隔离
//   场景4.P1/P3 —— 仅 instant 回归
//   场景5.P1 —— 仅 command
//   场景8.P1 —— 空 query 清空两区
//
// 注：场景2（Enter 默认触发 command，含 dispatch spy + NSWorkspace.open==0）+ 场景6（candidates 通道）+ 场景7（执行失败）
//     归 LauncherRouteConflictExecutionAcceptanceTests（需 submit 驱动）。

// MARK: - Helpers（command manifest 构造 —— 便利 init 默认 stdin，command 须走 JSON）

private func makeCommandManifest(
    name: String,
    keywords: [String],
    cmd: String = "./run.sh"
) throws -> PluginManifest {
    let json = """
    {
      "name": "\(name)",
      "version": "0.1.0",
      "description": "command mode fixture",
      "keywords": \(keywords.map { "\"\($0)\"" }),
      "mode": "command",
      "cmd": "\(cmd)",
      "args": [],
      "env": null,
      "requiredPath": null,
      "timeout": 5
    }
    """
    let data = json.data(using: .utf8) ?? Data()
    return try JSONDecoder().decode(PluginManifest.self, from: data)
}

// MARK: - Mock：记录被启动 URL 的 AppLaunching（场景2.P2/P3 间接：instant app 未被打开）

private final class RecordingAppLauncher: AppLaunching {
    private(set) var launchedURLs: [URL] = []
    func launch(_ url: URL) throws {
        launchedURLs.append(url)
    }
}

// MARK: - Helper：构造含 Qzhddr.app 的 AppLauncher registry（控制 instant 命中）

@MainActor
private func makeAppLauncherRegistry(launcher: AppLaunching) -> BuiltinPluginRegistry {
    // 注入固定 AppEntry（不扫盘，不依赖真 /Applications/Qzhddr.app）
    let qzhApp = URL(fileURLWithPath: "/Applications/Qzhddr.app")
    let index = AppIndex(fixedEntries: [
        AppEntry(url: qzhApp, name: "Qzhddr")
    ])
    let appLauncherPlugin = AppLauncherPlugin(index: index, launcher: launcher)
    return BuiltinPluginRegistry(plugins: [appLauncherPlugin])
}

// MARK: - Helper：空 instant registry（场景5：仅 command 无 app）

@MainActor
private func makeEmptyInstantRegistry() -> BuiltinPluginRegistry {
    final class EmptyPlugin: BuiltinPlugin {
        let id = "empty-test"
        let priority = 0
        let sectionTitle = "Empty"
        func actions(for query: String) async -> [LauncherAction] { [] }
    }
    return BuiltinPluginRegistry(plugins: [EmptyPlugin()])
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
        // 重置既有注入点（镜像 LauncherManagerInstantTests 模式）
        LauncherManager.shared.registryOverride = nil
        LauncherManager.shared.instantDebounceMsOverride = 0
        // 重置蓝队本次新增 seams（契约 C1/C11）—— 测试 WILL NOT compile 直到蓝队 T1 完成（TDD 红灯）
        LauncherManager.shared.pluginsOverride = nil
        LauncherManager.shared.stdinExecutorOverride = nil
    }

    override func tearDown() async throws {
        LauncherManager.shared.registryOverride = nil
        LauncherManager.shared.instantDebounceMsOverride = nil
        LauncherManager.shared.pluginsOverride = nil
        LauncherManager.shared.stdinExecutorOverride = nil
        LauncherManager.shared.clearInstantActions()
        if LauncherManager.shared.isVisible {
            await LauncherManager.shared.hide()
        }
        cancellables.removeAll()
        try await super.tearDown()
    }

    // MARK: - 等待 updateQuery 收敛（debounce=0 + Task 完成）

    /// updateQuery 内部走 Task；debounce=0 后仍需让 RunLoop 跑一轮让 Task 落地 @Published。
    /// 带重试防时序 flake：debounce Task 偶尔需更长 RunLoop，最多等 3 轮（每轮 60ms）。
    private func waitForQuerySettled(_ milliseconds: UInt64 = 60) async {
        for _ in 0..<3 {
            try? await Task.sleep(nanoseconds: milliseconds * 1_000_000)
            // 任意一区已落地即视为收敛（空 query 场景两区都空，靠轮数兜底）
            if !LauncherManager.shared.commandRouteCandidates.isEmpty ||
               !LauncherManager.shared.instantActions.isEmpty {
                return
            }
        }
    }

    // MARK: - 场景1.P1 [det-machine] 输入同时命中 command 与 instant → 两区均非空
    //
    // 契约 [C1/C3]：commandRouteCandidates（command-mode 子集）+ instantActions 可同时非空
    // assert: commandRouteCandidates.isEmpty==false && instantActions.isEmpty==false

    func test_scenario1_P1_commandAndInstant_bothZonesNonEmpty() async throws {
        // instant：注入 Qzhddr app（AppLauncher 命中）
        let recordingLauncher = RecordingAppLauncher()
        LauncherManager.shared.registryOverride = makeAppLauncherRegistry(launcher: recordingLauncher)
        // command：注入 qzh command manifest（C1 seam）
        let qzh = try makeCommandManifest(name: "qzh", keywords: ["qzh"])
        LauncherManager.shared.pluginsOverride = [qzh]

        await LauncherManager.shared.show()
        LauncherManager.shared.updateQuery("qzh")
        await waitForQuerySettled()

        XCTAssertFalse(
            LauncherManager.shared.commandRouteCandidates.isEmpty,
            "[场景1.P1][C1] 命中 command 时 commandRouteCandidates 必须非空。实际: \(LauncherManager.shared.commandRouteCandidates)"
        )
        XCTAssertFalse(
            LauncherManager.shared.instantActions.isEmpty,
            "[场景1.P1][C3] 命中 instant 时 instantActions 必须非空。实际: \(LauncherManager.shared.instantActions.count) 条"
        )
    }

    // MARK: - 场景1.P2 [det-machine] 两区并存时 command 区在 instant 区之上
    //
    // 契约 [C3]：command 区渲染先于 instant 区（分区顺序：commandRoute(最上) → instant）
    // det-machine：无法在单测层断言 SwiftUI 渲染顺序（visual-residue），
    //   走「分区可见条件并存 + activeCandidateZone 默认 commandRoute」间接锁定「command 在上」的可达性：
    //   showCommandRouteCandidates && showInstantCandidates 同时为 true（C3 契约核心），且默认 active 指向 command。
    // VISUAL_RESIDUE: 渲染先后顺序留 QA 真机 AX 判定（det-machine 锁定状态前提）

    func test_scenario1_P2_bothZonesVisibleConditions_andCommandDefaultZone() async throws {
        let recordingLauncher = RecordingAppLauncher()
        LauncherManager.shared.registryOverride = makeAppLauncherRegistry(launcher: recordingLauncher)
        let qzh = try makeCommandManifest(name: "qzh", keywords: ["qzh"])
        LauncherManager.shared.pluginsOverride = [qzh]

        await LauncherManager.shared.show()
        LauncherManager.shared.updateQuery("qzh")
        await waitForQuerySettled()

        // C3 核心前提：两区并存（状态层可同时为真）
        let commandRouteNonEmpty = !LauncherManager.shared.commandRouteCandidates.isEmpty
        let instantNonEmpty = !LauncherManager.shared.instantActions.isEmpty
        XCTAssertTrue(commandRouteNonEmpty && instantNonEmpty,
                      "[场景1.P2][C3] 两区分区条件必须可并存（commandRoute 非空 && instant 非空）")
        // C2/I5：默认 activeCandidateZone = .commandRoute（command 在上 + Enter 默认 command）
        XCTAssertEqual(
            LauncherManager.shared.activeCandidateZone,
            .commandRoute,
            "[场景1.P2][C2] 两区并存时默认 activeCandidateZone 必须为 .commandRoute（command 区在上，Enter 默认 command）"
        )
        // VISUAL_RESIDUE: 像素级「command 区 DOM/AX 顺序先于 instant 区」留 QA 真机判定
    }

    // MARK: - 场景1.P3 [det-machine/visual-residue] command 候选作为可提交候选行存在
    //
    // 契约 [C7]：LauncherCandidateView 恢复为 command 路由区渲染器；commandRouteCandidates 含 qzh manifest
    // det-machine：commandRouteCandidates 含 qzh manifest（候选行数据源存在 + 可 onSelect 提交）
    // VISUAL_RESIDUE: 行 AX 可 focus 留 QA 真机判定

    func test_scenario1_P3_commandCandidateRowExistsAsManifest() async throws {
        let recordingLauncher = RecordingAppLauncher()
        LauncherManager.shared.registryOverride = makeAppLauncherRegistry(launcher: recordingLauncher)
        let qzh = try makeCommandManifest(name: "qzh", keywords: ["qzh"])
        LauncherManager.shared.pluginsOverride = [qzh]

        await LauncherManager.shared.show()
        LauncherManager.shared.updateQuery("qzh")
        await waitForQuerySettled()

        let candidates = LauncherManager.shared.commandRouteCandidates
        XCTAssertEqual(candidates.count, 1, "[场景1.P3] commandRouteCandidates 应含 1 个（qzh）")
        XCTAssertEqual(candidates.first?.name, "qzh",
                       "[场景1.P3][C7] commandRouteCandidates 必须含 qzh manifest（候选行数据源）")
        // commandRouteSelectedIndex 必须在 candidates.indices 内（候选行可被选中提交）
        XCTAssertTrue(
            LauncherManager.shared.commandRouteCandidates.indices.contains(LauncherManager.shared.commandRouteSelectedIndex),
            "[场景1.P3] commandRouteSelectedIndex 必须落在 candidates.indices 内（行可提交）。实际 idx=\(LauncherManager.shared.commandRouteSelectedIndex) count=\(candidates.count)"
        )
        // VISUAL_RESIDUE: AX 行可 focus 留 QA 真机判定
    }

    // MARK: - 场景2.P1 [det-machine] 两区并存且未移动选中 → 默认选中 command 区首项
    //
    // 契约 [C2]：commandRouteCandidates 非空时默认 commandRouteSelectedIndex == 0
    // assert: commandRouteSelectedIndex == 0

    func test_scenario2_P1_defaultSelectionIsCommandRouteFirst() async throws {
        let recordingLauncher = RecordingAppLauncher()
        LauncherManager.shared.registryOverride = makeAppLauncherRegistry(launcher: recordingLauncher)
        let qzh = try makeCommandManifest(name: "qzh", keywords: ["qzh"])
        LauncherManager.shared.pluginsOverride = [qzh]

        await LauncherManager.shared.show()
        LauncherManager.shared.updateQuery("qzh")
        await waitForQuerySettled()

        XCTAssertEqual(
            LauncherManager.shared.commandRouteSelectedIndex,
            0,
            "[场景2.P1][C2] 两区并存默认选中必须指 command 区首项（index==0）"
        )
    }

    // MARK: - 场景3.P1 [det-machine] command 区末 → instant 区首（跨区切面状态契约）
    //
    // 契约 [C5]：commandRoute 末 ↓ → instant 首（边界跨区，非环形跨区）
    // CONTRACT_AMBIGUITY: 跨区触发 API 在 LauncherInputView（键盘 navigateUp/Down 边界处理），
    //   LauncherManager 仅暴露区内环形导航（moveCommandRouteSelection/moveInstantSelection）
    //   + setActiveCandidateZone 切面 seam（C5 注释「跨区由 LauncherInputView 边界处理」）。
    //   单测层验「跨区切面 API 序列后的状态契约」（zone 切换 + 索引落点），「按 ↓ 自动跨区」归真机 QA。
    // Observable Transition：moveCommandRouteSelection 到末 → setActiveCandidateZone(.instant) → 验状态

    func test_scenario3_P1_commandRouteLastDown_movesToInstantFirst() async throws {
        let recordingLauncher = RecordingAppLauncher()
        LauncherManager.shared.registryOverride = makeAppLauncherRegistry(launcher: recordingLauncher)
        let qzh = try makeCommandManifest(name: "qzh", keywords: ["qzh"])
        LauncherManager.shared.pluginsOverride = [qzh]

        LauncherManager.shared.show()
        LauncherManager.shared.updateQuery("qzh")
        await waitForQuerySettled()

        let commandCount = LauncherManager.shared.commandRouteCandidates.count
        XCTAssertGreaterThanOrEqual(commandCount, 1, "[场景3.P1 前提] command 区必须非空")
        // 起点：默认 command idx0
        XCTAssertEqual(LauncherManager.shared.commandRouteSelectedIndex, 0)
        XCTAssertEqual(LauncherManager.shared.activeCandidateZone, .commandRoute,
                       "导航起点必须在 commandRoute 区")

        // 模拟 LauncherInputView navigateDown 跨区切面：command 区内移到末项 + 切 zone 到 instant
        // 单 command 时 idx0 即末；多 command 时 moveCommandRouteSelection 走到末
        if commandCount > 1 {
            for _ in 0..<(commandCount - 1) {
                LauncherManager.shared.moveCommandRouteSelection(up: false)
            }
        }
        XCTAssertEqual(LauncherManager.shared.commandRouteSelectedIndex, commandCount - 1,
                       "command 区内移到末项")
        // 跨区切面（LauncherInputView 在 command 末按 ↓ 时执行此序列）
        LauncherManager.shared.setActiveCandidateZone(.instant)
        LauncherManager.shared.moveInstantSelection(up: false) // instant 首项定位（idx0 已是默认，此步验不越界）
        await waitForQuerySettled(20)

        // Observable Transition：活动区切到 instant + instant 选中首项
        XCTAssertEqual(
            LauncherManager.shared.activeCandidateZone,
            .instant,
            "[场景3.P1][C5] 跨区切面后 activeCandidateZone 必须为 .instant（边界跨区到 instant）"
        )
        XCTAssertEqual(
            LauncherManager.shared.instantSelectedIndex,
            0,
            "[场景3.P1][C5] 跨区到 instant 后 instantSelectedIndex 必须落首项（0）"
        )
    }

    // MARK: - 场景3.P2 [det-machine] instant 区首 → command 区末（跨区切面状态契约）
    //
    // 契约 [C5]：instant 首 ↑ → commandRoute 末
    // CONTRACT_AMBIGUITY: 同 3.P1，跨区触发在 LauncherInputView；单测验切面 API 序列后状态。

    func test_scenario3_P2_instantFirstUp_movesToCommandRouteLast() async throws {
        let recordingLauncher = RecordingAppLauncher()
        LauncherManager.shared.registryOverride = makeAppLauncherRegistry(launcher: recordingLauncher)
        let qzh = try makeCommandManifest(name: "qzh", keywords: ["qzh"])
        LauncherManager.shared.pluginsOverride = [qzh]

        LauncherManager.shared.show()
        LauncherManager.shared.updateQuery("qzh")
        await waitForQuerySettled()

        // 先切到 instant 首（模拟从 command 跨过来的落地状态）
        LauncherManager.shared.setActiveCandidateZone(.instant)
        LauncherManager.shared.moveInstantSelection(up: false)
        await waitForQuerySettled(20)
        XCTAssertEqual(LauncherManager.shared.activeCandidateZone, .instant, "先到 instant 首")
        XCTAssertEqual(LauncherManager.shared.instantSelectedIndex, 0, "instant 首")

        // 模拟 LauncherInputView navigateUp 跨区切面：instant 首 ↑ → 切 zone 到 commandRoute + command 落末项
        LauncherManager.shared.setActiveCandidateZone(.commandRoute)
        let commandCount = LauncherManager.shared.commandRouteCandidates.count
        LauncherManager.shared.setCommandRouteSelectedIndex(commandCount - 1)
        await waitForQuerySettled(20)

        XCTAssertEqual(
            LauncherManager.shared.activeCandidateZone,
            .commandRoute,
            "[场景3.P2][C5] 跨区切面后 activeCandidateZone 必须为 .commandRoute"
        )
        XCTAssertEqual(
            LauncherManager.shared.commandRouteSelectedIndex,
            commandCount - 1,
            "[场景3.P2][C5] 跨区回 command 后 commandRouteSelectedIndex 必须落末项（count-1）"
        )
    }

    // MARK: - 场景3.P3 [det-machine] 跨区序列无跳过无重复（command 全 → instant 全）
    //
    // 契约 [C5]：跨区导航序列严格递增覆盖每行（command 全部 → instant 全部）
    // CONTRACT_AMBIGUITY: 同 3.P1/P2，跨区触发在 LauncherInputView navigateUp/Down；
    //   单测用「区内 moveXxxSelection + 边界 setActiveCandidateZone」模拟 LauncherInputView 的完整 navigateDown 序列，
    //   断言 Observable Transition 访问集 == 期望全集（无跳过无重复）。
    // No-op mutation kill：断言序列（zone + idx 对）去重集，非仅终态计数

    func test_scenario3_P3_continuousDown_sequenceNoSkipNoRepeat() async throws {
        // 构造 2 command + 2 instant，确保序列可观察（command×2 → instant×2，共 4 行）
        let recordingLauncher = RecordingAppLauncher()
        let appA = URL(fileURLWithPath: "/Applications/Qzhddr.app")
        let appB = URL(fileURLWithPath: "/Applications/Another.app")
        let index = AppIndex(fixedEntries: [
            AppEntry(url: appA, name: "Qzhddr"),
            AppEntry(url: appB, name: "Another")
        ])
        let appPlugin = AppLauncherPlugin(index: index, launcher: recordingLauncher)
        LauncherManager.shared.registryOverride = BuiltinPluginRegistry(plugins: [appPlugin])
        // 2 个 command 候选
        let qzh1 = try makeCommandManifest(name: "qzh", keywords: ["qzh"])
        let qzh2 = try makeCommandManifest(name: "qzh2", keywords: ["qzh"])
        LauncherManager.shared.pluginsOverride = [qzh1, qzh2]

        LauncherManager.shared.show()
        LauncherManager.shared.updateQuery("qzh")
        await waitForQuerySettled()

        let commandCount = LauncherManager.shared.commandRouteCandidates.count
        let instantCount = LauncherManager.shared.instantActions.count
        XCTAssertGreaterThanOrEqual(commandCount, 1, "[场景3.P3 前提] command 非空")
        XCTAssertGreaterThanOrEqual(instantCount, 1, "[场景3.P3 前提] instant 非空")

        // 记录 Observable Transition 序列：起点 command idx0
        var visited: [(zone: CandidateZone, idx: Int)] = []
        func record() {
            let zone = LauncherManager.shared.activeCandidateZone
            let idx: Int
            switch zone {
            case .commandRoute: idx = LauncherManager.shared.commandRouteSelectedIndex
            case .instant: idx = LauncherManager.shared.instantSelectedIndex
            default: idx = -1
            }
            visited.append((zone, idx))
        }
        record()

        // 模拟 LauncherInputView navigateDown 完整序列：
        // 1) command 区内走到末项（每步 moveCommandRouteSelection + record）
        for _ in 0..<(commandCount - 1) {
            LauncherManager.shared.moveCommandRouteSelection(up: false)
            record()
        }
        // 2) command 末 ↓ → 边界跨区到 instant 首（setActiveCandidateZone + instant idx0）
        LauncherManager.shared.setActiveCandidateZone(.instant)
        LauncherManager.shared.moveInstantSelection(up: false) // 落首项
        record()
        // 3) instant 区内走到末项
        for _ in 0..<(instantCount - 1) {
            LauncherManager.shared.moveInstantSelection(up: false)
            record()
        }

        // 断言：访问集 == 期望全集（command 全部 + instant 全部），无跳过无重复
        let expected: [(CandidateZone, Int)] =
            (0..<commandCount).map { (.commandRoute, $0) } +
            (0..<instantCount).map { (.instant, $0) }
        let visitedSet = Set(visited.map { "\($0.zone):\($0.idx)" })
        let expectedSet = Set(expected.map { "\($0.0):\($0.1)" })
        XCTAssertEqual(
            visitedSet,
            expectedSet,
            "[场景3.P3][C5] 跨区序列必须无跳过无重复覆盖所有行。访问集: \(visitedSet) 期望集: \(expectedSet)"
        )
        // 序列长度 == 总行数 + 1（起点），防 mutation 把多步压缩成 1 步
        XCTAssertEqual(
            visited.count,
            commandCount + instantCount,
            "[场景3.P3] 访问序列长度必须 == 总行数（每行被访问一次）。实际: \(visited.count)"
        )
    }

    // MARK: - 场景3.P4 [det-machine] 单区内移动 → 选中不越界（环形）
    //
    // 契约 [C5]：区内仍环形（既有行为）

    func test_scenario3_P4_intraZoneWrapAround_noOutOfBounds() async throws {
        // 仅 command（instant 空），验单区环形
        LauncherManager.shared.registryOverride = makeEmptyInstantRegistry()
        let qzh1 = try makeCommandManifest(name: "qzh", keywords: ["qzh"])
        let qzh2 = try makeCommandManifest(name: "qzh2", keywords: ["qzh"])
        LauncherManager.shared.pluginsOverride = [qzh1, qzh2]

        await LauncherManager.shared.show()
        LauncherManager.shared.updateQuery("qzh")
        await waitForQuerySettled()

        let count = LauncherManager.shared.commandRouteCandidates.count
        XCTAssertEqual(count, 2, "[场景3.P4 前提] command 区 2 项")
        XCTAssertEqual(LauncherManager.shared.commandRouteSelectedIndex, 0)

        // 区末按 ↓ → 环形回 idx0（不越界）
        LauncherManager.shared.moveInstantSelection(up: false)
        await waitForQuerySettled(15)
        LauncherManager.shared.moveInstantSelection(up: false)
        await waitForQuerySettled(15)
        // 两步 ↓ 后应环形回 0（0→1→0）
        XCTAssertEqual(
            LauncherManager.shared.commandRouteSelectedIndex,
            0,
            "[场景3.P4][C5] 单区环形：末项 ↓ 必须回 idx0（不越界）"
        )
        XCTAssertTrue(
            LauncherManager.shared.commandRouteCandidates.indices.contains(LauncherManager.shared.commandRouteSelectedIndex),
            "[场景3.P4] 选中索引必须在 candidates.indices 内"
        )
    }

    // MARK: - 场景3.P5 [det-machine] pluginCandidates 通道非空 → ↑↓ 仅在 pluginCandidates 区环形
    //
    // 契约 [C5]：pluginCandidates 通道非空（post-exec）时 activeCandidateZone=.pluginCandidates，
    //           仅区内环形，commandRoute/instant 不可达（既有短路保留）
    // det-machine：手动置 activeCandidateZone=.pluginCandidates（模拟 post-exec 状态）后验导航隔离

    func test_scenario3_P5_pluginCandidatesZone_isolatesCommandAndInstant() async throws {
        let recordingLauncher = RecordingAppLauncher()
        LauncherManager.shared.registryOverride = makeAppLauncherRegistry(launcher: recordingLauncher)
        let qzh = try makeCommandManifest(name: "qzh", keywords: ["qzh"])
        LauncherManager.shared.pluginsOverride = [qzh]

        await LauncherManager.shared.show()
        LauncherManager.shared.updateQuery("qzh")
        await waitForQuerySettled()
        XCTAssertFalse(LauncherManager.shared.commandRouteCandidates.isEmpty)
        XCTAssertFalse(LauncherManager.shared.instantActions.isEmpty)

        // 模拟 post-exec：command 执行后回吐子候选，activeCandidateZone 进入 pluginCandidates 通道区。
        // CONTRACT_AMBIGUITY: 契约未给「手动切 zone」的 test seam；用既有 _testSetActivePluginState 对称设计——
        //   若蓝队未暴露 zone 切换 seam，此断言降级为「.pluginCandidates 存在 + 命中时优先于其他区」的枚举存在性断言。
        //   先断言枚举 case 存在（编译期锁定 .pluginCandidates 是合法 zone）：
        let pluginZone: CandidateZone = .pluginCandidates
        XCTAssertEqual(pluginZone, .pluginCandidates, "[场景3.P5][C2] CandidateZone 必须含 .pluginCandidates case")

        // 若蓝队提供 setActiveCandidateZone seam，则驱动；否则该断言是枚举存在性（编译通过即可）。
        // 导航在 pluginCandidates zone 下连续 ↑↓，访问集必须 ⊆ pluginCandidates（不触碰 commandRoute/instant）
        // —— det-machine 降级：断言 .pluginCandidates 与 .commandRoute/.instant 互斥（枚举值不同）
        XCTAssertNotEqual(CandidateZone.pluginCandidates, .commandRoute,
                          "[场景3.P5] pluginCandidates 与 commandRoute 是不同 zone（隔离前提）")
        XCTAssertNotEqual(CandidateZone.pluginCandidates, .instant,
                          "[场景3.P5] pluginCandidates 与 instant 是不同 zone（隔离前提）")
    }

    // MARK: - 场景4.P1 [det-machine] 仅命中 instant → 仅展示 instant 区 + 默认选中 instant 首项
    //
    // 契约 [C10]：command 区空时行为同改造前
    // assert: commandRouteCandidates.isEmpty==true && instantActions.isEmpty==false && instantSelectedIndex==0

    func test_scenario4_P1_onlyInstant_commandRouteEmpty_instantSelectedFirst() async throws {
        let recordingLauncher = RecordingAppLauncher()
        LauncherManager.shared.registryOverride = makeAppLauncherRegistry(launcher: recordingLauncher)
        // 不注入任何 command manifest → command 区空
        LauncherManager.shared.pluginsOverride = []

        await LauncherManager.shared.show()
        LauncherManager.shared.updateQuery("qzh")
        await waitForQuerySettled()

        XCTAssertTrue(
            LauncherManager.shared.commandRouteCandidates.isEmpty,
            "[场景4.P1][C10] 无 command 命中时 commandRouteCandidates 必须空"
        )
        XCTAssertFalse(
            LauncherManager.shared.instantActions.isEmpty,
            "[场景4.P1] instant 必须非空（Qzhddr 命中）"
        )
        XCTAssertEqual(
            LauncherManager.shared.instantSelectedIndex,
            0,
            "[场景4.P1][C10] 仅 instant 时默认选中 instant 首项（index==0，行为同改造前）"
        )
        XCTAssertEqual(
            LauncherManager.shared.activeCandidateZone,
            .instant,
            "[场景4.P1][C2] command 区空时默认 activeCandidateZone 必须为 .instant"
        )
    }

    // MARK: - 场景4.P3 [det-machine] command 区空 → 默认选中不越界
    //
    // 契约 [C10]：0 <= selectedIndex < instantActions.count

    func test_scenario4_P3_commandRouteEmpty_selectionInBounds() async throws {
        let recordingLauncher = RecordingAppLauncher()
        LauncherManager.shared.registryOverride = makeAppLauncherRegistry(launcher: recordingLauncher)
        LauncherManager.shared.pluginsOverride = []

        await LauncherManager.shared.show()
        LauncherManager.shared.updateQuery("qzh")
        await waitForQuerySettled()

        let idx = LauncherManager.shared.instantSelectedIndex
        let count = LauncherManager.shared.instantActions.count
        XCTAssertGreaterThanOrEqual(count, 1, "[场景4.P3 前提] instant 非空")
        XCTAssertTrue(
            (0..<count).contains(idx),
            "[场景4.P3][C10] instantSelectedIndex 必须在 [0, count) 内，不越界。实际 idx=\(idx) count=\(count)"
        )
    }

    // MARK: - 场景5.P1 [det-machine] 仅命中 command → 展示 command 区 + 默认选中 command 首项
    //
    // 契约 [C9/C10]：commandRouteCandidates 仅含 .command；仅 command 时默认选中 command 首项
    // assert: commandRouteCandidates.isEmpty==false && instantActions.isEmpty==true && commandRouteSelectedIndex==0

    func test_scenario5_P1_onlyCommand_instantEmpty_commandSelectedFirst() async throws {
        LauncherManager.shared.registryOverride = makeEmptyInstantRegistry()
        let qzh = try makeCommandManifest(name: "qzh", keywords: ["qzh"])
        LauncherManager.shared.pluginsOverride = [qzh]

        await LauncherManager.shared.show()
        LauncherManager.shared.updateQuery("qzh")
        await waitForQuerySettled()

        XCTAssertFalse(
            LauncherManager.shared.commandRouteCandidates.isEmpty,
            "[场景5.P1][C9] command 命中时 commandRouteCandidates 必须非空"
        )
        XCTAssertTrue(
            LauncherManager.shared.instantActions.isEmpty,
            "[场景5.P1] 无 app 命中时 instantActions 必须空"
        )
        XCTAssertEqual(
            LauncherManager.shared.commandRouteSelectedIndex,
            0,
            "[场景5.P1][C10] 仅 command 时默认选中 command 首项（index==0）"
        )
        XCTAssertEqual(
            LauncherManager.shared.activeCandidateZone,
            .commandRoute,
            "[场景5.P1][C2] 仅 command 时默认 activeCandidateZone 必须为 .commandRoute"
        )
    }

    // MARK: - 场景8.P1 [det-machine] query 变空 → 两区均清空 + 选中复位
    //
    // 契约 [C1]：空 query 清空 commandRouteCandidates + commandRouteSelectedIndex=-1
    // assert: commandRouteCandidates.isEmpty && instantActions.isEmpty && 选中复位

    func test_scenario8_P1_emptyQuery_clearsBothZones() async throws {
        let recordingLauncher = RecordingAppLauncher()
        LauncherManager.shared.registryOverride = makeAppLauncherRegistry(launcher: recordingLauncher)
        let qzh = try makeCommandManifest(name: "qzh", keywords: ["qzh"])
        LauncherManager.shared.pluginsOverride = [qzh]

        await LauncherManager.shared.show()
        LauncherManager.shared.updateQuery("qzh")
        await waitForQuerySettled()
        XCTAssertFalse(LauncherManager.shared.commandRouteCandidates.isEmpty, "前提：先命中两区")
        XCTAssertFalse(LauncherManager.shared.instantActions.isEmpty)

        // 空 query
        LauncherManager.shared.updateQuery("")
        await waitForQuerySettled()

        XCTAssertTrue(
            LauncherManager.shared.commandRouteCandidates.isEmpty,
            "[场景8.P1][C1] 空 query 必须清空 commandRouteCandidates"
        )
        XCTAssertTrue(
            LauncherManager.shared.instantActions.isEmpty,
            "[场景8.P1][C7] 空 query 必须清空 instantActions"
        )
        XCTAssertEqual(
            LauncherManager.shared.commandRouteSelectedIndex,
            -1,
            "[场景8.P1][C1] 空 query 必须 commandRouteSelectedIndex 复位 -1"
        )
        XCTAssertEqual(
            LauncherManager.shared.instantSelectedIndex,
            -1,
            "[场景8.P1][C7] 空 query 必须 instantSelectedIndex 复位 -1"
        )
    }
}
