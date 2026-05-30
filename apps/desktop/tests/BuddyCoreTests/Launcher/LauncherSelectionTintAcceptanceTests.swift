import XCTest
import AppKit
import SwiftUI
@testable import BuddyCore

// MARK: - LauncherSelectionTintAcceptanceTests
//
// 红队验收测试：C2 selectionTint alpha 上界契约
//
// 覆盖契约：
//   C2: LauncherTheme.selectionTint 在 light/dark 任一外观下，
//       转换为 NSColor 后 alpha component 必须 < 0.25（推荐 0.12/0.18）。
//
// 测试策略：
//   NSColor(LauncherTheme.selectionTint)，用
//   NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance 切换 light 上下文，
//   用 .darkAqua 切换 dark 上下文，读 alphaComponent 断言 < 0.25。
//
// 设计意图：selectionTint 是候选行选中背景色，需要足够透明（< 0.25 alpha）
// 以确保选中行不过于突兀，保持 Apple HIG 级别的克制视觉风格。
//
// 测试 WILL NOT compile 直到蓝队合并实现 — 这是预期的 TDD 红灯。

final class LauncherSelectionTintAcceptanceTests: XCTestCase {

    // MARK: - 辅助方法

    /// 在指定外观下读取 selectionTint 的 alpha component
    private func selectionTintAlpha(appearance: NSAppearance.Name) -> CGFloat {
        var alpha: CGFloat = 1.0
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            let nsColor = NSColor(LauncherTheme.selectionTint)
            // 转换到 sRGB 保证 alphaComponent 可读
            if let resolved = nsColor.usingColorSpace(.sRGB) {
                alpha = resolved.alphaComponent
            } else {
                alpha = nsColor.alphaComponent
            }
        }
        return alpha
    }

    // MARK: - C2: light 模式 selectionTint alpha < 0.25

    /// light 模式下 selectionTint 的 alpha 必须 < 0.25
    func test_C2_selectionTint_lightMode_alphaBelow025() {
        let alpha = selectionTintAlpha(appearance: .aqua)

        XCTAssertLessThan(
            alpha,
            0.25,
            """
            C2 违反（light 模式）：LauncherTheme.selectionTint 的 alpha 值必须 < 0.25。
            实际 alpha = \(alpha)
            设计意图：候选行选中背景应半透明（推荐 0.12～0.18），避免过于突兀。
            """
        )

        // 同时断言 alpha > 0（完全透明无法提供视觉反馈）
        XCTAssertGreaterThan(
            alpha,
            0.0,
            """
            C2 补充（light 模式）：selectionTint alpha 不应 == 0（完全透明无视觉反馈）。
            实际 alpha = \(alpha)
            """
        )
    }

    /// dark 模式下 selectionTint 的 alpha 必须 < 0.25
    func test_C2_selectionTint_darkMode_alphaBelow025() {
        let alpha = selectionTintAlpha(appearance: .darkAqua)

        XCTAssertLessThan(
            alpha,
            0.25,
            """
            C2 违反（dark 模式）：LauncherTheme.selectionTint 的 alpha 值必须 < 0.25。
            实际 alpha = \(alpha)
            设计意图：候选行选中背景应半透明（推荐 0.12～0.18），在暗色背景下同样克制。
            """
        )

        // 同时断言 alpha > 0（完全透明无法提供视觉反馈）
        XCTAssertGreaterThan(
            alpha,
            0.0,
            """
            C2 补充（dark 模式）：selectionTint alpha 不应 == 0（完全透明无视觉反馈）。
            实际 alpha = \(alpha)
            """
        )
    }

    // MARK: - C2 补充：selectionTint 属性编译时存在

    /// LauncherTheme.selectionTint 必须作为 Color 类型存在（编译即验证）
    func test_C2_selectionTint_propertyExists() {
        let _: Color = LauncherTheme.selectionTint
        // 编译通过即验证成功
    }

    // MARK: - C2 补充：light/dark 推荐范围（0.08 ～ 0.22）

    /// 推荐范围：alpha 在 0.08 和 0.22 之间（过低无视觉，过高侵入）
    func test_C2_selectionTint_lightMode_alphaInRecommendedRange() {
        let alpha = selectionTintAlpha(appearance: .aqua)

        // 推荐范围下界 0.08（低于此几乎不可见）
        XCTAssertGreaterThanOrEqual(
            alpha,
            0.08,
            """
            C2 推荐范围（light 模式）：selectionTint alpha 建议 >= 0.08（可见度下界）。
            实际 alpha = \(alpha)（此为设计建议，非硬性契约）
            """
        )
    }

    func test_C2_selectionTint_darkMode_alphaInRecommendedRange() {
        let alpha = selectionTintAlpha(appearance: .darkAqua)

        // 推荐范围下界 0.08
        XCTAssertGreaterThanOrEqual(
            alpha,
            0.08,
            """
            C2 推荐范围（dark 模式）：selectionTint alpha 建议 >= 0.08（可见度下界）。
            实际 alpha = \(alpha)（此为设计建议，非硬性契约）
            """
        )
    }
}
