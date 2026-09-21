import XCTest
@testable import BuddyCore

// MARK: - LauncherCardPanelHeightAcceptanceTests
//
// 红队验收测试（TDD 红灯）：W3 #6 面板高度按内容收缩——card 纯函数计高
//
// 谓词映射（SSOT: state.md ## 验收场景）：
//   s4p2 [det-machine] 少行结果（≤2 条目卡片）→ 输出区高度 < 400pt 且 ≥ 内容最小高度（QA 绑定下限）
//        ｜ artifact: /tmp/autopilot-artifacts/s4p2.out
//   s4p3 [det-machine] 少行切多行 → 高度单调增长 且 少行高度 ≠ 400
//        ｜ artifact: /tmp/autopilot-artifacts/s4p3.out
//
// 契约逐字（W3 #6）：
//   「panelHeight 输出高度改为实际估算（card 用纯函数 cardHeight(_:) 按条目数计算；
//     文本按行数×行高估算）clamp 到 outputMaxHeight，修『有输出固定撑满 400pt』」
//   LauncherConstants.outputMaxHeight == 400（既有稳定常量，HEAD 实证）
//
// 注入点声明（## 契约规约 + W3 #6 字面）：LauncherInputView.cardHeight(_:) 纯函数、
// PluginCard 解码自设计 ## 数据结构 card JSON schema。
//
// CONTRACT_AMBIGUOUS：
//   1. cardHeight(_:) 假定为 LauncherInputView 的 static 纯函数（panelHeight 同构，先例：
//      LauncherCandidatePanelHeightAcceptanceTests 直调 static panelHeight）；若蓝队落为
//      实例方法/改签名，仅调调用点，不得改断言。
//   2. 「内容最小高度」的绝对下限字面量设计未钉死（QA 绑定）——本测试以下限三重代理守护：
//      h > 0（正性）∧ 单调递增（结构）∧ < 400（收缩核心）。绝对下限留 QA 真机绑定。
//   3. 文本输出路径的行数×行高估算在 view body 内部（无声明 seam），由 QA 真机 e2e
//      （gcli_card_ui.e2e.acceptance.test.sh s4p1/s4p2 步骤）兜底。
//
// TDD 红灯：cardHeight(_:) / PluginCard 未实现时编译失败，属预期。

@MainActor
final class LauncherCardPanelHeightAcceptanceTests: XCTestCase {

    // MARK: - fixture（设计 ## 数据结构 card JSON schema 解码）

    private func entry(name: String, level: String, windows: [[String: Any]]) -> [String: Any] {
        ["name": name, "level": level, "badge": "", "windows": windows]
    }

    private func makeCard(entries: [[String: Any]], title: String) throws -> PluginCard {
        let json: [String: Any] = ["title": title, "entries": entries]
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(PluginCard.self, from: data)
    }

    private func makeCard(entryCount: Int) throws -> PluginCard {
        var entries: [[String: Any]] = []
        for i in 0..<entryCount {
            entries.append(entry(name: "e\(i)", level: "ok", windows: [
                ["label": "5h", "percent": 12, "reset": "3h20m"],
                ["label": "周窗", "percent": 45, "reset": "2d4h"],
            ]))
        }
        return try makeCard(entries: entries, title: "gcli 套餐限额 · \(entryCount) 个")
    }

    private func writeArtifact(_ name: String, _ lines: [String]) {
        let dir = "/tmp/autopilot-artifacts"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let content = ([name] + lines).joined(separator: "\n") + "\n"
        try? content.write(toFile: dir + "/" + name, atomically: true, encoding: .utf8)
    }

    // MARK: - s4p2：≤2 条目 → 输出区高度 < 400pt 且 ≥ 内容最小高度

