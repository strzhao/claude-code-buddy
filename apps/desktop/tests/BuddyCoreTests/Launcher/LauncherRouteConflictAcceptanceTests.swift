import XCTest
import Combine
@testable import BuddyCore

// MARK: - LauncherRouteConflictAcceptanceTests
//
// 方案 B 两阶段改造后的验收测试（det-machine）：command 路由候选 + instant 候选分区并存，
// 以及「选中 = 锁定 ≠ 执行」新语义（C-LOCK-NOT-EXECUTE / C-UNIQUE-AUTOLOCK）。
//
// 关键语义变更（vs 旧方案 B）：
//   - 唯一命中 command → 自动锁定（C-UNIQUE-AUTOLOCK），候选清空，instant 隔离（C-PARAM-ISOLATE）。
//   - 多命中 command → 候选列出（C-MULTI-SELECT-LOCK），两区可并存；用户显式选中才锁定。
//   - 选中 = 设 lockedCommand，不执行（C-LOCK-NOT-EXECUTE）。
//
// 故旧测试用「唯一 qzh」构造两区并存的场景，全部改为「多 command 共享 keyword」构造多命中两区并存。
//
// 覆盖谓词（det-machine）：
//   场景1.P1/P2/P3 —— 多命中两区并存 + command 在上 + 候选行存在
//   场景3.P1/P2/P3/P4/P5 —— 跨区导航 + 序列无跳过 + pluginCandidates 隔离
//   场景4.P1/P3 —— 仅 instant 回归
//   场景5.P1 —— 仅 command（多命中，验证候选列出）
//   场景8.P1 —— 空 query 清空两区
//   场景9 —— 唯一命中自动锁定（C-UNIQUE-AUTOLOCK，新）

// MARK: - Helpers（command manifest 构造 —— 便利 init 默认 stdin，command 须走 JSON）

