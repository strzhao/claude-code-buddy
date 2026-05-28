import XCTest
@testable import BuddyCore

// MARK: - LauncherPanelHeightAcceptanceTests
//
// 红队验收测试：C3 + C7 panelHeight 纯函数行为（7 个 case 全覆盖）
//
// 覆盖契约：
//   C3: 三态自适应面板高度公式
//   C7: panelHeight(candidateCount:hasSelected:outputHeight:) -> CGFloat 的 7 个具体数值
//
// C7 表格：
//   | candidateCount | hasSelected | outputHeight | 期望 |
//   | 0              | false       | 0            | 90   |
//   | 3              | false       | 0            | 222  |
//   | 5              | true        | 0            | 310  |
//   | 8              | true        | 0            | 310  (capped at 5)  |
//   | 1              | true        | 200          | 334  |
//   | 1              | true        | 500          | 534  (output capped at 400) |
//   | 0              | false       | 300          | 390  |
//
// 函数签名必须为：static func panelHeight(candidateCount:hasSelected:outputHeight:) -> CGFloat
// 位于 LauncherInputView（非扩展，不是 free function）
//
// 测试 WILL NOT compile 直到蓝队合并实现 — 这是预期的 TDD 红灯。

final class LauncherPanelHeightAcceptanceTests: XCTestCase {

    // MARK: - C7-1: 空态 (0 candidates, no output) → 90

    /// 空态：无候选、无选中、无输出 → 面板高度 == 90
    func test_C7_case1_empty_returns90() {
        let height = LauncherInputView.panelHeight(
            candidateCount: 0,
            hasSelected: false,
            outputHeight: 0
        )
        XCTAssertEqual(
            height,
            90.0,
            accuracy: 0.001,
            "空态（candidateCount=0, hasSelected=false, outputHeight=0）期望高度 == 90"
        )
    }

    // MARK: - C7-2: 3 候选，无输出 → 90 + 3×44 = 222

    /// 3 个候选（未选中），无输出 → 90 + 132 = 222
    func test_C7_case2_threeCandidates_returns222() {
        let height = LauncherInputView.panelHeight(
            candidateCount: 3,
            hasSelected: false,
            outputHeight: 0
        )
        XCTAssertEqual(
            height,
            222.0,
            accuracy: 0.001,
            "3 候选无输出期望 == 90 + 3×44 = 222，实际 \(height)"
        )
    }

    // MARK: - C7-3: 5 候选，有选中，无输出 → 90 + 5×44 = 310

    /// 5 个候选（选中 1 个），无输出 → 90 + 220 = 310
    func test_C7_case3_fiveCandidates_hasSelected_returns310() {
        let height = LauncherInputView.panelHeight(
            candidateCount: 5,
            hasSelected: true,
            outputHeight: 0
        )
        XCTAssertEqual(
            height,
            310.0,
            accuracy: 0.001,
            "5 候选有选中无输出期望 == 90 + 5×44 = 310，实际 \(height)"
        )
    }

    // MARK: - C7-4: 8 候选（超上限），有选中，无输出 → 90 + 5×44 = 310（capped）

    /// 8 个候选超过 routerMaxCandidates=5 上限，capped → 90 + 220 = 310
    func test_C7_case4_eightCandidates_cappedAt5_returns310() {
        let height = LauncherInputView.panelHeight(
            candidateCount: 8,
            hasSelected: true,
            outputHeight: 0
        )
        XCTAssertEqual(
            height,
            310.0,
            accuracy: 0.001,
            "8 候选应 capped at 5，期望 == 90 + 5×44 = 310，实际 \(height)（未 cap 则返回 90+8×44=442）"
        )
    }

    // MARK: - C7-5: 1 候选 + 有选中 + 输出 200 → 90 + 44 + 200 = 334

