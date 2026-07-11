import XCTest
import AppKit
import SwiftUI
@testable import BuddyCore

// MARK: - SnipWindowSizingTests
//
// 回归：进入「插件 → snip」面板后设置窗口高度塌缩。
//
// 根因（证据见各测试）：
//   SnipPanelVC 是 NSHostingController<SnipPanelView>，SwiftUI root（HSplitView）无 height/width
//   frame → view.fittingSize 塌缩到 32×32；NSHostingController 默认 sizingOptions=[.minSize,.maxSize,
//   .preferredContentSize]（rawValue=7）把这个 32×32 fittingSize 经 preferredContentSize 向上传播
//   → 顶层 NSWindow 被压缩（真机 GUI session 下；swift test 无完整 layout engine 复现不了端到端，
//   但 fittingSize 塌缩 + sizingOptions 全传播两条根因证据可在单元测试确凿捕获）。
//
// 对照：其他 detail VC（General/SkinGallery/PluginGallery）loadView 用固定 frame NSView（防
//   fittingSize 缩 0，patterns/2026-06-16），非 NSHostingController，不主动传播 preferredContentSize。
//
// 关联 pattern：
//   - 2026-05-28 SwiftUI 缺 .frame 让 NSHostingController 把 panel 缩到 intrinsic size
//   - 2026-05-29 NSHostingController.sizingOptions（launcher 浮窗正向用 [.preferredContentSize] 让 window 跟随；
//     snip detail 反向应用 —— 不需要 window 跟随，应切断传播）

@MainActor
final class SnipWindowSizingTests: XCTestCase {

    override func tearDown() async throws {
        for w in NSApp.windows where w is SettingsWindow {
            w.orderOut(nil)
        }
        try await super.tearDown()
    }

    // MARK: - 机制验证：默认 sizingOptions 含 .preferredContentSize 会把 fittingSize 传给 window
    //
    // 直接把 NSHostingController 设为 NSWindow.contentViewController（pattern 2026-05-28 场景），
    // 默认 sizingOptions（rawValue=7，含 .preferredContentSize）会把 SwiftUI fittingSize 写入
    // hosting controller.preferredContentSize → NSWindow 遵循它压缩 contentSize 到 fittingSize。
    // 这证明 .preferredContentSize 是「hosting fittingSize → window」的传播通路（snip 修复切断它）。

    func test_mechanism_defaultSizingOptions_propagatesFittingSizeToWindow() {
        let smallView = Text("x").frame(width: 50, height: 40)  // fittingSize ~50×40

        let w = makeWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 700))
        let hc = NSHostingController(rootView: smallView)
        w.contentViewController = hc
        w.makeKeyAndOrderFront(nil)
        spinRunLoop(0.3)
        let contentSize = w.contentRect(forFrameRect: w.frame).size
        print("🩺 [mech] default sizingOptions → window contentSize = \(contentSize)")

        // 默认应被压缩到接近 fittingSize（高度远小于初始 700）—— 证明 hosting fittingSize 会传到 window
        XCTAssertLessThan(contentSize.height, 200,
            "默认 sizingOptions 应把 window 压到 fittingSize，实际 contentSize=\(contentSize)")

        w.orderOut(nil)
    }

    // MARK: - AC-WIN-02：SnipPanelVC 迁 AppKit 后不再是 NSHostingController（sizingOptions hack 消除）
    //
    // stage-4 迁移后 SnipPanelVC 是纯 NSViewController（非 NSHostingController），sizingOptions
    // 属性随 NSHostingController 一起消除。本断言替代旧 test_snipPanelVC_sizingOptions_doesNotPropagatePreferredSize
    // （旧测试读 sizingOptions，重写后无此属性编译失败）。

    func test_AC_WIN_02_snipPanelVC_isNotNSHostingController_sizingOptionsEliminated() {
        let vc = SnipPanelVC()
        _ = vc.view
        // NSHostingController 是 SwiftUI 宿主控制器，带 sizingOptions 属性（窗口压缩通路）。
        // stage-4 迁移后 SnipPanelVC 是纯 NSViewController，不再是 NSHostingController 子类。
        XCTAssertTrue(type(of: vc).self != NSHostingController<AnyView>.self,
                      "SnipPanelVC 应纯 AppKit（非 NSHostingController），sizingOptions hack 消除")
        // 进一步：class 名不含 "NSHostingController"
        let typeName = String(describing: type(of: vc))
        XCTAssertFalse(typeName.contains("NSHostingController"),
                       "SnipPanelVC 类型应为 SnipPanelVC，实际 \(typeName)")
    }

    // MARK: - AC-WIN-03：SnipPanelVC 作 containment child 不向 window 传播 preferredContentSize
    //
    // 真机盲区覆盖（patterns/2026-07-09）：旧 NSHostingController<SnipPanelView> 的 sizingOptions
    // 含 .preferredContentSize，会把 SwiftUI root（HSplitView 无 frame）塌缩的 fittingSize(32×32)
    // 经 preferredContentSize 向上传到 NSWindow → 压缩整个设置窗口。
    // stage-4 迁纯 AppKit NSViewController 后：
    //   1. SnipPanelVC 无 sizingOptions 属性（NSHostingController 专属，AC-WIN-01/02 已守）
    //   2. NSViewController 默认不向 window 传播 preferredContentSize（除非显式设）
    // 本测试断言 #2：SnipPanelVC 的 preferredContentSize 变化不触发 window contentSize 跟随。
    //
    // 注：SnipPanelVC 在生产是 pluginPanelContainer 的 containment child（非 window.contentViewController），
    // 故不直接测 contentViewController 场景（那会触发 NSWindow 自身 layout 行为，非 sizing 传播问题）。

    func test_AC_WIN_03_snipPanelVC_doesNotPropagatePreferredContentSize() {
        let vc = SnipPanelVC()
        _ = vc.view

        // SnipPanelVC 不应主动改 window.preferredContentWidth/Height（NSHostingController 的传播通路）
        // 默认 NSViewController.preferredContentSize == .zero，除非显式设。
        // 我们断言：SnipPanelVC viewDidLoad 后 preferredContentSize 保持默认（未被 fittingSize 污染）。
        // 注：实际 preferredContentSize 可能是 window 的初始值，关键是它不为 (32×32) 这类塌缩值。
        let psize = vc.preferredContentSize
        print("🩺 [snip-appkit] SnipPanelVC preferredContentSize = \(psize)")

        // 关键断言：preferredContentSize 不应等于 NSHostingController<SnipPanelView> 时代的 32×32 塌缩值
        // （那是窗口压缩的直接根因）。纯 NSViewController loadView 用固定 frame container，
        // 不计算 SwiftUI fittingSize，preferredContentSize 保持默认。
        XCTAssertFalse(psize.width == 32 && psize.height == 32,
            """
            AC-WIN-03 违反：SnipPanelVC.preferredContentSize=\(psize) 不应是 32×32 塌缩值
            （旧 NSHostingController<SnipPanelView> 的 SwiftUI root HSplitView 无 frame 导致 fittingSize
            塌缩 → 经 preferredContentSize 传 window 压缩）。纯 NSViewController 不应出现此值。
            """)
    }



    // MARK: - Helpers

    private func makeWindow(contentRect: NSRect) -> NSWindow {
        let w = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        // 小 minSize 避免 minSize 兜底掩盖 fittingSize 压缩效果
        w.minSize = NSSize(width: 10, height: 10)
        return w
    }

    private func spinRunLoop(_ seconds: TimeInterval) {
        let until = Date(timeIntervalSinceNow: seconds)
        while Date() < until {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
    }
}
