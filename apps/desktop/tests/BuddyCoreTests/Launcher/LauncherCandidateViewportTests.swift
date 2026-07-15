import XCTest
@testable import BuddyCore

// MARK: - LauncherCandidateViewportTests
//
// 蓝队单元测试：候选可视行数上限 candidateVisibleMax=8（混合阈值 T=8）
//
// 覆盖契约：
//   C-VIEWPORT-THRESHOLD：candidateVisibleMax == 8
//   C-HEIGHT-CONSISTENCY：panelHeight 与候选 ScrollView .frame(height:) 均用
//                         min(count, candidateVisibleMax) * candidateRowHeight
//   C-GENERIC-SCOPE：lastRoute(candidateCount) 不从 panelHeight 分配高度（I3）
//   C-ROW-HEIGHT-CONST：禁字面量 5/8/44，统一常量
//
// 场景映射（state.md 验收场景）：
//   场景1（8 候选全展示）/ 场景3（12 候选封顶 8）/ 场景7（边界 5/8/9）
//   / 场景9（动态变化自适应）/ I3（lastRoute 不计高）

final class LauncherCandidateViewportTests: XCTestCase {

    // MARK: - C-VIEWPORT-THRESHOLD：常量存在且 == 8

    /// candidateVisibleMax 必须 == 8（混合阈值 T=8，≤8 全展示、>8 封顶 8 行+滚动）
    func test_C_VIEWPORT_THRESHOLD_candidateVisibleMax_is8() {
        XCTAssertEqual(
            LauncherConstants.candidateVisibleMax,
            8,
            "candidateVisibleMax 必须 == 8（混合阈值 T=8：≤8 全展示、>8 封顶 8 行+滚动）"
        )
    }

    /// 区分语义边界：candidateVisibleMax=8 与 builtinActionsLimit=8/appSearchLimit=8 同值不同义
    func test_candidateVisibleMax_semantic_independence_from_other_eights() {
        // 同值（都 8）但语义独立：candidateVisibleMax = 可视行数上限（渲染层）
        // builtinActionsLimit = 内置插件候选全局截断（数据层）
        // appSearchLimit = 单次 App 搜索返回上限（数据层）
        XCTAssertEqual(LauncherConstants.candidateVisibleMax, LauncherConstants.builtinActionsLimit)
        XCTAssertEqual(LauncherConstants.candidateVisibleMax, LauncherConstants.appSearchLimit)
        // 三者都是 8，但分别独立定义（非互相引用）
    }

    // MARK: - 场景1 / 场景9.P1：pluginCandidateCount 8 全展示（≤8 自适应）

    /// 8 个 pluginCandidates → 面板高度 == inputH + 8 行高（无封顶、无滚动）
    func test_scenario1_pluginCandidate_8_fullDisplay() {
        let h = LauncherInputView.panelHeight(
            candidateCount: 0,
            hasSelected: false,
            outputHeight: 0,
            hasFooter: false,
            instantCount: 0,
            pluginCandidateCount: 8,
            commandRouteCount: 0
        )
        let expected = LauncherConstants.inputHeight
            + CGFloat(8) * LauncherConstants.candidateRowHeight
        XCTAssertEqual(h, expected, accuracy: 0.001,
                       "8 候选应全展示 8 行（≤8 自适应），不封顶")
    }

    /// 5 个 pluginCandidates → 面板高度 == inputH + 5 行高（场景7.P1 边界）
    func test_scenario7_pluginCandidate_5_fullDisplay() {
        let h = LauncherInputView.panelHeight(
            candidateCount: 0,
            hasSelected: false,
            outputHeight: 0,
            hasFooter: false,
            instantCount: 0,
            pluginCandidateCount: 5,
            commandRouteCount: 0
        )
        let expected = LauncherConstants.inputHeight
            + CGFloat(5) * LauncherConstants.candidateRowHeight
        XCTAssertEqual(h, expected, accuracy: 0.001,
                       "5 候选应全展示 5 行（≤8），不封顶")
    }

    // MARK: - 场景3 / 场景9.P2：pluginCandidateCount 12 封顶 8

    /// 12 个 pluginCandidates → 面板高度封顶 8 行（== 8 行高度，不 == 12 行）
    func test_scenario3_pluginCandidate_12_cappedAt8() {
        let h = LauncherInputView.panelHeight(
            candidateCount: 0,
            hasSelected: false,
            outputHeight: 0,
            hasFooter: false,
            instantCount: 0,
            pluginCandidateCount: 12,
            commandRouteCount: 0
        )
        let expected = LauncherConstants.inputHeight
            + CGFloat(LauncherConstants.candidateVisibleMax) * LauncherConstants.candidateRowHeight
        XCTAssertEqual(h, expected, accuracy: 0.001,
                       "12 候选应封顶 8 行高度（>8 封顶 + 滚动）")
        XCTAssertLessThan(h, LauncherConstants.inputHeight
                          + CGFloat(12) * LauncherConstants.candidateRowHeight,
                          "12 候选面板高度必须 < 12 行高度（被封顶）")
    }

