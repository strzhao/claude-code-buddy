import AppKit

// MARK: - BuddyPalette

/// 跨子系统共享的品牌色常量（A2 同源策略）。
///
/// 设置页 `SettingsTheme.accent` 与启动器 `LauncherTheme.primary` 都引用 `sage`，
/// 消除两份 `#3a7d68` 字面量漂移风险。色值用 `NSColor(name:dynamicProvider:)` 包装，
/// 跟随 macOS 系统 light/dark 主题自动更新（patterns/2026-05-28 明暗机制）。
enum BuddyPalette {

    /// sage 品牌主色：light `#3a7d68` / dark `#52a688`。
    /// 单一定义点，SettingsTheme 与 LauncherTheme 共同引用（SC-SET-10 同源断言）。
    static let sage: NSColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0x52 / 255, green: 0xa6 / 255, blue: 0x88 / 255, alpha: 1.0)
            : NSColor(red: 0x3a / 255, green: 0x7d / 255, blue: 0x68 / 255, alpha: 1.0)
    }

    /// sage hover 态：light `#52a688` / dark `#6bbf9f`。
    static let sageHover: NSColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0x6b / 255, green: 0xbf / 255, blue: 0x9f / 255, alpha: 1.0)
            : NSColor(red: 0x52 / 255, green: 0xa6 / 255, blue: 0x88 / 255, alpha: 1.0)
    }
}
