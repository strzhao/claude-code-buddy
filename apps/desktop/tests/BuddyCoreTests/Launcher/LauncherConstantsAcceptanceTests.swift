import XCTest
@testable import BuddyCore

// MARK: - LauncherConstantsAcceptanceTests (UI Redesign)
//
// 红队验收测试：C2 LauncherConstants 数值契约（UI 重设计 task 002 新增常量）
//
// 覆盖契约：
//   C2-A: windowWidth == 720
//   C2-B: windowMinHeight == 90
//   C2-C: inputFontSize == 28
//   C2-D: inputPaddingH == 20
//   C2-E: inputPaddingV == 16
//   C2-F: candidateRowHeight == 44
//
// 注意：此文件专测 UI 重设计追加的常量（windowWidth 720 / candidateRowHeight 44 等）
//       旧常量（maxQueryLength / windowYRatio）由 LauncherHotkeyAcceptanceTests 覆盖。
// 测试 WILL NOT compile 直到蓝队合并实现 — 这是预期的 TDD 红灯。

final class LauncherConstantsUIAcceptanceTests: XCTestCase {

    // MARK: - C2-A: windowWidth == 720

    /// windowWidth 必须从 600 升级到 720（Alfred 标准面板宽度）
    func test_C2A_windowWidth_is720() {
        XCTAssertEqual(
            LauncherConstants.windowWidth,
            720.0,
            accuracy: 0.001,
            "LauncherConstants.windowWidth 必须 == 720（Alfred 标准面板宽度，UI 重设计契约）"
        )
    }

    // MARK: - C2-B: windowMinHeight == 90

    /// windowMinHeight 必须从 80 升级到 90（空态高度）
    func test_C2B_windowMinHeight_is90() {
        XCTAssertEqual(
            LauncherConstants.windowMinHeight,
            90.0,
            accuracy: 0.001,
            "LauncherConstants.windowMinHeight 必须 == 90（空态高度 = 输入区 64 + 上下 padding 13×2）"
        )
    }

    // MARK: - C2-C: inputFontSize == 28

    /// 输入框字号必须 == 28（大字体，Alfred 级可用性）
    func test_C2C_inputFontSize_is28() {
        XCTAssertEqual(
            LauncherConstants.inputFontSize,
            28.0,
            accuracy: 0.001,
            "LauncherConstants.inputFontSize 必须 == 28（从旧值 18 升级，Alfred 级字号契约）"
        )
    }

    // MARK: - C2-D: inputPaddingH == 20

    /// 输入框水平 padding 必须 == 20
    func test_C2D_inputPaddingH_is20() {
        XCTAssertEqual(
            LauncherConstants.inputPaddingH,
            20.0,
            accuracy: 0.001,
            "LauncherConstants.inputPaddingH 必须 == 20（从旧值 12 升级）"
        )
    }

    // MARK: - C2-E: inputPaddingV == 16

    /// 输入框垂直 padding 必须 == 16
    func test_C2E_inputPaddingV_is16() {
        XCTAssertEqual(
            LauncherConstants.inputPaddingV,
            16.0,
            accuracy: 0.001,
            "LauncherConstants.inputPaddingV 必须 == 16（从旧值 8 升级）"
        )
    }

    // MARK: - C2-F: candidateRowHeight == 44

    /// 候选行高必须 == 44（新增常量，标准触摸友好尺寸）
    func test_C2F_candidateRowHeight_is44() {
        XCTAssertEqual(
            LauncherConstants.candidateRowHeight,
            44.0,
            accuracy: 0.001,
            "LauncherConstants.candidateRowHeight 必须 == 44（新增，标准候选行高）"
        )
    }

    // MARK: - 派生值一致性验证

    /// windowMaxHeight 的上限应与 C7 最大值 534 一致
    /// 90 + 44（1 候选）+ 400（输出上限）== 534
    func test_windowMaxHeight_is534_consistentWithC7Cap() {
        XCTAssertEqual(
            LauncherConstants.windowMaxHeight,
            534.0,
            accuracy: 0.001,
            "windowMaxHeight 应 == 534（= 90 + 44 + 400，与 C7 公式上限一致）"
        )
    }

    /// 常量几何约束：windowWidth > windowMinHeight（宽面板，非方形）
    func test_windowWidth_greaterThan_windowMinHeight() {
        XCTAssertGreaterThan(
            LauncherConstants.windowWidth,
            LauncherConstants.windowMinHeight,
            "windowWidth(\(LauncherConstants.windowWidth)) 应远大于 windowMinHeight(\(LauncherConstants.windowMinHeight))"
        )
    }

    /// 候选区高度上限 = 5 × 44 = 220，空态 90 + 220 == 310
    func test_maxCandidatesHeight_equals_5rows_x_44() {
        let maxCandidateRows = LauncherConstants.routerMaxCandidates
        let rowHeight = LauncherConstants.candidateRowHeight
        let expectedMaxCandidateHeight = CGFloat(maxCandidateRows) * rowHeight
        XCTAssertEqual(
            expectedMaxCandidateHeight,
            220.0,
            accuracy: 0.001,
            "5 × 44 == 220，候选区最大高度必须一致（routerMaxCandidates=5, candidateRowHeight=44）"
        )
    }
}
