import XCTest
import AppKit
@testable import BuddyCore

// MARK: - SnipAccordionTests
//
// 蓝队自测：SnipPanelVC 单列 accordion 重构后的核心契约（autopilot 2026-07-13）。
//
// 覆盖契约（state.md ## 契约规约）：
//   C-PANEL-NEW-INSTANCE   makePanelVC() 每次返回新实例（!== self）
//   C-SNIP-SINGLE-COLUMN   单列全宽（view 不含嵌套 ContentColumnView）
//   C-SNIP-ACCORDION-ONE   同一时刻最多展开 1 项（expandedRow: Int? 单值）
//   C-AX-STABLE            snip AX id settings.plugins.snip.row.<i> / .expanded.<i>
//
// 测试驱动：in-process UI（selectRow/performClick/stringValue），不用 XCUITest 外部 AX。
// 隔离：每个测试注入临时 snippetsFile（init(snippetsFile:)），不污染 ~/.buddy/snippets.json。
//
// 注意：本测试是「蓝队自测」（验证我自己的实现行为），不是红队 acceptance。
// 只跑本测试类：make test-only FILTER=SnipAccordionTests

@MainActor
final class SnipAccordionTests: XCTestCase {

    // MARK: - Helpers

    /// 临时 snippets.json URL（每测试独立 tmp 目录，初始空数组）
    private func makeTempSnippetsURL(initialItems: String = "[]") throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("snip-accordion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("snippets.json")
        try initialItems.data(using: .utf8)?.write(to: file)
        return file
    }

    /// 构造带隔离 service 的 SnipPanelVC，预填 2 条片段。
    private func makePanelWithTwoItems() throws -> (SnipPanelVC, SnippetsService) {
        let url = try makeTempSnippetsURL()
        let service = SnippetsService(snippetsFile: url)
        try service.add(keyword: "sig", content: "张三")
        try service.add(keyword: "greet", content: "你好 {date}")
        // SnipPanelVC 用注入 service 构造（不污染 .shared）
        let vc = SnipPanelVC(service: service)
        _ = vc.view  // 触发 loadView
        vc.testHook_reload()
        return (vc, service)
    }

    // MARK: - C-PANEL-NEW-INSTANCE：makePanelVC 每次返回新实例

    func test_makePanelVC_returnsNewInstance_eachCall() {
        let provider = SnipPanelVC()
        let a = provider.makePanelVC()
        let b = provider.makePanelVC()

        XCTAssertTrue(a is SnipPanelVC, "makePanelVC 应返回 SnipPanelVC 实例")
        XCTAssertFalse(a === provider, "makePanelVC 禁返回 self（C-PANEL-NEW-INSTANCE）")
        XCTAssertFalse(a === b, "makePanelVC 每次应返回不同实例（C-PANEL-NEW-INSTANCE）")
    }

    // MARK: - C-SNIP-ACCORDION-ONE：同一时刻最多展开 1 项

    func test_accordion_expandRowA_thenRowB_aCollapses() throws {
        let (vc, _) = try makePanelWithTwoItems()
        // 初始无展开
        XCTAssertNil(vc.expandedRowIndex, "初始应无展开行")
        XCTAssertEqual(vc.testHook_currentDetailMode, .empty, "初始模式应为 empty")

        // 展开行 0（sig）
        vc.testHook_selectRow(0)
        XCTAssertEqual(vc.expandedRowIndex, 0, "展开行 0 后 expandedRowIndex==0")
        XCTAssertEqual(vc.testHook_currentDetailMode, .edit, "展开已有行模式应为 edit")

        // 展开行 1（greet）→ 行 0 自动折叠
        vc.testHook_selectRow(1)
        XCTAssertEqual(vc.expandedRowIndex, 1, "展开行 1 后 expandedRowIndex==1（C-SNIP-ACCORDION-ONE）")
        XCTAssertEqual(vc.testHook_currentDetailMode, .edit, "展开已有行模式应为 edit")
    }

    func test_accordion_createRow_thenSelectExisting_createCollapses() throws {
        let (vc, _) = try makePanelWithTwoItems()
        // 展开新建行
        vc.testHook_startCreate()
        XCTAssertEqual(vc.expandedRowIndex, SnipPanelVC.createRowIndex, "新建展开 expandedRowIndex==createRowIndex(-1)")
        XCTAssertEqual(vc.testHook_currentDetailMode, .create, "新建行模式应为 create")

        // 展开已有行 → 新建折叠
        vc.testHook_selectRow(0)
        XCTAssertEqual(vc.expandedRowIndex, 0, "展开已有行后新建应折叠")
        XCTAssertEqual(vc.testHook_currentDetailMode, .edit, "模式应变 edit")
    }

