import SwiftUI
import AppKit

// MARK: - LauncherTheme

/// 视觉 token 桥接：颜色/字体/阴影/边框（双主题）
/// 颜色用 dynamic NSColor 包装，跟随 macOS 系统 light/dark 主题自动更新。
/// 子视图直接用 LauncherTheme.xxx，无需手传 colorScheme。
enum LauncherTheme {

    // MARK: - Colors (dynamic, NSAppearance-aware)

    /// 面板背景色 light #f7f6f1 / dark #0f0f0e
    static let canvas = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0x0f / 255, green: 0x0f / 255, blue: 0x0e / 255, alpha: 1.0)
            : NSColor(red: 0xf7 / 255, green: 0xf6 / 255, blue: 0xf1 / 255, alpha: 1.0)
    })

    /// 输出区背景色 light #ffffff / dark #1c1c1a
    static let surface = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0x1c / 255, green: 0x1c / 255, blue: 0x1a / 255, alpha: 1.0)
            : NSColor(red: 0xff / 255, green: 0xff / 255, blue: 0xff / 255, alpha: 1.0)
    })

    /// 主文字色 light #1a1a18 / dark #edece7
    static let ink = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0xed / 255, green: 0xec / 255, blue: 0xe7 / 255, alpha: 1.0)
            : NSColor(red: 0x1a / 255, green: 0x1a / 255, blue: 0x18 / 255, alpha: 1.0)
    })

    /// 次要文字色 light #8f8f8d / dark #6e6e6c
    static let smoke = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0x6e / 255, green: 0x6e / 255, blue: 0x6c / 255, alpha: 1.0)
            : NSColor(red: 0x8f / 255, green: 0x8f / 255, blue: 0x8d / 255, alpha: 1.0)
    })

    /// 主品牌色（sage） light #3a7d68 / dark #52a688
    static let primary = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0x52 / 255, green: 0xa6 / 255, blue: 0x88 / 255, alpha: 1.0)
            : NSColor(red: 0x3a / 255, green: 0x7d / 255, blue: 0x68 / 255, alpha: 1.0)
    })

    /// 主品牌色 hover 态 light #52a688 / dark #6bbf9f
    static let primaryHover = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0x6b / 255, green: 0xbf / 255, blue: 0x9f / 255, alpha: 1.0)
            : NSColor(red: 0x52 / 255, green: 0xa6 / 255, blue: 0x88 / 255, alpha: 1.0)
    })

    /// 像素边框颜色 light #1a1a18 / dark #edece7
    static let borderPixel = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0xed / 255, green: 0xec / 255, blue: 0xe7 / 255, alpha: 1.0)
            : NSColor(red: 0x1a / 255, green: 0x1a / 255, blue: 0x18 / 255, alpha: 1.0)
    })

    /// 像素阴影颜色 light #1a1a18 / dark #000000
    static let shadowPixel = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0x00 / 255, green: 0x00 / 255, blue: 0x00 / 255, alpha: 1.0)
            : NSColor(red: 0x1a / 255, green: 0x1a / 255, blue: 0x18 / 255, alpha: 1.0)
    })

    /// 选中态薄雾背景 light #e8f2ee / dark #1c2c25
    static let mist = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0x1c / 255, green: 0x2c / 255, blue: 0x25 / 255, alpha: 1.0)
            : NSColor(red: 0xe8 / 255, green: 0xf2 / 255, blue: 0xee / 255, alpha: 1.0)
    })

    /// 选中文字反白色 light #ffffff / dark #1a1a18
    static let selectedText = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0x1a / 255, green: 0x1a / 255, blue: 0x18 / 255, alpha: 1.0)
            : NSColor(red: 0xff / 255, green: 0xff / 255, blue: 0xff / 255, alpha: 1.0)
    })

    // MARK: - Typography

    /// 输入框主字体 28pt
    static let bodyText: Font = .system(size: 28)

    /// 候选项名字 14pt medium
    static let candidateName: Font = .system(size: 14, weight: .medium)

    /// 候选项描述 12pt
    static let candidateDesc: Font = .system(size: 12)

    /// badge 等宽 10pt semibold monospaced
    static let badgeMono: Font = .system(size: 10, design: .monospaced).weight(.semibold)

    /// 底部提示等宽 9pt monospaced
    static let footerMono: Font = .system(size: 9, design: .monospaced)

    /// 输出区正文 14pt
    static let outputBody: Font = .system(size: 14)

    // MARK: - Layout Constants

    /// 像素阴影偏移（4,4）
    static let pixelShadowOffset = CGSize(width: 4, height: 4)

    /// 小号像素阴影偏移（2,2）
    static let pixelShadowSmOffset = CGSize(width: 2, height: 2)

    /// 像素边框宽度
    static let pixelBorderWidth: CGFloat = 2

    /// 面板圆角
    static let panelCornerRadius: CGFloat = 14
}
