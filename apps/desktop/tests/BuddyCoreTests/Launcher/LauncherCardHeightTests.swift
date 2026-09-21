import XCTest
@testable import BuddyCore

// MARK: - LauncherCardHeightTests
//
// 蓝队单测：W3 面板高度收缩 —— 输出高度按内容估算的纯函数（headless 可测）。
//
// 契约引用（state.md 实现计划 5 + 验收场景 4）：
//   s4p2: 少行结果（≤2 条目卡片）→ 输出高度 < 400pt（outputMaxHeight）且 ≥ 内容最小高度
//   s4p3: 少行切多行 → 高度单调增长 且 少行高度 ≠ 400
//   修「有输出固定撑满 400pt」：cardHeight(条目数) / estimatedTextHeight(行数) 纯函数估算。

final class LauncherCardHeightTests: XCTestCase {

    private func makeCard(entries: Int, windowsPerEntry: Int = 2) -> PluginCard {
        PluginCard(
            title: "gcli 套餐限额 · \(entries) 个",
            entries: (0..<entries).map { i in
                CardEntry(
                    name: "entry-\(i)",
                    level: i % 3 == 0 ? "ok" : (i % 3 == 1 ? "warn" : "danger"),
                    badge: nil,
                    windows: (0..<windowsPerEntry).map { w in
                        CardWindow(label: w == 0 ? "5h" : "周窗", percent: 10 * w, reset: "3h20m")
                    }
                )
            }
        )
    }

    // MARK: - cardHeight 纯函数

    func test_cardHeight_positive_and_underOutputMax_forTwoEntries() {
        let h = LauncherInputView.cardHeight(makeCard(entries: 2))
        XCTAssertGreaterThan(h, 0, "卡片高度必须为正")
        XCTAssertLessThan(h, LauncherConstants.outputMaxHeight,
                          "s4p2: ≤2 条目卡片高度必须 < 400pt（内容收缩，不再固定撑满）")
    }

    func test_cardHeight_monotonicGrowth_withEntryCount() {
        let h1 = LauncherInputView.cardHeight(makeCard(entries: 1))
        let h2 = LauncherInputView.cardHeight(makeCard(entries: 2))
        let h5 = LauncherInputView.cardHeight(makeCard(entries: 5))
        XCTAssertGreaterThan(h2, h1, "s4p3: 条目增多高度必须单调增长")
        XCTAssertGreaterThan(h5, h2)
    }

    func test_cardHeight_monotonicGrowth_withWindowCount() {
        let w1 = LauncherInputView.cardHeight(makeCard(entries: 1, windowsPerEntry: 1))
        let w2 = LauncherInputView.cardHeight(makeCard(entries: 1, windowsPerEntry: 2))
        XCTAssertGreaterThan(w2, w1, "窗口行增多高度必须增长")
    }

    func test_cardHeight_emptyEntries_stillPositive() {
        let card = PluginCard(title: "gcli 套餐限额 · 0 个", entries: [])
        XCTAssertGreaterThan(LauncherInputView.cardHeight(card), 0,
                             "空 entries 卡片（仅标题）高度不得为 0（防面板塌缩裁切）")
    }

    // MARK: - estimatedTextHeight 纯函数

    func test_estimatedTextHeight_lineCountScaling() {
        XCTAssertEqual(LauncherInputView.estimatedTextHeight(""), 0, "空文本高度 0")
        let one = LauncherInputView.estimatedTextHeight("single line")
        let three = LauncherInputView.estimatedTextHeight("a\nb\nc")
        XCTAssertGreaterThan(one, 0)
        XCTAssertGreaterThan(three, one, "行数增多高度增长")
    }

    // MARK: - panelHeight 集成：估算高度接入后少行输出 < 旧固定 400 形态

    func test_panelHeight_smallOutput_notPinnedToMax() {
        let outputH = LauncherInputView.cardHeight(makeCard(entries: 2))
        let h = LauncherInputView.panelHeight(
            candidateCount: 0, hasSelected: false, outputHeight: outputH)
        // 全面板高 = inputHeight(64) + output（< 400）→ 必须显著小于旧「64 + 400」撑满形态
        XCTAssertLessThan(h, LauncherConstants.inputHeight + LauncherConstants.outputMaxHeight,
                          "s4p2: 少行输出全面板高必须 < 64+400（固定撑满形态）")
    }

    func test_panelHeight_outputClampedToMax() {
        let huge = LauncherConstants.outputMaxHeight + 500
        let h = LauncherInputView.panelHeight(
            candidateCount: 0, hasSelected: false, outputHeight: huge)
        XCTAssertEqual(h, LauncherConstants.inputHeight + LauncherConstants.outputMaxHeight,
                       "超大输出仍 clamp 到 outputMaxHeight（面板不过度膨胀）")
    }
}
