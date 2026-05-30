import XCTest
import KeyboardShortcuts
@testable import BuddyCore

// MARK: - LauncherHotkeyDefaultAcceptanceTests
//
// 红队验收测试：SC-17 全局快捷键默认 ⌘⇧Space
//
// 契约覆盖：
//   SC-17：断言 LauncherHotkey.default 的 key == .space
//          && modifiers 包含 .command 和 .shift，且不包含 .control
//
// 注意：现有代码使用 KeyboardShortcuts.Name("launcher-toggle", default: .init(.space, modifiers: [.command, .shift]))
// 本测试验证这个 default shortcut 的 key 和 modifiers 符合设计文档 C6 契约。
//
// 设计文档 C6：
//   - key == .space
//   - modifiers == [.command, .shift]
//   - 旧 [.control] 不允许（不再是默认值）
//
// ASSUMES blue team: LauncherHotkey.default 属性存在，返回 KeyboardShortcuts.Shortcut
//   OR: 可通过 KeyboardShortcuts.getShortcut(for: LauncherHotkey.toggle) 获取默认值
//
// 备选方案：如果 LauncherHotkey.default 不存在，通过检查 toggle Name 的 defaultShortcut 来验证。

@MainActor
final class LauncherHotkeyDefaultAcceptanceTests: XCTestCase {

    // MARK: - SC-17: 快捷键默认为 ⌘⇧Space

    /// SC-17：LauncherHotkey 的默认快捷键必须是 ⌘⇧Space（command + shift + space）。
    ///
    /// 精确断言：
    ///   key == .space（不是其他键）
    ///   modifiers 包含 .command 和 .shift（不少于这两个修饰键）
    ///   modifiers 不包含 .control（旧版被弃用的修饰键）
    ///
    /// Mutation 探针：
    ///   - 如果改回 [.control]，modifiers 包含 .control 断言红灯
    ///   - 如果 key 变成 .p 或其他键，key == .space 断言红灯
    func test_SC17_hotkeyDefault_isCommandShiftSpace() {
        // 通过 KeyboardShortcuts.Name 的 defaultShortcut 获取默认快捷键
        // LauncherHotkey.toggle 定义时传入了 default: .init(.space, modifiers: [.command, .shift])
        let shortcutName = LauncherHotkey.toggle

        // 获取 default shortcut（KeyboardShortcuts.Name.defaultShortcut 是 init 时传入的值）
        // KeyboardShortcuts 库：Name.default 字段存储了构造时的 default shortcut
        guard let defaultShortcut = shortcutName.defaultShortcut else {
            XCTFail("SC-17: LauncherHotkey.toggle 的 defaultShortcut 不应为 nil")
            return
        }

        // 精确断言 key == .space
        XCTAssertEqual(defaultShortcut.key, .space,
                       "SC-17: 默认快捷键的 key 必须是 .space，actual=\(String(describing: defaultShortcut.key))")

        // 精确断言 modifiers 包含 .command
        XCTAssertTrue(defaultShortcut.modifiers.contains(.command),
                      "SC-17: 默认快捷键 modifiers 必须包含 .command，actual=\(defaultShortcut.modifiers)")

        // 精确断言 modifiers 包含 .shift
        XCTAssertTrue(defaultShortcut.modifiers.contains(.shift),
                      "SC-17: 默认快捷键 modifiers 必须包含 .shift，actual=\(defaultShortcut.modifiers)")

        // 精确断言 modifiers 不包含 .control（旧版快捷键已废弃）
        XCTAssertFalse(defaultShortcut.modifiers.contains(.control),
                       "SC-17: 默认快捷键 modifiers 不能包含 .control（旧版 ⌃Space 已废弃），actual=\(defaultShortcut.modifiers)")
    }

    // MARK: - SC-17 补充：通过 LauncherHotkey.default 属性验证（如蓝队添加此属性）
    //
    // ASSUMES blue team will also expose:
    //   static var `default`: KeyboardShortcuts.Shortcut { get }
    // 如果蓝队未添加，此测试使用备选路径验证

    /// SC-17 备选验证：通过直接构造 KeyboardShortcuts.Shortcut 来对比验证。
    ///
    /// 不依赖 LauncherHotkey.default 属性，而是直接检查 toggle.rawValue 的 default 字段。
    /// Mutation 探针：如果 modifiers 集合改变（[.command, .shift] → [.command] 或其他），精确比对失败。
    func test_SC17_hotkeyDefault_exactModifiers_commandAndShiftOnly() {
        guard let defaultShortcut = LauncherHotkey.toggle.defaultShortcut else {
            XCTFail("SC-17: defaultShortcut 不应为 nil")
            return
        }

        // 精确断言：modifiers 集合应 == [.command, .shift]（不多不少）
        // KeyboardShortcuts 的 modifiers 是 NSEvent.ModifierFlags
        let expectedModifiers: NSEvent.ModifierFlags = [.command, .shift]

        // 比较 rawValue（NSEvent.ModifierFlags 可能含内部保留位，只比较设备独立位）
        let actualDeviceIndependent = defaultShortcut.modifiers.intersection(.deviceIndependentFlagsMask)
        let expectedDeviceIndependent = expectedModifiers.intersection(.deviceIndependentFlagsMask)

        XCTAssertEqual(actualDeviceIndependent, expectedDeviceIndependent,
                       "SC-17: 默认快捷键 modifiers 必须精确为 [.command, .shift]（设备无关位），actual=\(actualDeviceIndependent.rawValue), expected=\(expectedDeviceIndependent.rawValue)")
    }

    // MARK: - SC-17 + 现有 LauncherHotkeyAcceptanceTests 兼容性

    /// SC-17 向后兼容：LauncherHotkey.toggle.rawValue 仍为 "launcher-toggle"（契约锁定不变）。
    /// 确保 SC-17 的改动没有意外破坏 Name 字符串。
    func test_SC17_toggleName_rawValueUnchanged() {
        XCTAssertEqual(LauncherHotkey.toggle.rawValue, "launcher-toggle",
                       "SC-17 兼容性：LauncherHotkey.toggle.rawValue 必须保持 'launcher-toggle'，" +
                       "切换快捷键 combo 不应影响 Name 标识符")
    }
}
