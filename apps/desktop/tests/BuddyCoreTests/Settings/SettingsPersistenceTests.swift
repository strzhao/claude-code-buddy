import XCTest
import AppKit
@testable import BuddyCore

// MARK: - 红队验收测试：通用设置 toggle 持久化（SC-SET-11）
//
// 设计权威源（状态文件 `## 验收场景` SC-SET-11 + 契约 C5 保留项）：
//
// SC-SET-11 [det-machine]：When GeneralSettings toggle 翻转, 持久化生效。
//   observe: XCTest 读 UserDefaults
//   assert: 翻转后 key 取反, 重开窗口 state==持久值
//   artifact: XCTest/CLI JSON
//
// 持久化 key（来自设计 + 现有 SettingsSidebarAcceptanceTests.SC14 确认，非蓝队新改动）：
//   - `alwaysShowLabel`（标签开关）
//   - `soundEnabled`（音效开关）
//   - LaunchAtLogin 相关 key（开机自启，设计未明列 key 名，SMAppService 可能用系统态而非 UserDefaults）
//
// ⚠️ API 假设：
//   - GeneralSettingsViewController() 无参构造（现有代码已确认）。
//   - 翻转 NSSwitch 的方式：`sw.state = .on/off` + 触发 `target/action`（模拟用户拨动）。
//     与 SettingsSidebarAcceptanceTests.test_SC14_generalSettings_switchesFlipCorrectUserDefaultsKeys 同款。
//   - 开机自启 key：CONTRACT_AMBIGUITY。设计未明列 key 名（SMAppService 用系统 LaunchAgents，非标准 UserDefaults）。
//     本测试只断言 alwaysShowLabel + soundEnabled（设计明确），LaunchAtLogin 标注为 QA 真机验证。
//
// 红队原则：所有断言代表"设计意图应该满足"，不代表"实现实际做了什么"。
// 本测试是 SC-SET-11 的自动化部分；重开窗口恢复态（assert 第二句）由本测试的"重开"路径覆盖。

@MainActor
final class SettingsPersistenceTests: XCTestCase {

    private static let alwaysShowLabelKey = "alwaysShowLabel"
    private static let soundEnabledKey = "soundEnabled"

