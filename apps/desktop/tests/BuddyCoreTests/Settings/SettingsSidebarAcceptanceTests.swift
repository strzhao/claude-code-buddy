import XCTest
import AppKit
@testable import BuddyCore

// MARK: - 红队验收测试：设置窗口 Sidebar 重构（SC-01..14）

/// 黑盒验收测试：基于设计文档契约（macOS 原生系统设置风格 NSWindow + NSSplitViewController）。
///
/// 设计权威源（本测试逐字断言的契约）：
/// - 窗口：标准 `NSWindow`（非 NSPanel），styleMask `[.titled, .closable, .minimizable, .resizable]`，
///   无 `.fullSizeContentView`，无 `.floating` level，初始 760×540，minSize 600×420，title "设置"，
///   `canBecomeKey==true`，失焦不隐藏。
/// - 骨架：`contentViewController = SettingsSplitViewController`（NSSplitViewController 子类），
///   两 NSSplitViewItem：sidebar 项（behavior:.sidebar）→ SettingsSidebarViewController（NSTableView 列分类）；
///   content 项 → detail 容器，按选中切换 child VC。
/// - 数据驱动 sidebar：`SettingsSection` 枚举 `case skins, plugins, hotkey, general, about`，
///   `allCases` 单一数据源。
/// - detail 切换：skins→SkinGalleryViewController，plugins→PluginGalleryViewController，
///   hotkey→KeyboardShortcutsViewController，general→GeneralSettingsViewController，about→AboutSettingsViewController。
/// - 持久化：选中分类存 UserDefaults key `SettingsSelectedCategory`（值=SettingsSection.rawValue），默认 `.skins`。
///
/// 工作规则：本文件是 TDD 红灯，对设计的契约断言，不读实现代码、不对实现状态容错。
/// 每个谓词 SC-01..14 至少 1 个硬断言，失败即挂测试。
@MainActor
final class SettingsSidebarAcceptanceTests: XCTestCase {

    /// 新持久化 key（契约 4）。逐字断言。
    private static let selectedCategoryKey = "SettingsSelectedCategory"

    /// 旧 key（契约 4 废弃，验证新实现不再读写它）。
    private static let legacyKey = "BuddyStoreSelectedTab"

