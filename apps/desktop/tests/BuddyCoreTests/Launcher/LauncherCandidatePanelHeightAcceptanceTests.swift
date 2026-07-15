import XCTest
@testable import BuddyCore

// MARK: - LauncherCandidatePanelHeightAcceptanceTests
//
// 红队验收测试：launcher 候选列表视口阈值（混合阈值 T=8）panelHeight 纯函数谓词（det-machine）。
//
// 本文件覆盖（期望值逐字取自 state.md ## 验收场景 assert 列 + ## 契约规约）：
//   场景1.P1   ｜ snip 8 候选全展示 ｜ panelHeight == expectedHeightFor(8)（8 行非 5）
//   场景3.P1   ｜ 12 候选封顶 8 行 ｜ panelHeight == expectedHeightFor(8)
//   场景7.P1   ｜ count==5 全展示 ｜ panelHeight == expectedHeightFor(5)
//   场景7.P2   ｜ count==8 恰好阈值全展示 ｜ panelHeight == expectedHeightFor(8)
//   场景7.P3   ｜ count==9 封顶 8 ｜ panelHeight == expectedHeightFor(8)
//   场景9.P1   ｜ 3→8 自适应增高 ｜ panelHeight_at_8 > panelHeight_at_3 且 == expectedHeightFor(8)
//   场景9.P2   ｜ 8→12 封顶不变 ｜ panelHeight_at_12 == panelHeight_at_8 == expectedHeightFor(8)
//
// 契约逐字一致（## 契约规约）：
//   C-VIEWPORT-THRESHOLD  candidateVisibleMax == 8（LauncherConstants 新增）；panelHeight 用 min(count, candidateVisibleMax) * candidateRowHeight
//   C-ROW-HEIGHT-CONST    panelHeight 禁用字面量 44/5/8，统一 candidateRowHeight / candidateVisibleMax
//   C-GENERIC-SCOPE       3 渲染区（pluginCandidate/commandRoute/instant）均 cap 8；lastRoute(candidateCount) 不渲染→不计高度
//
// 红队红线：
//   - 不读蓝队新写的 LauncherInputView panelHeight body / LauncherPluginCandidateView / LauncherCandidateView / LauncherInstantCandidateView 实现
//   - 仅调既有 static func panelHeight(...) 公开签名（HEAD 既有，签名稳定；body 是蓝队要改的对象，测试黑盒断言返回值）
//   - 期望值取自 assert 字面量（expectedHeightFor(n) = inputHeight + n * candidateRowHeight [+ footer]）
//
// CONTRACT_AMBIGUOUS:
//   - panelHeight single-zone 分支（无 output / 无 commandRoute+instant 并存）对 pluginCandidates 的计高公式：
//     设计文档 I3 明确「effectiveCount 移除 candidateCount（lastRoute 不渲染）」，即 single-zone 只看 pluginCandidateCount。
//     但 single-zone 与 commandRoute+instant 并存的精确互斥条件（哪个 count 非零走哪分支）设计文档未给字节面量分支表。
//     本测试以「最简 single-zone」驱动：只传 pluginCandidateCount（commandRouteCount=0, instantCount=0, outputHeight=0），
//     断言 panelHeight == inputHeight + min(pluginCandidateCount, 8) * candidateRowHeight。
//     若蓝队 single-zone 分支条件不同（如要求 candidateCount==0），需同步契约。
//   - hasSelected 死参数（设计决策 9：YAGNI 不动），本测试一律传 false（既有 body `hasSelected ? 44 : 0`，
//     设计文档未声明改 hasSelected 语义，保持 false 使该项贡献 0，不影响候选行高度断言）。

@MainActor
final class LauncherCandidatePanelHeightAcceptanceTests: XCTestCase {

    // MARK: - 期望值公式（取自契约，非硬编码魔数）

    /// inputHeight：LauncherConstants 既有稳定契约（=64），是 panelHeight 基线高度。
    private var inputH: CGFloat { LauncherConstants.inputHeight }

    /// candidateRowHeight：LauncherConstants 既有稳定契约（=44），每候选行高度。
    private var rowH: CGFloat { LauncherConstants.candidateRowHeight }

    /// 候选区期望高度：min(count, candidateVisibleMax) * candidateRowHeight。
    /// candidateVisibleMax 是蓝队新增常量（=8），若未合并则编译失败（预期 TDD 红灯）。
    private func candidateExtra(_ count: Int) -> CGFloat {
        CGFloat(min(count, LauncherConstants.candidateVisibleMax)) * rowH
    }

    /// 最简 single-zone 期望 panelHeight = inputHeight + candidateExtra(count)（无 output / footer / 并存区）。
    private func expectedHeightFor(_ count: Int) -> CGFloat {
        inputH + candidateExtra(count)
    }

