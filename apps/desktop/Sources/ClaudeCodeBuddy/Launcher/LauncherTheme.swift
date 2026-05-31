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

    /// 选中态半透明背景（C2 契约）：light 0.12 / dark 0.18，基于 primary sage
    static let selectionTint = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0x52 / 255, green: 0xa6 / 255, blue: 0x88 / 255, alpha: 0.18)
            : NSColor(red: 0x3a / 255, green: 0x7d / 255, blue: 0x68 / 255, alpha: 0.12)
    })

    /// 即时候选选中态实色填充（task 011 交互优化）：去边框/竖条，纯色 pill 突出高亮，简洁。
    /// 实色 sage（带轻微透明让毛玻璃质感透出），白色文字。light #3a7d68 / dark #52a688，alpha 0.92
    static let instantSelectionFill = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0x52 / 255, green: 0xa6 / 255, blue: 0x88 / 255, alpha: 0.92)
            : NSColor(red: 0x3a / 255, green: 0x7d / 255, blue: 0x68 / 255, alpha: 0.92)
    })

    /// 选中行左侧指示竖条颜色（不带 alpha，实色 sage）
    static let selectionIndicator = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0x52 / 255, green: 0xa6 / 255, blue: 0x88 / 255, alpha: 1.0)
            : NSColor(red: 0x3a / 255, green: 0x7d / 255, blue: 0x68 / 255, alpha: 1.0)
    })

    /// 内边框高光（C1 辅助）：light 0.12 / dark 0.20（retry 2 加强，dark 桌面下可见性）
    static let innerHighlight = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1.0, alpha: 0.20)
            : NSColor(white: 0.0, alpha: 0.12)
    })

    /// 面板 tint（retry 2 四次平衡）：让 .behindWindow 毛玻璃模糊感透出，但 tint 保证对比度
    /// light: 白色 alpha 0.55 / dark: 深灰 alpha 0.55
    static let panelTint = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.12, alpha: 0.55)
            : NSColor(white: 1.0, alpha: 0.55)
    })

    // MARK: - Plugin Watermark Chip tokens

    /// Chip 文字色：低对比度灰色（#6c7a7a / 0.65 opacity）
    static let chipText = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0x6c / 255, green: 0x7a / 255, blue: 0x7a / 255, alpha: 0.65)
            : NSColor(red: 0x6c / 255, green: 0x7a / 255, blue: 0x7a / 255, alpha: 0.65)
    })

    /// Chip 边框色：rgba(255,255,255,0.16) dark / rgba(0,0,0,0.12) light
    static let chipBorder = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1.0, alpha: 0.16)
            : NSColor(white: 0.0, alpha: 0.12)
    })

    // MARK: - Typography

    /// 输入框主字体 22pt rounded（C7 契约）
    static let bodyText: Font = .system(size: 22, weight: .regular, design: .rounded)

    /// 候选项名字 18pt medium rounded（C7 契约，retry 2 第 8 轮 16→18）
    static let candidateName: Font = .system(size: 18, weight: .medium, design: .rounded)

    /// 候选项描述 16pt rounded（C7 契约，retry 2 第 8 轮 14→16）
    static let candidateDesc: Font = .system(size: 16, design: .rounded)

    /// 底部状态栏 13pt rounded（C7 契约，retry 2 第 7 轮 12→13）
    static let statusFooter: Font = .system(size: 13, design: .rounded)

    /// badge 等宽 10pt semibold monospaced
    static let badgeMono: Font = .system(size: 10, design: .monospaced).weight(.semibold)

    /// 底部提示等宽 9pt monospaced
    static let footerMono: Font = .system(size: 9, design: .monospaced)

    /// 输出区正文 18pt（retry 2 第 8 轮 16→18）
    static let outputBody: Font = .system(size: 18)

    // MARK: - Layout Constants

    /// 像素阴影偏移（4,4）
    static let pixelShadowOffset = CGSize(width: 4, height: 4)

    /// 小号像素阴影偏移（2,2）
    static let pixelShadowSmOffset = CGSize(width: 2, height: 2)

    /// 像素边框宽度
    static let pixelBorderWidth: CGFloat = 2

    /// 面板圆角 16pt
    static let panelCornerRadius: CGFloat = 16
}