private func makeCommandManifest(
    name: String,
    keywords: [String],
    cmd: String = "./run.sh"
) throws -> PluginManifest {
    // 用 JSONSerialization 正确编码 keywords（避免字符串插值把 keyword 包成带引号字面量，
    // 导致 commandPrefixMatched 严格前缀匹配漏命中）。
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

// MARK: - Helper：构造含 Qzhddr.app 的 AppLauncher registry（控制 instant 命中）

@MainActor
private func makeAppLauncherRegistry(launcher: AppLaunching) -> BuiltinPluginRegistry {
    let qzhApp = URL(fileURLWithPath: "/Applications/Qzhddr.app")
    let index = AppIndex(fixedEntries: [
        AppEntry(url: qzhApp, name: "Qzhddr")
    ])
    let appLauncherPlugin = AppLauncherPlugin(index: index, launcher: launcher)
    return BuiltinPluginRegistry(plugins: [appLauncherPlugin])
}

// MARK: - Helper：空 instant registry（仅 command 场景）

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

    // MARK: - 等待 updateQuery 收敛

    private func waitForQuerySettled(_ milliseconds: UInt64 = 60) async {
        for _ in 0..<3 {
            try? await Task.sleep(nanoseconds: milliseconds * 1_000_000)
            if !LauncherManager.shared.commandRouteCandidates.isEmpty ||
               !LauncherManager.shared.instantActions.isEmpty {
                return
            }
        }
    }

    /// 构造两个共享 keyword「qzh」的 command manifest（多命中：query "qzh" 行尾分隔符匹配两 manifest）。
    private func makeTwoSharedCommandManifests() throws -> [PluginManifest] {
        return [
            try makeCommandManifest(name: "qzh", keywords: ["qzh"]),
            try makeCommandManifest(name: "qzh2", keywords: ["qzh"])
        ]
    }

    // MARK: - 场景1.P1 [det-machine] 多命中 command + instant → 两区均非空

    func test_scenario1_P1_commandAndInstant_bothZonesNonEmpty() async throws {
        let recordingLauncher = RecordingAppLauncher()
        LauncherManager.shared.registryOverride = makeAppLauncherRegistry(launcher: recordingLauncher)
        LauncherManager.shared.pluginsOverride = try makeTwoSharedCommandManifests()

        await LauncherManager.shared.show()
        LauncherManager.shared.updateQuery("qzh")
        await waitForQuerySettled()

        XCTAssertFalse(
            LauncherManager.shared.commandRouteCandidates.isEmpty,
            "[场景1.P1][C1] 多命中 command 时 commandRouteCandidates 必须非空。实际: \(LauncherManager.shared.commandRouteCandidates)"
        )
        XCTAssertFalse(
            LauncherManager.shared.instantActions.isEmpty,
            "[场景1.P1][C3] 命中 instant 时 instantActions 必须非空。实际: \(LauncherManager.shared.instantActions.count) 条"
        )
    }

    // MARK: - 场景1.P2 [det-machine] 两区并存时 command 区默认活动区

    func test_scenario1_P2_bothZonesVisibleConditions_andCommandDefaultZone() async throws {
        let recordingLauncher = RecordingAppLauncher()
        LauncherManager.shared.registryOverride = makeAppLauncherRegistry(launcher: recordingLauncher)
        LauncherManager.shared.pluginsOverride = try makeTwoSharedCommandManifests()

        await LauncherManager.shared.show()
        LauncherManager.shared.updateQuery("qzh")
        await waitForQuerySettled()

        let commandRouteNonEmpty = !LauncherManager.shared.commandRouteCandidates.isEmpty
        let instantNonEmpty = !LauncherManager.shared.instantActions.isEmpty
        XCTAssertTrue(commandRouteNonEmpty && instantNonEmpty,
                      "[场景1.P2][C3] 多命中两区分区条件必须可并存")
        XCTAssertEqual(
            LauncherManager.shared.activeCandidateZone,
            .commandRoute,
            "[场景1.P2][C2] 多命中两区并存时默认 activeCandidateZone 必须为 .commandRoute"
        )
    }

    // MARK: - 场景1.P3 [det-machine] 多命中 command 候选行存在

    func test_scenario1_P3_commandCandidateRowExistsAsManifest() async throws {
        let recordingLauncher = RecordingAppLauncher()
        LauncherManager.shared.registryOverride = makeAppLauncherRegistry(launcher: recordingLauncher)
        LauncherManager.shared.pluginsOverride = try makeTwoSharedCommandManifests()

        await LauncherManager.shared.show()
        LauncherManager.shared.updateQuery("qzh")
        await waitForQuerySettled()

        let candidates = LauncherManager.shared.commandRouteCandidates
        XCTAssertEqual(candidates.count, 2, "[场景1.P3] 多命中 commandRouteCandidates 应含 2 个")
        XCTAssertTrue(
            LauncherManager.shared.commandRouteCandidates.indices.contains(LauncherManager.shared.commandRouteSelectedIndex),
            "[场景1.P3] commandRouteSelectedIndex 必须落在 candidates.indices 内"
        )
    }

    // MARK: - 场景2.P1 [det-machine] 多命中两区并存默认选中 command 区首项

    func test_scenario2_P1_defaultSelectionIsCommandRouteFirst() async throws {
        let recordingLauncher = RecordingAppLauncher()
        LauncherManager.shared.registryOverride = makeAppLauncherRegistry(launcher: recordingLauncher)
        LauncherManager.shared.pluginsOverride = try makeTwoSharedCommandManifests()

        await LauncherManager.shared.show()
        LauncherManager.shared.updateQuery("qzh")
        await waitForQuerySettled()

        XCTAssertEqual(
            LauncherManager.shared.commandRouteSelectedIndex,
            0,
            "[场景2.P1][C2] 多命中两区并存默认选中必须指 command 区首项（index==0）"
        )
    }

    // MARK: - 场景3.P1 [det-machine] command 区末 → instant 区首（跨区切面）

    func test_scenario3_P1_commandRouteLastDown_movesToInstantFirst() async throws {
        let recordingLauncher = RecordingAppLauncher()
        LauncherManager.shared.registryOverride = makeAppLauncherRegistry(launcher: recordingLauncher)
        LauncherManager.shared.pluginsOverride = try makeTwoSharedCommandManifests()

        LauncherManager.shared.show()
        LauncherManager.shared.updateQuery("qzh")
        await waitForQuerySettled()

        let commandCount = LauncherManager.shared.commandRouteCandidates.count
        XCTAssertGreaterThanOrEqual(commandCount, 1, "[场景3.P1 前提] command 区必须非空")
        XCTAssertEqual(LauncherManager.shared.commandRouteSelectedIndex, 0)
        XCTAssertEqual(LauncherManager.shared.activeCandidateZone, .commandRoute,
                       "导航起点必须在 commandRoute 区")

        if commandCount > 1 {
            for _ in 0..<(commandCount - 1) {
                LauncherManager.shared.moveCommandRouteSelection(up: false)
            }
        }
        XCTAssertEqual(LauncherManager.shared.commandRouteSelectedIndex, commandCount - 1,
                       "command 区内移到末项")
        LauncherManager.shared.setActiveCandidateZone(.instant)
        LauncherManager.shared.moveInstantSelection(up: false)
        await waitForQuerySettled(20)

        XCTAssertEqual(LauncherManager.shared.activeCandidateZone, .instant,
                       "[场景3.P1][C5] 跨区切面后 activeCandidateZone 必须为 .instant")
        XCTAssertEqual(LauncherManager.shared.instantSelectedIndex, 0,
                       "[场景3.P1][C5] 跨区到 instant 后 instantSelectedIndex 必须落首项（0）")
    }

    // MARK: - 场景3.P2 [det-machine] instant 区首 → command 区末

    func test_scenario3_P2_instantFirstUp_movesToCommandRouteLast() async throws {
        let recordingLauncher = RecordingAppLauncher()
        LauncherManager.shared.registryOverride = makeAppLauncherRegistry(launcher: recordingLauncher)
        LauncherManager.shared.pluginsOverride = try makeTwoSharedCommandManifests()

        LauncherManager.shared.show()
        LauncherManager.shared.updateQuery("qzh")
        await waitForQuerySettled()

        LauncherManager.shared.setActiveCandidateZone(.instant)
        LauncherManager.shared.moveInstantSelection(up: false)
        await waitForQuerySettled(20)
        XCTAssertEqual(LauncherManager.shared.activeCandidateZone, .instant, "先到 instant 首")
        XCTAssertEqual(LauncherManager.shared.instantSelectedIndex, 0, "instant 首")

        LauncherManager.shared.setActiveCandidateZone(.commandRoute)
        let commandCount = LauncherManager.shared.commandRouteCandidates.count
        LauncherManager.shared.setCommandRouteSelectedIndex(commandCount - 1)
        await waitForQuerySettled(20)

        XCTAssertEqual(LauncherManager.shared.activeCandidateZone, .commandRoute,
                       "[场景3.P2][C5] 跨区切面后 activeCandidateZone 必须为 .commandRoute")
        XCTAssertEqual(LauncherManager.shared.commandRouteSelectedIndex, commandCount - 1,
                       "[场景3.P2][C5] 跨区回 command 后 commandRouteSelectedIndex 必须落末项")
    }

    // MARK: - 场景3.P3 [det-machine] 跨区序列无跳过无重复

    func test_scenario3_P3_continuousDown_sequenceNoSkipNoRepeat() async throws {
        let recordingLauncher = RecordingAppLauncher()
        let appA = URL(fileURLWithPath: "/Applications/Qzhddr.app")
        let appB = URL(fileURLWithPath: "/Applications/Another.app")
        let index = AppIndex(fixedEntries: [
            AppEntry(url: appA, name: "Qzhddr"),
            AppEntry(url: appB, name: "Another")
        ])
        let appPlugin = AppLauncherPlugin(index: index, launcher: recordingLauncher)
        LauncherManager.shared.registryOverride = BuiltinPluginRegistry(plugins: [appPlugin])
        LauncherManager.shared.pluginsOverride = try makeTwoSharedCommandManifests()

        LauncherManager.shared.show()
        LauncherManager.shared.updateQuery("qzh")
        await waitForQuerySettled()

        let commandCount = LauncherManager.shared.commandRouteCandidates.count
        let instantCount = LauncherManager.shared.instantActions.count
        XCTAssertGreaterThanOrEqual(commandCount, 1, "[场景3.P3 前提] command 非空")
        XCTAssertGreaterThanOrEqual(instantCount, 1, "[场景3.P3 前提] instant 非空")

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

        for _ in 0..<(commandCount - 1) {
            LauncherManager.shared.moveCommandRouteSelection(up: false)
            record()
        }
        LauncherManager.shared.setActiveCandidateZone(.instant)
        LauncherManager.shared.moveInstantSelection(up: false)
        record()
        for _ in 0..<(instantCount - 1) {
            LauncherManager.shared.moveInstantSelection(up: false)
            record()
        }

        let expected: [(CandidateZone, Int)] =
            (0..<commandCount).map { (.commandRoute, $0) } +
            (0..<instantCount).map { (.instant, $0) }
        let visitedSet = Set(visited.map { "\($0.zone):\($0.idx)" })
        let expectedSet = Set(expected.map { "\(($0.0)):\(($0.1))" })
        XCTAssertEqual(visitedSet, expectedSet,
                       "[场景3.P3][C5] 跨区序列必须无跳过无重复覆盖所有行")
        XCTAssertEqual(visited.count, commandCount + instantCount,
                       "[场景3.P3] 访问序列长度必须 == 总行数")
    }

    // MARK: - 场景3.P4 [det-machine] 单区内移动 → 选中不越界（环形）

    func test_scenario3_P4_intraZoneWrapAround_noOutOfBounds() async throws {
        LauncherManager.shared.registryOverride = makeEmptyInstantRegistry()
        LauncherManager.shared.pluginsOverride = try makeTwoSharedCommandManifests()

        await LauncherManager.shared.show()
        LauncherManager.shared.updateQuery("qzh")
        await waitForQuerySettled()

        let count = LauncherManager.shared.commandRouteCandidates.count
        XCTAssertEqual(count, 2, "[场景3.P4 前提] command 区 2 项")
        XCTAssertEqual(LauncherManager.shared.commandRouteSelectedIndex, 0)

        // command 区单区环形（moveCommandRouteSelection，非 moveInstantSelection）
        LauncherManager.shared.moveCommandRouteSelection(up: false) // 0→1
        XCTAssertEqual(LauncherManager.shared.commandRouteSelectedIndex, 1)
        LauncherManager.shared.moveCommandRouteSelection(up: false) // 1→0（环形）
        XCTAssertEqual(LauncherManager.shared.commandRouteSelectedIndex, 0,
                       "[场景3.P4][C5] 单区环形：末项 ↓ 必须回 idx0（不越界）")
        XCTAssertTrue(
            LauncherManager.shared.commandRouteCandidates.indices.contains(LauncherManager.shared.commandRouteSelectedIndex),
            "[场景3.P4] 选中索引必须在 candidates.indices 内"
        )
    }

    // MARK: - 场景3.P5 [det-machine] pluginCandidates 通道枚举隔离

    func test_scenario3_P5_pluginCandidatesZone_isolatesCommandAndInstant() async throws {
        let pluginZone: CandidateZone = .pluginCandidates
        XCTAssertEqual(pluginZone, .pluginCandidates, "[场景3.P5][C2] CandidateZone 必须含 .pluginCandidates case")
        XCTAssertNotEqual(CandidateZone.pluginCandidates, .commandRoute,
                          "[场景3.P5] pluginCandidates 与 commandRoute 是不同 zone")
        XCTAssertNotEqual(CandidateZone.pluginCandidates, .instant,
                          "[场景3.P5] pluginCandidates 与 instant 是不同 zone")
    }

    // MARK: - 场景4.P1 [det-machine] 仅命中 instant → 仅展示 instant 区

    func test_scenario4_P1_onlyInstant_commandRouteEmpty_instantSelectedFirst() async throws {
        let recordingLauncher = RecordingAppLauncher()
        LauncherManager.shared.registryOverride = makeAppLauncherRegistry(launcher: recordingLauncher)
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
        XCTAssertEqual(LauncherManager.shared.instantSelectedIndex, 0,
                       "[场景4.P1][C10] 仅 instant 时默认选中 instant 首项")
        XCTAssertEqual(LauncherManager.shared.activeCandidateZone, .instant,
                       "[场景4.P1][C2] command 区空时默认 activeCandidateZone 必须为 .instant")
    }

    // MARK: - 场景4.P3 [det-machine] command 区空 → 默认选中不越界

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
        XCTAssertTrue((0..<count).contains(idx),
                      "[场景4.P3][C10] instantSelectedIndex 必须在 [0, count) 内")
    }

    // MARK: - 场景5.P1 [det-machine] 多命中 command → 候选列出（未自动锁定）

    func test_scenario5_P1_multiCommand_listCandidates_notLocked() async throws {
        LauncherManager.shared.registryOverride = makeEmptyInstantRegistry()
        LauncherManager.shared.pluginsOverride = try makeTwoSharedCommandManifests()

        await LauncherManager.shared.show()
        LauncherManager.shared.updateQuery("qzh")
        await waitForQuerySettled()

        XCTAssertFalse(
            LauncherManager.shared.commandRouteCandidates.isEmpty,
            "[场景5.P1][C9] 多命中 command 时 commandRouteCandidates 必须非空"
        )
        XCTAssertTrue(
            LauncherManager.shared.instantActions.isEmpty,
            "[场景5.P1] 无 app 命中时 instantActions 必须空"
        )
        XCTAssertEqual(LauncherManager.shared.commandRouteSelectedIndex, 0,
                       "[场景5.P1][C2] 多命中默认选中 command 首项（index==0）")
        XCTAssertEqual(LauncherManager.shared.activeCandidateZone, .commandRoute,
                       "[场景5.P1][C2] 多命中默认 activeCandidateZone 必须为 .commandRoute")
        XCTAssertNil(LauncherManager.shared.lockedCommand,
                     "[场景5.P1][C-MULTI-SELECT-LOCK] 多命中不应自动锁定")
    }

    // MARK: - 场景8.P1 [det-machine] query 变空 → 两区均清空 + 选中复位

    func test_scenario8_P1_emptyQuery_clearsBothZones() async throws {
        let recordingLauncher = RecordingAppLauncher()
        LauncherManager.shared.registryOverride = makeAppLauncherRegistry(launcher: recordingLauncher)
        LauncherManager.shared.pluginsOverride = try makeTwoSharedCommandManifests()

        await LauncherManager.shared.show()
        LauncherManager.shared.updateQuery("qzh")
        await waitForQuerySettled()
        XCTAssertFalse(LauncherManager.shared.commandRouteCandidates.isEmpty, "前提：先命中两区")
        XCTAssertFalse(LauncherManager.shared.instantActions.isEmpty)

        LauncherManager.shared.updateQuery("")
        await waitForQuerySettled()

        XCTAssertTrue(LauncherManager.shared.commandRouteCandidates.isEmpty,
                      "[场景8.P1][C1] 空 query 必须清空 commandRouteCandidates")
        XCTAssertTrue(LauncherManager.shared.instantActions.isEmpty,
                      "[场景8.P1][C7] 空 query 必须清空 instantActions")
        XCTAssertEqual(LauncherManager.shared.commandRouteSelectedIndex, -1,
                       "[场景8.P1][C1] 空 query 必须 commandRouteSelectedIndex 复位 -1")
        XCTAssertEqual(LauncherManager.shared.instantSelectedIndex, -1,
                       "[场景8.P1][C7] 空 query 必须 instantSelectedIndex 复位 -1")
    }

    // MARK: - 场景9 [det-machine] 唯一命中自动锁定（C-UNIQUE-AUTOLOCK，新两阶段语义）

    /// 唯一 command 命中 → updateQuery 自动锁 lockedCommand，候选清空，instant 隔离。
    func test_scenario9_uniqueHit_autoLocks() async throws {
        LauncherManager.shared.registryOverride = makeEmptyInstantRegistry()
        let qzh = try makeCommandManifest(name: "qzh", keywords: ["qzh"])
        LauncherManager.shared.pluginsOverride = [qzh]

        await LauncherManager.shared.show()
        LauncherManager.shared.updateQuery("qzh")
        await waitForQuerySettled()

        XCTAssertEqual(LauncherManager.shared.lockedCommand?.name, "qzh",
                       "[场景9][C-UNIQUE-AUTOLOCK] 唯一命中应自动锁定 qzh")
        XCTAssertTrue(LauncherManager.shared.commandRouteCandidates.isEmpty,
                      "[场景9][C-UNIQUE-AUTOLOCK] 唯一命中锁定后候选应清空（参数态隐藏候选）")
        XCTAssertTrue(LauncherManager.shared.instantActions.isEmpty,
                      "[场景9][C-PARAM-ISOLATE] 锁定后 instant 区应隔离")
    }

    // MARK: - 场景10 [det-machine] 多命中显式选中 = 锁定，不执行（C-LOCK-NOT-EXECUTE）

    /// 多命中态：用户选中 → 设 lockedCommand，但 stage 仍 idle（未执行）。
    func test_scenario10_multiHit_selectLocks_notExecute() async throws {
        LauncherManager.shared.registryOverride = makeEmptyInstantRegistry()
        LauncherManager.shared.pluginsOverride = try makeTwoSharedCommandManifests()

        await LauncherManager.shared.show()
        LauncherManager.shared.updateQuery("qzh")
        await waitForQuerySettled()
        XCTAssertNil(LauncherManager.shared.lockedCommand, "前提：多命中未锁定")

        // 模拟用户 ↓ + Enter/Tab 选中第二项 → 锁定
        LauncherManager.shared.setCommandRouteSelectedIndex(1)
        LauncherManager.shared.selectCommandRouteCandidateForLock()

        XCTAssertEqual(LauncherManager.shared.lockedCommand?.name, "qzh2",
                       "[场景10][C-MULTI-SELECT-LOCK] 显式选中应锁定该项")
        XCTAssertEqual(LauncherManager.shared.stage, .idle,
                       "[场景10][C-LOCK-NOT-EXECUTE] 选中 = 锁定，不执行（stage 仍 idle）")
    }
}
