import AppKit

/// Settings 面板的 tab content VC 协议。
///
/// SettingsPanel.sendEvent 把全局点击转发到 activeTab.handleClickAt（解耦硬绑 SkinGalleryViewController）。
/// SkinGalleryViewController / PluginGalleryViewController 都 conform。
protocol SettingsTabClickReceiver: AnyObject {
    func handleClickAt(windowPoint: NSPoint)
}

/// MarketplaceManager 的抽象（测试可注入 mock）。
///
/// - `inspect()` 是 `throws` 非 async（task 003 实际签名）。
/// - `reseed()` 是 `async throws`。
protocol MarketplaceInspecting {
    func inspect() throws -> MarketplaceInspection
    func reseed() async throws
}

/// PluginManager 的禁用/启用抽象（测试可注入 mock）。
protocol PluginToggling {
    func disable(name: String) throws
    func enable(name: String) throws
}

extension MarketplaceManager: MarketplaceInspecting {}
extension PluginManager: PluginToggling {}
