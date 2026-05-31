import XCTest
import AppKit
@testable import BuddyCore

/// 蓝队单元测试：聚焦 MarketHUD 类自身行为 + 协议契约 + dismissDelay 注入。
///
/// 与红队 MarketHUDAcceptanceTests 互补：红队主要测 MarketplaceManager 调用 HUD 的路径，
/// 本文件覆盖 MarketHUD class 自身（panel 生命周期、倒计时取消、Action handler 触发等）。
///
/// 测试类标 `@MainActor`（B4 修复）：MarketHUD 是 @MainActor，所有方法主线程访问。
@MainActor
final class MarketHUDTests: XCTestCase {

    /// 每个 case 用全新实例（不复用 MarketHUD.shared），避免互相干扰。
    private var hud: MarketHUD!

    override func setUp() async throws {
        try await super.setUp()
        hud = MarketHUD()
    }

    override func tearDown() async throws {
        hud.dismiss()
        hud = nil
        try await super.tearDown()
    }

    // MARK: - 1. show → panel.isVisible

    func test_show_makesPanelVisible() {
        hud.show(text: "hello", actions: [])
        XCTAssertTrue(hud.isVisible, "show 调用后 HUD 应可见")
    }

    // MARK: - 2. dismissDelay 注入 0.1s → 自隐

    func test_show_withShortDelay_autoHides() async throws {
        hud.dismissDelay = 0.1
        hud.show(text: "auto-dismiss", actions: [])
        XCTAssertTrue(hud.isVisible, "show 之后立即可见")

        // 等够 0.1s（额外 buffer 防 task scheduler 抖动）
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(hud.isVisible, "0.1s dismissDelay 之后 HUD 应自动隐藏")
    }

    // MARK: - 3. 重复 show 重置倒计时

    func test_show_repeated_resetsCountdown() async throws {
        hud.dismissDelay = 0.3
        hud.show(text: "first", actions: [])
        try await Task.sleep(nanoseconds: 200_000_000) // 0.2s
        XCTAssertTrue(hud.isVisible, "0.2s < 0.3s 仍应可见")

        // 第二次 show 重置倒计时
        hud.show(text: "second", actions: [])
        // 再等 0.2s（总 0.4s，但第二次重置后只过 0.2s < 0.3s）
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(hud.isVisible, "重复 show 后倒计时应重置，0.2s < 0.3s 仍可见")

        // 再等 0.3s 后必然消失
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(hud.isVisible, "重复 show 0.3s 之后应自动消失")
    }

    // MARK: - 4. dismiss 立即隐藏

    func test_dismiss_hidesPanel() {
        hud.show(text: "to dismiss", actions: [])
        XCTAssertTrue(hud.isVisible)
        hud.dismiss()
        XCTAssertFalse(hud.isVisible, "dismiss 后应立即隐藏")
    }

    // MARK: - 5. Action handler 触发

    func test_actionHandler_invokesClosure() {
        var fired = false
        let action = MarketHUD.Action(label: "go") { fired = true }
        action.handler()
        XCTAssertTrue(fired, "Action.handler 调用后 closure 应执行")
    }

    // MARK: - 6. configureHUD 同实例 no-op（行为契约）

    func test_configureHUD_sameInstanceTwice_doesNotTrap() {
        let mgr = MarketplaceManager(
            resolver: NoopResolver(),
            trustStore: TrustStore.shared,
            pluginsDir: URL(fileURLWithPath: NSTemporaryDirectory())
                .appending(path: "hud-cfg-\(UUID().uuidString)"),
            marketplacePath: URL(fileURLWithPath: NSTemporaryDirectory())
                .appending(path: "m-\(UUID().uuidString).json"),
            metaPath: URL(fileURLWithPath: NSTemporaryDirectory())
                .appending(path: "meta-\(UUID().uuidString).json"),
            syncLogPath: URL(fileURLWithPath: NSTemporaryDirectory())
                .appending(path: "log-\(UUID().uuidString).log")
        )
        // 同一实例两次注入 → 不应触发 precondition
        mgr.configureHUD(hud)
        mgr.configureHUD(hud)
        XCTAssertTrue(mgr.hud === hud, "同实例 configureHUD 两次后 hud 仍是同一个")
        mgr.resetHUDForTesting()
    }

    // MARK: - 7. dismiss 多次调用不抛错

    func test_dismiss_idempotent() {
        hud.dismiss()
        hud.dismiss()
        XCTAssertFalse(hud.isVisible)
    }

    // MARK: - 8. 未 show 直接 dismiss → 不可见

    func test_dismiss_withoutShow_keepsHidden() {
        XCTAssertFalse(hud.isVisible)
        hud.dismiss()
        XCTAssertFalse(hud.isVisible)
    }
}

// MARK: - Test helpers

/// 不会被实际调用的 resolver stub（仅供 MarketplaceManager 初始化）。
private final class NoopResolver: PluginSourceResolving {
    func resolve(_ source: PluginSourceConfig, bundleRoot: URL?) async throws -> URL {
        throw LauncherError.pluginInvalid("NoopResolver")
    }
}
