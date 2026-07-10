import XCTest
import AppKit
@testable import BuddyCore

// MARK: - 红队验收测试：设置窗口 frame 级谓词（stage-2 设置主体套地基后，2026-07-10）
//
// 黑盒验收测试：基于设计文档 stage-2 承诺的 frame 级谓词下断言。
//
// 信息隔离铁律：本文件**不读取** docs/superpowers/plans/、蓝队 stage-2 改的源码
// （SettingsSplitViewController/EmptyPluginStateVC/各 VC）、蓝队的 SettingsLayoutAcceptanceTests。
// 仅对设计承诺的「frame 级外部可观测行为」下断言（AX 唯一性 / sidebar 固定宽 / 内容列限宽）。
//
// 设计权威源（唯一真相）：
// - **AC-AX-01**：全窗递归 `accessibilityIdentifier() == "settings.detail"` 命中唯一。
//   仅活动 child root view 持该 id；容器 view / 空态 view 用别的 id。遍历各 SettingsSection，
//   每 section 下命中数 == 1。
//   杀死「AX 重复 / 空态 view 抢占 settings.detail id / 容器与 child 同时挂同 id」回归。
//
// - **AC-SPLIT-01**：设置 sidebar 分栏宽度恒 200。窗口宽 800 / 1000 / 1400 三次读
//   sidebarItem 的 viewController.view.bounds.width 都 == 200。
//   杀死「sidebar 宽度随窗口缩放漂移 / minimumThickness=180 让 sidebar 收窄」回归。
//
// - **AC-WIDTH-01**：设置页接入 ContentColumnView 后，detail 内容列（ContentColumnView.contentColumn）
//   在宽屏（>1000）时 bounds.width ≤ 780（SettingsTheme.contentMaxWidth）。
//   杀死「内容列在宽屏溢出 / ContentColumnView 未接入主体面板」回归。
//
// 工作规则：每个谓词至少 1 个硬断言，失败即挂测试。不对实现状态容错。

@MainActor
final class SettingsFrameAcceptanceTests: XCTestCase {

    // MARK: - 持久化 key 清理（防其他测试污染）