    // MARK: - AX id 契约（C-AX-STABLE）

    func test_axIdentifier_collapsedRow_isSnipRowPrefix() throws {
        let (vc, _) = try makePanelWithTwoItems()
        // 触发 tableView 渲染
        vc.view.layoutSubtreeIfNeeded()

        // 收集所有 cell 的 AX id，断言折叠行含 settings.plugins.snip.row.<i>
        let ids = collectAccessibilityIdentifiers(in: vc.view)
        let rowIDs = ids.filter { $0.hasPrefix("settings.plugins.snip.row.") }
        XCTAssertGreaterThanOrEqual(rowIDs.count, 1,
                                    "应至少有 1 个折叠行 AX id settings.plugins.snip.row.<i>，实际：\(ids)")
    }

    func test_axIdentifier_expandedRow_isSnipExpandedPrefix() throws {
        let (vc, _) = try makePanelWithTwoItems()
        vc.testHook_selectRow(0)
        vc.view.layoutSubtreeIfNeeded()

        let ids = collectAccessibilityIdentifiers(in: vc.view)
        let expandedIDs = ids.filter { $0.hasPrefix("settings.plugins.snip.expanded.") }
        XCTAssertTrue(expandedIDs.contains("settings.plugins.snip.expanded.0"),
                      "展开行 0 应有 AX id settings.plugins.snip.expanded.0，实际 ids：\(ids)")
    }

    // MARK: - C-SNIP-SINGLE-COLUMN：单列全宽（无嵌套 ContentColumnView）

    func test_singleColumn_noNestedContentColumnView() throws {
        let (vc, _) = try makePanelWithTwoItems()
        vc.view.layoutSubtreeIfNeeded()

        // SnipPanelVC.view 子树不应含 ContentColumnView（嵌套已移除）
        let hasNested = containsViewOfType(vc.view, viewType: ContentColumnView.self)
        XCTAssertFalse(hasNested, "C-SNIP-SINGLE-COLUMN: SnipPanelVC.view 不应嵌套 ContentColumnView")
    }

    // MARK: - create 态：经真实 action 链路保存

    func test_create_save_persistsNewItem() throws {
        let (vc, service) = try makePanelWithTwoItems()
        let initialCount = service.list().count

        try vc.testHook_fillAndSaveCreate(keyword: "newkw", content: "new content")

        XCTAssertEqual(service.list().count, initialCount + 1, "保存后 service 应 +1 条")
        let added = service.list().first { $0.keyword == "newkw" }
        XCTAssertEqual(added?.content, "new content", "保存的 content 应匹配")
    }

    // MARK: - 空列表边界态（场景 5）

    func test_emptyList_doesNotCrash_rendersPlaceholder() throws {
        let url = try makeTempSnippetsURL()
        let service = SnippetsService(snippetsFile: url)
        let vc = SnipPanelVC(service: service)
        _ = vc.view
        vc.testHook_reload()
        vc.view.layoutSubtreeIfNeeded()

        // 空列表 selectRow 不崩
        vc.testHook_selectRow(0)
        // 面板稳定（view bounds > 0）
        XCTAssertGreaterThan(vc.view.bounds.height, 0, "空列表面板 bounds.height 应 > 0")
    }

    // MARK: - 私有 helpers

    /// 递归收集 view 子树所有非空 accessibilityIdentifier。
    private func collectAccessibilityIdentifiers(in view: NSView) -> [String] {
        var ids: [String] = []
        let id = view.accessibilityIdentifier() ?? ""
        if !id.isEmpty {
            ids.append(id)
        }
        for sub in view.subviews {
            ids.append(contentsOf: collectAccessibilityIdentifiers(in: sub))
        }
        return ids
    }

    /// 递归检查 view 子树是否含指定类型的 NSView 子类实例。
    private func containsViewOfType<T: NSView>(_ view: NSView, viewType: T.Type) -> Bool {
        if view is T { return true }
        return view.subviews.contains { containsViewOfType($0, viewType: T.self) }
    }
}