    /// 9 个 pluginCandidates → 封顶 8 行（场景7.P3 边界，恰好 >8）
    func test_scenario7_pluginCandidate_9_cappedAt8() {
        let h = LauncherInputView.panelHeight(
            candidateCount: 0,
            hasSelected: false,
            outputHeight: 0,
            hasFooter: false,
            instantCount: 0,
            pluginCandidateCount: 9,
            commandRouteCount: 0
        )
        let expected = LauncherConstants.inputHeight
            + CGFloat(LauncherConstants.candidateVisibleMax) * LauncherConstants.candidateRowHeight
        XCTAssertEqual(h, expected, accuracy: 0.001,
                       "9 候选应封顶 8 行（恰好 >8 阈值）")
    }

    // MARK: - 场景7.P2：8 候选恰好阈值全展示（== 8，no-op）

    /// 恰好 8 个 → 全展示，面板高度 == 8 行（边界：== 阈值不封顶）
    func test_scenario7_pluginCandidate_exactly8_noCap() {
        let h8 = LauncherInputView.panelHeight(
            candidateCount: 0, hasSelected: false, outputHeight: 0,
            pluginCandidateCount: 8, commandRouteCount: 0
        )
        let h9 = LauncherInputView.panelHeight(
            candidateCount: 0, hasSelected: false, outputHeight: 0,
            pluginCandidateCount: 9, commandRouteCount: 0
        )
        XCTAssertEqual(h8, h9, accuracy: 0.001,
                       "8 与 9 候选面板高度应相等（8 全展示 == 9 封顶 8）")
    }

    // MARK: - 场景9：候选数动态变化面板高度自适应

    /// 3 → 8 → 12：高度递增到 8 行封顶后不变
    func test_scenario9_dynamicCandidateCount_adapts() {
        let h3 = LauncherInputView.panelHeight(
            candidateCount: 0, hasSelected: false, outputHeight: 0,
            pluginCandidateCount: 3, commandRouteCount: 0)
        let h8 = LauncherInputView.panelHeight(
            candidateCount: 0, hasSelected: false, outputHeight: 0,
            pluginCandidateCount: 8, commandRouteCount: 0)
        let h12 = LauncherInputView.panelHeight(
            candidateCount: 0, hasSelected: false, outputHeight: 0,
            pluginCandidateCount: 12, commandRouteCount: 0)

        // 场景9.P1: 3→8 高度递增
        XCTAssertGreaterThan(h8, h3, "候选数 3→8 面板高度应递增")
        // 场景9.P2: 8→12 封顶不变
        XCTAssertEqual(h8, h12, accuracy: 0.001, "候选数 8→12 面板高度应封顶不变")
    }

    // MARK: - 空态

    /// 0 候选 → 空态，面板高度 == inputH（+ footer 可选）
    func test_scenario_empty_0candidates_inputOnly() {
        let h = LauncherInputView.panelHeight(
            candidateCount: 0, hasSelected: false, outputHeight: 0,
            hasFooter: false, instantCount: 0,
            pluginCandidateCount: 0, commandRouteCount: 0
        )
        XCTAssertEqual(h, LauncherConstants.inputHeight, accuracy: 0.001,
                       "0 候选空态面板高度 == inputHeight")
    }

    // MARK: - I3：lastRoute(candidateCount) 不计入 panelHeight 高度

    /// I3 核心断言：candidateCount（= lastRouteCandidates，不渲染为可见列表）
    /// 不应从 panelHeight 分配高度——避免 >8 时空白行。
    /// 即 candidateCount=20 + pluginCandidateCount=0 → 空态高度（不分配 20 行高度）
    func test_I3_lastRouteCandidateCount_notCounted_height() {
        let hWithLastRouteOnly = LauncherInputView.panelHeight(
            candidateCount: 20,          // lastRouteCandidates，不渲染
            hasSelected: false,
            outputHeight: 0,
            hasFooter: false,
            instantCount: 0,
            pluginCandidateCount: 0,     // 无渲染候选
            commandRouteCount: 0
        )
        let hEmpty = LauncherInputView.panelHeight(
            candidateCount: 0, hasSelected: false, outputHeight: 0,
            pluginCandidateCount: 0, commandRouteCount: 0
        )
        XCTAssertEqual(hWithLastRouteOnly, hEmpty, accuracy: 0.001,
                       "I3: lastRouteCandidates(candidateCount) 不渲染为可见列表，"
                       + "不得从 panelHeight 分配高度（否则 >8 时空白行）")
    }

