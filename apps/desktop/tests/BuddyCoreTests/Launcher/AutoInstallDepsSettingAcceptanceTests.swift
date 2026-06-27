import XCTest
@testable import BuddyCore

// MARK: - AutoInstallDepsSettingAcceptanceTests
//
// 红队验收测试（shimmering-bubbling-bonbon，依赖合并权限弹框，2026-06-25）
//
// 覆盖模块：M7 (T6) 设置页全局开关 UI + UserDefaults
// 覆盖契约（state.md ## 契约规约）：
//   - 边界值：全局开关 key：buddy.launcher.plugin.autoInstallDeps，默认 == true
//   - 设计文档 M7：
//     UI：PluginGalleryViewController 或 SettingsSection 加「自动安装插件依赖」开关
//     关时：installAll 返回 .manualRequired，TrustPromptView 依赖区回退显示
//           `brew install <pkg>` 命令 + 「复制」按钮（不自动装）
//   - 副作用清单：UserDefaults：buddy.launcher.plugin.autoInstallDeps（设置页开关）
//
// 覆盖验收场景：
//   - 场景 11：设置页「自动安装依赖」开关持久化（11.P1 det-machine）
//   - 场景 7 前置：自动安装关 → installAll 返回 manualRequired（7.P2 negate）
//
// 红队红线：不读 Sources/ClaudeCodeBuddy/Settings/ 等蓝队实现，
// 仅依据 state.md 的「## 契约规约 + ## 设计文档 M7」黑盒断言。
// 测试 WILL NOT compile 直到蓝队合并 T6 实现 — 这是预期的 TDD 红灯。

final class AutoInstallDepsSettingAcceptanceTests: XCTestCase {

    // MARK: - 契约-M7 / 场景 11.P1: 全局开关 key 精确字符串 + 默认 true

    /// 契约 M7 边界值：「全局开关 key：buddy.launcher.plugin.autoInstallDeps，默认 == true」。
    /// 验证 key 字符串精确（拼写契约，UserDefaults 持久化基础）。
    ///
    /// 对应 P#：场景 11.P1（重启后 UserDefaults buddy.launcher.plugin.autoInstallDeps == false）的前置。
    /// Mutation-Survival：若 key 拼写错（如 autoInstallDependency），本测试挂。
    ///
    /// 已对齐蓝队闭包 seam（CONTRACT_AMBIGUOUS 已解）：
    ///   蓝队 key 定义在 DependencySettingsStore.autoInstallKey（红队原假设 LauncherConstants.autoInstallDepsSettingKey 不存在）。
    func test_M7_autoInstallDepsSettingKey_exactString() {
        XCTAssertEqual(DependencySettingsStore.autoInstallKey,
                       "buddy.launcher.plugin.autoInstallDeps",
                       "全局开关 key 必须精确匹配契约（M7 边界值 + 场景 11.P1 UserDefaults key）")
    }

    // MARK: - 契约-M7 / 场景 11.P1: 默认值 == true

    /// 契约 M7：「默认 == true」。首次读（UserDefaults 无值）必须返回 true。
    ///
    /// 对应 P#：场景 11.P1 前置（设置页开关默认 ON）。
    /// 用临时 UserDefaults suite 隔离（避免污染真实 UserDefaults.standard）。
    func test_M7_autoInstallDepsDefault_isTrue() throws {
        let suiteName = "AutoInstallDepsDefault-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // 蓝队真相：DependencySettingsStore(defaults:).isEnabled 读开关状态
        // （红队原假设 AutoInstallDepsSetting.isAutoInstallEnabled 已修正为 DependencySettingsStore.isEnabled）
        let enabled = DependencySettingsStore(defaults: defaults).isEnabled

        XCTAssertTrue(enabled,
                      "全局开关默认必须 true（M7 边界值 + 场景 11：设置页开关默认 ON）")
    }

    // MARK: - 场景 11.P1: 设置页切 OFF → 持久化（UserDefaults == false）

    /// 契约 M7 / 场景 11.P1：「用户设置页切开关 OFF 并重启 app，launcher shall 开关状态持久化」。
    /// 「重启后 UserDefaults buddy.launcher.plugin.autoInstallDeps == false」。
    ///
    /// 对应 P#：场景 11.P1（持久化值 == false）。
    /// 本测试：set false → 重新读（模拟重启后读 UserDefaults）→ 必须 false。
    ///
    /// Mutation-Survival：若 set 不落盘（只改内存），「重启读」会拿到默认 true，本测试挂。
    /// No-op kill：断言 set 后 + 「重新构造 reader」读仍是 false。
    func test_M7_setOff_persists_acrossReaderRecreation() throws {
        let suiteName = "AutoInstallDepsOff-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // 设置页切 OFF（蓝队：DependencySettingsStore.setEnabled）
        DependencySettingsStore(defaults: defaults).setEnabled(false)

        // 模拟「重启」：重新读 UserDefaults（新进程视角）
        // 关键：值必须落盘（UserDefaults 持久化），而非只在内存
        let persistedValue = defaults.object(forKey: DependencySettingsStore.autoInstallKey) as? Bool
        XCTAssertEqual(persistedValue, false,
                       "场景 11.P1：set OFF 后 UserDefaults 持久化值必须 == false")

        // 用新 reader 实例读（模拟重启后）
        let enabledAfterRestart = DependencySettingsStore(defaults: defaults).isEnabled
        XCTAssertFalse(enabledAfterRestart,
                       "场景 11.P1：重启（重新读）后开关状态必须仍 OFF（持久化）")
    }

