import XCTest
import AppKit
@testable import BuddyCore

// MARK: - 红队验收测试：设置窗口 AX 契约不破坏（SC-SET-03/04）
//
// 设计权威源（状态文件 `## 契约规约` C1 AX 红线 + `## 验收场景` SC-SET-03/04）：
//
// C1 — AX 红线（SC-SET-03/04，硬红线，重构前后逐字相等）：
//   - sidebar row AX id 集合 == {`settings.sidebar.skins`, `settings.sidebar.plugins`,
//     `settings.sidebar.hotkey`, `settings.sidebar.general`, `settings.sidebar.about`, `settings.sidebar.ai`}
//     （来自 SettingsSection.rawValue + SettingsSidebarViewController didAdd rowView 设 AX id）
//   - detail AX id == `settings.detail`（容器 + child root view，切换 5 次常驻）
//     （来自 SettingsSplitViewController viewDidLoad 设 detailContainer.view AX id +
//      SettingsDetailContainerViewController.transition 设 child root view AX id）
//   - 窗口 title == `设置`
//     （来自 SettingsWindowController.convenience init 设 window.title = "设置"）
//
// SC-SET-03 [det-machine]：While 设置窗口打开 AX dump, sidebar row AX id 集合保持。
//   assert: id 集合 == {`settings.sidebar.skins`, `.plugins`, `.hotkey`, `.general`, `.about`}
//            （重构前后逐字相等）
//
// SC-SET-04 [det-machine]：When 切换 5 个 section, detail AX id 常驻 + title 不变。
//   assert: 每次切换 detail id==`settings.detail` 且 title==`设置`
//
// 载体文件（设计 A5 明确不动，本测试可依赖其 AX 契约行为）：
//   - SettingsSplitViewController.swift（detailContainer.view + child root view AX id）
//   - SettingsSidebarViewController.swift（testHook_tableView + didAdd rowView AX id）
//   - SettingsWindowController.swift（window.title = "设置"）
//
// 红队原则：所有断言代表"设计意图应该满足"，不代表"实现实际做了什么"。
// 本测试是 AX 契约的红线守护：蓝队重构 5 页 UI 时若破坏 sidebar/detail AX id 或窗口 title，测试挂。

@MainActor
final class SettingsAXContractTests: XCTestCase {

    // SC-SET-03 逐字断言的 sidebar row AX id 集合（来自 SettingsSection.rawValue 全集）
    private static let expectedSidebarIDs: Set<String> = [
        "settings.sidebar.skins",
        "settings.sidebar.plugins",
        "settings.sidebar.hotkey",
        "settings.sidebar.general",
        "settings.sidebar.about",
        "settings.sidebar.ai",
    ]

    private static let detailAXID = "settings.detail"
    /// detail 容器 view AX id（容器层，非活动 child；AX 唯一性修订后与 child root view 区分）。
    private static let detailContainerAXID = "settings.detail.container"
    private static let windowTitle = "设置"