    /// I3 mutation 探针：若恢复 candidateCount 计高，
    /// candidateCount=20 会让面板撑出 8 行（封顶）而非空态。
    /// 此处断言 candidateCount 独立不影响高度（pluginCandidateCount 才影响）。
    func test_I3_mutation_candidateCount_restored_would_inflate() {
        // 正确行为：candidateCount=20 + plugin=0 → 空态
        let correct = LauncherInputView.panelHeight(
            candidateCount: 20, hasSelected: false, outputHeight: 0,
            pluginCandidateCount: 0, commandRouteCount: 0)
        XCTAssertEqual(correct, LauncherConstants.inputHeight, accuracy: 0.001)

        // 对照：pluginCandidateCount=20 → 封顶 8 行（应 > 空态）
        let withPlugin = LauncherInputView.panelHeight(
            candidateCount: 0, hasSelected: false, outputHeight: 0,
            pluginCandidateCount: 20, commandRouteCount: 0)
        XCTAssertGreaterThan(withPlugin, correct,
                             "pluginCandidateCount 计高，candidateCount(lastRoute) 不计")
    }

    // MARK: - commandRoute / instant 通道同样 cap 8（C-GENERIC-SCOPE）

    /// commandRoute 10 候选 → 封顶 8 行（场景6.P1）
    func test_scenario6_commandRoute_10_cappedAt8() {
        let h = LauncherInputView.panelHeight(
            candidateCount: 0, hasSelected: false, outputHeight: 0,
            instantCount: 0, pluginCandidateCount: 0,
            commandRouteCount: 10
        )
        let expected = LauncherConstants.inputHeight
            + CGFloat(LauncherConstants.candidateVisibleMax) * LauncherConstants.candidateRowHeight
        XCTAssertEqual(h, expected, accuracy: 0.001,
                       "commandRoute 10 候选应封顶 8 行")
    }

    /// instant 7 候选 → 全展示 7 行（场景5.P1，≤8）
    func test_scenario5_instant_7_fullDisplay() {
        let h = LauncherInputView.panelHeight(
            candidateCount: 0, hasSelected: false, outputHeight: 0,
            instantCount: 7, pluginCandidateCount: 0,
            commandRouteCount: 0
        )
        let expected = LauncherConstants.inputHeight
            + CGFloat(7) * LauncherConstants.candidateRowHeight
        XCTAssertEqual(h, expected, accuracy: 0.001,
                       "instant 7 候选应全展示 7 行（≤8）")
    }

    /// commandRoute + instant 并存态叠加（两区各封顶 8）
    func test_combined_commandRoute_plus_instant_summed() {
        let h = LauncherInputView.panelHeight(
            candidateCount: 0, hasSelected: false, outputHeight: 0,
            instantCount: 10,           // 封顶 8
            pluginCandidateCount: 0,
            commandRouteCount: 10       // 封顶 8
        )
        let expected = LauncherConstants.inputHeight
            + CGFloat(LauncherConstants.candidateVisibleMax) * LauncherConstants.candidateRowHeight  // cmd 8
            + CGFloat(LauncherConstants.candidateVisibleMax) * LauncherConstants.candidateRowHeight  // instant 8
        XCTAssertEqual(h, expected, accuracy: 0.001,
                       "commandRoute + instant 并存各封顶 8 后叠加")
    }

    // MARK: - C-ROW-HEIGHT-CONST：output 态 pluginCandidateExtra 也 cap 8

    /// output 态下 pluginCandidateCount=12 → pluginCandidateExtra 封顶 8（非旧 5）
    func test_outputState_pluginCandidate_cappedAt8() {
        let h = LauncherInputView.panelHeight(
            candidateCount: 0, hasSelected: false,
            outputHeight: 100,
            hasFooter: false, instantCount: 0,
            pluginCandidateCount: 12, commandRouteCount: 0
        )
        // output 态：inputH + outputHeight + pluginCandidateExtra(封顶 8)
        let expected = LauncherConstants.inputHeight
            + CGFloat(100)
            + CGFloat(LauncherConstants.candidateVisibleMax) * LauncherConstants.candidateRowHeight
        XCTAssertEqual(h, expected, accuracy: 0.001,
                       "output 态 pluginCandidateExtra 也应封顶 8（非旧 5）")
    }
}