    // MARK: - 契约-M7: set ON → 持久化（对称）

    /// 契约 M7 对称：set true → UserDefaults == true。覆盖 set 往返。
    func test_M7_setOn_persists() throws {
        let suiteName = "AutoInstallDepsOn-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // 先 OFF
        DependencySettingsStore(defaults: defaults).setEnabled(false)
        XCTAssertEqual(defaults.object(forKey: DependencySettingsStore.autoInstallKey) as? Bool, false)

        // 再 ON
        DependencySettingsStore(defaults: defaults).setEnabled(true)
        XCTAssertEqual(defaults.object(forKey: DependencySettingsStore.autoInstallKey) as? Bool,
                       true,
                       "set ON 后持久化值必须 == true（对称）")
    }

    // MARK: - 契约-M7 / 场景 11.P1: UI 状态与持久化值一致

    /// 契约 M7 / 场景 11.P1 尾句：「设置页开关 UI 状态 == OFF」。
    /// 本测试验证 reader 读到的值与 UserDefaults 持久化值一致（UI 绑定基础）。
    ///
    /// CONTRACT_AMBIGUOUS: UI 状态读取 API 未定（SageSwitch state vs reader API）。
    /// 红队假设 reader API（AutoInstallDepsSetting.isAutoInstallEnabled）是 UI 绑定的 SSOT，
    /// 即 UI 开关状态 = reader 读到的值。真机 UI 断言（AX 开关 state）留 QA。
    func test_M7_readerValue_matchesUserDefaultsValue() throws {
        let suiteName = "AutoInstallDepsConsistency-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // OFF 一致
        DependencySettingsStore(defaults: defaults).setEnabled(false)
        XCTAssertEqual(DependencySettingsStore(defaults: defaults).isEnabled,
                       defaults.object(forKey: DependencySettingsStore.autoInstallKey) as? Bool,
                       "reader 值必须与 UserDefaults 持久化值一致（场景 11.P1 UI 一致性基础）")

        // ON 一致
        DependencySettingsStore(defaults: defaults).setEnabled(true)
        XCTAssertEqual(DependencySettingsStore(defaults: defaults).isEnabled,
                       defaults.object(forKey: DependencySettingsStore.autoInstallKey) as? Bool)
    }

    // MARK: - 场景 7 前置 / 契约-M7: 开关 OFF → installAll manualRequired（不起子进程）

    /// 契约 M7 / 场景 7.P2 negate：「关时：installAll 返回 .manualRequired，
    /// TrustPromptView 依赖区回退显示 `brew install <pkg>` 命令 + 「复制」按钮（不自动装）」。
    ///
    /// 对应 P#：场景 7.P2 negate（自动安装关，不起 brew 子进程）。
    /// 本测试验证：开关 OFF 时 installAll（注入 autoInstallDeps=false）→ manualRequired。
    /// （与 DependencyInstallerAcceptanceTests.test_M3_installAll_autoInstallOff_returnsManualRequired_noProcess
    ///   互补：那个测 installAll 内部，这个测「开关 OFF 状态如何传到 installAll」）
    ///
    /// 已对齐蓝队闭包 seam（CONTRACT_AMBIGUOUS 已解）：
    ///   蓝队 DependencyInstaller 构造注入 settings: DependencySettingsStore（读全局开关）。
    ///   红队原假设 processFactory/verifyInstalled/defaults/timeoutMs 适配为 runner + settings。
    @MainActor
    func test_M7_switchOff_installAllReturnsManualRequired() async throws {
        let suiteName = "AutoInstallDepsOff-Installer-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        DependencySettingsStore(defaults: defaults).setEnabled(false)

        // 蓝队：DependencyInstaller(runner:settings:brewAvailable:)
        let installer = DependencyInstaller(
            runner: { _, _, _ in
                XCTFail("开关 OFF 时不应起 brew 子进程（场景 7.P2 negate）")
                return ProcessRunResult(exitCode: 0, stdout: "", stderr: "", wasCancelled: false)
            },
            settings: DependencySettingsStore(defaults: defaults), // 注入 OFF 状态
            brewAvailable: { true }
        )

        let result = await installer.installAll([
            DependencyStatus(check: "qrencode", label: nil,
                             isInstalled: false, brewPackage: "qrencode")
        ])

        guard case .manualRequired = result else {
            return XCTFail("场景 7.P2：开关 OFF → installAll 必须 .manualRequired，实际: \(result)")
        }
    }
}

// MARK: - seam 占位（已移除）
//
// 红队原假设的 TestProcessBox 占位已移除（蓝队用 ProcessRunner 闭包 seam，
// 测试直接传闭包字面量返 ProcessRunResult，无需占位类型）。