    // MARK: - 场景1.P1：snip 8 候选全展示（≤8 自适应，核心修复）

    /// 场景1.P1 [det-machine]：pluginCandidateCount==8 时，panelHeight == inputH + 8 * rowH
    /// （非旧的 inputH + 5 * rowH —— 核心修复点：8 候选不再被裁到 5 行）。
    ///
    /// Mutation-Survival 自检：
    /// - No-op mutant（未改 min(count,5)→min(count,8)）→ 返回 inputH+5*rowH ≠ expectedHeightFor(8) → 失败（捕获）
    /// - 阈值 mutation（candidateVisibleMax 改 5）→ 同上 → 失败（捕获）
    func test_scenario1P1_eightCandidates_fullHeight_notCappedToFive() {
        let h = LauncherInputView.panelHeight(
            candidateCount: 0,
            hasSelected: false,
            outputHeight: 0,
            hasFooter: false,
            instantCount: 0,
            pluginCandidateCount: 8,
            commandRouteCount: 0
        )
        XCTAssertEqual(h, expectedHeightFor(8), accuracy: 0.5,
            "场景1.P1: 8 候选 panelHeight 必须 == \(expectedHeightFor(8))（8 行全展示），实际 \(h)；" +
            "若 == \(inputH + 5 * rowH) 说明 min(count,5) 未改 candidateVisibleMax")
    }

    // MARK: - 场景3.P1：12 候选封顶 8 行

    /// 场景3.P1 [det-machine]：pluginCandidateCount==12（>8）时，panelHeight 封顶 == expectedHeightFor(8)。
    ///
    /// Mutation-Survival 自检：
    /// - 无封顶 mutant（min 移除）→ 返回 inputH+12*rowH > expectedHeightFor(8) → 失败（捕获）
    func test_scenario3P1_twelveCandidates_cappedToEight() {
        let h = LauncherInputView.panelHeight(
            candidateCount: 0,
            hasSelected: false,
            outputHeight: 0,
            hasFooter: false,
            instantCount: 0,
            pluginCandidateCount: 12,
            commandRouteCount: 0
        )
        XCTAssertEqual(h, expectedHeightFor(8), accuracy: 0.5,
            "场景3.P1: 12 候选 panelHeight 必须封顶 == \(expectedHeightFor(8))（8 行），实际 \(h)")
    }

    // MARK: - 场景7.P1：count==5 全展示

    /// 场景7.P1 [det-machine]：pluginCandidateCount==5 时 panelHeight == expectedHeightFor(5)。
    func test_scenario7P1_fiveCandidates_fullHeight() {
        let h = LauncherInputView.panelHeight(
            candidateCount: 0,
            hasSelected: false,
            outputHeight: 0,
            hasFooter: false,
            instantCount: 0,
            pluginCandidateCount: 5,
            commandRouteCount: 0
        )
        XCTAssertEqual(h, expectedHeightFor(5), accuracy: 0.5,
            "场景7.P1: 5 候选 panelHeight 必须 == \(expectedHeightFor(5))，实际 \(h)")
    }

    // MARK: - 场景7.P2：count==8 恰好阈值全展示

    /// 场景7.P2 [det-machine]：pluginCandidateCount==8（恰好阈值）panelHeight == expectedHeightFor(8)。
    /// 边界 kill：`>`→`>=` mutation（count==8 误判超阈值封顶到 7）—— 但 panelHeight 封顶语义是
    /// min(count, T)，count==8 时 min(8,8)==8 无论 > 还是 >= 都同值，该 mutation 在 panelHeight 无害；
    /// 此处断言 count==8 高度 == count==8 期望（防封顶到 7 的 Off-by-one）。
    func test_scenario7P2_eightCandidates_atThreshold_fullHeight() {
        let h = LauncherInputView.panelHeight(
            candidateCount: 0,
            hasSelected: false,
            outputHeight: 0,
            hasFooter: false,
            instantCount: 0,
            pluginCandidateCount: 8,
            commandRouteCount: 0
        )
        XCTAssertEqual(h, expectedHeightFor(8), accuracy: 0.5,
            "场景7.P2: 8 候选（恰好阈值）panelHeight 必须 == \(expectedHeightFor(8))，实际 \(h)")
    }

    // MARK: - 场景7.P3：count==9 封顶 8

    /// 场景7.P3 [det-machine]：pluginCandidateCount==9 panelHeight == expectedHeightFor(8)（封顶）。
    /// 边界 kill：阈值 Off-by-one（count==9 若误用 min(count,7) 或 T==7 → 高度少一行）。
    func test_scenario7P3_nineCandidates_cappedToEight() {
        let h = LauncherInputView.panelHeight(
            candidateCount: 0,
            hasSelected: false,
            outputHeight: 0,
            hasFooter: false,
            instantCount: 0,
            pluginCandidateCount: 9,
            commandRouteCount: 0
        )
        XCTAssertEqual(h, expectedHeightFor(8), accuracy: 0.5,
            "场景7.P3: 9 候选 panelHeight 必须封顶 == \(expectedHeightFor(8))，实际 \(h)")
    }

