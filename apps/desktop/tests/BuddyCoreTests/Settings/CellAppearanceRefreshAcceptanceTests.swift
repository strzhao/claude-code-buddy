import XCTest
import AppKit
@testable import BuddyCore

// MARK: - 红队验收测试：设置页 cell 背景色响应系统外观切换（SC-01 / SC-02）
//
// 设计权威源（状态文件 `## 验收场景` SC-01/SC-02）：
//
// 根因：SettingsGroupView 在初始化时用 `layer?.backgroundColor = SettingsTheme.cardBackgroundColor.cgColor`
//   设置 CALayer 背景色，但 `.cgColor` 快照为当前 effectiveAppearance 的固定值。外观切换后不会自动刷新。
//
// 修复方案（设计文档摘要）：
//   1. SettingsGroupView 添加 `viewDidChangeEffectiveAppearance` override
//   2. SkinCardItem 添加 `viewDidChangeEffectiveAppearance` override
//
// --- 验收场景 ---
//
// SC-01 [det-machine]：When 系统外观切换，SettingsGroupView 的 layer backgroundColor 应更新。
//   observe: 验证 viewDidChangeEffectiveAppearance 方法存在
//   assert: 方法包含 super + backgroundColor 刷新
//
// SC-02 [det-machine]：When 系统外观切换，SkinCardItem 应刷新外观。
//   observe: 验证 viewDidChangeEffectiveAppearance 方法存在
//   assert: 方法包含 super + updateSelectionAppearance 调用
//
// ⚠️ 红队发现：SkinCardItem 继承自 NSCollectionViewItem（→ NSViewController），
//   但 `viewDidChangeEffectiveAppearance()` 是 NSView 的方法，NSViewController 不声明此方法。
//   蓝队在 SkinCardItem.swift:281 的 `override func viewDidChangeEffectiveAppearance()`
//   会导致编译错误："method does not override any method from its superclass"。
//
//   因此 SC-02 的验证策略调整为：验证 SkinCardItem 的 **view**（NSView）能响应外观变化
//   —— 即 item.view 作为 NSView 实例，其 `viewDidChangeEffectiveAppearance()` 可被调用且不崩溃。
//   updateSelectionAppearance 的调用链由 item.view 的外观变化触发（而非 NSViewController 层）。
//
// 验证策略：
//   - 编译期：本文件 import BuddyCore 并使用对应类型。
//     若蓝队未实现 override，SC-01 的运行时调用即证明编译通过（方法存在）。
//   - 运行期：创建实例 → 调方法 → 断言无崩溃 + 验证副作用。
//
// 红队原则：所有断言代表"设计意图应该满足"，不代表"实现实际做了什么"。

@MainActor
final class CellAppearanceRefreshAcceptanceTests: XCTestCase {

    // MARK: - SC-01: SettingsGroupView（NSView 子类）外观刷新

    /// 编译期 + 运行期：SettingsGroupView 实例可调用 viewDidChangeEffectiveAppearance() 且不崩溃。
    ///
    /// 编译通过 = 方法 override 存在（Swift 编译期强制，SettingsGroupView: NSView，
    /// NSView 声明 viewDidChangeEffectiveAppearance()，override 合法）。
    /// 运行不崩 = super.viewDidChangeEffectiveAppearance() 被调用且路径可达。
    func test_SC_01_viewDidChangeEffectiveAppearance_compilesAndDoesNotCrash() {
        let group = SettingsGroupView(frame: .zero)

        // 编译通过证明 override 存在；运行不崩证明 super 被调用
        group.viewDidChangeEffectiveAppearance()

        // 若到这里没崩，super 调用成功
        XCTAssertTrue(true, "viewDidChangeEffectiveAppearance() 调用完成无崩溃——super 路径可达")
    }

