import XCTest
import AppKit
@testable import BuddyCore

/// 蓝队单测：popover「后台任务」分组（C-POPOVER-GROUP）——分组排序、header、
/// headless 行 ⚙ 与禁点击。in-process AppKit 驱动（能力 1）。
@MainActor
final class SessionPopoverGroupTests: XCTestCase {

    private var controller: SessionPopoverController!

    override func setUp() {
        super.setUp()
        controller = SessionPopoverController()
        _ = controller.view   // 强制 loadView
    }

    // MARK: - Fixtures

    private func makeSession(
        _ id: String, headless: Bool, minutesAgo: Int = 0
    ) -> SessionInfo {
        var info = SessionInfo(
            sessionId: id, label: id, color: .coral, cwd: "/p/\(id)", pid: nil,
            terminalId: nil, state: .idle,
            lastActivity: Date(timeIntervalSinceNow: -Double(minutesAgo) * 60),
            toolDescription: nil, model: nil, startedAt: nil,
            totalTokens: 12_345, toolCallCount: 2)
        info.headlessState = headless ? .headless : .interactive
        return info
    }

    /// 取 stackView 中的 section header label（AX id 绑定）
    private func headlessHeaderLabel() -> NSTextField? {
        controller.view.findallViews { $0.accessibilityIdentifier() == "popover-section-headless" }
            .compactMap { $0 as? NSTextField }
            .first
    }

    /// 取 stackView arrangedSubviews 中的 SessionRowView 序列（含 header 混排，验证顺序）
    private func arrangedRowSequence() -> [String] {
        var sequence: [String] = []
        for case let row as SessionRowView in stackView().arrangedSubviews {
            sequence.append(row.isHeadlessRow ? "headless" : "interactive")
        }
        return sequence
    }

    private func stackView() -> NSStackView {
        controller.view.findallViews { $0 is NSStackView }
            .compactMap { $0 as? NSStackView }
            .first!
    }

    private func arrangedRows() -> [SessionRowView] {
        stackView().arrangedSubviews.compactMap { $0 as? SessionRowView }
    }

    // MARK: - C-POPOVER-GROUP：分组与顺序

    func testInteractiveGroupFirstHeadlessGroupLast() {
        let sessions = [
            makeSession("bg-1", headless: true, minutesAgo: 1),
            makeSession("i-1", headless: false, minutesAgo: 10),
            makeSession("bg-2", headless: true, minutesAgo: 2),
            makeSession("i-2", headless: false, minutesAgo: 1),
        ]
        controller.updateSessions(sessions)
        controller.view.layoutSubtreeIfNeeded()   // NSStackView 自动布局求值后再读 frame

        // 行序列：交互在前（lastActivity 降序 i-2 → i-1），headless 在后（bg-1 → bg-2）
        XCTAssertEqual(arrangedRowSequence(), ["interactive", "interactive", "headless", "headless"],
                       "固定顺序 = 交互组在前 + headless 组在后")
        XCTAssertEqual(arrangedRows()[0].frame.maxY > arrangedRows()[1].frame.maxY ? "i-2" : "i-1", "i-2",
                       "交互组内 lastActivity 降序")
    }

    func testSectionHeaderRenderedWithCount() {
        controller.updateSessions([
            makeSession("i-1", headless: false),
            makeSession("bg-1", headless: true),
            makeSession("bg-2", headless: true),
        ])
        let header = headlessHeaderLabel()
        XCTAssertNotNil(header, "N>0 时必须渲染「后台任务 (N)」header")
        XCTAssertEqual(header?.stringValue, "后台任务 (2)")
    }

    func testNoSectionHeaderWhenNoHeadless() {
        controller.updateSessions([makeSession("i-1", headless: false)])
        XCTAssertNil(headlessHeaderLabel(), "N=0 不渲染 header")
        XCTAssertEqual(arrangedRowSequence(), ["interactive"])
    }

    // MARK: - C-HEADLESS-NO-TERMINAL：headless 行禁点击 + ⚙ 图标

    func testHeadlessRowHasNoClickGesture() {
        controller.updateSessions([
            makeSession("i-1", headless: false),
            makeSession("bg-1", headless: true),
        ])
        let rows = arrangedRows()
        XCTAssertEqual(rows.count, 2)
        XCTAssertFalse(rows[0].isHeadlessRow)
        XCTAssertTrue(rows[1].isHeadlessRow)
        XCTAssertGreaterThan(rows[0].gestureRecognizers.count, 0,
                             "交互行有点击手势")
        XCTAssertEqual(rows[1].gestureRecognizers.count, 0,
                       "后台行无点击手势（点击不触发终端跳转）")
    }

    func testHeadlessRowOnClickedDoesNotFireCallback() {
        var clicked: [String] = []
        controller.onSessionClicked = { clicked.append($0.sessionId) }
        controller.updateSessions([
            makeSession("bg-1", headless: true),
        ])
        // controller 对 headless 行不挂 onClick → 行手势缺失，直接无回调可达
        let rows = arrangedRows()
        XCTAssertTrue(rows[0].isHeadlessRow)
        rows[0].simulateTapForTesting()
        XCTAssertTrue(clicked.isEmpty, "后台行点击不得触发 onSessionClicked")
    }

    func testInteractiveRowClickFiresCallback() {
        var clicked: [String] = []
        controller.onSessionClicked = { clicked.append($0.sessionId) }
        controller.updateSessions([
            makeSession("i-1", headless: false),
        ])
        arrangedRows()[0].simulateTapForTesting()
        XCTAssertEqual(clicked, ["i-1"])
    }

    func testHeadlessRowRendersGearIconInsteadOfColorDot() {
        controller.updateSessions([
            makeSession("bg-1", headless: true),
        ])
        let row = arrangedRows()[0]
        XCTAssertTrue(row.isHeadlessRow)
        // 行首图标 = ⚙ 文本 label（灰色）；无颜色圆点 NSView
        let texts = row.subviews.compactMap { $0 as? NSTextField }
        XCTAssertTrue(texts.contains { $0.stringValue.contains("⚙") },
                      "后台行行首应为 ⚙ 图标")
    }

    // MARK: - 混合计数标签

    func testCountLabelCountsAllSessions() {
        controller.updateSessions([
            makeSession("i-1", headless: false),
            makeSession("bg-1", headless: true),
        ])
        // countLabel 显示总会话数（交互 + 后台）
        let labels = controller.view.findallViews { $0 is NSTextField }
            .compactMap { $0 as? NSTextField }
        XCTAssertTrue(labels.contains { $0.stringValue == "2 sessions" })
    }
}

// MARK: - 测试辅助

extension NSView {
    /// 深度优先查找满足谓词的后代 view
    func findallViews(_ predicate: (NSView) -> Bool) -> [NSView] {
        var result: [NSView] = []
        for sub in subviews {
            if predicate(sub) { result.append(sub) }
            result.append(contentsOf: sub.findallViews(predicate))
        }
        return result
    }
}

extension SessionRowView {
    /// 测试辅助：直接走点击处理链路（手势不可编程触发；后台行 onClick 为 nil → 无回调）
    func simulateTapForTesting() {
        testHook_handleClick()
    }
}
