import AppKit

final class LauncherWindow: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: LauncherConstants.windowWidth, height: LauncherConstants.windowMinHeight),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .transient]
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true   // 系统阴影（替代手写硬阴影）
        hidesOnDeactivate = true   // 失焦自动隐藏（macOS 默认行为）
        // standardWindowButton 全隐藏
        for btn in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(btn)?.isHidden = true
        }
        // C1 契约：init 后 contentView 链中必须存在 NSVisualEffectView。
        // 立即注入到默认 contentView；contentView 替换时由 didSet 再次注入。
        installVisualEffect()
    }

    override var contentView: NSView? {
        didSet { installVisualEffect() }
    }

    /// 注入 NSVisualEffectView 作为毛玻璃背景（C1 契约）
    /// 可重入：guard 防重复，由 init + contentView didSet 同时调用
    func installVisualEffect() {
        guard let contentView = contentView else { return }
        // 避免重复安装
        if contentView.subviews.contains(where: { $0 is NSVisualEffectView }) { return }

        let vfx = NSVisualEffectView()
        // .menu material 在 dark 模式下比 .popover 更深，配合半透 tint 与桌面模糊保持平衡
        vfx.material = .menu
        // .behindWindow 让 vfx 真实 sample 桌面像素并模糊，呈现毛玻璃特征
        // 配合上层 panelTint 0.55 让桌面模糊感透出，同时保证文字对比度
        vfx.blendingMode = .behindWindow
        vfx.state = .active
        vfx.wantsLayer = true
        // 圆角 mask：让毛玻璃跟随设计 16pt 圆角，配合 panel.hasShadow 系统阴影按 alpha mask 绘制
        vfx.layer?.cornerRadius = LauncherTheme.panelCornerRadius
        vfx.layer?.masksToBounds = true
        vfx.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(vfx, positioned: .below, relativeTo: contentView.subviews.first)
        NSLayoutConstraint.activate([
            vfx.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            vfx.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            vfx.topAnchor.constraint(equalTo: contentView.topAnchor),
            vfx.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
        // contentView 自身也加圆角 mask，确保 panel 可视区域形成圆角 → 系统阴影自动跟随
        contentView.wantsLayer = true
        contentView.layer?.cornerRadius = LauncherTheme.panelCornerRadius
        contentView.layer?.masksToBounds = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }   // 不抢应用主窗口

    /// Esc 总能退出 launcher：不依赖 SwiftUI focus / onExitCommand
    /// AppKit cancelOperation 是 panel 级响应，焦点不在 TextField 内时也生效
    override func cancelOperation(_ sender: Any?) {
        LauncherManager.shared.hide()
    }

    func centerOnScreen() {
        guard let screen = NSScreen.main else { return }
        let rect = screen.visibleFrame
        let x = rect.midX - frame.width / 2
        let y = rect.minY + rect.height * (1 - LauncherConstants.windowYRatio)
        setFrameOrigin(NSPoint(x: x, y: y))
    }
}