    /// 有输出时：90 + (hasSelected ? 44 : 0) + min(outputHeight, 400)
    /// 1 候选选中 + 输出 200 → 90 + 44 + 200 = 334
    func test_C7_case5_oneCandidate_hasSelected_output200_returns334() {
        let height = LauncherInputView.panelHeight(
            candidateCount: 1,
            hasSelected: true,
            outputHeight: 200
        )
        XCTAssertEqual(
            height,
            334.0,
            accuracy: 0.001,
            "1 候选选中 + 输出 200 期望 == 90 + 44 + 200 = 334，实际 \(height)"
        )
    }

    // MARK: - C7-6: 1 候选 + 有选中 + 输出 500（超上限）→ 90 + 44 + 400 = 534（capped）

    /// 输出高度 capped at 400：90 + 44 + min(500, 400) = 90 + 44 + 400 = 534
    func test_C7_case6_oneCandidate_hasSelected_output500_cappedReturns534() {
        let height = LauncherInputView.panelHeight(
            candidateCount: 1,
            hasSelected: true,
            outputHeight: 500
        )
        XCTAssertEqual(
            height,
            534.0,
            accuracy: 0.001,
            "输出 500 应 capped at 400，期望 == 90 + 44 + 400 = 534，实际 \(height)（未 cap 则 634）"
        )
    }

    // MARK: - C7-7: 0 候选 + 无选中 + 输出 300 → 90 + 0 + 300 = 390

    /// 无候选无选中但有输出：90 + 0 + 300 = 390
    func test_C7_case7_noCandidates_noSelected_output300_returns390() {
        let height = LauncherInputView.panelHeight(
            candidateCount: 0,
            hasSelected: false,
            outputHeight: 300
        )
        XCTAssertEqual(
            height,
            390.0,
            accuracy: 0.001,
            "无候选无选中输出 300 期望 == 90 + 0 + 300 = 390，实际 \(height)"
        )
    }

    // MARK: - C3: 边界行为补充验证

    /// 输出 400 恰好在上限边界（不应 capped）→ 90 + 0 + 400 = 490
    func test_C3_outputHeight_exactlyAt400Limit_returns490() {
        let height = LauncherInputView.panelHeight(
            candidateCount: 0,
            hasSelected: false,
            outputHeight: 400
        )
        XCTAssertEqual(
            height,
            490.0,
            accuracy: 0.001,
            "输出恰好 400（上限边界）期望 == 90 + 400 = 490，实际 \(height)"
        )
    }

    /// 输出 401 超限一格（应 capped at 400）→ 90 + 400 = 490
    func test_C3_outputHeight_oneOverLimit_stillReturns490() {
        let height = LauncherInputView.panelHeight(
            candidateCount: 0,
            hasSelected: false,
            outputHeight: 401
        )
        XCTAssertEqual(
            height,
            490.0,
            accuracy: 0.001,
            "输出 401（超限 1）应 capped，期望 == 90 + 400 = 490，实际 \(height)"
        )
    }

    /// outputHeight > 0 时，candidateCount 只通过 hasSelected 影响高度（不是 candidateCount×44）
    /// 验证三态逻辑：output 态优先，不走候选态公式
    func test_C3_outputMode_ignoresCandidateCount_usesHasSelected() {
        // 5 候选有选中有输出 → 走输出态而非候选态
        let outputModeHeight = LauncherInputView.panelHeight(
            candidateCount: 5,
            hasSelected: true,
            outputHeight: 100
        )
        // 期望：90 + 44 + 100 = 234（输出态）而不是 90 + 5×44 = 310（候选态）
        XCTAssertEqual(
            outputModeHeight,
            234.0,
            accuracy: 0.001,
            "outputHeight > 0 时应走输出态公式（90 + 44 + 100），不走候选态（90 + 5×44），实际 \(outputModeHeight)"
        )
    }

    /// panelHeight 必须是 static func（可在无实例下调用，红队直接调用即证明）
    func test_C3_panelHeight_isStaticFunc_callableWithoutInstance() {
        // 能编译通过 + 运行到这里即证明 panelHeight 是 static（否则编译报错）
        let result = LauncherInputView.panelHeight(candidateCount: 0, hasSelected: false, outputHeight: 0)
        XCTAssertGreaterThan(result, 0, "static panelHeight 应返回正值")
    }
}