    // MARK: - 场景9.P1：3→8 自适应增高

    /// 场景9.P1 [det-machine]：候选数从 3 增至 8，panelHeight 自适应增高至 8 行高度。
    ///
    /// Mutation-Survival 自检：
    /// - 钉死高度 mutant（panelHeight 不随 count 变）→ at_8 == at_3 → 失败（捕获）
    func test_scenario9P1_growFrom3To8_heightIncreases() {
        let at_3 = LauncherInputView.panelHeight(
            candidateCount: 0, hasSelected: false, outputHeight: 0, hasFooter: false,
            instantCount: 0, pluginCandidateCount: 3, commandRouteCount: 0
        )
        let at_8 = LauncherInputView.panelHeight(
            candidateCount: 0, hasSelected: false, outputHeight: 0, hasFooter: false,
            instantCount: 0, pluginCandidateCount: 8, commandRouteCount: 0
        )
        XCTAssertEqual(at_8, expectedHeightFor(8), accuracy: 0.5,
            "场景9.P1: at_8 必须 == \(expectedHeightFor(8))，实际 \(at_8)")
        XCTAssertGreaterThan(at_8, at_3,
            "场景9.P1: panelHeight_at_8(\(at_8)) 必须 > panelHeight_at_3(\(at_3))（自适应增高）")
    }

    // MARK: - 场景9.P2：8→12 封顶不变

    /// 场景9.P2 [det-machine]：候选数从 8 增至 12，panelHeight 封顶 8 行不变。
    func test_scenario9P2_growFrom8To12_heightCapped() {
        let at_8 = LauncherInputView.panelHeight(
            candidateCount: 0, hasSelected: false, outputHeight: 0, hasFooter: false,
            instantCount: 0, pluginCandidateCount: 8, commandRouteCount: 0
        )
        let at_12 = LauncherInputView.panelHeight(
            candidateCount: 0, hasSelected: false, outputHeight: 0, hasFooter: false,
            instantCount: 0, pluginCandidateCount: 12, commandRouteCount: 0
        )
        XCTAssertEqual(at_12, expectedHeightFor(8), accuracy: 0.5,
            "场景9.P2: at_12 必须 == \(expectedHeightFor(8))（封顶），实际 \(at_12)")
        XCTAssertEqual(at_12, at_8, accuracy: 0.5,
            "场景9.P2: panelHeight_at_12(\(at_12)) 必须 == panelHeight_at_8(\(at_8))（封顶不变）")
    }

    // MARK: - 0 候选空态（场景隐含：panelHeight 不含候选行高度）

    /// 空态谓词：pluginCandidateCount==0 时 panelHeight == inputH（候选区贡献 0 高度）。
    ///
    /// Mutation-Survival 自检：
    /// - 最小高度 mutant（空态仍加 1 行高）→ 返回 inputH+rowH ≠ inputH → 失败（捕获）
    func test_zeroCandidates_emptyState_inputHeightOnly() {
        let h = LauncherInputView.panelHeight(
            candidateCount: 0, hasSelected: false, outputHeight: 0, hasFooter: false,
            instantCount: 0, pluginCandidateCount: 0, commandRouteCount: 0
        )
        XCTAssertEqual(h, inputH, accuracy: 0.5,
            "空态: 0 候选 panelHeight 必须 == inputHeight(\(inputH))，实际 \(h)")
    }

    // MARK: - C-GENERIC-SCOPE：lastRoute(candidateCount) 不计入高度（I3）