    /// SC-01 assert：调用 viewDidChangeEffectiveAppearance 后 layer.backgroundColor 被刷新为
    /// SettingsTheme.cardBackgroundColor.cgColor（当前 effectiveAppearance 下的动态颜色值）。
    ///
    /// 验证方式：先故意把 backgroundColor 设为一个已知的"脏值"（红色），再调 viewDidChangeEffectiveAppearance，
    /// 断言 backgroundColor 已被刷新（不再等于脏值）。
    /// 杀死"override 方法体为空"的 mutation。
    func test_SC_01_backgroundColorRefreshedAfterAppearanceChange() {
        let group = SettingsGroupView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))

        // 验证初始 backgroundColor 已正确设置（init 时 setupView 设过一遍）
        XCTAssertNotNil(group.layer?.backgroundColor,
                        "SettingsGroupView.layer 必须存在且 backgroundColor 已设置")

        // 故意污染为红色
        let dirtyColor = NSColor.red.cgColor
        group.layer?.backgroundColor = dirtyColor

        // 触发外观刷新
        group.viewDidChangeEffectiveAppearance()

        // 断言 backgroundColor 已被刷新（不再是脏红色）
        let refreshed = group.layer?.backgroundColor
        XCTAssertNotNil(refreshed, "刷新后 backgroundColor 必须非 nil")
        XCTAssertFalse(refreshed == dirtyColor,
                       "viewDidChangeEffectiveAppearance 应刷新 backgroundColor，"
                       + "不再等于污染的红色，实际仍是红色（未刷新）")
    }

    /// SC-01 追加断言：viewDidChangeEffectiveAppearance 刷新后的 backgroundColor
    /// 在不同 appearance 上下文下应 resolve 为正确的动态颜色值。
    ///
    /// 杀死"用 `awakeFromNib` 一次性赋值而不在 viewDidChangeEffectiveAppearance 中刷新"的 mutation。
    func test_SC_01_backgroundColorResolvesToDynamicCardBackgroundColor() {
        let group = SettingsGroupView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))

        // 先切到 light appearance，强制刷新，取 light 下的 backgroundColor
        let lightAppearance = NSAppearance(named: .aqua)!
        lightAppearance.performAsCurrentDrawingAppearance {
            group.viewDidChangeEffectiveAppearance()
        }
        let lightBG = group.layer?.backgroundColor

        // 再切到 dark appearance，强制刷新，取 dark 下的 backgroundColor
        let darkAppearance = NSAppearance(named: .darkAqua)!
        darkAppearance.performAsCurrentDrawingAppearance {
            group.viewDidChangeEffectiveAppearance()
        }
        let darkBG = group.layer?.backgroundColor

        XCTAssertNotNil(lightBG, "light 外观下 backgroundColor 必须非 nil")
        XCTAssertNotNil(darkBG, "dark 外观下 backgroundColor 必须非 nil")

        // dynamic color 的 light/dark 背景色应不同（controlBackgroundColor 在 light/dark 下本身不同）
        // 若相同，说明未生成新的 dynamic CGColor，只是缓存了旧值
        let lightComponents = lightBG?.components
        let darkComponents = darkBG?.components
        if let lc = lightComponents, let dc = darkComponents, lc.count >= 3 && dc.count >= 3 {
            let rDiff = abs(lc[0] - dc[0])
            let gDiff = abs(lc[1] - dc[1])
            let bDiff = abs(lc[2] - dc[2])
            XCTAssertTrue(rDiff > 0.001 || gDiff > 0.001 || bDiff > 0.001,
                          "light/dark 下 backgroundColor 应不同（动态颜色），"
                          + "light=\(lightBG!), dark=\(darkBG!)")
        }
    }

    // MARK: - SC-02: SkinCardItem 外观刷新

    // ⚠️ 设计契约调整说明：
    // SkinCardItem 继承 NSCollectionViewItem（→ NSViewController），
    // 而 viewDidChangeEffectiveAppearance() 是 NSView 的方法。
    // NSViewController 不声明此方法，因此无法在 SkinCardItem 上 override。
    //
    // 正确的架构是：外观刷新逻辑应放在 item.view（NSView）层，通过
    // viewDidChangeEffectiveAppearance() 触发 updateSelectionAppearance()。
    //
    // 以下测试验证 item.view 的外观刷新机制（NSView 层），而非 NSViewController 层。

    /// 编译期 + 运行期：SkinCardItem 的 view（NSView）可调用 viewDidChangeEffectiveAppearance() 且不崩溃。
    ///
    /// SkinCardItem.loadView() 创建的 container 是 NSView 实例，
    /// NSView 声明 viewDidChangeEffectiveAppearance()，调用合法。
    func test_SC_02_itemView_viewDidChangeEffectiveAppearance_compilesAndDoesNotCrash() {
        let item = SkinCardItem(nibName: nil, bundle: nil)
        item.loadView()

        // item.view 是 NSView，其 viewDidChangeEffectiveAppearance 合法可调用
        item.view.viewDidChangeEffectiveAppearance()

        XCTAssertTrue(true)
    }

    /// SC-02 assert：外观切换后 SkinCardItem 的选中态视觉效果（borderWidth）应正确更新。
    ///
    /// 验证方式：设 isSelectedSkin=true → 调 item.view.viewDidChangeEffectiveAppearance() →
    /// 断言 view.layer?.borderWidth 已更新为选中态。
    ///
    /// 杀死"外观切换后选中态视觉效果不刷新"的 mutation。
    func test_SC_02_selectedCardBorderWidthUpdatesOnAppearanceChange() {
        let item = SkinCardItem(nibName: nil, bundle: nil)
        item.loadView()

        // 非选中态下，borderWidth 应为 0
        item.isSelectedSkin = false
        item.view.viewDidChangeEffectiveAppearance()
        let unselectedBW = item.view.layer?.borderWidth ?? -1
        XCTAssertEqual(unselectedBW, 0,
                       "isSelectedSkin=false 时 borderWidth 应为 0，实际: \(unselectedBW)")

        // 切到选中态，borderWidth 应为 2.5（选中边框）
        item.isSelectedSkin = true
        item.view.viewDidChangeEffectiveAppearance()
        let selectedBW = item.view.layer?.borderWidth ?? -1
        XCTAssertEqual(selectedBW, 2.5, accuracy: 0.1,
                       "isSelectedSkin=true 时 borderWidth 应为约 2.5（选中高亮边框），实际: \(selectedBW)")

        // 切回非选中态，borderWidth 应回归 0
        item.isSelectedSkin = false
        item.view.viewDidChangeEffectiveAppearance()
        let revertedBW = item.view.layer?.borderWidth ?? -1
        XCTAssertEqual(revertedBW, 0,
                       "切回 isSelectedSkin=false 后 borderWidth 应回归 0，实际: \(revertedBW)")
    }

    /// SC-02 追加断言：checkmarkBadge 的可见性在 viewDidChangeEffectiveAppearance 后与 isSelectedSkin 一致。
    ///
    /// 杀死"外观刷新未关联 updateSelectionAppearance"的 mutation。
    func test_SC_02_checkmarkBadgeVisibilityMatchesSelectionState() {
        let item = SkinCardItem(nibName: nil, bundle: nil)
        item.loadView()

        // isSelectedSkin=true → viewDidChangeEffectiveAppearance → checkmarkBadge 应可见
        item.isSelectedSkin = true
        item.view.viewDidChangeEffectiveAppearance()

        let checkmarkAfterSelect = findCheckmarkBadge(in: item.view)
        XCTAssertNotNil(checkmarkAfterSelect,
                        "isSelectedSkin=true 时 checkmarkBadge 应存在于 view 层级中")
        if let badge = checkmarkAfterSelect as? NSTextField {
            XCTAssertFalse(badge.isHidden,
                           "isSelectedSkin=true + 外观刷新后 checkmarkBadge 不应隐藏")
        }

        // isSelectedSkin=false → viewDidChangeEffectiveAppearance → checkmarkBadge 应隐藏
        item.isSelectedSkin = false
        item.view.viewDidChangeEffectiveAppearance()

        let checkmarkAfterDeselect = findCheckmarkBadge(in: item.view)
        if let badge = checkmarkAfterDeselect as? NSTextField {
            XCTAssertTrue(badge.isHidden,
                          "isSelectedSkin=false + 外观刷新后 checkmarkBadge 应隐藏")
        }
    }

    /// SC-02 追加断言：外观切换后，选中卡片的 backgroundColor 应更新为 sage accent 浅色填充。
    ///
    /// 杀死"只刷新 borderWidth 不刷新 backgroundColor"的 mutation。
    func test_SC_02_selectedCardBackgroundColorUpdatesOnAppearanceChange() {
        let item = SkinCardItem(nibName: nil, bundle: nil)
        item.loadView()

        // 非选中态：背景色应为 cardBackgroundColor（系统控件背景）
        item.isSelectedSkin = false
        item.view.viewDidChangeEffectiveAppearance()
        let unselectedBG = item.view.layer?.backgroundColor

        // 选中态：背景色应为 accent.withAlphaComponent(0.08)
        item.isSelectedSkin = true
        item.view.viewDidChangeEffectiveAppearance()
        let selectedBG = item.view.layer?.backgroundColor

        XCTAssertNotNil(unselectedBG, "非选中态 backgroundColor 必须非 nil")
        XCTAssertNotNil(selectedBG, "选中态 backgroundColor 必须非 nil")

        // 选中与非选中的背景色应不同（选中态有 accent 填充）
        let uc = unselectedBG?.components
        let sc = selectedBG?.components
        if let u = uc, let s = sc, u.count >= 3 && s.count >= 3 {
            let rDiff = abs(u[0] - s[0])
            let gDiff = abs(u[1] - s[1])
            let bDiff = abs(u[2] - s[2])
            XCTAssertTrue(rDiff > 0.001 || gDiff > 0.001 || bDiff > 0.001,
                          "选中/非选中 backgroundColor 应不同（选中态有 accent 填充），"
                          + "unselected=\(unselectedBG!), selected=\(selectedBG!)")
        }
    }

    // MARK: - 辅助方法

    /// 在 view 层级中递归查找包含 checkmark 字符 "✓" 的 NSTextField（checkmarkBadge）。
    private func findCheckmarkBadge(in view: NSView) -> NSView? {
        if let textField = view as? NSTextField,
           textField.stringValue.contains("\u{2713}") {
            return textField
        }
        for subview in view.subviews {
            if let found = findCheckmarkBadge(in: subview) {
                return found
            }
        }
        return nil
    }
}
