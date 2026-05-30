import AppKit
import SwiftUI

// MARK: - MarketHUDDisplaying 协议（DI 入口）

/// in-app HUD 显示协议。生产实现 = MarketHUD.shared；测试用 mock 注入。
///
/// 所有方法标 `@MainActor`：调用方（MarketplaceManager 非 isolated async 上下文）
/// 直接 `await hud?.show(...)`，编译器自动 hop 主线程，**不**嵌套 `MainActor.run`。
protocol MarketHUDDisplaying: AnyObject {
    @MainActor func show(text: String, actions: [MarketHUD.Action])
    @MainActor func dismiss()
}

// MARK: - MarketHUD

/// 自建 in-app NSPanel toast 浮窗（替代 deprecated NSUserNotificationCenter）。
///
/// 特性：
/// - nonactivatingPanel：不抢焦点，零权限
/// - 屏幕右上角，距 menubar/右边 16pt
/// - 默认 5s 自隐（`dismissDelay` 可测试注入 0.1s 加速）
/// - 重复 show：取消旧倒计时 + 替换内容 + 重新计时
/// - 多 Action 按钮 + X 关闭按钮
@MainActor
final class MarketHUD: MarketHUDDisplaying {

    static let shared = MarketHUD()

    /// HUD 上的按钮（label + handler 闭包）。
    ///
    /// handler 标 `@MainActor`：调用方（openSyncLog / openBuddyStore）确保主线程执行。
    struct Action {
        let label: String
        let handler: @MainActor () -> Void

        init(label: String, handler: @MainActor @escaping () -> Void) {
            self.label = label
            self.handler = handler
        }
    }

    /// 5s 自隐倒计时；测试可注入 0.1s 加速（B5 修复）。
    var dismissDelay: TimeInterval = 5.0

    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    /// 当前是否可见（暴露给单测）。
    var isVisible: Bool { panel?.isVisible ?? false }

    init() {}

    // MARK: - 公开 API

    func show(text: String, actions: [Action] = []) {
        // 取消旧倒计时（重复 show 重置）
        dismissTask?.cancel()

        let panel = ensurePanel()
        let hostingController = NSHostingController(
            rootView: HUDView(
                text: text,
                actions: actions,
                onDismiss: { [weak self] in self?.dismiss() }
            )
        )
        panel.contentViewController = hostingController
        positionPanel(panel)
        panel.orderFrontRegardless()

        let delay = dismissDelay
        dismissTask = Task { [weak self] in
            let nanos = UInt64(max(0, delay) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            if Task.isCancelled { return }
            await MainActor.run { self?.dismiss() }
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        panel?.orderOut(nil)
    }

    // MARK: - 私有

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 64),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        self.panel = panel
        return panel
    }

    private func positionPanel(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let margin: CGFloat = 16
        let width = panel.frame.width
        let height = panel.frame.height
        let x = visible.maxX - width - margin
        let y = visible.maxY - height - margin
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - SwiftUI HUDView

private struct HUDView: View {
    let text: String
    let actions: [MarketHUD.Action]
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox.fill")
                .foregroundStyle(.tint)
            Text(text)
                .font(.system(size: 13))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                Button(action.label) {
                    action.handler()
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}