    // MARK: - Set up / tear down

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: SettingsWindowController.selectedCategoryDefaultsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: SettingsWindowController.selectedCategoryDefaultsKey)
        super.tearDown()
    }

    // MARK: - SC-SET-03 sidebar row AX id 集合逐字保持
    //
    // 谓词：sidebar row AX id 集合 == {`settings.sidebar.skins`, `.plugins`, `.hotkey`, `.general`, `.about`}
    // （重构前后逐字相等）
    //
    // AX id 设置位置（载体文件，设计 A5 不动）：
    //   - SettingsSidebarViewController.tableView(_:didAdd:forRow:) 在 rowView 层设
    //     `settings.sidebar.\(section.rawValue)`（契约 7：AXRow 层设 id）
    //   - SettingsSidebarCellView.configure(with:) 在 cellView 层设同 id（双保险）

    /// sidebar row AX id 集合逐字相等：实例化 splitVC，遍历 rowView 收集 AX id，断言集合相等。
    func test_SC_SET_03_sidebarRowAXIDs_matchExpectedSet() {
        let splitVC = SettingsSplitViewController()
        _ = splitVC.view // force viewDidLoad

        let sidebarIDs = collectSidebarRowAXIDs(from: splitVC)
        XCTAssertEqual(sidebarIDs, Self.expectedSidebarIDs,
                       "SC-SET-03 失败：sidebar row AX id 集合必须逐字 == \(Self.expectedSidebarIDs)，实际: \(sidebarIDs)")
    }

    /// sidebar AX id 数量 == 6（6 个 section，不多不少）。
    /// 杀死"少设/多设 AX id"的 mutation。
    func test_SC_SET_03_sidebarRowAXIDs_countIs6() {
        let splitVC = SettingsSplitViewController()
        _ = splitVC.view

        let sidebarIDs = collectSidebarRowAXIDs(from: splitVC)
        XCTAssertEqual(sidebarIDs.count, 6,
                       "sidebar row AX id 数量必须 == 6（对应 SettingsSection.allCases.count），实际: \(sidebarIDs.count)")
    }

    /// sidebar AX id 命名格式逐字（前缀 `settings.sidebar.` + section.rawValue）。
    /// 杀死"改了前缀或 rawValue"的 mutation。
    func test_SC_SET_03_sidebarRowAXIDs_followNamingConvention() {
        let splitVC = SettingsSplitViewController()
        _ = splitVC.view

        let sidebarIDs = collectSidebarRowAXIDs(from: splitVC)
        for section in SettingsSection.allCases {
            let expected = "settings.sidebar.\(section.rawValue)"
            XCTAssertTrue(sidebarIDs.contains(expected),
                          "sidebar AX id 集合必须含 '\(expected)'（section: \(section.rawValue)），实际: \(sidebarIDs)")
        }
    }

    // MARK: - SC-SET-04 detail AX id 常驻 + 窗口 title 不变（切换 5 section）
    //
    // 谓词：When 切换 5 个 section, detail AX id 常驻 + title 不变。
    // assert: 每次切换 detail id==`settings.detail` 且 title==`设置`

    /// 初始 detail AX id == `settings.detail`（容器 + child root view）。
    func test_SC_SET_04_detailAXID_isSettingsDetail_initially() {
        let splitVC = SettingsSplitViewController()
        _ = splitVC.view // force viewDidLoad（初始选中 skins，detail 已 transition）

        let detailID = detailAXID(from: splitVC)
        XCTAssertEqual(detailID, Self.detailAXID,
                       "SC-SET-04 失败：detail AX id 必须常驻 == '\(Self.detailAXID)'，初始状态实际: \(detailID ?? "nil")")
    }

    /// 切换 5 个 section，每次 detail AX id 都 == `settings.detail`（常驻，不随切换丢失）。
    /// 杀死"切换后 detail AX id 丢失/被 child 覆盖"的 mutation。
    func test_SC_SET_04_detailAXID_persistsAcrossAllSectionSwitches() {
        let splitVC = SettingsSplitViewController()
        _ = splitVC.view

        for section in SettingsSection.allCases {
            // 程序化切换（模拟 sidebar 点击 → switchTo）
            splitVC.testHook_selectSection(section)
            // force detail child view 加载（AX id 设在 child root view，需 view 已加载）
            if let child = splitVC.detailChildViewController {
                _ = child.view
            }

            let detailID = detailAXID(from: splitVC)
            XCTAssertEqual(detailID, Self.detailAXID,
                           "SC-SET-04 失败：切换到 section '\(section.rawValue)' 后 detail AX id 必须 == '\(Self.detailAXID)'，实际: \(detailID ?? "nil")")
        }
    }

    /// detail 容器 view（settings.detail.container）与 child root view（settings.detail）各自持 AX id。
    /// 设计：AX 唯一性修订后，容器 view 与 child root view 区分（全窗递归 settings.detail 唯一命中活动 child）。
    func test_SC_SET_04_detailContainerAndView_bothHaveSettingsDetailID() {
        let splitVC = SettingsSplitViewController()
        _ = splitVC.view

        // 容器 view AX id（splitVC 第二个 splitViewItem 的 viewController.view）
        guard let splitItems = splitVC.splitViewItems as? [NSSplitViewItem],
              splitItems.count >= 2 else {
            return XCTFail("无法获取 splitViewItems 或数量 < 2")
        }
        let detailContainer = splitItems[1].viewController
        let containerID = detailContainer.view.accessibilityIdentifier()
        XCTAssertEqual(containerID, Self.detailContainerAXID,
                       "detail 容器 view AX id 必须 == '\(Self.detailContainerAXID)'，实际: \(containerID ?? "nil")")

        // child root view AX id（detailChildViewController.view）
        if let child = splitVC.detailChildViewController {
            let childID = child.view.accessibilityIdentifier()
            XCTAssertEqual(childID, Self.detailAXID,
                           "detail child root view AX id 必须 == '\(Self.detailAXID)'，实际: \(childID ?? "nil")")
        } else {
            XCTFail("detailChildViewController 必须存在（初始应 transition 到默认 section）")
        }
    }

    /// 窗口 title == `设置`（SettingsWindowController 设 window.title）。
    func test_SC_SET_04_windowTitle_isSettings() {
        let wc = SettingsWindowController()
        guard let title = wc.window?.title else {
            return XCTFail("SettingsWindowController.window 必须存在且 title 非空")
        }
        XCTAssertEqual(title, Self.windowTitle,
                       "SC-SET-04 失败：窗口 title 必须 == '\(Self.windowTitle)'，实际: '\(title)'")
    }

    /// 窗口 title 在切换 section 后保持 == `设置`（title 不随 detail 切换变）。
    func test_SC_SET_04_windowTitle_persistsAfterSectionSwitches() {
        let wc = SettingsWindowController()
        guard let window = wc.window,
              let splitVC = wc.splitViewController else {
            return XCTFail("无法获取 window / splitVC")
        }

        for section in SettingsSection.allCases {
            splitVC.testHook_selectSection(section)
            XCTAssertEqual(window.title, Self.windowTitle,
                           "SC-SET-04 失败：切换到 section '\(section.rawValue)' 后窗口 title 必须仍 == '\(Self.windowTitle)'，实际: '\(window.title)'")
        }
    }

    // MARK: - 辅助方法

    /// 收集 sidebar 所有 rowView 的 AX id（SC-SET-03 核心断言数据源）。
    /// 遍历 SettingsSidebarViewController.testHook_tableView 的每行 rowView，取 accessibilityIdentifier。
    private func collectSidebarRowAXIDs(from splitVC: SettingsSplitViewController) -> Set<String> {
        // sidebar 在第一个 splitViewItem
        guard let splitItems = splitVC.splitViewItems as? [NSSplitViewItem],
              splitItems.count >= 1 else {
            XCTFail("无法获取 splitViewItems")
            return []
        }
        let sidebarVC = splitItems[0].viewController
        guard let sidebar = sidebarVC as? SettingsSidebarViewController else {
            // 若蓝队改了 sidebar 类型，AX 契约可能已破坏——用反射兜底找 testHook_tableView
            return collectSidebarIDsViaReflection(sidebarVC)
        }

        let tableView = sidebar.testHook_tableView
        var ids: Set<String> = []
        for row in 0..<tableView.numberOfRows {
            // makeIfNecessary: true 触发 cell/rowView 创建（didAdd rowView 回调设 AX id）
            if let rowView = tableView.rowView(atRow: row, makeIfNecessary: true) {
                let id = rowView.accessibilityIdentifier()
                if !id.isEmpty {
                    ids.insert(id)
                }
            }
        }
        return ids
    }

    /// 兜底：若 sidebarVC 不是 SettingsSidebarViewController 类型（蓝队破坏了类型契约），
    /// 递归找 NSTableView 取 rowView AX id。此路径不应被命中（命中说明 AX 载体被破坏）。
    private func collectSidebarIDsViaReflection(_ vc: NSViewController) -> Set<String> {
        _ = vc.view
        guard let tableView = findFirst(NSTableView.self, in: vc.view) else { return [] }
        var ids: Set<String> = []
        for row in 0..<tableView.numberOfRows {
            if let rowView = tableView.rowView(atRow: row, makeIfNecessary: true) {
                let id = rowView.accessibilityIdentifier()
                if !id.isEmpty {
                    ids.insert(id)
                }
            }
        }
        return ids
    }

    /// 取 detail AX id：优先 child root view（AX 可见层），回退容器 view。
    private func detailAXID(from splitVC: SettingsSplitViewController) -> String? {
        // 优先 child root view（设计：AX id 设在 child root view，容器被 child 遮蔽）
        if let child = splitVC.detailChildViewController {
            _ = child.view // force load
            let id = child.view.accessibilityIdentifier()
            if !id.isEmpty {
                return id
            }
        }
        // 回退容器 view
        guard let splitItems = splitVC.splitViewItems as? [NSSplitViewItem],
              splitItems.count >= 2 else {
            return nil
        }
        return splitItems[1].viewController.view.accessibilityIdentifier()
    }

    /// 递归找第一个指定类型的子视图（复用 SettingsSidebarAcceptanceTests 模式）。
    private func findFirst<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let typed = view as? T { return typed }
        for sub in view.subviews {
            if let found = findFirst(type, in: sub) { return found }
        }
        return nil
    }

    // MARK: - SC-SET-12/13（不写自动测试，标注 QA 命令）
    //
    // SC-SET-12 [manual+det-machine]：手动切换 sidebar section(sendEvent 兜底), detail child VC 切换 + AX id 保持。
    //   det 部分（detail AX id==settings.detail）：本文件 test_SC_SET_04_detailAXID_persistsAcrossAllSectionSwitches 已覆盖
    //     （程序化切换 testHook_selectSection 模拟选中，断言 detail AX id 常驻）。
    //   manual 部分（buddy CLI 无 sidebar 驱动命令 + CGEvent 不路由非 key 窗口）：
    //     QA 真机手动点 sidebar 5 次 + AX dump，断言切换后 detail AX id==settings.detail 且各 section 特征内容出现。
    //
    // SC-SET-13 [manual]：LSUIElement 非 key 窗口，真鼠标交互须手动验证。
    //   QA 真机：手动操作 recorder 录制/重置 + 关于按钮 + 目视间距，断言 recorder 可录制重置、按钮非 dead、间距统一无错位。
}
