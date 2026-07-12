import XCTest
import AppKit
@testable import BuddyCore

// MARK: - SettingsLayoutAcceptanceTests
//
// 蓝队 stage-2 frame 级谓词验收（AX 唯一性修订 + sidebar 固定宽）。
//
// AC-AX-01：全窗递归 identifier=="settings.detail" 命中唯一（仅活动 child root view）。
//   覆盖 plan-reviewer blocker B1/B2 修复：容器 view / 空态 view 已改用别的 id，
//   settings.detail 仅由 :160 child root view 持有，逐 section 遍历命中数 == 1。
//
// AC-SPLIT-01：sidebar 宽恒 200（删 180-240 区间后固定）。
//   经 SettingsWindowController 建真实 window，三次窗口宽读 sidebar view.bounds.width == 200。
//
// 信息隔离：本文件是蓝队自验收，与红队 SettingsFrameAcceptanceTests 独立（后者黑盒同契约）。

@MainActor
final class SettingsLayoutAcceptanceTests: XCTestCase {

    /// AC-AX-01：全窗递归 identifier==settings.detail 命中唯一（仅 :160 child）。
    /// 逐 section 切换后断言命中数 == 1，杀死「容器 / 空态 view 抢占 settings.detail id」回归。
    func test_AC_AX_01_settingsDetailUnique_acrossSections() {
        let splitVC = makeSplitVC()
        forceLoadView(splitVC)

        for section in SettingsSection.allCases {
            splitVC.testHook_selectSection(section)
            splitVC.view.layoutSubtreeIfNeeded()
            let matches = findAllSubviews(in: splitVC.view) { $0.accessibilityIdentifier() == "settings.detail" }
            XCTAssertEqual(matches.count, 1,
                           """
                           AC-AX-01 违反：section=\(section.rawValue) 下 settings.detail 命中数必须 == 1，\
                           实际 \(matches.count)。仅活动 child root view 应持该 id。
                           """)
        }
    }

    /// AC-SPLIT-01：sidebar 宽恒 200（三次窗口宽读 sidebar view.bounds.width）。
    func test_AC_SPLIT_01_sidebarFixed200() {
        let splitVC = makeSplitVC()
        guard let window = splitVC.view.window else {
            return XCTFail("splitVC.view.window 必须存在（SettingsWindowController 已建窗）")
        }
        forceLoadView(splitVC)

        for width in [800.0, 1000.0, 1400.0] {
            let height = window.contentView?.bounds.height ?? 600
            window.setContentSize(NSSize(width: width, height: height))
            window.layoutIfNeeded()
            splitVC.view.layoutSubtreeIfNeeded()

            let sidebarWidth = sidebarView(of: splitVC).bounds.width
            XCTAssertEqual(sidebarWidth, SettingsTheme.sidebarWidth, accuracy: 0.5,
                           """
                           AC-SPLIT-01 违反：窗口宽 \(width) 时 sidebar.bounds.width 必须 == \
                           \(SettingsTheme.sidebarWidth)，实际 \(sidebarWidth)。
                           """)
        }
    }

    // MARK: - Helpers

    private func makeSplitVC() -> SettingsSplitViewController {
        let wc = SettingsWindowController()
        // splitVC 现作 host 的 child（非 contentViewController），经 wc.splitViewController 取。
        guard let splitVC = wc.splitViewController else {
            fatalError("SettingsWindowController.splitViewController 必须存在")
        }
        return splitVC
    }

    private func forceLoadView(_ vc: NSViewController) {
        _ = vc.view
        vc.view.layoutSubtreeIfNeeded()
    }

    /// 取 sidebar root view（splitViewItems[0]，AppKit public 属性，无需 @testable 改 sidebarItem 可见性）。
    private func sidebarView(of splitVC: SettingsSplitViewController) -> NSView {
        guard splitVC.splitViewItems.count >= 1 else {
            fatalError("splitViewItems 必须至少 1 项（sidebar）")
        }
        return splitVC.splitViewItems[0].viewController.view
    }

    /// 递归收集满足谓词的全部子视图。
    private func findAllSubviews(in view: NSView, where predicate: (NSView) -> Bool) -> [NSView] {
        var result: [NSView] = []
        if predicate(view) { result.append(view) }
        for sub in view.subviews {
            result.append(contentsOf: findAllSubviews(in: sub, where: predicate))
        }
        return result
    }
}
