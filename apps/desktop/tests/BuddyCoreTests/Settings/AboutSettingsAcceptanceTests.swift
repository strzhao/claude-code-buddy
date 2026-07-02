import XCTest
import AppKit
@testable import BuddyCore

// MARK: - 红队验收测试：关于页 3 按钮同行 — AC-ABOUT-ROW / AC-ABOUT-STATUS（T7 + C5）
//
// 设计权威源（逐字断言的契约）：
// - T7（#4 关于页 3 按钮同一行）：`AboutSettingsViewController.swift:119-194`
//   新增 `buttonRow: NSStackView`（horizontal，centerX）含 `checkUpdateButton, feedbackButton, repoButton`。
//   状态行 `progressIndicator + statusLabel + upgradeButton` 放 `buttonRow` 正下方一行（centerX）。
//   约束：buttonRow.top == versionLabel.bottom + (groupSpacing+4)；
//   状态行 top == buttonRow.bottom + rowSpacing。
//   `renderUpdateArea`（line 229-282）状态机逻辑完全不动，只改控件几何位置。
// - 契约 C5：`UpdateAreaState` + `renderUpdateArea` 渲染逻辑不变，仅改控件几何约束
//   （位置从垂直堆叠 → 按钮行 + 状态行）。
//
// 工作规则：黑盒视角，实例化 AboutSettingsViewController，遍历子视图断言。
//           AC-ABOUT-STATUS 必须强断言三态，杀死 no-op（不能只断言 view exists）。

@MainActor
final class AboutSettingsAcceptanceTests: XCTestCase {

    // MARK: - AC-ABOUT-ROW [det-machine] 检查更新/反馈/开源 3 按钮 centerY 同一水平线

    /// AC-ABOUT-ROW：实例化 AboutSettingsViewController，遍历子视图断言 checkUpdate/feedback/repo
    /// 三按钮 vertical 中心线相等（同一水平行）。
    ///
    /// 黑盒识别：三按钮都是 NSButton，按 title 匹配（"检查更新"/"反馈问题"/"开源地址"）。
    /// T7 设计：三按钮在一个水平 NSStackView（buttonRow）内 → centerY 相等。
    func test_AC_ABOUT_ROW_threeButtons_sameHorizontalLine() {
        let vc = AboutSettingsViewController()
        _ = vc.view // force loadView

        // 触发布局（约束需 layout 后 frame 才有效）
        vc.view.layoutSubtreeIfNeeded()

        let buttons = findAll(NSButton.self, in: vc.view)
        let checkUpdate = buttons.first { $0.title.contains("检查更新") || $0.title.lowercased().contains("check") }
        let feedback = buttons.first { $0.title.contains("反馈") }
        let repo = buttons.first { $0.title.contains("开源") || $0.title.lowercased().contains("repo") || $0.title.lowercased().contains("github") }

        XCTAssertNotNil(checkUpdate, "必须含 '检查更新' 按钮，实际 buttons: \(buttons.map { $0.title })")
        XCTAssertNotNil(feedback, "必须含 '反馈' 按钮，实际 buttons: \(buttons.map { $0.title })")
        XCTAssertNotNil(repo, "必须含 '开源' 按钮，实际 buttons: \(buttons.map { $0.title })")

        guard let cu = checkUpdate, let fb = feedback, let rp = repo else { return }

        // 三按钮 centerY 必须相等（同一水平行）——T7 核心契约
        // 允许 1pt 浮点容差（Auto Layout 求解后微小漂移）
        let cuCY = cu.frame.midY
        let fbCY = fb.frame.midY
        let rpCY = rp.frame.midY

        XCTAssertEqual(cuCY, fbCY, accuracy: 1.0,
                       """
                       AC-ABOUT-ROW: '检查更新'(midY=\(cuCY)) 与 '反馈'(midY=\(fbCY)) centerY 必须相等（T7 同一行），
                       差值: \(abs(cuCY - fbCY))pt
                       """)
        XCTAssertEqual(cuCY, rpCY, accuracy: 1.0,
                       """
                       AC-ABOUT-ROW: '检查更新'(midY=\(cuCY)) 与 '开源'(midY=\(rpCY)) centerY 必须相等（T7 同一行），
                       差值: \(abs(cuCY - rpCY))pt
                       """)
    }

