import AppKit

/// 设置窗口 sidebar 分类枚举（单一数据源，契约 2）。
///
/// 加分类 = 加一个 case（SC-12 旁证）；窗口/splitVC/sidebar 初始化
/// **不得**按分类数量 switch/if 硬编码分支。
enum SettingsSection: String, CaseIterable {

    /// 热键录入（KeyboardShortcutsViewController）
    case hotkey
    /// 插件市场（PluginGalleryViewController）
    case plugins
    /// 皮肤市场（SkinGalleryViewController）
    case skins
    /// 通用偏好（音效/标签开关 + 开机自启，GeneralSettingsViewController）
    case general
    /// 关于（版本/反馈/开源，AboutSettingsViewController）
    case about

    /// 中文展示名（sidebar cell title 与 AX title 共用）。
    var displayTitle: String {
        switch self {
        case .skins:   return "皮肤"
        case .plugins: return "插件"
        case .hotkey:   return "热键"
        case .general: return "通用"
        case .about:   return "关于"
        }
    }

    /// SF Symbol 图标名（sidebar cell 左侧图标）。
    var symbolName: String {
        switch self {
        case .skins:   return "paintbrush"
        case .plugins: return "puzzlepiece"
        case .hotkey:   return "keyboard"
        case .general: return "gearshape"
        case .about:   return "info.circle"
        }
    }
}
