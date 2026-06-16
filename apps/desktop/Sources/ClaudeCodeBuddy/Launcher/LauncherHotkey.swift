import KeyboardShortcuts
import AppKit

enum LauncherHotkey {
    /// 默认热键：Ctrl+Space（参考 Alfred 大而方便；⌘⇧Space 已弃用）
    /// 系统占用验证：⌘+Space=输入法 key60，⌥⌃Space=输入法 key61，纯 ⌃+Space 空闲
    static let toggle = KeyboardShortcuts.Name(
        "launcher-toggle",
        default: .init(.space, modifiers: [.control])
    )

    /// 迁移标志 UserDefaults key：一次性幂等清理旧版（⌘⇧Space 时期）不兼容的 UserDefaults 值
    static let migrationV1Key = "launcher.hotkeyMigrationV1"

    /// 库内部 UserDefaults key（`userDefaultsPrefix + rawValue`）
    /// SOURCE OF TRUTH: KeyboardShortcuts.KeyboardShortcuts.swift userDefaultsKey(for:)
    static let libraryUserDefaultsKey = "KeyboardShortcuts_launcher-toggle"

    /// 注册全局快捷键，回调 toggle 启动器
    static func register(toggle action: @escaping () -> Void) {
        KeyboardShortcuts.onKeyUp(for: Self.toggle, action: action)
    }

    /// 首次启动探针：检查快捷键 combo 是否被占用
    /// 返回 false → 弹 KeyboardShortcuts.Recorder 让用户改键
    @MainActor
    static func probeIfNeeded() async -> Bool {
        let key = LauncherConstants.hotkeyProbeCompletedKey
        if UserDefaults.standard.bool(forKey: key) { return true }

        // 简单探针：检查 KeyboardShortcuts.getShortcut 返回的 combo 是否能注册
        // 真实探针：dispatch 一个合成 keyDown 看是否回调（涉及辅助功能权限，MVP 不做）
        // 替代方案：注册后立即检查 KeyboardShortcuts.isEnabled
        let combo = KeyboardShortcuts.getShortcut(for: toggle)
        let registered = combo != nil
        UserDefaults.standard.set(true, forKey: key)
        return registered
    }

    // MARK: - Migration

    /// 一次性幂等迁移：清理旧版（⌘⇧Space 默认时期）可能残留的不兼容 UserDefaults 值。
    /// 触发条件：迁移标志 `launcher.hotkeyMigrationV1` 未置位。
    /// 行为：删除 `KeyboardShortcuts_launcher-toggle` 旧值（库用新 default Ctrl+Space 重注册）+ 置标志。
    /// 幂等：标志已置位时直接返回（不重复清理）。
    @MainActor
    static func migrateLegacyIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migrationV1Key) else { return }

        // 清理旧值（可能为旧 ⌘⇧Space 编码或损坏值）；删除后库 getShortcut 返回 nil → 回 defaultShortcut
        defaults.removeObject(forKey: libraryUserDefaultsKey)
        defaults.set(true, forKey: migrationV1Key)
    }
}