    /// AC-ABOUT-ROW 补：三按钮在水平方向不重叠（X 上有间隔）。
    /// 杀死"三按钮 frame 重叠/挤一起"的 mutation。
    func test_AC_ABOUT_ROW_threeButtons_horizontallySeparated() {
        let vc = AboutSettingsViewController()
        _ = vc.view
        vc.view.layoutSubtreeIfNeeded()

        let buttons = findAll(NSButton.self, in: vc.view)
        let checkUpdate = buttons.first { $0.title.contains("检查更新") }
        let feedback = buttons.first { $0.title.contains("反馈") }
        let repo = buttons.first { $0.title.contains("开源") }

        guard let cu = checkUpdate, let fb = feedback, let rp = repo else {
            return XCTFail("三按钮必须存在（前置见 test_AC_ABOUT_ROW_threeButtons_sameHorizontalLine）")
        }

        // 按 minX 排序，相邻按钮的 maxX < 下一按钮的 minX（不重叠）
        let sorted = [cu, fb, rp].sorted { $0.frame.minX < $1.frame.minX }
        for i in 0..<(sorted.count - 1) {
            let left = sorted[i]
            let right = sorted[i + 1]
            XCTAssertLessThanOrEqual(left.frame.maxX, right.frame.minX,
                                     """
                                     AC-ABOUT-ROW: 相邻按钮不得水平重叠。
                                     '\(left.title)'.maxX=\(left.frame.maxX) > '\(right.title)'.minX=\(right.frame.minX)
                                     """)
        }
    }

    /// AC-ABOUT-ROW 补：状态行（statusLabel/progressIndicator/upgradeButton）在 buttonRow 下方。
    /// 杀死"状态行还在按钮上方（旧垂直堆叠未改）"的 mutation。
    /// 注：statusLabel/progressIndicator 在 idle 态可能 hidden，但 frame 仍可读（hidden 不影响 frame）。
    func test_AC_ABOUT_ROW_statusRow_belowButtonRow() {
        let vc = AboutSettingsViewController()
        _ = vc.view
        vc.view.layoutSubtreeIfNeeded()

        let buttons = findAll(NSButton.self, in: vc.view)
        let checkUpdate = buttons.first { $0.title.contains("检查更新") }
        guard let cu = checkUpdate else {
            return XCTFail("必须含 '检查更新' 按钮")
        }

        // statusLabel 是 NSTextField（labelWithString: ""），在 AboutSettingsViewController 内
        // 找非 button 的 NSTextField 中最可能是 statusLabel 的（含状态文案或为空 label）
        // CONTRACT_AMBIGUOUS: statusLabel 初始 stringValue 为 ""，难以唯一识别。
        // 退化为：断言存在某个 NSTextField（labelWithString）在 checkUpdateButton 下方
        // （状态行整体在 buttonRow 下方，至少有一个 label）。
        let labels = findAll(NSTextField.self, in: vc.view).filter { tf in
            // 排除 versionLabel（通常含版本号）和其他已知 label
            // statusLabel 初始空，但 renderUpdateArea 后会有文案
            return true
        }

        // 至少有一个 label 的 minY < checkUpdateButton.minY（在按钮下方）
        // 注：NSView 坐标系 origin 在左下，minY 小 = 在下方
        let labelsBelowButton = labels.filter { $0.frame.minY < cu.frame.minY }
        XCTAssertFalse(labelsBelowButton.isEmpty,
                       """
                       AC-ABOUT-ROW: 状态行必须在 buttonRow 下方。
                       checkUpdateButton.minY=\(cu.frame.minY)，但找不到在其下方的 label（状态行）。
                       实际 labels minY: \(labels.map { $0.frame.minY })
                       """)
    }

    // MARK: - AC-ABOUT-STATUS [det-machine, C5] 三态 statusLabel + upgradeButton.isHidden 断言