    /// I3 契约：lastRouteCandidates 不渲染为可见列表，panelHeight 的 candidateCount 项不影响高度。
    /// 设计文档 I3 明确「effectiveCount 移除 candidateCount」——传大 candidateCount 高度不应增加。
    ///
    /// 用 pluginCandidateCount=3（小于 cap 8）放大差异：
    /// - HEAD 旧（candidateCount 计入 effectiveCount）：candidateCount=0 → eff=3 → 3*44；
    ///   candidateCount=100 → eff=100 → min(100,5)=5 → 5*44 → 两者不等（candidateCount 影响高度）
    /// - 设计文档新 I3（移除 candidateCount）：两者 eff=3 → 3*44 → 相等
    ///
    /// Mutation-Survival 自检：
    /// - lastRoute 计高 mutation（恢复 candidateCount 计入 effectiveCount）→
    ///   candidateCount=100 时 eff=100 被 cap，高度 ≠ candidateCount=0 时 → 失败（捕获）
    func test_contract_I3_lastRouteCandidateCount_doesNotAffectHeight() {
        // pluginCandidateCount=3（< cap 8，放大 candidateCount 计入与否的差异）
        let withFewRoute = LauncherInputView.panelHeight(
            candidateCount: 0, hasSelected: false, outputHeight: 0, hasFooter: false,
            instantCount: 0, pluginCandidateCount: 3, commandRouteCount: 0
        )
        let withManyRoute = LauncherInputView.panelHeight(
            candidateCount: 100, hasSelected: false, outputHeight: 0, hasFooter: false,
            instantCount: 0, pluginCandidateCount: 3, commandRouteCount: 0
        )
        XCTAssertEqual(withManyRoute, withFewRoute, accuracy: 0.5,
            "I3: candidateCount(lastRoute) 不应影响 panelHeight；" +
            "pluginCandidateCount=3 时 candidateCount=0 h=\(withFewRoute)，candidateCount=100 h=\(withManyRoute) 应相等；" +
            "若不等说明 candidateCount(lastRoute) 被计入 effectiveCount（I3 违反，会致 >8 时空白行）")
        // 双向断言：两者都应 == expectedHeightFor(3)（I3 下 eff=pluginCandidateCount=3）
        XCTAssertEqual(withFewRoute, expectedHeightFor(3), accuracy: 0.5,
            "I3: pluginCandidateCount=3 时 panelHeight 必须 == \(expectedHeightFor(3))，实际 \(withFewRoute)")
    }

    // MARK: - C-GENERIC-SCOPE：commandRoute + instant 渲染区也 cap 8（跨数据流）

    /// 契约 C-GENERIC-SCOPE：commandRoute 与 instant 渲染区同样 cap candidateVisibleMax。
    /// 注：设计文档 step 5 备注「commandRoute+instant 并存态两区各封顶 8，极端并存 16 行面板会高——保持既有 sum 语义」。
    /// 本测试验证「单区 commandRoute 也 cap 8」+「单区 instant 也 cap 8」（非并存叠加）。
    ///
    /// CONTRACT_AMBIGUOUS: commandRoute 单区计高的精确分支条件（与 pluginCandidate 是否互斥）
    ///   设计文档未给字节面量分支表，本测试假设「commandRouteCount>0 且 pluginCandidateCount==0」
    ///   走 commandRoute 单区分支。若蓝队分支条件不同需同步。
    func test_contract_CGenericScope_commandRouteCappedToEight() {
        let h = LauncherInputView.panelHeight(
            candidateCount: 0, hasSelected: false, outputHeight: 0, hasFooter: false,
            instantCount: 0, pluginCandidateCount: 0, commandRouteCount: 12
        )
        // commandRoute 12 应封顶 8
        XCTAssertEqual(h, inputH + candidateExtra(8), accuracy: 0.5,
            "C-GENERIC-SCOPE: commandRoute 12 应封顶 8 行，panelHeight == \(inputH + candidateExtra(8))，实际 \(h)")
    }

    /// instant 单区同样 cap 8（场景 5 数据流覆盖的 panelHeight 切片）。
    func test_contract_CGenericScope_instantCappedToEight() {
        let h = LauncherInputView.panelHeight(
            candidateCount: 0, hasSelected: false, outputHeight: 0, hasFooter: false,
            instantCount: 12, pluginCandidateCount: 0, commandRouteCount: 0
        )
        XCTAssertEqual(h, inputH + candidateExtra(8), accuracy: 0.5,
            "C-GENERIC-SCOPE: instant 12 应封顶 8 行，panelHeight == \(inputH + candidateExtra(8))，实际 \(h)")
    }

    // MARK: - C-ROW-HEIGHT-CONST：candidateVisibleMax == 8（常量值契约）

    /// 契约 C-VIEWPORT-THRESHOLD：LauncherConstants.candidateVisibleMax 必须 == 8。
    /// 防蓝队误写成 7 或 9。
    func test_contract_candidateVisibleMax_equalsEight() {
        XCTAssertEqual(LauncherConstants.candidateVisibleMax, 8,
            "C-VIEWPORT-THRESHOLD: LauncherConstants.candidateVisibleMax 必须 == 8，实际 \(LauncherConstants.candidateVisibleMax)")
    }

    /// 契约 C-ROW-HEIGHT-CONST：candidateRowHeight 既有稳定（=44），panelHeight 行高基准。
    /// 防蓝队误改 candidateRowHeight 值（会连锁影响所有期望）。
    func test_contract_candidateRowHeight_unchanged() {
        XCTAssertEqual(LauncherConstants.candidateRowHeight, 44,
            "C-ROW-HEIGHT-CONST: LauncherConstants.candidateRowHeight 应保持 44（既有稳定契约），实际 \(LauncherConstants.candidateRowHeight)")
    }
}
