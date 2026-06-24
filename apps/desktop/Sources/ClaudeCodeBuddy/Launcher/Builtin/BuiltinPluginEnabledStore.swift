import Foundation

/// C3：内置插件开关持久化（SOURCE OF TRUTH: BuiltinPluginEnabledStore.swift）。
///
/// 存储：`UserDefaults.standard`，key 模式 `buddy.launcher.builtin.<id>.disabled`（Bool，true=关闭）。
/// 默认全部 enabled（无 key = true）。
///
/// 关闭语义：`BuiltinPluginRegistry.actions(for:)` 跳过 disabled 的插件（不产生候选/不响应）。
/// Paste 关闭仅阻断候选展示，`ClipboardHistoryService` Timer 仍记录剪贴板（YAGNI，留后续）。
///
/// key 前缀 `buddy.launcher.builtin.` 与外部插件 `.disabled` 文件机制隔离（两套独立开关）。
final class BuiltinPluginEnabledStore {

    static let shared = BuiltinPluginEnabledStore()

    /// C3 key 前缀。`<prefix><pluginId>.disabled`。
    static let keyPrefix = "buddy.launcher.builtin."
    static let disabledSuffix = ".disabled"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 返回插件是否启用。默认（无 key）= true。
    func isEnabled(id: String) -> Bool {
        // key 存在且 == true 表示显式关闭；不存在或 false 表示启用
        let key = disabledKey(id: id)
        if defaults.object(forKey: key) == nil { return true }
        return !defaults.bool(forKey: key)
    }

    /// 设置插件启用/关闭。
    /// - Parameters:
    ///   - id: 插件 id（如 "calculator"）
    ///   - enabled: true=启用，false=关闭
    func setEnabled(id: String, enabled: Bool) {
        let key = disabledKey(id: id)
        // enabled=true → 写 disabled=false（或移除 key 回默认）。这里统一写显式值，便于排查。
        defaults.set(!enabled, forKey: key)
    }

    /// 测试用：重置某插件到默认（移除 key）。
    func reset(id: String) {
        defaults.removeObject(forKey: disabledKey(id: id))
    }

    private func disabledKey(id: String) -> String {
        "\(Self.keyPrefix)\(id)\(Self.disabledSuffix)"
    }
}
