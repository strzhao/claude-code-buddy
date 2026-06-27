import AppKit

// MARK: - TrustPromptWindow（方案 B：自定义 NSWindow + 毛玻璃 + sendEvent 兜底）
//
// 用户真机反馈「布局遮挡 + 整体变大 + 背景毛玻璃」，NSAlert 壳满足不了：
// - 默认尺寸 ~300 宽，依赖区被挤压遮挡
// - 窗口不透明，无毛玻璃
//
// 本窗口对称 SettingsWindow（LSUIElement key window 兜底）+ LauncherWindow（NSVisualEffectView 毛玻璃）：
// - NSVisualEffectView .menu 材质 + .behindWindow（知识库 swiftui-material-vs-nsvisualeffectview-injection：
//   模态窗口可用 NSVisualEffectView，按 effectiveAppearance 求值稳定；禁 SwiftUI .ultraThinMaterial
//   因 NSPanel/LSUIElement 浮窗 colorScheme 传播不可靠——本窗口虽非浮窗但沿用 stable 路径）
// - sendEvent 拦截 leftMouseDown（知识库 lsuielement-standard-nswindow-key-window-sendevent-fallback：
//   LSUIElement accessory app 下标准 NSWindow 也可能不成为 key window，致按钮点击不路由）
// - 大尺寸：宽 480+（NSAlert ~300 宽遮挡），高自适应 NSHostingController fittingSize
// - 居中：screen.visibleFrame midX/midY
// - 圆角 + 阴影：.titled styleMask 提供系统圆角阴影 + backgroundColor=.clear + isOpaque=false

final class TrustPromptWindow: NSWindow {

    /// 最小宽度（用户反馈「整体变大」，NSAlert 默认 ~300 宽遮挡依赖区）。
    static let minWidth: CGFloat = 560

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    init(contentRect: NSRect = NSRect(x: 0, y: 0, width: 560, height: 380)) {
        // borderless（styleMask=[]）：去 .titled 系统标题栏边框（顶部直角根因），
        // 标准按钮已隐藏 + 标题栏透明无可见元素，去 .titled 无损失；
        // contentView/vfx cornerRadius 直接显示顶+底全圆角 + hasShadow 系统阴影
        super.init(
            contentRect: contentRect,
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        isMovableByWindowBackground = true
        // 透明背景 + 非不透明 → 让 NSVisualEffectView 毛玻璃透出
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        level = .floating
        // center 会用 screen.visibleFrame 居中（makeKeyAndOrderFront 前）
        center()
        installVisualEffect()
    }

    override var contentView: NSView? {
        didSet { installVisualEffect() }
    }

    /// 注入 NSVisualEffectView 作为毛玻璃背景（对称 LauncherWindow.installVisualEffect）。
    /// 可重入：guard 防重复，由 init + contentView didSet 同时调用。
    private func installVisualEffect() {
        guard let contentView = contentView else { return }
        if contentView.subviews.contains(where: { $0 is NSVisualEffectView }) { return }

        let vfx = NSVisualEffectView()
        // .menu 材质：dark 模式下比 .popover 深，配合半透桌面模糊保持对比度（同 LauncherWindow）
        vfx.material = .menu
        // .behindWindow：真实 sample 桌面像素并模糊，呈现毛玻璃特征
        vfx.blendingMode = .behindWindow
        vfx.state = .active
        vfx.wantsLayer = true
        // appearance = nil → 跟随 effectiveAppearance（不锁死 light/dark）
        vfx.appearance = nil
        vfx.translatesAutoresizingMaskIntoConstraints = false
        // 圆角（顶+底全圆角，对称 LauncherWindow：标题栏顶部也圆角，修复用户反馈「上方直角」）
        vfx.layer?.cornerRadius = LauncherTheme.panelCornerRadius
        vfx.layer?.masksToBounds = true

        contentView.addSubview(vfx, positioned: .below, relativeTo: contentView.subviews.first)
        NSLayoutConstraint.activate([
            vfx.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            vfx.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            vfx.topAnchor.constraint(equalTo: contentView.topAnchor),
            vfx.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
        contentView.wantsLayer = true
        // contentView 自身圆角 mask（确保可视区域顶+底全圆角 → 系统阴影自动跟随）
        contentView.layer?.cornerRadius = LauncherTheme.panelCornerRadius
        contentView.layer?.masksToBounds = true
    }

    /// LSUIElement key window 兜底（知识库 lsuielement-standard-nswindow-key-window-sendevent-fallback）。
    ///
    /// LSUIElement accessory app 下标准 NSWindow 可能不成为 key window，致 SwiftUI Button 点击不路由。
    /// sendEvent 是最底层且 100% 可靠的事件入口，拦截 leftMouseDown 兜底：
    /// - 先 makeKeyAndOrderFront 确保窗口 key（若失焦）
    /// - 再 super.sendEvent 让 SwiftUI/Button 正常处理
    ///
    /// 注：SwiftUI Button 依赖 key window 才能接收 Action，sendEvent 兜底保证点击即生效。
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, !isKeyWindow {
            makeKeyAndOrderFront(nil)
        }
        super.sendEvent(event)
    }

    /// Esc 关闭弹框（模态 stopModal cancel）。标准 close 按钮已隐藏 + 模态下不触发 stopModal，
    /// 关闭由 SwiftUI 拒绝按钮（onDeny）+ 本 Esc 兜底承担（对称 LauncherWindow.cancelOperation）。
    override func cancelOperation(_ sender: Any?) {
        NSApp.stopModal(withCode: .cancel)
    }
}
