import XCTest
@testable import BuddyCore

// MARK: - DependencySettingsStoreTests
//
// 蓝队单测 T6：设置页全局开关 + DependencySettingsStore 持久化（契约 M7 + 场景 11）。
//
// 契约引用（state.md ## 契约规约 M7 + 边界值）：
//   UserDefaults key：`buddy.launcher.plugin.autoInstallDeps`，默认 == true
//   DependencySettingsStore.isEnabled / setEnabled / reset
//   关闭语义：installAll 返回 .manualRequired（T3 已覆盖），TrustPromptView 回退显示命令 + 复制
//
// 场景 11：设置页切 OFF → 重启 app → 开关仍 OFF（UserDefaults 持久化）。
//
// 测试策略：注入临时 UserDefaults suite（隔离，不污染全局 .standard）。

final class DependencySettingsStoreTests: XCTestCase {

    /// 构造临时 UserDefaults suite（每次测试独立，不污染 .standard）。
    private func makeDefaults() -> UserDefaults {
        let suite = "test-dep-settings-\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    // MARK: - 默认值（边界值：默认 == true）

    /// 契约 M7：无 key 时默认 ON（true）。
    func test_AT01_defaultEnabled() {
        let defaults = makeDefaults()
        let store = DependencySettingsStore(defaults: defaults)
        XCTAssertTrue(store.isEnabled, "默认应 ON（无 key = true）")
    }

    // MARK: - setEnabled 持久化（场景 11）

    /// 契约 M7 + 场景 11：setEnabled(false) → 持久化 → 新 store 实例读仍 false（模拟重启）。
    func test_AT02_setEnabledFalse_persistsAcrossInstances() {
        let defaults = makeDefaults()
        let store1 = DependencySettingsStore(defaults: defaults)
        store1.setEnabled(false)

        // 模拟重启：新 store 实例（同 defaults）
        let store2 = DependencySettingsStore(defaults: defaults)
        XCTAssertFalse(store2.isEnabled, "重启后开关状态应持久化（false）")
    }

    /// 契约 M7：setEnabled(true) → 持久化 → 新实例读 true。
    func test_AT03_setEnabledTrue_persists() {
        let defaults = makeDefaults()
        let store1 = DependencySettingsStore(defaults: defaults)
        store1.setEnabled(false)  // 先关
        store1.setEnabled(true)   // 再开

        let store2 = DependencySettingsStore(defaults: defaults)
        XCTAssertTrue(store2.isEnabled)
    }

    // MARK: - key 逐字匹配（契约边界）

    /// 契约 M7：key 必须逐字 `buddy.launcher.plugin.autoInstallDeps`。
    func test_AT04_keyLiteralMatches() {
        XCTAssertEqual(DependencySettingsStore.autoInstallKey, "buddy.launcher.plugin.autoInstallDeps",
                       "UserDefaults key 必须逐字匹配契约")
    }

    // MARK: - reset

    /// 契约 M7：reset 回默认（移除 key，isEnabled 回 true）。
    func test_AT05_reset_returnsToDefault() {
        let defaults = makeDefaults()
        let store = DependencySettingsStore(defaults: defaults)
        store.setEnabled(false)
        XCTAssertFalse(store.isEnabled)

        store.reset()
        XCTAssertTrue(store.isEnabled, "reset 后应回默认 true")
    }

    // MARK: - key 隔离（不与 marketplace.autoUpdate / builtin 等冲突）

    /// 契约 M7：与 MarketplaceAutoUpdateStore key 隔离。
    func test_AT06_keyIsolatedFromMarketplaceAutoUpdate() {
        XCTAssertNotEqual(DependencySettingsStore.autoInstallKey, MarketplaceAutoUpdateStore.autoUpdateKey,
                          "依赖安装开关 key 必须与 marketplace autoUpdate key 隔离")
    }
}
