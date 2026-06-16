import XCTest
import KeyboardShortcuts
@testable import BuddyCore

// MARK: - LauncherHotkeyDefaultAcceptanceTests
//
// 红队验收测试：SC-17 全局快捷键默认 Ctrl+Space（contract update: 2026-06-15）
//
// 设计文档契约（state.md 契约 1 + 契约 3 + brainstorm C6 演进）：
//   - 默认 combo = Ctrl+Space = `.space` + `[.control]`
//   - `LauncherHotkey.toggle.rawValue == "launcher-toggle"`（锁定不变，向后兼容）
//   - 旧默认 ⌘⇧Space 已废弃（A2：⌘⇧Space 不再是默认）
//
// 这是改默认键的契约守护测试。任何回退到 [.command, .shift] 或更改 rawValue
// 都会让下列强断言红灯。
//
// 红队黑盒视角：通过 KeyboardShortcuts.Name.defaultShortcut 公开 API 观察。
// 测试 WILL NOT compile 直到蓝队合并实现 — 这是预期的 TDD 红灯。

@MainActor
final class LauncherHotkeyDefaultAcceptanceTests: XCTestCase {

    // MARK: - A1: 默认快捷键是 Ctrl+Space

    /// SC-17 契约演进：默认快捷键必须从 ⌘⇧Space 改为 Ctrl+Space。
    ///
    /// 精确断言：
    ///   key == .space（不是其他键）
    ///   modifiers 包含 .control（新默认 ctrl+space）
    ///   modifiers 不包含 .command（旧默认已废弃）
    ///   modifiers 不包含 .shift（旧默认已废弃）
    ///
    /// Mutation 探针：
    ///   - 若回退到 [.command, .shift]，.control 缺失 + .command/.shift 存在 → 多个断言红灯
    ///   - 若 key 改成 .p 等其他键 → key == .space 断言红灯
    func test_SC17_hotkeyDefault_isCtrlSpace() {
        guard let defaultShortcut = LauncherHotkey.toggle.defaultShortcut else {
            XCTFail("SC-17: LauncherHotkey.toggle.defaultShortcut 不应为 nil — Name 必须传入 default combo")
            return
        }

        // 精确断言 key == .space
        XCTAssertEqual(defaultShortcut.key, .space,
                       "SC-17 (contract 2026-06-15): 默认快捷键 key 必须是 .space（Ctrl+Space），actual=\(String(describing: defaultShortcut.key))")

        // 精确断言 modifiers 包含 .control（新默认）
        XCTAssertTrue(defaultShortcut.modifiers.contains(.control),
                      "SC-17 (contract 2026-06-15): 默认快捷键 modifiers 必须包含 .control（Ctrl+Space），actual=\(defaultShortcut.modifiers)")

        // 精确断言 modifiers 不包含 .command（旧默认 ⌘⇧Space 已废弃）
        XCTAssertFalse(defaultShortcut.modifiers.contains(.command),
                       "SC-17 (contract 2026-06-15): 默认快捷键 modifiers 不能包含 .command（旧默认 ⌘⇧Space 已废弃），actual=\(defaultShortcut.modifiers)")

        // 精确断言 modifiers 不包含 .shift（旧默认 ⌘⇧Space 已废弃）
        XCTAssertFalse(defaultShortcut.modifiers.contains(.shift),
                       "SC-17 (contract 2026-06-15): 默认快捷键 modifiers 不能包含 .shift（旧默认 ⌘⇧Space 已废弃），actual=\(defaultShortcut.modifiers)")
    }

    // MARK: - A1 补充：modifiers 精确集合 == [.control]

    /// 默认快捷键的 modifiers 集合必须精确等于 [.control]（不多不少，无残留位）。
    ///
    /// Mutation 探针：若 modifiers 是 [.control, .shift] 或 [.command, .control]，
    /// 设备无关位的精确比对失败。
    func test_SC17_hotkeyDefault_exactModifiers_controlOnly() {
        guard let defaultShortcut = LauncherHotkey.toggle.defaultShortcut else {
            XCTFail("SC-17: defaultShortcut 不应为 nil")
            return
        }

        let expectedModifiers: NSEvent.ModifierFlags = [.control]
        let actualDeviceIndependent = defaultShortcut.modifiers.intersection(.deviceIndependentFlagsMask)
        let expectedDeviceIndependent = expectedModifiers.intersection(.deviceIndependentFlagsMask)

        XCTAssertEqual(actualDeviceIndependent, expectedDeviceIndependent,
                       "SC-17: 默认快捷键 modifiers 必须精确为 [.control]（设备无关位），actual=\(actualDeviceIndependent.rawValue), expected=\(expectedDeviceIndependent.rawValue)")
    }

    // MARK: - A2: ⌘⇧Space 不再是默认（回归守护）

    /// A2 场景：旧默认 ⌘⇧Space 必须不再是默认值。
    /// 若有人意外回退，本测试红灯。
    func test_A2_commandShiftSpace_isNotDefaultAnymore() {
        guard let defaultShortcut = LauncherHotkey.toggle.defaultShortcut else {
            XCTFail("A2: defaultShortcut 不应为 nil")
            return
        }

        let isOldDefault = defaultShortcut.modifiers.contains(.command)
            && defaultShortcut.modifiers.contains(.shift)
            && !defaultShortcut.modifiers.contains(.control)
            && defaultShortcut.key == .space

        XCTAssertFalse(isOldDefault,
                       "A2: ⌘⇧Space 不再是默认快捷键（应为 Ctrl+Space），actual modifiers=\(defaultShortcut.modifiers), key=\(defaultShortcut.key)")
    }

    // MARK: - 契约 1: LauncherHotkey.toggle.rawValue 锁定不变

    /// LauncherHotkey.toggle.rawValue 必须保持 "launcher-toggle"（向后兼容，UserDefaults 存储键）。
    /// 改默认 combo 不应影响 Name 标识符。
    func test_contract1_toggleName_rawValueUnchanged() {
        XCTAssertEqual(LauncherHotkey.toggle.rawValue, "launcher-toggle",
                       "契约 1: LauncherHotkey.toggle.rawValue 必须保持 'launcher-toggle'，" +
                       "切换快捷键 combo 不应影响 Name 标识符（UserDefaults 存储键依赖）")
    }
}
