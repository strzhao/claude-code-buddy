import XCTest
import AppKit
@testable import BuddyCore

// MARK: - 红队验收测试：插件面板 frame 级谓词（stage-3 插件左栏固定 240，2026-07-10）
//
// 黑盒验收测试：基于设计文档 stage-3 承诺的 frame 级谓词下断言。
//
// 信息隔离铁律：本文件**不读取** docs/superpowers/plans/、蓝队 stage-3 改的
// PluginGalleryViewController 源码（具体约束代码）、蓝队的测试文件。仅对设计承诺的
// 「frame 级外部可观测行为」下断言（左栏宽度恒 240 / 多次布局稳定不跳）。
//
// 设计权威源（唯一真相）：
// - **AC-SPLIT-02**：插件面板左列表栏宽度恒 240（删原 200-260 区间 + 比例算法，消除拖动跳动）。
//   窗口宽 800 / 1400 两次读 sidebarTableView 的 enclosing container（PluginGalleryViewController
//   内部 NSSplitView 的左栏 = arrangedSubviews[0]）的 bounds.width，都 == 240。
//   杀死「左栏宽度在 200-260 区间漂移 / 比例算法随窗口宽缩放漂移 / 拖动后不回 240」回归。
//
// - **AC-SPLIT-04**：设置→插件切换时左栏不跳。进入 plugins 面板后左栏 width == 240，
//   多次 layoutSubtreeIfNeeded 后稳定不变。
//   杀死「进入插件面板瞬间左栏先变窄/宽再 settle（闪跳）/ 多次布局后左栏 drift」回归。
//
// 插件面板结构（验收前已知，基于现有公开代码，非 stage-3 改后代码）：
// PluginGalleryViewController 内部有自己的 NSSplitView（非顶层 SettingsSplitViewController 的）：
// 左 `sidebarView`（NSTableView 列表的 enclosing container）+ 右 `detailContainer`。
// NSSplitView 无 NSSplitViewItem 抽象（那是 NSSplitViewController 子类专用），
// 故用 splitView.arrangedSubviews[0]（即 add 顺序的第一个 = 左栏 container）读 bounds.width。
// splitView 自身有 AX id `settings.plugins.splitview`，可作定位锚点。
//
// 驱动方式（复用 stage-2 SettingsFrameAcceptanceTests 模式）：
// - SettingsWindowController().window.contentViewController as? SettingsSplitViewController
// - splitVC.testHook_selectSection(.plugins) 切到插件面板
// - splitVC.detailChildViewController as? PluginGalleryViewController 取插件面板
// - 递归找 PluginGalleryViewController.view 下的 NSSplitView（AX id settings.plugins.splitview），
//   splitView.arrangedSubviews.first 读 bounds.width
//
// 工作规则：每个谓词至少 1 个硬断言，失败即挂测试。不对实现状态容错。

@MainActor
final class PluginGalleryLayoutAcceptanceTests: XCTestCase {

    // MARK: - 持久化 key 清理（防其他测试污染）

    /// 选中分类持久化 key（与 SettingsSplitViewController.selectedCategoryDefaultsKey 同值）。
    private static let selectedCategoryKey = "SettingsSelectedCategory"

