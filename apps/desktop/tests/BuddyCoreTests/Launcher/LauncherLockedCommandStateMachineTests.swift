import XCTest
@testable import BuddyCore

// MARK: - LauncherLockedCommandStateMachineTests
//
// T2 单测：lockedCommand 状态机（统一混排语义，C-TAB-LOCK / C-LOCK-STICKY /
// C-ESC-EXIT / C-PARAM-ISOLATE）。
//
// 语义变更（vs 方案 B 分区）：锁定仅来自 Tab/点击显式操作（lockPluginCandidate）；
// 「唯一命中自动锁定」「多命中列 commandRoute 候选」已退役（C-TAB-LOCK：不存在）。
//
// mock 构造用 JSON 解码（mode:"command"），禁用 PluginManifest(name:...) 便利 init。

private func makeCmdManifest(
    name: String,
    keywords: [String],
    cmd: String = "echo"
) -> PluginManifest {
    let json: [String: Any] = [
        "name": name,
        "version": "0.0.1-test",
        "description": "test command plugin \(name)",
        "keywords": keywords,
        "mode": "command",
        "cmd": cmd,
        "args": [] as [String]
    ]
    return try! JSONDecoder().decode(PluginManifest.self, from: try JSONSerialization.data(withJSONObject: json))
}

private func makeStdinManifestForLock(
    name: String,
    keywords: [String]
) -> PluginManifest {
    let json: [String: Any] = [
        "name": name,
        "version": "0.0.1-test",
        "description": "test stdin plugin \(name)",
        "keywords": keywords,
        "mode": "stdin",
        "cmd": "echo",
        "args": [] as [String]
    ]
    return try! JSONDecoder().decode(PluginManifest.self, from: try JSONSerialization.data(withJSONObject: json))
}

@MainActor
final class LauncherLockedCommandStateMachineTests: XCTestCase {

    private var qr: PluginManifest!
    private var stdinHello: PluginManifest!

    override func setUp() async throws {
        try await super.setUp()
        qr = makeCmdManifest(name: "qr", keywords: ["qr", "qrcode", "二维码", "码"])
        stdinHello = makeStdinManifestForLock(name: "hello", keywords: ["hello", "示例"])
        await MainActor.run {
            LauncherManager.shared.resetSubmittingStateForTesting()
            LauncherManager.shared.lockedCommand = nil
            LauncherManager.shared.clearInstantActions()
            LauncherManager.shared.instantDebounceMsOverride = 0
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            LauncherManager.shared.pluginsOverride = nil
            LauncherManager.shared.lockedCommand = nil
            LauncherManager.shared.instantDebounceMsOverride = nil
        }
        try await super.tearDown()
    }

    // MARK: - C-TAB-LOCK（预期反转）：命中不再自动锁定

    func test_唯一命中_不自动锁定_候选列出() {
        LauncherManager.shared.pluginsOverride = [qr]
        LauncherManager.shared.updateQuery("qr https://example.com")
        XCTAssertNil(LauncherManager.shared.lockedCommand,
                     "C-TAB-LOCK：唯一命中不得自动锁定（自动锁定已退役）")
    }

    func test_tab锁定_后不立即执行() {
        LauncherManager.shared.pluginsOverride = [qr]
        LauncherManager.shared.updateQuery("qr https://x")
        LauncherManager.shared.lockPluginCandidate(qr)
        XCTAssertEqual(LauncherManager.shared.lockedCommand?.name, "qr")
        // stage 仍 idle（未提交执行）
        XCTAssertEqual(LauncherManager.shared.stage, .idle,
                       "锁定后 stage 应仍为 .idle（未执行）")
    }

    // MARK: - C-TAB-LOCK：多命中同样不自动锁定，候选列出（统一列表）

    func test_多命中_不自动锁定_统一列表列出() {
        let qrWithQ = makeCmdManifest(name: "qr", keywords: ["q", "qr"])
        let qzhWithQ = makeCmdManifest(name: "qzh", keywords: ["q"])
        LauncherManager.shared.pluginsOverride = [qrWithQ, qzhWithQ]
        LauncherManager.shared.updateQuery("q xxx")
        XCTAssertNil(LauncherManager.shared.lockedCommand, "多命中不应自动锁定")
    }

    // MARK: - C-LOCK-STICKY：锁定后 query 仍以 keyword 开头 → 保持锁定

    func test_锁定粘性_继续输入参数保持锁定() {
        LauncherManager.shared.pluginsOverride = [qr]
        LauncherManager.shared.updateQuery("qr")
        LauncherManager.shared.lockPluginCandidate(qr)
        XCTAssertEqual(LauncherManager.shared.lockedCommand?.name, "qr")
        // 继续输入参数
        LauncherManager.shared.updateQuery("qr https://example.com")
        XCTAssertEqual(LauncherManager.shared.lockedCommand?.name, "qr",
                       "粘性：query 仍以 keyword 开头应保持锁定")
        XCTAssertTrue(LauncherManager.shared.instantActions.isEmpty,
                      "参数态候选应隐藏")
    }

