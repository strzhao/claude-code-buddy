import XCTest
@testable import BuddyCore

// MARK: - LauncherGcliCandidateRenameAcceptanceTests
//
// 红队验收测试（TDD 红灯）：场景 1 候选发现层——显示名/热词改 gcli 后的统一混排候选
//
// 谓词映射（SSOT: state.md ## 验收场景）：
//   s1p1 [det-machine] 输入 gcli → 候选列表含 ≥1 个显示名含 gcli 的条目
//        ｜ observe: 候选项 stringValue（in-process instantActions 管线，等价 AX 候选流）
//        ｜ artifact: /tmp/autopilot-artifacts/s1p1.out
//   s1p4 [det-machine]（负例）输入旧名 quota → 候选不出现 gcli 条目（防词表残留）
//        ｜ artifact: /tmp/autopilot-artifacts/s1p4.out
//
// 驱动方式：apps/desktop/CLAUDE.md「GUI 自动化测试」能力 1（XCTest in-process）——
// LauncherManager.shared.updateQuery → 统一混排 instantActions 管线（真实打分器），
// 与 AX 候选项同源（LauncherInstantCandidateView 渲染该数组）。禁 osascript keystroke。
//
// 契约逐字（W1）：plugin.json name "quota"→"gcli"；keywords ["gcli","限额","套餐","用量"]
// （quota/limit 移除）。候选行 D1：id="plugin:<name>"、title=name。
//
// 红队红线：manifest 为 W1 目标态 fixture（插件名/词表契约的管道级验证）；
// 真实 plugin.json 词表残留由 bash 验收 s1p2 硬断言兜底，两层合取覆盖 s1 场景。
// 本类只用既有符号，蓝队未动管道时即可编译运行（管线回归守护）。

@MainActor
final class LauncherGcliCandidateRenameAcceptanceTests: XCTestCase {

    // MARK: - 生命周期（PluginEnterDispatchAcceptanceTests 同构隔离）

    override func setUp() async throws {
        try await super.setUp()
        LauncherManager.shared.resetSubmittingStateForTesting()
        LauncherManager.shared.instantDebounceMsOverride = 0
        LauncherManager.shared.registryOverride = makeEmptyRegistry()
        LauncherManager.shared.pluginsOverride = nil
        LauncherManager.shared.stdinExecutorOverride = nil
        LauncherManager.shared.clearInstantActions()
        LauncherManager.shared.updateQuery("")
        if LauncherManager.shared.isVisible {
            LauncherManager.shared.hide()
        }
    }

    override func tearDown() async throws {
        LauncherManager.shared.pluginsOverride = nil
        LauncherManager.shared.registryOverride = nil
        LauncherManager.shared.stdinExecutorOverride = nil
        LauncherManager.shared.clearInstantActions()
        LauncherManager.shared.updateQuery("")
        try await super.tearDown()
    }

    // MARK: - fixture

    /// W1 目标态 manifest：name "gcli" + keywords ["gcli","限额","套餐","用量"]（逐字）
    private func makeGcliManifest() -> PluginManifest {
        let json: [String: Any] = [
            "name": "gcli",
            "version": "0.2.0-test",
            "description": "gcli 套餐限额查询（红队 fixture）",
            "keywords": ["gcli", "限额", "套餐", "用量"],
            "mode": "command",
            "cmd": "echo",
            "args": [] as [String]
        ]
        return try! JSONDecoder().decode(PluginManifest.self,
                                         from: try JSONSerialization.data(withJSONObject: json))
    }

    private func makeEmptyRegistry() -> BuiltinPluginRegistry {
        BuiltinPluginRegistry(plugins: [EmptyActionsPluginForGcliTest()])
    }

    private func updateQueryAndSettle(_ query: String) async {
        LauncherManager.shared.updateQuery(query)
        var lastCount = -1
        var stablePolls = 0
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline && stablePolls < 4 {
            let count = LauncherManager.shared.instantActions.count
            if count == lastCount { stablePolls += 1 } else { stablePolls = 0; lastCount = count }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func writeArtifact(_ name: String, _ lines: [String]) {
        let dir = "/tmp/autopilot-artifacts"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let content = ([name] + lines).joined(separator: "\n") + "\n"
        try? content.write(toFile: dir + "/" + name, atomically: true, encoding: .utf8)
    }

    // MARK: - s1p1：输入 gcli → ≥1 个显示名含 gcli 的候选

    func test_s1p1_queryGcli_candidateWithGcliDisplayName() async throws {
        LauncherManager.shared.pluginsOverride = [makeGcliManifest()]

        await updateQueryAndSettle("gcli")
        let rows = LauncherManager.shared.instantActions
        let evidence = rows.map { "row: id=\($0.id) title=\($0.title) pluginId=\($0.pluginId) score=\($0.score)" }

        writeArtifact("s1p1.out", ["query=gcli", "count=\(rows.count)"] + evidence + ["expect: ≥1 行显示名含 gcli"])

        let gcliRow = rows.first { $0.title.contains("gcli") || $0.pluginId.contains("gcli") }
        XCTAssertNotNil(gcliRow,
            "s1p1: 输入 gcli 必须产出 ≥1 个显示名含 gcli 的候选，实际候选=[\(evidence.joined(separator: "; "))]")
    }

    // MARK: - s1p4（负例）：输入旧名 quota → 不出现 gcli 条目

    func test_s1p4_queryQuota_noGcliCandidate() async throws {
        LauncherManager.shared.pluginsOverride = [makeGcliManifest()]

        await updateQueryAndSettle("quota")
        let rows = LauncherManager.shared.instantActions
        let evidence = rows.map { "row: id=\($0.id) title=\($0.title) pluginId=\($0.pluginId) score=\($0.score)" }

        writeArtifact("s1p4.out", ["query=quota", "count=\(rows.count)"] + evidence + ["expect: 无任何含 gcli 的条目"])

        let leaked = rows.filter { $0.title.contains("gcli") || $0.pluginId.contains("gcli") }
        XCTAssertTrue(leaked.isEmpty,
            "s1p4: 旧名 quota 查询不得出现 gcli 条目（quota/limit 已移出词表），实际泄漏=[\(leaked.map(\.title))]")
    }
}

// MARK: - Mock 空 registry 插件（隔离 app/builtin 行干扰）

private struct EmptyActionsPluginForGcliTest: BuiltinPlugin {
    let id = "empty-gcli-test"
    let priority = 0
    let sectionTitle = "Empty"
    func actions(for query: String) async -> [LauncherAction] { [] }
}
