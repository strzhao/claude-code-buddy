import AppKit

// MARK: - PluginSettingsPanelProvider 协议（C3）
//
// 插件面板协议：插件可声明自己的设置面板（NSViewController）。
// 默认无面板插件（calculator/paste/applauncher/...）走 EmptyPluginStateVC 空态。
//
// 注册表 PluginPanelRegistry：[pluginName: Provider]，snip 首个注册（T2）。
//
// 范式参考 SettingsSplitViewController.detailViewControllerProvider :36-45（detail 工厂），
// 但此处是「插件粒度」面板工厂（非「分类粒度」detail）。

/// 插件设置面板提供者协议。
///
/// 实现者返回一个 NSViewController（如 SnipPanelVC）用于插件页右栏 detail 容器。
/// 调用方（PluginGalleryViewController）按选中插件 name 查 PluginPanelRegistry，
/// 命中 → makePanelVC()；未命中 → EmptyPluginStateVC。
///
/// @MainActor：NSViewController 创建必须在主线程（UI API），统一主线程隔离避免 Swift 6
/// 跨 actor 警告。
@MainActor
protocol PluginSettingsPanelProvider: AnyObject {
    /// 创建面板 VC（每次调用返回新实例，避免缓存脏状态）。
    func makePanelVC() -> NSViewController
}

// MARK: - PluginPanelRegistry 注册表（C3）

/// 插件面板注册表：pluginName → Provider。
///
/// snip 首个注册（T2 在 PluginGalleryViewController.viewDidLoad 或 init 时注册）。
/// 无面板插件不注册，调用方走 EmptyPluginStateVC（AC-SNIPGUI-03/27）。
///
/// @MainActor：注册发生在 app 启动 + UI 切换时，主线程访问足够。
@MainActor
final class PluginPanelRegistry {

    static let shared = PluginPanelRegistry()

    private var providers: [String: PluginSettingsPanelProvider] = [:]

    private init() {}

    /// 查询插件面板 provider。命中返回 provider，未命中返回 nil（调用方走 EmptyPluginStateVC）。
    func provider(for pluginName: String) -> PluginSettingsPanelProvider? {
        providers[pluginName]
    }

    /// 注册面板 provider（幂等：后注册覆盖前者）。
    func register(_ provider: PluginSettingsPanelProvider, for pluginName: String) {
        providers[pluginName] = provider
    }

    /// 清空注册表（测试 seam，AC-SNIPGUI-27 空注册表测试）。
    func resetForTesting() {
        providers.removeAll()
    }
}
