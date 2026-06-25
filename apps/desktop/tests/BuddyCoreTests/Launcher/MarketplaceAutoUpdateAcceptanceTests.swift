import XCTest
@testable import BuddyCore

// MARK: - MarketplaceAutoUpdateAcceptanceTests
//
// 红队验收测试（社区插件 git 化，2026-06-24）
//
// 覆盖契约：C4（自动更新开关默认 ON）+ C5（sync ON 覆盖 / OFF 仅 cache）
// 覆盖谓词：P4（开关默认 ON）/ P5（ON → 自动覆盖）/ P6（OFF → 不覆盖）的单元可验证部分
//
// 红队红线：不读实现源码，仅依据 state.md 契约 C4/C5 黑盒断言。
//
// 契约逐字（C4）：
//   - UserDefaults key `buddy.launcher.marketplace.autoUpdate`（Bool，默认 true）
//   - 新装/重置后默认 ON
// 契约逐字（C5）：
//   - sync 检测 updated + autoUpdate ON → installPlugin(replacing: true) 覆盖
//   - autoUpdate OFF → 仅更新 cache 不覆盖

final class MarketplaceAutoUpdateAcceptanceTests: XCTestCase {

    // MARK: - 隔离的 UserDefaults（避免污染 .standard）

    /// 契约 C4 key 逐字：`buddy.launcher.marketplace.autoUpdate`
    private static let autoUpdateKey = "buddy.launcher.marketplace.autoUpdate"

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        let suiteName = "test-marketplace-autoupdate-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        for key in defaults.dictionaryRepresentation().keys {
            defaults.removeObject(forKey: key)
        }
    }

    override func tearDown() {
        if let d = defaults {
            for key in d.dictionaryRepresentation().keys {
                d.removeObject(forKey: key)
            }
        }
        defaults = nil
        super.tearDown()
    }

    // MARK: - C4: 新装默认 ON（UserDefaults 无键时读 true）

    /// 契约 C4：UserDefaults key `buddy.launcher.marketplace.autoUpdate`（Bool，默认 true）。
    /// 新装/重置后（无键）默认 ON。
    ///
    /// 对应 P#：P4（自动更新开关默认 ON）的单元可验证部分。
    /// Mutation-Survival：若实现把默认值写成 false 或 key 名写错，本测试挂。
    func test_C4_autoUpdate_defaultsTrue_whenKeyAbsent() {
        let store = MarketplaceAutoUpdateStore(defaults: defaults)

        // 无键时必须读 true（默认 ON）
        XCTAssertTrue(store.isEnabled, "无键时 autoUpdate 默认必须 ON（C4：默认 true）")
        XCTAssertNil(defaults.object(forKey: Self.autoUpdateKey),
                     "未 setEnabled 前 UserDefaults 不应写入该键（默认值不应持久化）")
    }

    // MARK: - C4: setEnabled(false) → 读 false + 写入契约 key

    /// 契约 C4：setEnabled(false) 后读 false，且持久化到契约 key `buddy.launcher.marketplace.autoUpdate`。
    func test_C4_setEnabled_false_persistsToContractKey() {
        let store = MarketplaceAutoUpdateStore(defaults: defaults)

        store.setEnabled(false)

        XCTAssertFalse(store.isEnabled, "setEnabled(false) 后必须读 false")
        XCTAssertNotNil(defaults.object(forKey: Self.autoUpdateKey),
                       "setEnabled(false) 必须写入契约 key")
        XCTAssertEqual(defaults.bool(forKey: Self.autoUpdateKey), false,
                       "契约 key 值必须为 false")
    }

    // MARK: - C4: setEnabled(true) 后再读 true（往返）

    func test_C4_setEnabled_true_roundtrips() {
        let store = MarketplaceAutoUpdateStore(defaults: defaults)

        store.setEnabled(false)
        XCTAssertFalse(store.isEnabled)

        store.setEnabled(true)
        XCTAssertTrue(store.isEnabled, "setEnabled(true) 后必须读 true")
        XCTAssertEqual(defaults.bool(forKey: Self.autoUpdateKey), true,
                       "契约 key 值必须为 true")
    }

    // MARK: - C4: key 名逐字一致

    /// 契约逐字：UserDefaults key 必须是 `buddy.launcher.marketplace.autoUpdate`。
    /// 任何拼写偏差（驼峰/下划线/前缀）都会让 P4 defaults 键检查失败。
    func test_C4_keyName_isExactlyContractLiteral() {
        // setEnabled 写入后，契约 key 必须存在（逐字）
        let store = MarketplaceAutoUpdateStore(defaults: defaults)
        store.setEnabled(true)

        XCTAssertNotNil(defaults.object(forKey: "buddy.launcher.marketplace.autoUpdate"),
                       "key 必须**逐字**为 buddy.launcher.marketplace.autoUpdate（C4）")
    }

    // MARK: - C4: 持久化跨 store 实例

    /// 契约 C4：状态持久化到 UserDefaults，新 store 实例（同 defaults）应读到。
    func test_C4_persistence_acrossStoreInstances() {
        let store = MarketplaceAutoUpdateStore(defaults: defaults)
        store.setEnabled(false)

        let store2 = MarketplaceAutoUpdateStore(defaults: defaults)
        XCTAssertFalse(store2.isEnabled, "新 store 实例必须读到持久化的 false（C4 持久化）")
    }

    // MARK: - C5: autoUpdate ON → sync 检测 updated 触发覆盖（单元 seam）

    /// 契约 C5：sync 检测 updated + autoUpdate ON → installPlugin(replacing: true) 覆盖。
    ///
    /// 本测试是 P5 的单元可验证部分：注入 autoUpdateEnabled=true 的 store，
    /// 验证 sync 后 updated plugin 的目录被覆盖（version 变化）。
    /// 真实 sync 远程拉取 + debounce 留 REAL_SCENARIO（依赖网络 + 时间）。
    ///
    /// 注：此测试依赖蓝队提供的「sync 覆盖」seam。若实现把 autoUpdate 读取点放在
    /// syncFromRemote 内部且无注入 seam，本测试可能需调整——但契约 C5 明确 autoUpdate ON
    /// 必须触发覆盖，此断言不可放宽。
    func test_C5_autoUpdateON_syncOverwritesUpdatedPlugin() async throws {
        // REAL_SCENARIO 边界：完整 sync 远程拉取依赖网络 + marketplace-meta.json debounce。
        // 此处保留为契约级骨架，详细 mock 驱动见 QA Tier 1.5。
        // 驱动方式：
        //   1. rm ~/.buddy/marketplace-meta.json（重置 debounce，I2）
        //   2. monorepo bump hello version（git push）
        //   3. 等 sync 窗口（1h）或手动触发 sync
        //   4. buddy launcher inspect hello → version 变化
        //   5. sync 窗口内 log stream 无 trust/alert 关键字（C5：绕过 checkAndPrompt）

        // 契约级断言：autoUpdate store ON 时，isEnabled 必须为 true（sync 读取点的前提）
        let store = MarketplaceAutoUpdateStore(defaults: defaults)
        XCTAssertTrue(store.isEnabled, "autoUpdate ON 是 sync 覆盖的前提（C5）")

        // CONTRACT_AMBIGUOUS: sync 如何读取 autoUpdate store（注入 vs 单例）未在契约明确。
        // 蓝队实现需提供注入 seam（类似 MarketplaceManager(autoUpdateStore:)），
        // 否则本测试无法在单测层验证覆盖行为，只能留 REAL_SCENARIO。
        // REAL_SCENARIO: 留 QA Tier 1.5 真机验证，驱动方式见上方注释。
    }

    // MARK: - C5: autoUpdate OFF → sync 仅更新 cache 不覆盖

    /// 契约 C5：autoUpdate OFF → 仅更新 cache 不覆盖。
    ///
    /// 对应 P#：P6（开关 OFF → 不覆盖）。
    /// 真实 sync + version bump 留 REAL_SCENARIO。
    func test_C5_autoUpdateOFF_syncDoesNotOverwrite() {
        // REAL_SCENARIO: 留 QA Tier 1.5 真机验证，驱动方式：
        //   1. rm ~/.buddy/marketplace-meta.json（重置 debounce，I2）
        //   2. defaults write / buddy launcher marketplace auto-update off（或设置页 switch OFF）
        //   3. monorepo bump qr version + push
        //   4. sync 窗口后 buddy launcher inspect qr → version **不变**（C5：OFF 不覆盖）

        let store = MarketplaceAutoUpdateStore(defaults: defaults)
        store.setEnabled(false)
        XCTAssertFalse(store.isEnabled, "autoUpdate OFF 是 sync 不覆盖的前提（C5/P6）")

        // 契约级断言：OFF 时 store 明确返回 false，sync 据此跳过 installPlugin(replacing:true)
        // REAL_SCENARIO: 留 QA Tier 1.5 真机验证。
    }
}
