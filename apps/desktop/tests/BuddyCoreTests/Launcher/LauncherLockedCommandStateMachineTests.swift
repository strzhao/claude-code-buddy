import XCTest
@testable import BuddyCore

// MARK: - LauncherLockedCommandStateMachineTests
//
// T2 单测：lockedCommand 状态机（C-UNIQUE-AUTOLOCK / C-MULTI-SELECT-LOCK /
// C-LOCK-STICKY / C-ESC-EXIT / C-PARAM-ISOLATE）。
//
// updateQuery 是同步主干（instant 候选走 debounce Task，但 command 命中 + lockedCommand
// 是同步分支，可同步断言）。
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
    private var qr2: PluginManifest!  // 共享 keyword「q」用于多命中场景
    private var stdinHello: PluginManifest!

    override func setUp() async throws {
        try await super.setUp()
        qr = makeCmdManifest(name: "qr", keywords: ["qr", "qrcode", "二维码", "码"])
        qr2 = makeCmdManifest(name: "qzh", keywords: ["q"])
        stdinHello = makeStdinManifestForLock(name: "hello", keywords: ["hello", "示例"])
        // 清理 shared 单例状态（测试隔离）
        await MainActor.run {
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

    // MARK: - C-UNIQUE-AUTOLOCK：唯一命中 → updateQuery 自动锁

    func test_唯一命中_自动锁定() {
        LauncherManager.shared.pluginsOverride = [qr]
        LauncherManager.shared.updateQuery("qr https://example.com")
        XCTAssertEqual(LauncherManager.shared.lockedCommand?.name, "qr",
                       "唯一 command 命中应自动锁定")
        XCTAssertTrue(LauncherManager.shared.commandRouteCandidates.isEmpty,
                      "唯一命中锁定后候选应清空（参数态隐藏候选）")
    }

    func test_唯一命中_锁定后不立即执行() {
        // 锁定 ≠ 执行：仅设 lockedCommand，不应触发 submitCommandDirect
        LauncherManager.shared.pluginsOverride = [qr]
        LauncherManager.shared.updateQuery("qr https://x")
        XCTAssertEqual(LauncherManager.shared.lockedCommand?.name, "qr")
        // stage 仍 idle（未提交执行）
        XCTAssertEqual(LauncherManager.shared.stage, .idle,
                       "锁定后 stage 应仍为 .idle（未执行）")
    }

    // MARK: - C-MULTI-SELECT-LOCK：多命中 → 不锁，列候选

    func test_多命中_不自动锁定_列候选() {
        LauncherManager.shared.pluginsOverride = [qr, qr2]
        // 用共享 keyword「q」让两者都命中（qr keyword 含 qr，但 query「q x」qr 的 qr 前缀不匹配；
        // 改用 query 让两者命中：qr2 的 keyword 是「q」，qr 需要 keyword 含「q」——qr 没有「q」短 keyword。
        // 修正：让两个 plugin 都含 keyword「q」
        let qrWithQ = makeCmdManifest(name: "qr", keywords: ["q", "qr"])
        let qzhWithQ = makeCmdManifest(name: "qzh", keywords: ["q"])
        LauncherManager.shared.pluginsOverride = [qrWithQ, qzhWithQ]
        LauncherManager.shared.updateQuery("q xxx")
        XCTAssertNil(LauncherManager.shared.lockedCommand, "多命中不应自动锁定")
        XCTAssertEqual(LauncherManager.shared.commandRouteCandidates.count, 2, "多命中应列候选")
        XCTAssertEqual(LauncherManager.shared.commandRouteSelectedIndex, 0, "多命中默认选中首项")
    }

    // MARK: - C-LOCK-STICKY：锁定后 query 仍以 keyword 开头 → 保持锁定

    func test_锁定粘性_继续输入参数保持锁定() {
        LauncherManager.shared.pluginsOverride = [qr]
        LauncherManager.shared.updateQuery("qr")
        XCTAssertEqual(LauncherManager.shared.lockedCommand?.name, "qr")
        // 继续输入参数
        LauncherManager.shared.updateQuery("qr https://example.com")
        XCTAssertEqual(LauncherManager.shared.lockedCommand?.name, "qr",
                       "粘性：query 仍以 keyword 开头应保持锁定")
        XCTAssertTrue(LauncherManager.shared.commandRouteCandidates.isEmpty,
                      "参数态候选应隐藏")
    }

    func test_锁定粘性_参数态不被其他候选覆盖() {
        // 即便有其他 command 插件以当前 query 的某 keyword 命中，锁定也不被覆盖
        let qrA = makeCmdManifest(name: "qrA", keywords: ["qr"])
        let qrB = makeCmdManifest(name: "qrB", keywords: ["qrA"])  // 不会与 query「qr x」命中
        LauncherManager.shared.pluginsOverride = [qrA, qrB]
        LauncherManager.shared.updateQuery("qr x")
        XCTAssertEqual(LauncherManager.shared.lockedCommand?.name, "qrA")
        // 继续输入仍以 qr 开头
        LauncherManager.shared.updateQuery("qr more text")
        XCTAssertEqual(LauncherManager.shared.lockedCommand?.name, "qrA",
                       "粘性：保持原锁定，不被覆盖")
    }

    func test_锁定失效_query不再以keyword开头_解锁() {
        LauncherManager.shared.pluginsOverride = [qr]
        LauncherManager.shared.updateQuery("qr")
        XCTAssertEqual(LauncherManager.shared.lockedCommand?.name, "qr")
        // 改成不以 qr 开头的 query（但可能命中别的；这里改成一个无命中的）
        LauncherManager.shared.updateQuery("translate 你好")
        XCTAssertNil(LauncherManager.shared.lockedCommand,
                     "query 不再以 locked keyword 开头应解锁")
    }

    // MARK: - C-ESC-EXIT（清空输入框 = 退出锁定）

    func test_清空输入框_退出锁定() {
        LauncherManager.shared.pluginsOverride = [qr]
        LauncherManager.shared.updateQuery("qr")
        XCTAssertEqual(LauncherManager.shared.lockedCommand?.name, "qr")
        LauncherManager.shared.updateQuery("")
        XCTAssertNil(LauncherManager.shared.lockedCommand, "清空输入框应清 lockedCommand")
    }

    // MARK: - C-SCOPE-COMMAND-ONLY：stdin/prompt 不走 command 锁

    func test_stdin插件输入_不锁定command() {
        LauncherManager.shared.pluginsOverride = [stdinHello]
        LauncherManager.shared.updateQuery("hello world")
        XCTAssertNil(LauncherManager.shared.lockedCommand,
                     "stdin mode 插件命中不应触发 command 锁")
    }

    // MARK: - 选中锁定（C-LOCK-NOT-EXECUTE 配套，模拟用户选中）

    func test_多命中_显式选中_锁定不执行() {
        let qrWithQ = makeCmdManifest(name: "qr", keywords: ["q"])
        let qzhWithQ = makeCmdManifest(name: "qzh", keywords: ["q"])
        LauncherManager.shared.pluginsOverride = [qrWithQ, qzhWithQ]
        LauncherManager.shared.updateQuery("q xxx")
        XCTAssertNil(LauncherManager.shared.lockedCommand)
        // 模拟用户 ↓ 选中第二项 + Enter/Tab 选中锁定（LauncherManager 提供 selectCommandRouteForLock）
        LauncherManager.shared.setCommandRouteSelectedIndex(1)
        LauncherManager.shared.selectCommandRouteCandidateForLock()
        XCTAssertEqual(LauncherManager.shared.lockedCommand?.name, "qzh",
                       "显式选中应锁定该项")
        XCTAssertEqual(LauncherManager.shared.stage, .idle,
                       "选中 = 锁定，不执行")
    }

    // MARK: - .done 清 lockedCommand（执行完成回到初始候选态）

    func test_done_清lockedCommand() {
        LauncherManager.shared.pluginsOverride = [qr]
        LauncherManager.shared.updateQuery("qr")
        XCTAssertEqual(LauncherManager.shared.lockedCommand?.name, "qr")
        // 模拟执行完成（consume 流的 .done 分支会调 resetAfterDone，这里直接测公开行为：
        // consume 在 LauncherInputView，单测通过 resetLockedCommandAfterDone 验证）
        LauncherManager.shared.resetLockedCommandAfterDone()
        XCTAssertNil(LauncherManager.shared.lockedCommand,
                     ".done 后应清 lockedCommand 回到初始候选态")
    }

    // MARK: - C-PARAM-ISOLATE：锁定时 instant 区隔离（instant 走 debounce Task，置 0 ms）

    func test_参数态_instant区隔离() async {
        LauncherManager.shared.pluginsOverride = [qr]
        LauncherManager.shared.registryOverride = nil
        LauncherManager.shared.updateQuery("qr")
        XCTAssertEqual(LauncherManager.shared.lockedCommand?.name, "qr")
        // 等 debounce（0ms）落地
        try? await Task.sleep(nanoseconds: 50_000_000)
        await MainActor.run {
            XCTAssertTrue(LauncherManager.shared.instantActions.isEmpty,
                          "参数态（lockedCommand 非空）应隐藏 instant 候选")
        }
    }
}
