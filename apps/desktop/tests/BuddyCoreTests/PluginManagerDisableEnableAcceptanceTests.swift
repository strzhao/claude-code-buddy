import XCTest
@testable import BuddyCore

/// 红队验收测试 (task 004): PluginManager.disable / enable / disabledNames
///
/// 覆盖 12 个 AT（与 state.md `## 验证方案` 一致）：
/// AT01-AT09 直接 API 行为；AT10 LauncherRouter.narrowCandidates 集成；
/// AT11-AT12 manifest-invalid 目录与 disable 解耦的不变量验证。
final class PluginManagerDisableEnableAcceptanceTests: XCTestCase {

    private var rootDir: URL!

    override func setUp() {
        super.setUp()
        rootDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("buddy-pm-acc-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: rootDir)
        super.tearDown()
    }

    // MARK: - AT01

    /// disable 不存在的 plugin → throw pluginNotFound
    func test_AT01_disable_nonexistentPlugin_throwsPluginNotFound() throws {
        let mgr = PluginManager(rootDir: rootDir)
        XCTAssertThrowsError(try mgr.disable(name: "ghost")) { error in
            guard case LauncherError.pluginNotFound(let name) = error else {
                return XCTFail("expected LauncherError.pluginNotFound, got \(error)")
            }
            XCTAssertEqual(name, "ghost")
        }
    }

    // MARK: - AT02

    /// disable 有效 plugin → `.disabled` 文件创建（fileExists 为 true）
    func test_AT02_disable_validPlugin_createsDisabledMarker() throws {
        try makePromptPlugin(name: "translate")
        let mgr = PluginManager(rootDir: rootDir)

        try mgr.disable(name: "translate")

        let marker = rootDir
            .appendingPathComponent("translate")
            .appendingPathComponent(".disabled")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: marker.path),
            "expected .disabled marker at \(marker.path)"
        )
    }

    // MARK: - AT03

    /// disable 幂等：连续调 2 次不报错 + 文件仍存在
    func test_AT03_disable_idempotent_doesNotThrowAndMarkerPersists() throws {
        try makePromptPlugin(name: "translate")
        let mgr = PluginManager(rootDir: rootDir)

        XCTAssertNoThrow(try mgr.disable(name: "translate"))
        XCTAssertNoThrow(try mgr.disable(name: "translate"))

        let marker = rootDir
            .appendingPathComponent("translate")
            .appendingPathComponent(".disabled")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: marker.path),
            "second disable 不应删除 .disabled"
        )
    }

    // MARK: - AT04

    /// enable 不存在的 plugin → throw pluginNotFound
    func test_AT04_enable_nonexistentPlugin_throwsPluginNotFound() throws {
        let mgr = PluginManager(rootDir: rootDir)
        XCTAssertThrowsError(try mgr.enable(name: "ghost")) { error in
            guard case LauncherError.pluginNotFound(let name) = error else {
                return XCTFail("expected LauncherError.pluginNotFound, got \(error)")
            }
            XCTAssertEqual(name, "ghost")
        }
    }

    // MARK: - AT05

    /// enable 已禁用 → `.disabled` 删除
    func test_AT05_enable_disabledPlugin_removesMarker() throws {
        try makePromptPlugin(name: "translate")
        let mgr = PluginManager(rootDir: rootDir)
        try mgr.disable(name: "translate")

        try mgr.enable(name: "translate")

        let marker = rootDir
            .appendingPathComponent("translate")
            .appendingPathComponent(".disabled")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: marker.path),
            "enable 后 .disabled 应被删除"
        )
    }

    // MARK: - AT06

    /// enable 未禁用 → no-op 不报错
    func test_AT06_enable_alreadyEnabledPlugin_isNoOp() throws {
        try makePromptPlugin(name: "translate")
        let mgr = PluginManager(rootDir: rootDir)

        XCTAssertNoThrow(try mgr.enable(name: "translate"))

        // 仍然能正常 list
        let list = try mgr.list()
        XCTAssertTrue(list.contains { $0.name == "translate" })
    }

    // MARK: - AT07

    /// disabledNames 准确：disable a + b → 返回 Set(["a","b"])
    func test_AT07_disabledNames_returnsAllDisabledAsSet() throws {
        try makePromptPlugin(name: "alpha")
        try makePromptPlugin(name: "beta")
        try makePromptPlugin(name: "gamma")  // 不禁，做反面对照
        let mgr = PluginManager(rootDir: rootDir)

        try mgr.disable(name: "alpha")
        try mgr.disable(name: "beta")

        let disabled = try mgr.disabledNames()
        XCTAssertEqual(Set(disabled), Set(["alpha", "beta"]))
        XCTAssertFalse(disabled.contains("gamma"))
    }

    // MARK: - AT08

    /// disable 后 list() 不返回该 plugin
    func test_AT08_disable_excludesPluginFromList() throws {
        try makePromptPlugin(name: "translate")
        try makePromptPlugin(name: "other")
        let mgr = PluginManager(rootDir: rootDir)

        try mgr.disable(name: "translate")

        let list = try mgr.list()
        let names = list.map { $0.name }
        XCTAssertFalse(names.contains("translate"), "list 不应包含已禁用的 translate")
        XCTAssertTrue(names.contains("other"), "list 应保留未禁用插件")
    }

    // MARK: - AT09

    /// enable 后 list() 重新返回该 plugin
    func test_AT09_enable_restoresPluginInList() throws {
        try makePromptPlugin(name: "translate")
        let mgr = PluginManager(rootDir: rootDir)

        try mgr.disable(name: "translate")
        let listAfterDisable = try mgr.list().map { $0.name }
        XCTAssertFalse(listAfterDisable.contains("translate"))

        try mgr.enable(name: "translate")
        let listAfterEnable = try mgr.list().map { $0.name }
        XCTAssertTrue(
            listAfterEnable.contains("translate"),
            "enable 后 translate 应重新出现在 list()"
        )
    }

    // MARK: - AT10

    /// LauncherRouter.narrowCandidates 集成：
    /// 禁用 translate 后输入 "翻译 hello" → 候选不含 translate
    ///
    /// narrowCandidates 取 plugins 参数；本测验证 list() 过滤 → narrowCandidates 行为的端到端契约。
    /// 因 LauncherRouter 构造需 provider，但 narrowCandidates 不调用 provider，故构造一个最小桩 provider。
    func test_AT10_routerNarrowCandidates_excludesDisabledPlugin() throws {
        // translate plugin 带中文关键词 "翻译"，确保 narrowCandidates 在未禁用时命中
        try makePromptPlugin(
            name: "translate",
            description: "translate text",
            keywords: ["翻译", "translate"]
        )
        let mgr = PluginManager(rootDir: rootDir)
        let router = LauncherRouter(
            pluginManager: mgr,
            provider: StubProvider(),
            routerModel: "stub-model"
        )

        // 0. 未禁用时 narrowCandidates 应能命中
        let listBefore = try mgr.list()
        let candidatesBefore = router.narrowCandidates(query: "翻译 hello", plugins: listBefore)
        XCTAssertTrue(
            candidatesBefore.contains(where: { $0.name == "translate" }),
            "前置：未禁用时 translate 必须出现在候选里（否则 AT10 无意义）"
        )

        // 1. 禁用后 list 不再返回 translate，narrowCandidates 也命不中
        try mgr.disable(name: "translate")
        let listAfter = try mgr.list()
        let candidatesAfter = router.narrowCandidates(query: "翻译 hello", plugins: listAfter)
        XCTAssertFalse(
            candidatesAfter.contains(where: { $0.name == "translate" }),
            "禁用后 translate 不应出现在 narrowCandidates 结果中"
        )
    }

    // MARK: - AT11

    /// disable plugin.json 无效的目录：建假目录 + 无 plugin.json → disable 成功（路由控制与 manifest 解耦）
    func test_AT11_disable_dirWithoutManifest_succeeds() throws {
        let pluginDir = rootDir.appendingPathComponent("broken-no-manifest")
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        // 故意不写 plugin.json
        let mgr = PluginManager(rootDir: rootDir)

        XCTAssertNoThrow(
            try mgr.disable(name: "broken-no-manifest"),
            "disable 与 manifest 有效性正交，应允许"
        )

        let marker = pluginDir.appendingPathComponent(".disabled")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: marker.path),
            "broken 目录也应能创建 .disabled 标记"
        )
    }

    // MARK: - AT12

    /// disabledNames 包含 plugin.json 无效但有 `.disabled` 的目录
    func test_AT12_disabledNames_includesManifestInvalidDirs() throws {
        // 1) 无 plugin.json 的目录被禁用
        let brokenDir = rootDir.appendingPathComponent("broken-dir")
        try FileManager.default.createDirectory(at: brokenDir, withIntermediateDirectories: true)
        try Data().write(to: brokenDir.appendingPathComponent(".disabled"))

        // 2) plugin.json 内容损坏的目录被禁用
        let badJSONDir = rootDir.appendingPathComponent("bad-json")
        try FileManager.default.createDirectory(at: badJSONDir, withIntermediateDirectories: true)
        try "not valid json".write(
            to: badJSONDir.appendingPathComponent("plugin.json"),
            atomically: true, encoding: .utf8
        )
        try Data().write(to: badJSONDir.appendingPathComponent(".disabled"))

        // 3) 一个合法但已禁用的目录作正面对照
        try makePromptPlugin(name: "translate")
        let mgr = PluginManager(rootDir: rootDir)
        try mgr.disable(name: "translate")

        let disabled = try mgr.disabledNames()
        XCTAssertEqual(
            Set(disabled),
            Set(["broken-dir", "bad-json", "translate"]),
            "disabledNames 应包含 manifest 无效但有 .disabled 的目录"
        )
    }

    // MARK: - Helpers

    /// 构造一个最小有效的 prompt-mode plugin 目录（含合法 plugin.json）。
    private func makePromptPlugin(
        name: String,
        description: String = "test plugin",
        keywords: [String] = []
    ) throws {
        let pluginDir = rootDir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)

        let kwJSON = keywords.map { "\"\($0)\"" }.joined(separator: ", ")
        let json = """
        {
          "name": "\(name)",
          "version": "0.1.0",
          "description": "\(description)",
          "keywords": [\(kwJSON)],
          "mode": "prompt",
          "systemPrompt": "you are a helpful assistant",
          "maxIterations": 1,
          "autoCopyToClipboard": false
        }
        """
        try json.write(
            to: pluginDir.appendingPathComponent("plugin.json"),
            atomically: true,
            encoding: .utf8
        )
    }
}

// MARK: - StubProvider（仅 AT10 用，narrowCandidates 不调用 provider，故 send 返回任意值即可）

private final class StubProvider: LauncherProvider {
    func send(
        messages: [AgentMessage],
        tools: [AgentTool],
        model: String,
        system: String?
    ) async throws -> AgentResponse {
        // 不应被调用；narrowCandidates 是纯同步本地逻辑
        return AgentResponse(
            content: [.text("NONE")],
            stopReason: "end_turn",
            usage: nil
        )
    }
}