    /// 选中分类持久化 key（与 SettingsSplitViewController.selectedCategoryDefaultsKey 同值）。
    private static let selectedCategoryKey = "SettingsSelectedCategory"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: Self.selectedCategoryKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Self.selectedCategoryKey)
        super.tearDown()
    }

    // MARK: - Helpers

    /// 强制 view 加载（触发 loadView + viewDidLoad）。
    private func forceLoadView(_ vc: NSViewController) {
        _ = vc.view
    }

    /// 递归找全部 accessibilityIdentifier 匹配的视图。
    /// AX id 读取用 `accessibilityIdentifier()`（NSAccessibility 旧协议，AppKit 仍稳定可用）。
    private func findAllViewsWithIdentifier(_ id: String, in view: NSView) -> [NSView] {
        var result: [NSView] = []
        if view.accessibilityIdentifier() == id { result.append(view) }
        for sub in view.subviews {
            result.append(contentsOf: findAllViewsWithIdentifier(id, in: sub))
        }
        return result
    }

    /// 递归找全部指定类型的子视图（含自身）。
    private func findAll<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        var result: [T] = []
        if let typed = view as? T { result.append(typed) }
        for sub in view.subviews {
            result.append(contentsOf: findAll(type, in: sub))
        }
        return result
    }

    /// 从 SettingsWindowController 取 SettingsSplitViewController。
    /// 走 contentViewController as? SettingsSplitViewController（@testable 可见类型）。
    private func makeSplitVC() -> SettingsSplitViewController {
        let wc = SettingsWindowController()
        guard let window = wc.window else {
            XCTFail("SettingsWindowController.window 必须存在（实例化即建窗）")
            fatalError("unreachable — XCTFail 已挂")
        }
        guard let splitVC = window.contentViewController as? SettingsSplitViewController else {
            XCTFail("contentViewController 必须是 SettingsSplitViewController，实际: \(String(describing: window.contentViewController))")
            fatalError("unreachable — XCTFail 已挂")
        }
        return splitVC
    }

    /// 取 sidebar 的 root view（splitViewItems[0] 是 AppKit public 属性，无需 @testable）。
    private func sidebarView(of splitVC: SettingsSplitViewController) -> NSView {
        guard splitVC.splitViewItems.count >= 1 else {
            XCTFail("splitViewItems 必须至少 1 项（sidebar），实际: \(splitVC.splitViewItems.count)")
            fatalError("unreachable — XCTFail 已挂")
        }
        let sidebarVC = splitVC.splitViewItems[0].viewController
        return sidebarVC.view
    }

    /// 取 detail 容器的 root view（splitViewItems[1]，detailItem.viewController.view）。
    private func detailContainerView(of splitVC: SettingsSplitViewController) -> NSView {
        guard splitVC.splitViewItems.count >= 2 else {
            XCTFail("splitViewItems 必须至少 2 项（sidebar + detail），实际: \(splitVC.splitViewItems.count)")
            fatalError("unreachable — XCTFail 已挂")
        }
        let detailVC = splitVC.splitViewItems[1].viewController
        return detailVC.view
    }

    // MARK: - AC-AX-01：settings.detail AX identifier 全窗递归唯一（逐 section）

    /// AC-AX-01 [ax-detail-unique-per-section]：遍历 SettingsSection.allCases，
    /// 每 section testHook_selectSection + layoutSubtreeIfNeeded 后，
    /// 递归 splitVC.view 找 accessibilityIdentifier() == "settings.detail" 的命中数 == 1。
    ///
    /// 设计契约：仅活动 child root view 持 "settings.detail" id（AX 可见层）；
    /// 容器 view / 空态 view 用别的 id。若命中数 > 1，证明容器与 child 同时挂了同 id
    /// （AX 树歧义，自动化读 detail 层时无法定位）；若命中数 == 0，证明 child 未挂 id。
    func test_AC_AX_01_settingsDetailUnique_perSection() {
        let splitVC = makeSplitVC()
        forceLoadView(splitVC)

        for section in SettingsSection.allCases {
            // 切 section + 强制布局收敛（child VC containment 切换需 layoutSubtreeIfNeeded 生效）
            splitVC.testHook_selectSection(section)
            splitVC.view.layoutSubtreeIfNeeded()
            splitVC.view.window?.layoutIfNeeded()

            let hits = findAllViewsWithIdentifier("settings.detail", in: splitVC.view)
            XCTAssertEqual(hits.count, 1,
                """
                AC-AX-01 违反：section=\(section.rawValue) 下 settings.detail 命中数必须 == 1，实际 \(hits.count)。
                命中 > 1 → 容器 view 与 child root view 同时挂同 id（AX 歧义）。
                命中 == 0 → child root view 未挂 settings.detail id。
                """)
        }
    }

    // MARK: - AC-SPLIT-01：sidebar 宽度恒 200（三次窗口宽读 sidebar view.bounds.width）

    /// AC-SPLIT-01 [sidebar-fixed-200-across-widths]：window contentView 宽依次设
    /// 800 / 1000 / 1400，每次 layoutSubtreeIfNeeded 后读 sidebar view（splitViewItems[0]）的
    /// bounds.width，三次都 == 200。
    ///
    /// 设计契约：sidebar 分栏宽度恒 200（不随窗口缩放漂移）。若某次宽度 ≠ 200，
    /// 证明 sidebar 宽度随窗口缩放（minimumThickness=180 让它收窄，或 autolayout 让它跟随窗口）。
    func test_AC_SPLIT_01_sidebarFixed200_acrossWidths() {
        let splitVC = makeSplitVC()
        guard let window = splitVC.view.window else {
            return XCTFail("splitVC.view.window 必须存在（SettingsWindowController 已建窗）")
        }
        forceLoadView(splitVC)

        let widthsToTest: [CGFloat] = [800, 1000, 1400]

        for width in widthsToTest {
            // 改窗口 contentView 宽度（保持高度，触发 splitView 重新布局 sidebar）
            let height = window.contentView?.bounds.height ?? 600
            let contentRect = NSRect(x: 0, y: 0, width: width, height: height)
            window.setContentSize(contentRect.size)
            window.layoutIfNeeded()
            splitVC.view.layoutSubtreeIfNeeded()

            let sidebar = sidebarView(of: splitVC)
            let sidebarWidth = sidebar.bounds.width
            XCTAssertEqual(sidebarWidth, 200, accuracy: 0.5,
                """
                AC-SPLIT-01 违反：窗口宽 \(width) 时 sidebar.bounds.width 必须 == 200，实际 \(sidebarWidth)。
                sidebar 宽度必须恒 200，不随窗口缩放漂移。
                """)
        }
    }

    // MARK: - AC-WIDTH-01：ContentColumnView.contentColumn 在宽屏限宽 ≤ 780

    /// AC-WIDTH-01 [content-column-capped-wide-viewport]：宽屏（设 1200）+ 切 .general
    /// （接入 ContentColumnView 的主体面板），递归找 detail 子树中的 ContentColumnView，
    /// 断言其 contentColumn.bounds.width ≤ 780（SettingsTheme.contentMaxWidth）。
    ///
    /// 设计契约：stage-2 把 ContentColumnView（stage-1 建的限宽居中容器）接入设置主体单栏页。
    /// 接入后 detail 内容列在宽屏必须限宽（≤ 780），否则证明 ContentColumnView 未接入 / cap 失效。
    func test_AC_WIDTH_01_contentColumnCapped_wideViewport() {
        let splitVC = makeSplitVC()
        guard let window = splitVC.view.window else {
            return XCTFail("splitVC.view.window 必须存在（SettingsWindowController 已建窗）")
        }
        forceLoadView(splitVC)

        // 宽屏：窗口 contentView 宽 1200（> 1000，触发宽屏限宽）
        let height = window.contentView?.bounds.height ?? 600
        window.setContentSize(NSSize(width: 1200, height: height))
        window.layoutIfNeeded()

        // 切 general（stage-2 设计承诺接入 ContentColumnView 的主体单栏页之一）
        splitVC.testHook_selectSection(.general)
        splitVC.view.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        // 递归找 detail 子树中的 ContentColumnView（接入后应在 detail 容器的 child VC 子树）
        let detailContainer = detailContainerView(of: splitVC)
        let contentColumns = findAll(ContentColumnView.self, in: detailContainer)

        // 至少 1 个 ContentColumnView 必须存在（证明已接入；未接入则 AC-WIDTH-01 无法验收）
        XCTAssertGreaterThanOrEqual(contentColumns.count, 1,
            """
            AC-WIDTH-01 违反：detail 容器子树中必须至少 1 个 ContentColumnView（证明 stage-2 已接入主体面板），
            实际找到 \(contentColumns.count) 个。general 面板应接入 ContentColumnView。
            """)

        // 每个 ContentColumnView 的 contentColumn.bounds.width 必须 ≤ 780
        for (idx, column) in contentColumns.enumerated() {
            let contentColumnWidth = column.contentColumn.bounds.width
            XCTAssertLessThanOrEqual(contentColumnWidth, 780,
                """
                AC-WIDTH-01 违反：宽屏（1200）下 ContentColumnView[\(idx)].contentColumn.bounds.width 必须 ≤ 780，
                实际 \(contentColumnWidth)。ContentColumnView 必须限宽（SettingsTheme.contentMaxWidth=780）。
                """)
        }
    }
}