    // MARK: - Set up / tear down

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: Self.alwaysShowLabelKey)
        UserDefaults.standard.removeObject(forKey: Self.soundEnabledKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Self.alwaysShowLabelKey)
        UserDefaults.standard.removeObject(forKey: Self.soundEnabledKey)
        super.tearDown()
    }

    // MARK: - SC-SET-11 翻转 toggle 后 UserDefaults key 取反

    /// SC-SET-11：翻转 alwaysShowLabel 开关后，UserDefaults['alwaysShowLabel'] 取反。
    /// 杀死"开关存在但绑错 key / 未写 UserDefaults"的 mutation。
    func test_SC_SET_11_alwaysShowLabel_toggleFlipsUserDefaults() {
        // 初始 false
        UserDefaults.standard.set(false, forKey: Self.alwaysShowLabelKey)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: Self.alwaysShowLabelKey),
                       "初始 alwaysShowLabel 应为 false")

        let vc = GeneralSettingsViewController()
        _ = vc.view

        // 找到绑定 alwaysShowLabel 的开关并翻转
        guard let switchVC = findSwitchThatControls(key: Self.alwaysShowLabelKey, in: vc) else {
            return XCTFail("GeneralSettings 必须有一个开关翻转后写 UserDefaults['alwaysShowLabel']（SC-SET-11），"
                           + "实际未找到。说明开关缺失或绑错 key。")
        }

        // 翻转开关 → 触发 action → 应写 UserDefaults['alwaysShowLabel']=true
        flipSwitch(switchVC)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: Self.alwaysShowLabelKey),
                      "翻转 alwaysShowLabel 开关后，UserDefaults['alwaysShowLabel'] 必须变 true（SC-SET-11），"
                      + "实际: \(UserDefaults.standard.bool(forKey: Self.alwaysShowLabelKey))")

        // 翻回 → 应变 false
        flipSwitch(switchVC)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: Self.alwaysShowLabelKey),
                       "翻回 alwaysShowLabel 开关后，UserDefaults['alwaysShowLabel'] 必须变 false（SC-SET-11 双向持久化），"
                       + "实际: \(UserDefaults.standard.bool(forKey: Self.alwaysShowLabelKey))")
    }

    /// SC-SET-11：翻转 soundEnabled 开关后，UserDefaults['soundEnabled'] 取反。
    func test_SC_SET_11_soundEnabled_toggleFlipsUserDefaults() {
        UserDefaults.standard.set(false, forKey: Self.soundEnabledKey)

        let vc = GeneralSettingsViewController()
        _ = vc.view

        guard let switchVC = findSwitchThatControls(key: Self.soundEnabledKey, in: vc) else {
            return XCTFail("GeneralSettings 必须有一个开关翻转后写 UserDefaults['soundEnabled']（SC-SET-11），"
                           + "实际未找到。说明开关缺失或绑错 key。")
        }

        flipSwitch(switchVC)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: Self.soundEnabledKey),
                      "翻转 soundEnabled 开关后，UserDefaults['soundEnabled'] 必须变 true（SC-SET-11）")

        flipSwitch(switchVC)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: Self.soundEnabledKey),
                       "翻回 soundEnabled 开关后，UserDefaults['soundEnabled'] 必须变 false（SC-SET-11 双向）")
    }

    /// SC-SET-11：重开窗口后开关初始 state == 持久化值（读取路径不回归）。
    /// assert 第二句："重开窗口 state==持久值"。
    func test_SC_SET_11_toggleStateRestoredOnReopen() {
        // 预设 alwaysShowLabel=true，新 VC 初始应有对应开关 .on
        UserDefaults.standard.set(true, forKey: Self.alwaysShowLabelKey)

        let vc = GeneralSettingsViewController()
        _ = vc.view

        let switches = findAll(NSSwitch.self, in: vc.view)
        let onSwitches = switches.filter { $0.state == .on }
        XCTAssertGreaterThanOrEqual(onSwitches.count, 1,
                                    "alwaysShowLabel=true 时，重开 VC 至少一个 NSSwitch 初始 state 应为 .on（SC-SET-11 重开恢复），"
                                    + "实际 on 数: \(onSwitches.count)")

        // 预设 alwaysShowLabel=false，新 VC 初始对应开关应 .off
        UserDefaults.standard.set(false, forKey: Self.alwaysShowLabelKey)
        let vc2 = GeneralSettingsViewController()
        _ = vc2.view

        let switches2 = findAll(NSSwitch.self, in: vc2.view)
        let offSwitches = switches2.filter { $0.state == .off }
        XCTAssertGreaterThanOrEqual(offSwitches.count, switches2.count - 1,
                                    "alwaysShowLabel=false 时，重开 VC 对应开关初始 state 应为 .off（SC-SET-11 重开恢复），"
                                    + "实际: \(switches2.map { $0.state == .on ? "on" : "off" })")
    }

    /// SC-SET-11：通用设置至少含 2 个开关（音效 + 标签）。
    /// 杀死"开关缺失"的 mutation。
    func test_SC_SET_11_generalSettings_hasAtLeastTwoSwitches() {
        let vc = GeneralSettingsViewController()
        _ = vc.view

        let switches = findAll(NSSwitch.self, in: vc.view)
        XCTAssertGreaterThanOrEqual(switches.count, 2,
                                    "GeneralSettingsViewController 应至少含 2 个 NSSwitch（音效 + 标签，设计 A4），"
                                    + "实际: \(switches.count)")
    }

    // MARK: - LaunchAtLogin（CONTRACT_AMBIGUITY，标注 QA）
    //
    // 开机自启：设计 A4 明列"系统(开机自启)"，但未明列 key 名。
    //   可能实现：SMAppService（macOS 13+，系统 LaunchAgents，非标准 UserDefaults）或
    //             ServiceManagement 的 SMLoginItemSetEnabled（旧 API，UserDefaults key 未标准化）。
    //   本测试无法在单元层可靠断言 SMAppService 状态（需 entitlements + 真机）。
    //   QA 真机验证：在通用页勾选"开机自启"→ 重启 → app 自动启动；取消 → 重启 → 不启动。
    //   （SC-SET-13 manual 验证范围内）

    // MARK: - 辅助方法

    /// 翻转一个 NSSwitch：切 state + 触发 target/action。
    private func flipSwitch(_ sw: NSSwitch) {
        sw.state = (sw.state == .on) ? .off : .on
        if let target = sw.target, let action = sw.action {
            _ = target.perform(action, with: sw)
        }
    }

    /// 找到翻转后会改变指定 UserDefaults key 的开关。
    /// 策略：逐个翻转开关，检查 UserDefaults[key] 是否变化，命中后翻回恢复。
    private func findSwitchThatControls(key: String, in vc: NSViewController) -> NSSwitch? {
        let switches = findAll(NSSwitch.self, in: vc.view)
        for sw in switches {
            let before = UserDefaults.standard.bool(forKey: key)
            flipSwitch(sw)
            let after = UserDefaults.standard.bool(forKey: key)
            if before != after {
                // 命中：翻回原态（调用方会再翻）
                flipSwitch(sw)
                return sw
            }
            // 未命中：翻回
            flipSwitch(sw)
        }
        return nil
    }

    /// 递归找全部指定类型的子视图（复用 SettingsSidebarAcceptanceTests 模式）。
    private func findAll<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        var result: [T] = []
        if let typed = view as? T { result.append(typed) }
        for sub in view.subviews {
            result.append(contentsOf: findAll(type, in: sub))
        }
        return result
    }
}