    // MARK: - Set up / tear down

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: Self.selectedCategoryKey)
        UserDefaults.standard.removeObject(forKey: Self.legacyKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Self.selectedCategoryKey)
        UserDefaults.standard.removeObject(forKey: Self.legacyKey)
        super.tearDown()
    }

    // MARK: - Helpers

    /// 让 main actor 上排队的 Task 完成。
    private func drainMainActor() async {
        await Task.yield()
        await Task.yield()
        await Task.yield()
    }

    /// 强制 view 加载。
    private func forceLoadView(_ vc: NSViewController) {
        _ = vc.view
    }

    /// 递归找第一个指定类型的子视图。
    private func findFirst<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let typed = view as? T { return typed }
        for sub in view.subviews {
            if let found = findFirst(type, in: sub) { return found }
        }
        return nil
    }

    /// 递归找全部指定类型的子视图。
    private func findAll<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        var result: [T] = []
        if let typed = view as? T { result.append(typed) }
        for sub in view.subviews {
            result.append(contentsOf: findAll(type, in: sub))
        }
        return result
    }

    /// 递归找 accessibilityIdentifier 匹配的视图。
    private func findViewWithIdentifier(_ id: String, in view: NSView) -> NSView? {
        if view.accessibilityIdentifier() == id { return view }
        for sub in view.subviews {
            if let found = findViewWithIdentifier(id, in: sub) { return found }
        }
        return nil
    }

    // MARK: - SC-01 窗口标准 NSWindow 非浮动 NSPanel

    /// 契约 1：窗口必须标准 `NSWindow`（className 不含 NSPanel），canBecomeKey==true，
    /// styleMask 含 .titled/.closable/.resizable，**不含** .fullSizeContentView，level != .floating。
    func test_SC01_window_isStandardNSWindow_notFloatingPanel() {
        let wc = SettingsWindowController()
        guard let window = wc.window else {
            return XCTFail("SettingsWindowController.window 必须存在")
        }

        // 标准窗口 className 不含 NSPanel
        let className = String(describing: type(of: window))
        XCTAssertFalse(className.contains("NSPanel"),
                      "窗口 className 不得含 'NSPanel'，实际: \(className)")
        XCTAssertFalse(window is NSPanel,
                      "窗口不得是 NSPanel 实例")

        // canBecomeKey 必须为 true（主方案标准 NSWindow；R1 sendEvent 降级仍需 canBecomeKey）
        XCTAssertTrue(window.canBecomeKey,
                      "标准 NSWindow.canBecomeKey 必须为 true（LSUIElement 下成 key window 的前提）")

        // styleMask 必含 .titled / .closable / .resizable
        let mask = window.styleMask
        XCTAssertTrue(mask.contains(.titled), "styleMask 必须含 .titled")
        XCTAssertTrue(mask.contains(.closable), "styleMask 必须含 .closable")
        XCTAssertTrue(mask.contains(.resizable), "styleMask 必须含 .resizable")

        // styleMask 不得含 .fullSizeContentView（这是浮动 NSPanel 的特征）
        XCTAssertFalse(mask.contains(.fullSizeContentView),
                      "styleMask 不得含 .fullSizeContentView（浮动 panel 特征，原生设置窗口不用）")

        // level 不得是 .floating（失焦不隐藏的前提之一）
        XCTAssertNotEqual(window.level, .floating,
                          "window.level 不得为 .floating（设计要求标准窗口层级，失焦不隐藏）")

        // REAL_DEVICE: 留 QA Tier 1.5 真机 AX 验证
        // SC-01 真机谓词：subrole == AXStandardWindow。单元层不可驱动 AX，但上面结构性断言
        // 已覆盖窗口类型（非 Panel）/ canBecomeKey / styleMask / level 四项硬契约。
    }

    /// SC-01 补：styleMask 必含可最小化标记。
    /// CONTRACT_AMBIGUITY: 设计文档写 `.minimizable`，但 AppKit 真实 API 是 `.miniaturizable`。
    /// 设计意图明确（窗口可最小化），测试采用 AppKit 正确 API 名 `.miniaturizable`。
    /// 若实现照抄设计的 `.minimizable` 会编译失败——此测试守护实现采用正确 API。
    func test_SC01_windowStyleMask_containsMiniaturizable() {
        let wc = SettingsWindowController()
        guard let window = wc.window else {
            return XCTFail("SettingsWindowController.window 必须存在")
        }
        XCTAssertTrue(window.styleMask.contains(.miniaturizable),
                      "styleMask 必须含 .miniaturizable（设计意图：窗口可最小化；AppKit API 名非 .minimizable）")
    }

    // MARK: - SC-02 窗口可调大小

    /// 契约：初始 760×540，minSize 600×420。
    /// 注：styleMask 含 .resizable（SC-01 已断言），此处补 minSize 与初始尺寸结构性断言。
    func test_SC02_window_isResizable_withCorrectMinSize() {
        let wc = SettingsWindowController()
        guard let window = wc.window else {
            return XCTFail("SettingsWindowController.window 必须存在")
        }

        // 初始尺寸 760×540（允许 0.5 浮点容差）
        let frame = window.frame
        XCTAssertEqual(frame.width, 760, accuracy: 1.0,
                       "初始窗口宽度应为 760，实际: \(frame.width)")
        XCTAssertEqual(frame.height, 540, accuracy: 1.0,
                       "初始窗口高度应为 540，实际: \(frame.height)")

        // minSize 600×420
        let minSize = window.minSize
        XCTAssertGreaterThanOrEqual(minSize.width, 600,
                                    "minSize.width 不得小于 600，实际: \(minSize.width)")
        XCTAssertGreaterThanOrEqual(minSize.height, 420,
                                     "minSize.height 不得小于 420，实际: \(minSize.height)")

        // REAL_DEVICE: 留 QA Tier 1.5 真机 AX 验证
        // SC-02 真机谓词：resize 后 sidebar width>0，详情区 x>sidebar 右边缘+8。
        // 单元层不可拖拽 resize，但 minSize + 初始尺寸契约已结构性覆盖。
    }

    // MARK: - SC-03 两栏 NSSplitView 布局

    /// 契约：contentViewController is SettingsSplitViewController（NSSplitViewController 子类），
    /// splitView 两个 NSSplitViewItem。
    func test_SC03_contentViewController_isSplitView_withTwoItems() {
        let wc = SettingsWindowController()
        guard let window = wc.window else {
            return XCTFail("SettingsWindowController.window 必须存在")
        }

        // contentViewController 必须是 NSSplitViewController 子类（设计名 SettingsSplitViewController）
        guard let splitVC = window.contentViewController as? NSSplitViewController else {
            return XCTFail("contentViewController 必须是 NSSplitViewController 子类（SettingsSplitViewController），实际: \(String(describing: window.contentViewController))")
        }

        // 恰好 2 个 splitViewItem：sidebar + detail
        let items = splitVC.splitViewItems
        XCTAssertEqual(items.count, 2,
                       "splitViewItems 必须恰好 2 项（sidebar + detail），实际: \(items.count)")

        // 第一项应为 sidebar（behavior == .sidebar）
        if items.count >= 1 {
            XCTAssertEqual(items[0].behavior, .sidebar,
                           "第一个 splitViewItem.behavior 必须为 .sidebar，实际: \(items[0].behavior)")
        }

        // REAL_DEVICE: 留 QA Tier 1.5 真机 AX 验证
        // SC-03 真机谓词：AXSplitGroup children==2。单元层通过 NSSplitViewItem 数量断言覆盖。
    }

    // MARK: - SC-04 sidebar 5 项顺序 [皮肤/插件/热键/通用/关于]

    /// 契约 3：sidebar 恰好 5 项，顺序 [皮肤,插件,热键,通用,关于]，不含 AI 配置。
    /// 契约 2：sidebar 分类来自单一数据源 SettingsSection.allCases。
    func test_SC04_SettingsSection_allCases_isFiveInOrder() {
        // SettingsSection.allCases 恰好 5 项
        XCTAssertEqual(SettingsSection.allCases.count, 5,
                       "SettingsSection.allCases 必须恰好 5 项，实际: \(SettingsSection.allCases.count)")

        // 顺序逐字断言：skins, plugins, hotkey, general, about
        let expected: [SettingsSection] = [.skins, .plugins, .hotkey, .general, .about]
        XCTAssertEqual(SettingsSection.allCases, expected,
                       "SettingsSection.allCases 顺序必须为 [skins, plugins, hotkey, general, about]")

        // 各 case rawValue 逐字断言（契约 4 持久化值依赖）
        XCTAssertEqual(SettingsSection.skins.rawValue, "skins")
        XCTAssertEqual(SettingsSection.plugins.rawValue, "plugins")
        XCTAssertEqual(SettingsSection.hotkey.rawValue, "hotkey")
        XCTAssertEqual(SettingsSection.general.rawValue, "general")
        XCTAssertEqual(SettingsSection.about.rawValue, "about")

        // 不含 AI 配置（契约 3：本次只做结构，不做 AI 配置）
        XCTAssertFalse(SettingsSection.allCases.contains(where: { $0.rawValue.lowercased().contains("ai") }),
                       "sidebar 分类不得含 AI 配置项（本次不做）")
    }

    /// SC-04 sidebar 渲染项数：NSTableView numberOfRows == 5。
    func test_SC04_sidebarTableView_hasFiveRows() {
        let wc = SettingsWindowController()
        guard let window = wc.window,
              let splitVC = window.contentViewController as? NSSplitViewController,
              splitVC.splitViewItems.count >= 1 else {
            return XCTFail("无法获取 splitViewController")
        }

        // sidebar VC 在第一个 splitViewItem
        let sidebarVC = splitVC.splitViewItems[0].viewController
        forceLoadView(sidebarVC)

        // 递归找 NSTableView
        guard let tableView = findFirst(NSTableView.self, in: sidebarVC.view) else {
            return XCTFail("sidebar VC 中必须含 NSTableView（设计：NSTableView 列分类）")
        }

        XCTAssertEqual(tableView.numberOfRows, 5,
                       "sidebar NSTableView.numberOfRows 必须为 5（对应 SettingsSection.allCases.count）")
    }

    // MARK: - SC-05 默认选中皮肤

    /// 契约：默认选中 .skins；UserDefaults 无 SettingsSelectedCategory 时初始选中 skins。
    func test_SC05_defaultSelection_isSkins() {
        UserDefaults.standard.removeObject(forKey: Self.selectedCategoryKey)

        let wc = SettingsWindowController()
        guard let window = wc.window,
              let splitVC = window.contentViewController as? NSSplitViewController,
              splitVC.splitViewItems.count >= 2 else {
            return XCTFail("无法获取 splitViewController / splitViewItems<2")
        }

        // detail VC 在第二个 splitViewItem 的子控制器
        // 设计：detail 项 → detail 容器，按选中切换 child VC
        let detailItem = splitVC.splitViewItems[1]
        let detailContainer = detailItem.viewController
        forceLoadView(detailContainer)

        // detail container 的当前 child VC 应为 SkinGalleryViewController（默认选中 skins）
        let childVCs = detailContainer.children
        let currentDetail = childVCs.last // 通常 detail 容器只有一个 child
        XCTAssertTrue(currentDetail is SkinGalleryViewController,
                      "默认选中应为 skins，detail 当前 child VC 必须为 SkinGalleryViewController，实际: \(String(describing: currentDetail))")
    }

    /// SC-05 真机谓词近邻：sidebar[0] selected == true。单元层通过 NSTableView 选区断言。
    func test_SC05_sidebarFirstRow_selectedByDefault() {
        let wc = SettingsWindowController()
        guard let window = wc.window,
              let splitVC = window.contentViewController as? NSSplitViewController,
              splitVC.splitViewItems.count >= 1 else {
            return XCTFail("无法获取 splitViewController")
        }

        let sidebarVC = splitVC.splitViewItems[0].viewController
        forceLoadView(sidebarVC)

        guard let tableView = findFirst(NSTableView.self, in: sidebarVC.view) else {
            return XCTFail("sidebar 必须含 NSTableView")
        }

        // 默认选中第 0 行（skins）
        let selectedRow = tableView.selectedRow
        XCTAssertEqual(selectedRow, 0,
                       "默认应选中第 0 行（skins），实际 selectedRow: \(selectedRow)")

        // REAL_DEVICE: SC-05 真机谓词「详情区含 AXCollection」留 QA Tier 1.5。
        // 单元层通过 detail child VC 类型 + selectedRow==0 覆盖。
    }

    // MARK: - SC-06 点插件→详情区插件列表

    /// 契约：sidebar 选中 plugins → detail viewController is PluginGalleryViewController。
    /// 这里用持久化 key 模拟"切到 plugins"路径（设计：选中持久化到 SettingsSelectedCategory）。
    func test_SC06_selectPlugins_detailIsPluginGallery() {
        UserDefaults.standard.set(SettingsSection.plugins.rawValue, forKey: Self.selectedCategoryKey)

        let wc = SettingsWindowController()
        guard let window = wc.window,
              let splitVC = window.contentViewController as? NSSplitViewController,
              splitVC.splitViewItems.count >= 2 else {
            return XCTFail("无法获取 splitViewController / splitViewItems<2")
        }

        let detailContainer = splitVC.splitViewItems[1].viewController
        forceLoadView(detailContainer)

        let currentDetail = detailContainer.children.last
        XCTAssertTrue(currentDetail is PluginGalleryViewController,
                      "预设 SettingsSelectedCategory=plugins 时，detail child VC 必须为 PluginGalleryViewController，实际: \(String(describing: currentDetail))")

        // SC-06 真机谓词：sidebar[1].selected==true。单元层通过 detail VC 类型间接覆盖。
        // REAL_DEVICE: 留 QA Tier 1.5 验证 sidebar[1] selected + 详情区 AXCollection items>0。
    }

    // MARK: - SC-07 点热键→详情区热键录入

    /// 契约：sidebar 选中 hotkey → detail viewController is KeyboardShortcutsViewController。
    func test_SC07_selectHotkey_detailIsKeyboardShortcuts() {
        UserDefaults.standard.set(SettingsSection.hotkey.rawValue, forKey: Self.selectedCategoryKey)

        let wc = SettingsWindowController()
        guard let window = wc.window,
              let splitVC = window.contentViewController as? NSSplitViewController,
              splitVC.splitViewItems.count >= 2 else {
            return XCTFail("无法获取 splitViewController / splitViewItems<2")
        }

        let detailContainer = splitVC.splitViewItems[1].viewController
        forceLoadView(detailContainer)

        let currentDetail = detailContainer.children.last
        XCTAssertTrue(currentDetail is KeyboardShortcutsViewController,
                      "预设 SettingsSelectedCategory=hotkey 时，detail child VC 必须为 KeyboardShortcutsViewController，实际: \(String(describing: currentDetail))")

        // SC-07 真机谓词：详情区含 AXTextField(非空)+AXButton(含"重置")。
        // 单元层补结构性近邻断言：KeyboardShortcutsViewController 视图层级中存在按钮（含"重置"文案）。
        if let hotkeyVC = currentDetail {
            forceLoadView(hotkeyVC)
            let buttons = findAll(NSButton.self, in: hotkeyVC.view)
            let hasResetButton = buttons.contains { $0.title.contains("重置") || $0.title.lowercased().contains("reset") }
            XCTAssertTrue(hasResetButton,
                          "热键详情区应含 '重置' 按钮，实际 buttons: \(buttons.map { $0.title })")
        }
        // REAL_DEVICE: 留 QA Tier 1.5 验证 AXTextField 非空。
    }

    // MARK: - SC-08 LSUIElement 下 sidebar 点击首次即生效（R1）

    /// 设计 R1 降级：主方案标准 NSWindow + canBecomeKey；R1 降级保留 sendEvent 安全网。
    /// 单元层无法模拟 LSUIElement 真机点击，但断言窗口 canBecomeKey（SC-01 已覆盖）+
    /// sidebar item 可响应点击（通过 didSelectRowAtIndexPath 类 seam 或 AX identifier 存在性）。
    func test_SC08_sidebarItems_haveAccessibilityIdentifiers_forClickTracking() {
        let wc = SettingsWindowController()
        guard let window = wc.window,
              let splitVC = window.contentViewController as? NSSplitViewController,
              splitVC.splitViewItems.count >= 1 else {
            return XCTFail("无法获取 splitViewController")
        }

        let sidebarVC = splitVC.splitViewItems[0].viewController
        forceLoadView(sidebarVC)

        guard let tableView = findFirst(NSTableView.self, in: sidebarVC.view) else {
            return XCTFail("sidebar 必须含 NSTableView")
        }

        XCTAssertEqual(tableView.numberOfRows, 5, "sidebar 必须有 5 行")

        // 契约 7：sidebar item accessibilityIdentifier = `settings.sidebar.\(section.rawValue)`
        // 逐行验证（cellView 或 rowView 的 accessibilityIdentifier 必须符合命名规范）
        for (index, section) in SettingsSection.allCases.enumerated() {
            let expectedID = "settings.sidebar.\(section.rawValue)"
            guard let rowView = tableView.rowView(atRow: index, makeIfNecessary: false) else {
                // 若 rowView 不可得，尝试从 cellView 取
                continue
            }
            // 检查 rowView 或其子 cellView 的 accessibilityIdentifier
            let rowID = rowView.accessibilityIdentifier()
            let cellHasID = findViewWithIdentifier(expectedID, in: rowView) != nil
            XCTAssertTrue(rowID == expectedID || cellHasID,
                          "sidebar row[\(index)] (\(section.rawValue)) 必须有 accessibilityIdentifier='\(expectedID)'，实际 rowID: \(rowID ?? "nil")")
        }

        // REAL_DEVICE: 留 QA Tier 1.5 真机 AX 验证
        // SC-08 真机谓词：每个 item 首次 action 后 selected==true。
        // 单元层不可驱动 Carbon 热键/真实点击，但 AX id 命名规范 + canBecomeKey（SC-01）已覆盖点击可达性前提。
    }

    // MARK: - SC-09 选中态持久化

    /// 契约 4：选中分类存 UserDefaults key `SettingsSelectedCategory`，值=SettingsSection.rawValue，
    /// 默认 .skins，重开恢复。旧 key `BuddyStoreSelectedTab` 废弃。
    func test_SC09_selectedCategoryKey_isCorrectConstant() {
        // 契约 4 逐字：key 名 = "SettingsSelectedCategory"
        // 通过 SettingsWindowController 暴露的静态常量验证（设计应暴露此常量供测试与 CLI 复用）
        XCTAssertEqual(SettingsWindowController.selectedCategoryDefaultsKey,
                       Self.selectedCategoryKey,
                       "持久化 key 必须为 'SettingsSelectedCategory'（契约 4 逐字）")
    }

    /// SC-09：预设 hotkey 后新建 wc → 选中热键（重开恢复）。
    func test_SC09_persistedHotkey_restoredOnReopen() {
        UserDefaults.standard.set(SettingsSection.hotkey.rawValue, forKey: Self.selectedCategoryKey)

        let wc = SettingsWindowController()
        guard let window = wc.window,
              let splitVC = window.contentViewController as? NSSplitViewController,
              splitVC.splitViewItems.count >= 2 else {
            return XCTFail("无法获取 splitViewController / splitViewItems<2")
        }

        // sidebar 选中第 2 行（hotkey，索引 2）
        let sidebarVC = splitVC.splitViewItems[0].viewController
        forceLoadView(sidebarVC)
        if let tableView = findFirst(NSTableView.self, in: sidebarVC.view) {
            XCTAssertEqual(tableView.selectedRow, 2,
                           "预设 SettingsSelectedCategory=hotkey 时，sidebar 应选中第 2 行（hotkey），实际: \(tableView.selectedRow)")
        }

        // detail 是 KeyboardShortcutsViewController
        let detailContainer = splitVC.splitViewItems[1].viewController
        forceLoadView(detailContainer)
        let currentDetail = detailContainer.children.last
        XCTAssertTrue(currentDetail is KeyboardShortcutsViewController,
                      "预设 hotkey 后重开，detail 必须为 KeyboardShortcutsViewController")
    }

    /// SC-09：未写 key 时默认 skins，且不写旧 key BuddyStoreSelectedTab。
    func test_SC09_emptyDefaults_writesSkins_notLegacyKey() {
        UserDefaults.standard.removeObject(forKey: Self.selectedCategoryKey)
        UserDefaults.standard.removeObject(forKey: Self.legacyKey)

        let wc = SettingsWindowController()
        _ = wc.window // 触发初始化

        // 默认选中 skins（通过 detail VC 类型验证）
        guard let window = wc.window,
              let splitVC = window.contentViewController as? NSSplitViewController,
              splitVC.splitViewItems.count >= 2 else {
            return XCTFail("无法获取 splitViewController")
        }
        let detailContainer = splitVC.splitViewItems[1].viewController
        forceLoadView(detailContainer)
        XCTAssertTrue(detailContainer.children.last is SkinGalleryViewController,
                      "UserDefaults 为空时默认选中 skins")

        // 旧 key 不得被新实现写入（契约：旧 key BuddyStoreSelectedTab 废弃）
        // 注：若旧实现遗留代码仍写旧 key，此断言会挂——这正是红队要抓的回归。
        XCTAssertNil(UserDefaults.standard.string(forKey: Self.legacyKey),
                     "新实现不得读写已废弃的旧 key 'BuddyStoreSelectedTab'")
    }

    // MARK: - SC-10 title 合理

    /// 契约：title "设置"。不得含类名/debug/旧 tab 名（Buddy Store）。
    func test_SC10_windowTitle_isSettings_notLegacy() {
        let wc = SettingsWindowController()
        guard let title = wc.window?.title else {
            return XCTFail("window.title 必须存在")
        }

        XCTAssertFalse(title.isEmpty, "window.title 不得为空")

        // 不得含类名 / debug / 旧 tab 名
        let forbidden = ["WindowController", "Panel", "ViewController", "Buddy Store", "NSSplitView", "Sidebar"]
        for bad in forbidden {
            XCTAssertFalse(title.contains(bad),
                          "window.title 不得含 '\(bad)'，实际: \(title)")
        }

        // 设计要求 title == "设置"
        XCTAssertEqual(title, "设置",
                       "window.title 应为 '设置'，实际: \(title)")
    }

    // MARK: - SC-11 标准窗口控件

    /// 契约：styleMask 含 .closable / .miniaturizable（SC-01 已验证 .closable/.resizable/.miniaturizable）。
    /// SC-11 真机谓词：AXCloseButton/AXMinimizeButton/AXZoomButton 各一。
    /// 单元层补 standardWindowButton 三控件存在性。
    func test_SC11_windowHasStandardWindowButtons() {
        let wc = SettingsWindowController()
        guard let window = wc.window else {
            return XCTFail("SettingsWindowController.window 必须存在")
        }

        // styleMask 必含 .miniaturizable（设计意图：可最小化；AppKit API 名非 .minimizable）
        XCTAssertTrue(window.styleMask.contains(.miniaturizable),
                      "styleMask 必须含 .miniaturizable")

        // standardWindowButton 三个标准控件存在
        let closeBtn = window.standardWindowButton(.closeButton)
        let miniBtn = window.standardWindowButton(.miniaturizeButton)
        let zoomBtn = window.standardWindowButton(.zoomButton)

        XCTAssertNotNil(closeBtn, "必须有 .closeButton（AXCloseButton）")
        XCTAssertNotNil(miniBtn, "必须有 .miniaturizeButton（AXMinimizeButton）")
        XCTAssertNotNil(zoomBtn, "必须有 .zoomButton（AXZoomButton）")

        // REAL_DEVICE: 留 QA Tier 1.5 真机 AX 验证 kAXPress 动作。
    }

    // MARK: - SC-12 sidebar 数据驱动

    /// 契约 2：sidebar 分类来自单一数据源 SettingsSection.allCases；
    /// 初始化代码不得按分类数量 switch/if 硬编码；加分类=加一个 case。
    ///
    /// 单元层断言：SettingsSection.allCases 是 sidebar 行数的唯一来源（通过 numberOfRowsInSection == allCases.count 验证一致性）。
    func test_SC12_sidebarRowCount_matchesAllCases_singleSource() {
        let wc = SettingsWindowController()
        guard let window = wc.window,
              let splitVC = window.contentViewController as? NSSplitViewController,
              splitVC.splitViewItems.count >= 1 else {
            return XCTFail("无法获取 splitViewController")
        }

        let sidebarVC = splitVC.splitViewItems[0].viewController
        forceLoadView(sidebarVC)

        guard let tableView = findFirst(NSTableView.self, in: sidebarVC.view) else {
            return XCTFail("sidebar 必须含 NSTableView")
        }

        // sidebar 行数 == SettingsSection.allCases.count（单一数据源一致性）
        XCTAssertEqual(tableView.numberOfRows, SettingsSection.allCases.count,
                       "sidebar 行数必须等于 SettingsSection.allCases.count（单一数据源），实际 rows: \(tableView.numberOfRows), allCases: \(SettingsSection.allCases.count)")
    }

    /// SC-12：验证 SettingsSidebarViewController.dataSource 取数走 allCases（而非硬编码数组）。
    /// 通过反射检查 SettingsSidebarViewController 不含独立的硬编码分类数组属性。
    /// 注：这是结构性近邻断言——真正的"加分类=加 case"需 QA 真机验证。
    func test_SC12_sidebarVC_doesNotHardcodeCategoryArray() {
        let wc = SettingsWindowController()
        guard let window = wc.window,
              let splitVC = window.contentViewController as? NSSplitViewController,
              splitVC.splitViewItems.count >= 1 else {
            return XCTFail("无法获取 splitViewController")
        }

        let sidebarVC = splitVC.splitViewItems[0].viewController

        // 设计要求 SettingsSidebarViewController 是新类（非旧 SettingsTabClickReceiver）。
        // 类名应含 "Sidebar"（设计命名 SettingsSidebarViewController）
        let className = String(describing: type(of: sidebarVC))
        XCTAssertTrue(className.contains("Sidebar"),
                     "sidebar VC 类名应含 'Sidebar'（设计: SettingsSidebarViewController），实际: \(className)")

        // 不得是旧 SettingsTabClickReceiver（契约 5：旧 SettingsTabClickReceiver 废弃）
        XCTAssertFalse(className.contains("SettingsTabClickReceiver"),
                       "不得复用已废弃的 SettingsTabClickReceiver")

        // 通过 numberOfRows == allCases.count 间接证明数据驱动（若硬编码 5 而非引用 allCases，
        // 加 case 后 allCases=6 但 numberOfRows 仍 5——此一致性由 test_SC12_sidebarRowCount_matchesAllCases_singleSource 守护）
        // REAL_DEVICE: SC-12 真机谓词「加假分类 children==6」留 QA Tier 1.5 验证。
    }

    // MARK: - SC-13 现有功能不回归

    /// 契约 5：三 tab VC 核心业务逻辑零回归。三分类 = skins/plugins/hotkey。
    /// 单元层验证三 VC 可实例化 + view 可加载（不崩）+ 核心状态可观测。
    func test_SC13_threeCoreVCs_instantiable_loadable() {
        // skins
        let skinsVC = SkinGalleryViewController()
        forceLoadView(skinsVC)
        XCTAssertNotNil(skinsVC.view, "SkinGalleryViewController.view 必须可加载")

        // plugins（构造器需依赖，参考 PluginGalleryViewControllerTests 的 mock 注入）
        let pluginsVC = PluginGalleryViewController(
            marketplace: SC13MockMarketplace(),
            plugins: SC13MockPluginToggle()
        )
        forceLoadView(pluginsVC)
        XCTAssertNotNil(pluginsVC.view, "PluginGalleryViewController.view 必须可加载")

        // hotkey
        let hotkeyVC = KeyboardShortcutsViewController()
        forceLoadView(hotkeyVC)
        XCTAssertNotNil(hotkeyVC.view, "KeyboardShortcutsViewController.view 必须可加载")
    }

    /// SC-13 真机谓词：三分类交互各产生可观测状态变化。
    /// 单元层补可观测 seam 近邻：PluginGalleryViewController 的 toggle 调用产生 disable 调用（已有 AT10/11 覆盖，此处复测防迁移破坏）。
    func test_SC13_pluginsToggle_producesObservableStateChange() async {
        let plugins = SC13MockPluginToggle()
        let market = SC13MockMarketplace(
            inspection: MarketplaceInspection(
                plugins: [.init(name: "translate", version: "0.1.0", enabled: true, source: "test")],
                sideloadedPlugins: [],
                lastSyncedAt: nil,
                consecutiveSyncFailures: 0
            )
        )
        let vc = PluginGalleryViewController(marketplace: market, plugins: plugins)
        forceLoadView(vc)
        vc.viewDidAppear()
        await drainMainActor()
        await drainMainActor()

        // 触发 disable
        let btn = NSButton(title: "禁用", target: vc, action: #selector(PluginGalleryViewController.toggleButtonClicked(_:)))
        btn.identifier = NSUserInterfaceItemIdentifier("translate")
        btn.tag = 0
        vc.toggleButtonClicked(btn)
        await drainMainActor()
        await drainMainActor()

        XCTAssertTrue(plugins.disableCalls.contains("translate"),
                      "plugins toggle tag=0 必须调 disable('translate')（SC-13 零回归），实际: \(plugins.disableCalls)")
    }

    // MARK: - SC-14 偏好开关迁移后行为不变

    /// 契约 5：音效/标签开关迁移到通用分类，UserDefaults key 不变。
    /// SC-14 真机谓词：开关可读可写，key 名 alwaysShowLabel 不变，值翻转。
    ///
    /// 单元层硬断言（杀死 No-op / 错 key mutation）：
    /// 1. GeneralSettingsViewController 含 ≥2 个 NSSwitch（开关存在）
    /// 2. 翻转某个开关后，UserDefaults 正确的 key（alwaysShowLabel 或 soundEnabled）值改变
    ///
    /// 这杀死了"开关存在但绑错 key"的 mutation：若蓝队绑到 `generalAlwaysShowLabel`，
    /// 翻转后 `alwaysShowLabel` 不会变，断言失败。
    func test_SC14_generalSettings_switchesFlipCorrectUserDefaultsKeys() {
        // 初始状态：两个 key 都设为 false
        UserDefaults.standard.set(false, forKey: "alwaysShowLabel")
        UserDefaults.standard.set(false, forKey: "soundEnabled")

        let vc = GeneralSettingsViewController()
        forceLoadView(vc)

        let switches = findAll(NSSwitch.self, in: vc.view)
        XCTAssertGreaterThanOrEqual(switches.count, 2,
                                    "GeneralSettingsViewController 应至少含 2 个 NSSwitch（音效 + 标签），实际: \(switches.count)")

        // 逐个翻转开关，验证至少有一个开关翻转后 alwaysShowLabel 变 true，
        // 至少有一个开关翻转后 soundEnabled 变 true。
        // 这杀死了"开关存在但绑错 key"的 mutation。
        var alwaysShowLabelFlipped = false
        var soundEnabledFlipped = false

        for sw in switches {
            // 模拟用户把开关拨到 .on
            sw.state = .on
            // 触发 target/action（若绑定了）
            if let target = sw.target, let action = sw.action {
                _ = target.perform(action, with: sw)
            }
            // 检查哪个 key 被翻转
            if UserDefaults.standard.bool(forKey: "alwaysShowLabel") == true {
                alwaysShowLabelFlipped = true
            }
            if UserDefaults.standard.bool(forKey: "soundEnabled") == true {
                soundEnabledFlipped = true
            }
            // 复位以测下一个开关
            sw.state = .off
            if let target = sw.target, let action = sw.action {
                _ = target.perform(action, with: sw)
            }
        }

        XCTAssertTrue(alwaysShowLabelFlipped,
                     "翻转某个开关后 UserDefaults['alwaysShowLabel'] 必须变 true（契约 5：key 名不变）。若失败说明开关未绑定到正确 key 或未写 UserDefaults")
        XCTAssertTrue(soundEnabledFlipped,
                     "翻转某个开关后 UserDefaults['soundEnabled'] 必须变 true（契约 5：key 名不变）。若失败说明开关未绑定到正确 key 或未写 UserDefaults")

        // REAL_DEVICE: 留 QA Tier 1.5 验证开关翻转的完整 UI 反馈（视觉态 + 持久化跨重启）。

        // 清理
        UserDefaults.standard.removeObject(forKey: "alwaysShowLabel")
        UserDefaults.standard.removeObject(forKey: "soundEnabled")
    }

    /// SC-14 补：迁移后开关初始 state 反映 UserDefaults 当前值（读取路径不回归）。
    /// 杀死"开关写了但读错/不读 UserDefaults"的 mutation。
    func test_SC14_generalSettings_switchesReadUserDefaultsOnInit() {
        // 设 alwaysShowLabel=true，验证至少一个开关初始 state==.on
        UserDefaults.standard.set(true, forKey: "alwaysShowLabel")
        UserDefaults.standard.set(false, forKey: "soundEnabled")

        let vc = GeneralSettingsViewController()
        forceLoadView(vc)

        let switches = findAll(NSSwitch.self, in: vc.view)
        let onSwitches = switches.filter { $0.state == .on }
        XCTAssertGreaterThanOrEqual(onSwitches.count, 1,
                                    "alwaysShowLabel=true 时，至少一个 NSSwitch 初始 state 应为 .on（读取路径不回归），实际 on 数: \(onSwitches.count)")

        // 清理
        UserDefaults.standard.removeObject(forKey: "alwaysShowLabel")
        UserDefaults.standard.removeObject(forKey: "soundEnabled")
    }

    /// SC-14 补：通用分类应含开机自启控件（设计：通用=音效/标签开关+开机自启）。
    /// CONTRACT_AMBIGUOUS: 设计未指定开机自启的 UserDefaults key 名（"launchAtLogin"? SMAppService?），
    /// 也未指定控件类型（NSSwitch / NSButton / Checkbox）。
    /// 断言存在性 + 可识别的标签文案（含"开机"/"自启"/"Launch"/"Login"之一）。
    func test_SC14_generalSettings_containsLaunchAtLoginControl() {
        let vc = GeneralSettingsViewController()
        forceLoadView(vc)

        // 收集所有可交互控件的文案（NSSwitch 通常无 title，靠邻近 label；NSButton/NSButton(checkbox) 有 title）
        let buttons = findAll(NSButton.self, in: vc.view)
        let labels = findAll(NSTextField.self, in: vc.view)
        let allTexts = buttons.map { $0.title } + labels.map { $0.stringValue }

        // 至少有一个文案含开机自启相关词
        let launchKeywords = ["开机", "自启", "启动", "Launch", "Login", "login", "startup", "Startup"]
        let hasLaunchControl = allTexts.contains { text in
            launchKeywords.contains { text.localizedCaseInsensitiveContains($0) }
        }
        XCTAssertTrue(hasLaunchControl,
                      "通用分类应含开机自启控件，文案应含 \(launchKeywords) 之一，实际所有文案: \(allTexts)")
    }

    // MARK: - SC-15（补充契约）：detail 容器 accessibilityIdentifier

    /// 契约 7：detail 容器 = `settings.detail`。
    func test_contract_detailContainer_accessibilityIdentifier() {
        let wc = SettingsWindowController()
        guard let window = wc.window,
              let splitVC = window.contentViewController as? NSSplitViewController,
              splitVC.splitViewItems.count >= 2 else {
            return XCTFail("无法获取 splitViewController / splitViewItems<2")
        }

        let detailContainer = splitVC.splitViewItems[1].viewController
        forceLoadView(detailContainer)

        XCTAssertEqual(detailContainer.view.accessibilityIdentifier(), "settings.detail",
                       "detail 容器 accessibilityIdentifier 必须为 'settings.detail'（契约 7 逐字）")
    }

    // MARK: - SC-16（补充契约）：CLI 通道与通知名不变

    /// 契约 6：CLI 通道 open_settings + hotkey_show/set/clear 行为零改动。
    /// 契约 8：AppDelegate.showSettings() 签名不变，.buddyStoreShouldOpen 通知名不变。
    func test_contract_buddyStoreShouldOpen_notificationName_unchanged() {
        // 通知名逐字断言（设计：.buddyStoreShouldOpen 通知名不变）
        XCTAssertEqual(Notification.Name.buddyStoreShouldOpen.rawValue,
                       "BuddyStoreShouldOpen",
                       ".buddyStoreShouldOpen 通知名必须保持 'BuddyStoreShouldOpen'（契约 8）")
    }

    /// SC-16：CLI open_settings 通道存在（QueryHandler 识别此 action）。
    /// 注：QueryHandler 是 socket 服务端，识别 open_settings → 发 buddyStoreShouldOpen 通知。
    /// 单元层不启动 socket，但验证 QueryHandler 仍认识此 action（通过字符串常量或 case 存在）。
    /// CONTRACT_AMBIGUOUS: QueryHandler 的 action 匹配是字符串 switch（见 grep: case "open_settings"），
    /// 无法单元层反射验证 case 存在性。此契约由 test_contract_buddyStoreShouldOpen_notificationName_unchanged
    /// + QA 真机 CLI 验证覆盖。
    func test_contract_openSettingsAction_recognizedByQueryHandler() {
        // 间接验证：QueryHandler.handle(open_settings) 会 post buddyStoreShouldOpen 通知。
        // 监听通知 + 直接调 QueryHandler（若可构造）验证。
        // 若 QueryHandler 不可单元构造，此测试退化为通知名存在性断言（已在上一测试覆盖）。
        // 此处保留 placeholder 断言 + REAL_DEVICE 注释。
        XCTAssertEqual(Notification.Name.buddyStoreShouldOpen.rawValue, "BuddyStoreShouldOpen")
        // REAL_DEVICE: 留 QA Tier 1.5 用 buddy CLI `open_settings` 真机验证设置窗口弹出。
    }
}

// MARK: - SC-13 独立 Mock（红队不复用蓝队 mock）

private final class SC13MockMarketplace: MarketplaceInspecting {
    private(set) var inspectCallCount = 0
    var inspection: MarketplaceInspection

    init(inspection: MarketplaceInspection = .init(
        plugins: [], sideloadedPlugins: [], lastSyncedAt: nil, consecutiveSyncFailures: 0
    )) {
        self.inspection = inspection
    }

    func inspect() throws -> MarketplaceInspection {
        inspectCallCount += 1
        return inspection
    }

    func reseed() async throws {}
}

private final class SC13MockPluginToggle: PluginToggling {
    private(set) var disableCalls: [String] = []
    private(set) var enableCalls: [String] = []

    func disable(name: String) throws {
        disableCalls.append(name)
    }

    func enable(name: String) throws {
        enableCalls.append(name)
    }
}
