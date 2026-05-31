import SwiftUI
import AppKit

/// 毛玻璃背景：NSVisualEffectView 的 SwiftUI 包装。
///
/// 为什么不用 `.ultraThinMaterial`：SwiftUI Material 的 light/dark 解析依赖
/// `@Environment(\.colorScheme)`，而该 environment 在 NSPanel + `hidesOnDeactivate`
/// 浮窗里传播**不可靠**（见 .autopilot/knowledge 2026-05-28 条目）—— 系统切到浅色时
/// material 仍可能停留在深色，导致毛玻璃发灰、与跟随 `effectiveAppearance` 的
/// 颜色 token（如白色 surface）错配，浅色模式整块渲染异常。
///
/// `NSVisualEffectView` 由 AppKit 直接按 `effectiveAppearance` 求值，天然跟随真实
/// 系统外观，绕开 SwiftUI environment 的不可靠传播。作为 SwiftUI `.background(...)`
/// 使用（而非手动插入 NSHostingView subview），可被正确合成、不会被内容覆盖
/// （对照 2026-05-29 条目的覆盖问题）。
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .menu
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        // appearance = nil → 跟随窗口/系统 effectiveAppearance（不锁死 light/dark）
        view.appearance = nil
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = .active
        nsView.appearance = nil
    }
}