    /// AC-ABOUT-STATUS：关于页更新区状态转移：
    /// - checking → statusLabel=="正在检查更新..." + upgradeButton.isHidden==true
    /// - updateAvailable(v) → statusLabel=="发现新版本 v" + upgradeButton.isHidden==false
    /// - upToDate → statusLabel=="✓ 已是最新版本" + upgradeButton.isHidden==true
    ///
    /// Mutation-Survival：强断言三态的 stringValue + isHidden 翻转，
    /// 杀死"状态机 no-op（永远 idle / isHidden 不翻转 / 文案写错）"的 mutation。
    /// 通过 vc.updateAreaState = .xxx 触发 renderUpdateArea（didSet）。
    func test_AC_ABOUT_STATUS_threeState_machineRendering() {
        let vc = AboutSettingsViewController()
        _ = vc.view

        // 公开 seam：vc.updateAreaState（didSet → renderUpdateArea）
        // 公开只读 accessor：updateAreaStatusText（statusLabel.stringValue）/ isUpgradeButtonHidden

        // --- 态 1: checking ---
        vc.updateAreaState = .checking
        XCTAssertEqual(vc.updateAreaStatusText, "正在检查更新...",
                       "AC-ABOUT-STATUS[checking]: statusLabel 必须为 '正在检查更新...'，实际: '\(vc.updateAreaStatusText)'")
        XCTAssertTrue(vc.isUpgradeButtonHidden,
                      "AC-ABOUT-STATUS[checking]: upgradeButton 必须隐藏，实际 isHidden: \(vc.isUpgradeButtonHidden)")

        // --- 态 2: updateAvailable(v) ---
        vc.updateAreaState = .updateAvailable("1.2.3")
        XCTAssertEqual(vc.updateAreaStatusText, "发现新版本 1.2.3",
                       """
                       AC-ABOUT-STATUS[updateAvailable]: statusLabel 必须为 '发现新版本 1.2.3'，
                       实际: '\(vc.updateAreaStatusText)'
                       """)
        XCTAssertFalse(vc.isUpgradeButtonHidden,
                       "AC-ABOUT-STATUS[updateAvailable]: upgradeButton 必须显示，实际 isHidden: \(vc.isUpgradeButtonHidden)")

        // --- 态 3: upToDate ---
        vc.updateAreaState = .upToDate
        XCTAssertEqual(vc.updateAreaStatusText, "✓ 已是最新版本",
                       "AC-ABOUT-STATUS[upToDate]: statusLabel 必须为 '✓ 已是最新版本'，实际: '\(vc.updateAreaStatusText)'")
        XCTAssertTrue(vc.isUpgradeButtonHidden,
                      "AC-ABOUT-STATUS[upToDate]: upgradeButton 必须隐藏，实际 isHidden: \(vc.isUpgradeButtonHidden)")
    }

    /// AC-ABOUT-STATUS 补：状态切换前后 isUpgradeButtonHidden 必须真翻转（防 stale）。
    /// 杀死"renderUpdateArea 漏改 isHidden / 状态切换不重渲"的 mutation。
    func test_AC_ABOUT_STATUS_upgradeButtonVisibility_actuallyFlips() {
        let vc = AboutSettingsViewController()
        _ = vc.view

        // checking → hidden
        vc.updateAreaState = .checking
        let hiddenWhenChecking = vc.isUpgradeButtonHidden

        // updateAvailable → 显示
        vc.updateAreaState = .updateAvailable("9.9.9")
        let hiddenWhenUpdateAvail = vc.isUpgradeButtonHidden

        // 必须翻转（checking=true, updateAvailable=false）
        XCTAssertTrue(hiddenWhenChecking,
                      "checking 态 upgradeButton 必须 hidden")
        XCTAssertFalse(hiddenWhenUpdateAvail,
                       "updateAvailable 态 upgradeButton 必须显示")
        XCTAssertNotEqual(hiddenWhenChecking, hiddenWhenUpdateAvail,
                          "AC-ABOUT-STATUS: checking↔updateAvailable 切换时 isUpgradeButtonHidden 必须翻转，否则 renderUpdateArea 是 no-op")
    }

    /// AC-ABOUT-STATUS 补：statusLabel 文案在三态间必须真变化（防 stale / 硬编码）。
    func test_AC_ABOUT_STATUS_statusText_actuallyChanges() {
        let vc = AboutSettingsViewController()
        _ = vc.view

        vc.updateAreaState = .checking
        let s1 = vc.updateAreaStatusText

        vc.updateAreaState = .upToDate
        let s2 = vc.updateAreaStatusText

        vc.updateAreaState = .updateAvailable("2.0.0")
        let s3 = vc.updateAreaStatusText

        XCTAssertNotEqual(s1, s2, "checking↔upToDate 文案必须不同，否则状态机 no-op")
        XCTAssertNotEqual(s2, s3, "upToDate↔updateAvailable 文案必须不同")
        XCTAssertNotEqual(s1, s3, "checking↔updateAvailable 文案必须不同")
    }

    // MARK: - Helpers

    private func findAll<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        var result: [T] = []
        if let typed = view as? T { result.append(typed) }
        for sub in view.subviews {
            result.append(contentsOf: findAll(type, in: sub))
        }
        return result
    }
}
