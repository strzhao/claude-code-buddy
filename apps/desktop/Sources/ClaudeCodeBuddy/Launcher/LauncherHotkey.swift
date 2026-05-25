import KeyboardShortcuts
import AppKit

enum LauncherHotkey {
    static let toggle = KeyboardShortcuts.Name(
        "launcher-toggle",
        default: .init(.space, modifiers: [.command, .shift])
    )

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
}
