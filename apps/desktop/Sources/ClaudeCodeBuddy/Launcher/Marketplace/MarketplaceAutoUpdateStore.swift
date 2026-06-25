import Foundation

/// C4：官方插件自动更新开关持久化（SOURCE OF TRUTH: MarketplaceAutoUpdateStore.swift）。
///
/// 存储：`UserDefaults.standard`，key `buddy.launcher.marketplace.autoUpdate`（Bool）。
/// 默认 ON（无 key = true）—— sync 检测到 updated 时自动 `installPlugin(replacing: true)` 覆盖。
///
/// 关闭语义（C5）：autoUpdate OFF 时 sync 仅更新 marketplace cache，不覆盖 `~/.buddy/launcher-plugins/`。
///
/// 与 `BuiltinPluginEnabledStore` 同模式（UserDefaults Bool 默认 true），但 key 独立
/// （`buddy.launcher.marketplace.*` vs `buddy.launcher.builtin.*`）。
final class MarketplaceAutoUpdateStore {

    static let shared = MarketplaceAutoUpdateStore()

    /// C4 契约 key 逐字：`buddy.launcher.marketplace.autoUpdate`。
    static let autoUpdateKey = "buddy.launcher.marketplace.autoUpdate"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 自动更新是否启用。默认（无 key）= true（C4）。
    /// 计算属性（红队测试 `store.isEnabled` 无括号访问）。
    var isEnabled: Bool {
        // key 不存在 = 默认 ON；存在则读其布尔值
        if defaults.object(forKey: Self.autoUpdateKey) == nil { return true }
        return defaults.bool(forKey: Self.autoUpdateKey)
    }

    /// 设置自动更新开关。
    /// - Parameter enabled: true=ON（sync 自动覆盖 updated 插件），false=OFF（仅更新 cache）
    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.autoUpdateKey)
    }

    /// 测试用：重置到默认（移除 key，回默认 true）。
    func reset() {
        defaults.removeObject(forKey: Self.autoUpdateKey)
    }
}