    func test_s4p2_fewEntries_heightBelow400_aboveContentMinimum() throws {
        let h1 = try LauncherInputView.cardHeight(makeCard(entryCount: 1))
        let h2 = try LauncherInputView.cardHeight(makeCard(entryCount: 2))

        writeArtifact("s4p2.out", [
            "outputMaxHeight=\(LauncherConstants.outputMaxHeight)",
            "cardHeight(1 entry)=\(h1)",
            "cardHeight(2 entries)=\(h2)",
            "expect: 0 < h < 400（收缩，不再固定撑满 400）",
        ])

        XCTAssertGreaterThan(h1, 0, "s4p2: 1 条目卡片输出高度必须 > 0（内容最小高度下限代理）")
        XCTAssertGreaterThan(h2, 0, "s4p2: 2 条目卡片输出高度必须 > 0")
        XCTAssertLessThan(h1, 400, "s4p2: 1 条目少行高度必须 < 400pt（修固定撑满），实际 \(h1)")
        XCTAssertLessThan(h2, 400, "s4p2: 2 条目少行高度必须 < 400pt，实际 \(h2)")
    }

    // MARK: - s4p3：少行切多行 → 单调增长 ∧ 少行高度 ≠ 400

    func test_s4p3_fewToMore_heightMonotonicGrowth_fewNot400() throws {
        let h1 = try LauncherInputView.cardHeight(makeCard(entryCount: 1))
        let h2 = try LauncherInputView.cardHeight(makeCard(entryCount: 2))
        let h3 = try LauncherInputView.cardHeight(makeCard(entryCount: 3))

        writeArtifact("s4p3.out", [
            "cardHeight(1)=\(h1) cardHeight(2)=\(h2) cardHeight(3)=\(h3)",
            "expect: h1 < h2 < h3（单调增长）∧ h1 != 400",
        ])

        XCTAssertLessThan(h1, h2, "s4p3: 1→2 条目高度必须单调增长（\(h1) → \(h2)）")
        XCTAssertLessThan(h2, h3, "s4p3: 2→3 条目高度必须单调增长（\(h2) → \(h3)）")
        XCTAssertNotEqual(h1, CGFloat(400),
            "s4p3: 少行高度不得等于固定撑满值 400（旧 bug 特征），实际 \(h1)")
    }

    // MARK: - 契约：clamp 到 outputMaxHeight（多行不越 400 上限）
    //
    // 设计 W3 #6 clamp 主语 = 「panelHeight 输出高度」链条：cardHeight(_:) 为内容估算器，
    // clamp 在 panelHeight 输出高度入链处生效。断言打在声明 seam 的组合上：
    // panelHeight(outputHeight: cardHeight(大卡)) 不得超过 inputHeight + outputMaxHeight。
    // CONTRACT_AMBIGUOUS：clamp 具体落在 cardHeight 内还是 panelHeight 入链处，设计未钉死——
    // 本断言对两种落点均成立（估算器内收敛 ⇒ 组合必然也收敛）；若两者都不收敛，
    // 即「有输出撑破 400」回归，属设计违反。

    func test_contract_panelHeight_clampsCardOutputToMax() throws {
        let h32 = try LauncherInputView.cardHeight(makeCard(entryCount: 32))
        let h40 = try LauncherInputView.cardHeight(makeCard(entryCount: 40))
        XCTAssertGreaterThan(h32, 0)
        XCTAssertGreaterThan(h40, 0)

        let ceiling = LauncherConstants.inputHeight + LauncherConstants.outputMaxHeight

        let panel32 = LauncherInputView.panelHeight(
            candidateCount: 0, hasSelected: false,
            outputHeight: h32,
            hasFooter: false, instantCount: 0, pluginCandidateCount: 0
        )
        let panel40 = LauncherInputView.panelHeight(
            candidateCount: 0, hasSelected: false,
            outputHeight: h40,
            hasFooter: false, instantCount: 0, pluginCandidateCount: 0
        )

        writeArtifact("s4-clamp.out", [
            "cardHeight(32)=\(h32) cardHeight(40)=\(h40)",
            "panelHeight(card32)=\(panel32) panelHeight(card40)=\(panel40)",
            "ceiling(input+outputMax)=\(ceiling)",
        ])

        XCTAssertLessThanOrEqual(panel32, ceiling + 0.5,
            "契约：32 条目卡片经 panelHeight 链后不得越过 input+\(LauncherConstants.outputMaxHeight)，实际 \(panel32)")
        XCTAssertLessThanOrEqual(panel40, ceiling + 0.5,
            "契约：40 条目卡片经 panelHeight 链后不得越过 input+\(LauncherConstants.outputMaxHeight)，实际 \(panel40)")
    }
}