    func test_锁定粘性_参数态不被其他候选覆盖() {
        let qrA = makeCmdManifest(name: "qrA", keywords: ["qr"])
        let qrB = makeCmdManifest(name: "qrB", keywords: ["qrA"])
        LauncherManager.shared.pluginsOverride = [qrA, qrB]
        LauncherManager.shared.updateQuery("qr x")
        LauncherManager.shared.lockPluginCandidate(qrA)
        XCTAssertEqual(LauncherManager.shared.lockedCommand?.name, "qrA")
        // 继续输入仍以 qr 开头
        LauncherManager.shared.updateQuery("qr more text")
        XCTAssertEqual(LauncherManager.shared.lockedCommand?.name, "qrA",
                       "粘性：保持原锁定，不被覆盖")
    }

    func test_锁定失效_query不再以keyword开头_解锁() {
        LauncherManager.shared.pluginsOverride = [qr]
        LauncherManager.shared.updateQuery("qr")
        LauncherManager.shared.lockPluginCandidate(qr)
        XCTAssertEqual(LauncherManager.shared.lockedCommand?.name, "qr")
        // 改成不以 qr 开头的 query
        LauncherManager.shared.updateQuery("translate 你好")
        XCTAssertNil(LauncherManager.shared.lockedCommand,
                     "query 不再以 locked keyword 开头应解锁")
    }

    // MARK: - C-ESC-EXIT（清空输入框 = 退出锁定）

    func test_清空输入框_退出锁定() {
        LauncherManager.shared.pluginsOverride = [qr]
        LauncherManager.shared.updateQuery("qr")
        LauncherManager.shared.lockPluginCandidate(qr)
        XCTAssertEqual(LauncherManager.shared.lockedCommand?.name, "qr")
        LauncherManager.shared.updateQuery("")
        XCTAssertNil(LauncherManager.shared.lockedCommand, "清空输入框应清 lockedCommand")
    }

    // MARK: - stdin 插件行也可 Tab 锁定（D5：不分 mode，stdin/prompt Enter 走 submitWithPlugin）

    func test_stdin插件_tab可锁定() {
        LauncherManager.shared.pluginsOverride = [stdinHello]
        LauncherManager.shared.updateQuery("hello world")
        // typing 期不锁定（C-TAB-LOCK）
        XCTAssertNil(LauncherManager.shared.lockedCommand)
        // Tab 锁定 stdin 插件（D5）
        LauncherManager.shared.lockPluginCandidate(stdinHello)
        XCTAssertEqual(LauncherManager.shared.lockedCommand?.name, "hello",
                       "D5: stdin 插件行 Tab 锁定生效")
    }

    // MARK: - 锁定（C-LOCK-NOT-EXECUTE 配套）

    func test_显式锁定_不执行() {
        LauncherManager.shared.pluginsOverride = [qr]
        LauncherManager.shared.updateQuery("qr")
        LauncherManager.shared.lockPluginCandidate(qr)
        XCTAssertEqual(LauncherManager.shared.lockedCommand?.name, "qr",
                       "显式锁定应设 lockedCommand")
        XCTAssertEqual(LauncherManager.shared.stage, .idle,
                       "锁定 = 锁定，不执行")
    }

    // MARK: - .done 清 lockedCommand（执行完成回到初始候选态）

    func test_done_清lockedCommand() {
        LauncherManager.shared.pluginsOverride = [qr]
        LauncherManager.shared.updateQuery("qr")
        LauncherManager.shared.lockPluginCandidate(qr)
        XCTAssertEqual(LauncherManager.shared.lockedCommand?.name, "qr")
        LauncherManager.shared.resetLockedCommandAfterDone()
        XCTAssertNil(LauncherManager.shared.lockedCommand,
                     ".done 后应清 lockedCommand 回到初始候选态")
    }

    // MARK: - C-PARAM-ISOLATE：锁定时 instant 区隔离

    func test_参数态_instant区隔离() async {
        LauncherManager.shared.pluginsOverride = [qr]
        LauncherManager.shared.registryOverride = nil
        LauncherManager.shared.updateQuery("qr")
        LauncherManager.shared.lockPluginCandidate(qr)
        XCTAssertEqual(LauncherManager.shared.lockedCommand?.name, "qr")
        // 等 debounce（0ms）落地
        try? await Task.sleep(nanoseconds: 50_000_000)
        await MainActor.run {
            XCTAssertTrue(LauncherManager.shared.instantActions.isEmpty,
                          "参数态（lockedCommand 非空）应隐藏 instant 候选")
        }
    }

    // MARK: - 回归 CI 2867（stage 跨测试污染）

    func test_回归CI2867_resetSubmittingStateForTesting_清submit残留stage() {
        LauncherManager.shared.configOverride = .empty
        defer {
            LauncherManager.shared.configOverride = nil
            LauncherManager.shared.resetSubmittingStateForTesting()
        }

        // 1. 干净起点
        LauncherManager.shared.resetSubmittingStateForTesting()
        XCTAssertEqual(LauncherManager.shared.stage, .idle, "前置：reset 后 stage 应 .idle")

        // 2. submit 同步污染 stage
        _ = LauncherManager.shared.submit("pollution trigger")
        let polluted = LauncherManager.shared.stage
        XCTAssertNotEqual(polluted, .idle,
                          "submit 必须残留 stage 非 idle（本地 .narrowing / CI .error）。实际: \(polluted)")

        // 3. reset 必须清回 idle
        LauncherManager.shared.resetSubmittingStateForTesting()
        XCTAssertEqual(LauncherManager.shared.stage, .idle,
                       "resetSubmittingStateForTesting 必须清 stage=.idle（setUp 应调用）")
    }
}
