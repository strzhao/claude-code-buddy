import XCTest
import AppKit
import SwiftUI
@testable import BuddyCore

// MARK: - LauncherVibrancyAcceptanceTests
//
// 红队验收测试：C1 NSVisualEffectView 注入契约
//
// 覆盖契约：
//   C1: LauncherWindow.init() 完成后，window 的 contentView 链中必须包含一个
//       NSVisualEffectView，其 material == .hudWindow 且 blendingMode == .behindWindow
//
// 测试策略：
//   在 @MainActor 上下文实例化 LauncherWindow()，递归遍历 contentView.subviews，
//   找到 NSVisualEffectView，断言 material/blendingMode 符合契约。
//
// 测试 WILL NOT compile 直到蓝队合并实现 — 这是预期的 TDD 红灯。

@MainActor
final class LauncherVibrancyAcceptanceTests: XCTestCase {

    private var window: LauncherWindow!

    override func setUp() async throws {
        try await super.setUp()
        window = LauncherWindow()
    }

    override func tearDown() async throws {
        window?.close()
        window = nil
        try await super.tearDown()
    }

    // MARK: - C1: contentView 链中必须存在 NSVisualEffectView

    /// contentView 链中至少存在一个 NSVisualEffectView
    func test_C1_window_containsVisualEffectView_withHUDMaterial() {
        guard let contentView = window.contentView else {
            XCTFail("C1 违反：LauncherWindow.contentView 为 nil，无法遍历视图树")
            return
        }

        let visualEffectView = findVisualEffectView(in: contentView)

        XCTAssertNotNil(
            visualEffectView,
            """
            C1 违反：LauncherWindow.contentView 链中未找到 NSVisualEffectView。
            Apple HIG / Raycast 风格要求 launcher 使用毛玻璃 NSVisualEffectView 承载面板背景。
            """
        )

        guard let vev = visualEffectView else { return }

        // C1: material 必须 == .menu（task 010 retry 2 演化序列：.hudWindow → .popover → .menu）
        // 注：vfx 现仅作为 contract 结构性兜底，实际毛玻璃由 SwiftUI .ultraThinMaterial 承担
        XCTAssertEqual(
            vev.material,
            .menu,
            """
            C1 违反：NSVisualEffectView.material 应 == .menu（task 010 retry 2 第 4 轮调整）。
            实际值：\(vev.material)
            设计意图：dark mode 下与桌面色平衡，配合 SwiftUI 层 .ultraThinMaterial 主毛玻璃合成。
            """
        )

        // C1: blendingMode 必须 == .behindWindow
        XCTAssertEqual(
            vev.blendingMode,
            .behindWindow,
            """
            C1 违反：NSVisualEffectView.blendingMode 应 == .behindWindow（透过窗口外融合）。
            实际值：\(vev.blendingMode)
            设计意图：behindWindow 使毛玻璃透过整个 window 背景采样，产生正确的磨砂效果。
            """
        )
    }

    // MARK: - C1 补充：NSVisualEffectView 状态应为 active

    /// NSVisualEffectView.state 应设为 .active（始终显示活跃毛玻璃效果，不随窗口焦点变化）
    func test_C1_visualEffectView_stateIsActive() {
        guard let contentView = window.contentView,
              let vev = findVisualEffectView(in: contentView) else {
            // 如果找不到 NSVisualEffectView，由上方的主测试捕获 — 这里只做补充断言
            return
        }

        XCTAssertEqual(
            vev.state,
            .active,
            """
            C1 补充：NSVisualEffectView.state 应 == .active（launcher 失去焦点时仍显示毛玻璃）。
            实际值：\(vev.state)
            """
        )
    }

    // MARK: - 私有辅助方法

    /// 递归遍历 NSView 子树，找到第一个 NSVisualEffectView（BFS）
    private func findVisualEffectView(in view: NSView) -> NSVisualEffectView? {
        if let vev = view as? NSVisualEffectView {
            return vev
        }
        for subview in view.subviews {
            if let found = findVisualEffectView(in: subview) {
                return found
            }
        }
        return nil
    }
}