    /// 插件选中持久化 key（与 PluginGalleryViewController.selectedPluginDefaultsKey 同值，
    /// 防选中状态残留影响左栏 layout）。
    private static let selectedPluginKey = "SettingsSelectedPlugin"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: Self.selectedCategoryKey)
        UserDefaults.standard.removeObject(forKey: Self.selectedPluginKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Self.selectedCategoryKey)
        UserDefaults.standard.removeObject(forKey: Self.selectedPluginKey)
        super.tearDown()
    }

    // MARK: - 设计契约常量

    /// stage-3 设计承诺的插件面板左栏固定宽度。
    private static let expectedPluginLeftPaneWidth: CGFloat = 240

    // MARK: - Helpers

    /// 强制 view 加载（触发 loadView + viewDidLoad）。
    private func forceLoadView(_ vc: NSViewController) {
        _ = vc.view
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

    /// 递归找 view 子树（含自身）中第一个指定类型的子视图。
    private func findFirst<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let typed = view as? T { return typed }
        for sub in view.subviews {
            if let found = findFirst(type, in: sub) { return found }
        }
        return nil
    }

    /// 递归找 view 子树中 AX id 匹配的第一个 NSSplitView。
    /// 用 AX id `settings.plugins.splitview` 精确定位 PluginGalleryViewController 内部的 splitView，
    /// 避免误中顶层 SettingsSplitViewController 的 splitView（那个 AX id 不同）。
    private func findPluginSplitView(in view: NSView) -> NSSplitView? {
        if let splitView = view as? NSSplitView,
           splitView.accessibilityIdentifier() == "settings.plugins.splitview" {
            return splitView
        }
        for sub in view.subviews {
            if let found = findPluginSplitView(in: sub) { return found }
        }
        return nil
    }

    /// 切到 .plugins 面板并取 PluginGalleryViewController detail child。
    /// 强制 layout 收敛后再返回，确保 loadView + child containment 完成。
    private func switchToPluginGallery() -> (splitVC: SettingsSplitViewController,
                                             gallery: PluginGalleryViewController) {
        let splitVC = makeSplitVC()
        guard let window = splitVC.view.window else {
            XCTFail("splitVC.view.window 必须存在（SettingsWindowController 已建窗）")
            fatalError("unreachable — XCTFail 已挂")
        }
        forceLoadView(splitVC)

        // 切到插件面板
        splitVC.testHook_selectSection(.plugins)
        splitVC.view.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        // 取 detail child（必须已切到 .plugins）
        guard let gallery = splitVC.detailChildViewController as? PluginGalleryViewController else {
            XCTFail("""
                detailChildViewController 切到 .plugins 后必须是 PluginGalleryViewController，
                实际: \(String(describing: splitVC.detailChildViewController))
                """)
            fatalError("unreachable — XCTFail 已挂")
        }
        // 强制插件面板 view 加载（触发 setupSplitLayout）
        forceLoadView(gallery)
        gallery.view.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        return (splitVC, gallery)
    }

    /// 取插件面板内部 NSSplitView 的左栏宽度（splitView.arrangedSubviews[0]）。
    /// arrangedSubviews 按 addSubview 顺序返回，第一个 = 左栏 sidebarView container。
    /// 优先用 AX id 定位（更稳）；fallback 到递归找第一个 NSSplitView（防御 stage-3 改 AX id）。
    private func pluginLeftPaneWidth(of gallery: PluginGalleryViewController) -> CGFloat {
        // 优先 AX id 定位
        var splitView = findPluginSplitView(in: gallery.view)
        // fallback：递归找第一个 NSSplitView（若 stage-3 删/改了 AX id，仍能定位 splitView）
        if splitView == nil {
            splitView = findFirst(NSSplitView.self, in: gallery.view)
            XCTAssertNotNil(splitView,
                """
                PluginGalleryViewController.view 子树中必须存在 NSSplitView（左=sidebar 列表 + 右=detail），
                找不到说明插件面板双栏布局未建立。
                """)
        }
        guard let sv = splitView else {
            fatalError("unreachable — XCTFail 已挂")
        }
        // NSSplitView 无 NSSplitViewItem 抽象，arrangedSubviews 按 add 顺序，[0] = 左栏
        XCTAssertFalse(sv.arrangedSubviews.isEmpty,
            """
            插件面板 NSSplitView.arrangedSubviews 必须非空（至少左 sidebarView + 右 detailContainer 两个子视图）。
            实际为空说明 splitView 未 addSubview 两栏。
            """)
        guard let leftPane = sv.arrangedSubviews.first else {
            fatalError("unreachable — XCTFail 已挂")
        }
        return leftPane.bounds.width
    }

    // MARK: - AC-SPLIT-02：插件面板左栏宽度恒 240（窗口宽 800 / 1400 两次读）

    /// AC-SPLIT-02 [plugin-left-pane-fixed-240-across-widths]：切到 .plugins 面板，
    /// 窗口宽依次设 800 / 1400，每次 layoutSubtreeIfNeeded 后读插件面板内部 NSSplitView 左栏
    /// （arrangedSubviews[0]）的 bounds.width，两次都 == 240。
    ///
    /// 设计契约（stage-3）：插件面板左栏固定 240（删原 200-260 区间 + 比例算法）。
    /// 若某次宽度 ≠ 240，证明 stage-3 未把左栏固定为 240（仍用旧 200-260 区间让它在窗口缩放时漂移，
    /// 或 setPosition 比例算法让它随窗口宽变化）。
    ///
    /// 杀死「左栏在 200-260 区间漂移 / 比例算法随窗口宽缩放 / 窗口收窄后左栏被压缩」回归。
    func test_AC_SPLIT_02_pluginLeftPaneFixed240_acrossWidths() {
        let (splitVC, gallery) = switchToPluginGallery()
        guard let window = splitVC.view.window else {
            return XCTFail("splitVC.view.window 必须存在（SettingsWindowController 已建窗）")
        }

        let widthsToTest: [CGFloat] = [800, 1400]

        for width in widthsToTest {
            // 改窗口 contentView 宽度（保持高度，触发插件面板 splitView 重新布局左栏）
            let height = window.contentView?.bounds.height ?? 600
            window.setContentSize(NSSize(width: width, height: height))
            window.layoutIfNeeded()
            splitVC.view.layoutSubtreeIfNeeded()
            gallery.view.layoutSubtreeIfNeeded()

            let leftPaneWidth = pluginLeftPaneWidth(of: gallery)
            XCTAssertEqual(leftPaneWidth, Self.expectedPluginLeftPaneWidth, accuracy: 0.5,
                """
                AC-SPLIT-02 违反：窗口宽 \(width) 时插件面板左栏 bounds.width 必须 == 240，
                实际 \(leftPaneWidth)。stage-3 必须把左栏固定 240（删原 200-260 区间 + 比例算法），
                不随窗口缩放漂移。
                """)
        }
    }

    // MARK: - AC-SPLIT-04：设置→插件切换时左栏不跳（多次布局稳定 == 240）

    /// AC-SPLIT-04 [plugin-left-pane-stable-across-layouts]：切 .plugins 面板后，
    /// 连续多次 layoutSubtreeIfNeeded（模拟用户进入面板后 layout 反复 settle 的场景），
    /// 每次读插件面板左栏 width，必须始终 == 240（不跳动、不 drift）。
    ///
    /// 设计契约（stage-3）：删原比例算法（setPosition 在 viewDidLayout 每次重算）后，
    /// 左栏宽度不再随 layout pass 变化。若多次布局后左栏 width 发生变化，证明仍残留
    /// 会导致跳动的逻辑（如 viewDidLayout setPosition 重算 / autolayout constraint 互相打架）。
    ///
    /// 杀死「进入面板瞬间左栏先变窄再回 240（闪跳）/ 多次布局后左栏 drift」回归。
    func test_AC_SPLIT_04_pluginLeftPaneStable_acrossLayouts() {
        let (splitVC, gallery) = switchToPluginGallery()
        guard let window = splitVC.view.window else {
            return XCTFail("splitVC.view.window 必须存在（SettingsWindowController 已建窗）")
        }

        // 先收敛一次 baseline（窗口已 settle，左栏应已是 240）
        window.layoutIfNeeded()
        splitVC.view.layoutSubtreeIfNeeded()
        gallery.view.layoutSubtreeIfNeeded()
        let baselineWidth = pluginLeftPaneWidth(of: gallery)

        // baseline 必须先满足 240（否则 AC-SPLIT-02 已挂，这里单独再断一次）
        XCTAssertEqual(baselineWidth, Self.expectedPluginLeftPaneWidth, accuracy: 0.5,
            """
            AC-SPLIT-04 违反：进入 .plugins 面板收敛后左栏 baseline bounds.width 必须 == 240，
            实际 \(baselineWidth)。stage-3 必须把左栏固定 240。
            """)

        // 连续多次 layoutSubtreeIfNeeded（模拟用户进入面板后 layout 反复 settle）
        // 每次后读左栏 width，必须与 baseline 一致（不跳动）
        let layoutPasses = 5
        for pass in 1...layoutPasses {
            gallery.view.layoutSubtreeIfNeeded()
            splitVC.view.layoutSubtreeIfNeeded()
            window.layoutIfNeeded()

            let widthAfterLayout = pluginLeftPaneWidth(of: gallery)
            XCTAssertEqual(widthAfterLayout, baselineWidth, accuracy: 0.5,
                """
                AC-SPLIT-04 违反：第 \(pass) 次 layoutSubtreeIfNeeded 后左栏 bounds.width 必须 \
                与 baseline（\(baselineWidth)）一致，实际 \(widthAfterLayout)。
                左栏宽度在多次布局间跳动，证明仍有导致 drift 的逻辑（如 viewDidLayout setPosition 重算）。
                """)
            XCTAssertEqual(widthAfterLayout, Self.expectedPluginLeftPaneWidth, accuracy: 0.5,
                """
                AC-SPLIT-04 违反：第 \(pass) 次 layoutSubtreeIfNeeded 后左栏 bounds.width 必须 == 240，
                实际 \(widthAfterLayout)。
                """)
        }
    }
}
