import XCTest
import AppKit
@testable import BuddyCore

// MARK: - 红队验收测试：设置页白屏 + 窗口未充满（autopilot 2026-07-12）
//
// 信息隔离铁律：本测试基于**设计契约**编写，未读取以下蓝队实现文件的当前内容 / diff：
//   - apps/desktop/Sources/ClaudeCodeBuddy/Settings/Components/ContentColumnView.swift
//   - apps/desktop/Sources/ClaudeCodeBuddy/Settings/SettingsSplitViewController.swift
//   - apps/desktop/Sources/ClaudeCodeBuddy/Settings/SettingsWindowController.swift
// 仅对设计承诺的「headless 可靠的代码契约 + 结构断言」下断言。
//
// ⚠️ headless 盲区说明（重要）：
//   C1 / AC-RENDER 的核心（NSScrollView documentView 在嵌套 NSSplitViewController 下塌缩 0×0）
//   **headless swift test 复现不了**（需完整 window server session，见
//   .autopilot/knowledge/patterns/ 2026-07-03 / 2026-07-09 同款）。故：
//   - 不写「实例化 ContentColumnView → 断言 documentView.bounds > 0」的行为断言
//     （headless 下 documentView 可能仍 0，会假阴性）。
//   - C1 / AC-RENDER 的行为验证由编排器 Tier 1.5 真机 bounds 已铁证（documentView 1712×1050）。
//   - 本文件聚焦 headless 可靠的代码契约 + 结构断言（autoresizingMask / containment 类型 /
//     styleMask / 兜底宽度 / 持久化 key / skins 隔离守护）。
//
// 设计权威源（逐字断言的契约）：
// - C1 [det-machine]：6 section 切换后 detail child root 内任一 ContentColumnView.documentView.bounds > 0
//   → 真机由 Tier 1.5 验证；本文件守 containment 结构（C1-STRUCT）。
// - C2 [det-machine/code]：window.frame.width ≥ visibleFrame.width×0.95 ∧ height ≥ ×0.9
//   → headless 若 NSScreen.main=nil 用兜底常量；本文件守 styleMask.resizable + width≥1000。
// - C3 [det-machine/code]：SkinGalleryViewController **不**引用 ContentColumnView（回归守护）。
// - C4 [code]：ContentColumnView.documentView 用 autoresizingMask 含 .width。
// - C5：select-plugin snip 后窗口高度不塌缩（真机由编排器验证；本文件守 resizable）。
// - C6 [persist]：SettingsSelectedCategory key 不变；rawValue 往返。

@MainActor
final class SettingsDetailRenderAcceptanceTests: XCTestCase {

    // MARK: - 持久化 key 清理（防测试间污染）

    private static let selectedCategoryKey = "SettingsSelectedCategory"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: Self.selectedCategoryKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Self.selectedCategoryKey)
        super.tearDown()
    }

    // MARK: - AC-SKINS-INTACT / C3（回归守护，最高价值）
    //
    // 谓词：SkinGalleryViewController 类的源码文件**不含**字符串 "ContentColumnView"。
    //
    // 为何重要：skins 是唯一**不**用 ContentColumnView 而正常渲染的 section。
    // 如果有人「统一化」误改让 skins 也用 ContentColumnView，skins 会染上白屏病
    // （documentView 在嵌套 NSSplitViewController 下塌缩）。此断言是防回归的硬守护。
    //
    // headless 可靠性：纯文件读取 + 字符串包含判断，无 AppKit 依赖，完全确定。

    func test_AC_SKINS_INTACT_skinGallerySourceDoesNotReferenceContentColumnView() {
        // 定位源文件（相对仓库根的固定路径；tests 在 apps/desktop 下跑，cwd 可信）
        let possiblePaths = [
            "apps/desktop/Sources/ClaudeCodeBuddy/Settings/SkinGalleryViewController.swift",
            "Sources/ClaudeCodeBuddy/Settings/SkinGalleryViewController.swift",
        ]
        let sourceURL = possiblePaths.lazy.compactMap { relative -> URL? in
            // 尝试相对 cwd 与测试 bundle 所在目录两处
            let candidates = [
                URL(fileURLWithPath: relative),
                URL(fileURLWithPath: #file)
                    .deletingLastPathComponent()
                    .appendingPathComponent(relative),
            ]
            return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
        }.first

        guard let url = sourceURL else {
            return XCTFail("""
                找不到 SkinGalleryViewController.swift 源文件，尝试路径: \(possiblePaths)
                """)
        }

        let source: String
        do {
            source = try String(contentsOf: url, encoding: .utf8)
        } catch {
            return XCTFail("读取源文件失败 \(url.path): \(error)")
        }

        XCTAssertFalse(source.contains("ContentColumnView"),
                       """
                       AC-SKINS-INTACT / C3 失败：SkinGalleryViewController.swift 不得引用 \
                       ContentColumnView。skins 是唯一不用它而正常渲染的 section（C3 回归守护）；
                       若引入 ContentColumnView，skins 会染上 documentView 塌缩的白屏病。
                       文件: \(url.path)
                       """)
    }

    // MARK: - C4（代码契约：documentView autoresizingMask 含 .width）
    //
    // 谓词：ContentColumnView.scrollView.documentView?.autoresizingMask 包含 .width。
    //
    // 为何重要：白屏根因之一 = documentView 在嵌套 NSSplitViewController 下塌缩 0×0。
    // 修复用 autoresizingMask 含 .width（而非 autolayout 约束钉 contentView.width），
    // 让 documentView 横向随 scrollView 变宽。此断言守护该代码契约不被回退。
    //
    // headless 可靠性：autoresizingMask 是 NSView 配置态属性，实例化后即可读，
    // 不依赖 window server / 布局收敛，完全确定。

    func test_C4_documentViewAutoresizingMaskContainsWidth() {
        let cv = ContentColumnView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))

        guard let documentView = cv.scrollView.documentView else {
            return XCTFail("ContentColumnView.scrollView.documentView 必须存在（NSScrollView 标配）")
        }

        let mask = documentView.autoresizingMask
        XCTAssertTrue(mask.contains(.width),
                      """
                      C4 失败：documentView.autoresizingMask 必须含 .width \
                      （横向随 scrollView 变宽，防嵌套 NSSplitViewController 下塌缩 0×0）。
                      实际 mask: \(mask)
                      """)
    }

    // MARK: - AC-RESIZABLE（窗口可缩放）
    //
    // 谓词：SettingsWindowController().window.styleMask 含 .resizable。
    //
    // 为何重要：C2 要求窗口充满屏幕，前提是窗口可缩放（否则 styleMask 锁死无法放大）。
    // 同时 C5（select-plugin snip 后窗口高度不塌缩）也依赖 resizable 维持用户可调整。
    //
    // headless 可靠性：styleMask 是 NSWindow 配置态，实例化即定，无布局依赖。

    func test_AC_RESIZABLE_windowStyleMaskContainsResizable() {
        let wc = SettingsWindowController()
        guard let window = wc.window else {
            return XCTFail("SettingsWindowController.window 必须存在（实例化即建窗）")
        }

        XCTAssertTrue(window.styleMask.contains(.resizable),
                      """
                      AC-RESIZABLE 失败：styleMask 必须含 .resizable。
                      C2 窗口充满屏幕 / C5 snip 后高度不塌缩 都依赖 resizable。
                      实际 styleMask: \(window.styleMask)
                      """)
    }

    // MARK: - AC-WINDOW / C2（兜底：width ≥ 1000）
    //
    // 谓词：SettingsWindowController().window.frame.width ≥ 1000。
    //
    // 为何用兜底常量而非 == visibleFrame：headless 下 NSScreen.main 可能 nil，
    // computeInitialSize 会用 fallback（如 1200×800 或 visibleFrame 兜底）。
    // 断言 == visibleFrame 在 headless 不稳（假阴性）；断言 ≥ 1000 既排除旧 808×572
    // 塌缩值，又对 fallback 友好。真机 visibleFrame×0.95 的行为由 Tier 1.5 验证。
    //
    // headless 可靠性：window.frame.width 实例化即定（由 computeInitialSize 算），
    // 不依赖 layout 收敛或 window server 完整 session。

    func test_AC_WINDOW_frameWidthAtLeast1000() {
        let wc = SettingsWindowController()
        guard let window = wc.window else {
            return XCTFail("SettingsWindowController.window 必须存在")
        }

        let width = window.frame.width
        XCTAssertGreaterThanOrEqual(width, 1000,
                                    """
                                    AC-WINDOW / C2 失败：窗口 width 必须 ≥ 1000pt。
                                    设计 C2 要求充满屏幕（visibleFrame.width×0.95）；headless 若 NSScreen.main=nil
                                    用 fallback 也应 ≥ 1000（兜底常量 1200）。旧塌缩值 808 必须挂测试。
                                    实际 width: \(width)
                                    """)
    }

    // MARK: - C1-STRUCT（containment 结构守护）
    //
    // 谓词：对每个 SettingsSection，testHook_selectSection 后 detailChildViewController
    // 是设计契约指定的 VC 类型。
    //
    // 为何重要：C1 的结构层守护。白屏根因是 detail child 内 ContentColumnView 塌缩；
    // 如果 containment 切换本身错乱（detail child 类型不对），ContentColumnView 根本
    // 不会被实例化，Tier 1.5 的 documentView 断言也无从触发。此测试守 detail 切换契约。
    //
    // mapping（设计契约）：
    //   .plugins → PluginGalleryViewController
    //   .hotkey  → KeyboardShortcutsViewController
    //   .ai      → ProviderSettingsViewController
    //   .skins   → SkinGalleryViewController
    //   .general → GeneralSettingsViewController
    //   .about   → AboutSettingsViewController
    //
    // headless 可靠性：containment 切换是 NSSplitViewController API 调用，
    // detailChildViewController 类型在 testHook_selectSection 后即定，不依赖渲染。

    func test_C1_STRUCT_detailChildTypePerSection() {
        let splitVC = makeSplitVC()
        forceLoadView(splitVC)

        // (section, 期望 VC 类型名) —— 用类型名字符串比较，避免 Swift `is` 不接受动态类型变量。
        let expectations: [(SettingsSection, String)] = [
            (.plugins, "PluginGalleryViewController"),
            (.hotkey, "KeyboardShortcutsViewController"),
            (.ai, "ProviderSettingsViewController"),
            (.skins, "SkinGalleryViewController"),
            (.general, "GeneralSettingsViewController"),
            (.about, "AboutSettingsViewController"),
        ]

        for (section, expectedTypeName) in expectations {
            splitVC.testHook_selectSection(section)
            splitVC.view.layoutSubtreeIfNeeded()

            let detail = splitVC.detailChildViewController
            let actualTypeName = detail.map { String(describing: type(of: $0)) }
                ?? "nil"
            XCTAssertEqual(actualTypeName, expectedTypeName,
                           """
                           C1-STRUCT 失败：section .\(section.rawValue) 的 detailChildViewController \
                           必须是 \(expectedTypeName)，实际: \(actualTypeName)
                           """)
        }
    }

    // MARK: - C1-STRUCT 补：6 个 section 全覆盖（防漏 case）
    //
    // 谓词：SettingsSection.allCases 恰好 6 项，且每个都能成功切换到非 nil detail。
    //
    // 为何重要：防新增 section 后忘记接 detail containment（会白屏），也防删 case。
    //
    // headless 可靠性：同上。

    func test_C1_STRUCT_allSixSectionsSwitchToNonNullDetail() {
        let splitVC = makeSplitVC()
        forceLoadView(splitVC)

        XCTAssertEqual(SettingsSection.allCases.count, 6,
                       "section 必须恰好 6 项（防加/删 case 漏接 detail containment）")

        for section in SettingsSection.allCases {
            splitVC.testHook_selectSection(section)
            splitVC.view.layoutSubtreeIfNeeded()

            XCTAssertNotNil(splitVC.detailChildViewController,
                            """
                            C1-STRUCT 失败：section .\(section.rawValue) 切换后 \
                            detailChildViewController 不得为 nil（否则该 section 必白屏）
                            """)
        }
    }

    // MARK: - C6（持久化 key 不变 + rawValue 往返）
    //
    // 谓词 1：SettingsSplitViewController.selectedCategoryDefaultsKey == "SettingsSelectedCategory"。
    // 谓词 2：SettingsSection.allCases 每个 rawValue 可往返 init。
    //
    // 为何重要：本轮修复不应动持久化契约；旧用户的 selection 不得丢失。
    //
    // headless 可靠性：静态常量 + 纯字符串往返，无任何 AppKit 依赖。

    func test_C6_selectedCategoryDefaultsKeyUnchanged() {
        XCTAssertEqual(SettingsWindowController.selectedCategoryDefaultsKey,
                       "SettingsSelectedCategory",
                       """
                       C6 失败：持久化 key 必须保持 'SettingsSelectedCategory' \
                       （本轮修复不应动持久化契约，旧用户 selection 不得丢失）
                       """)
    }

    func test_C6_sectionRawValueRoundTrip() {
        for section in SettingsSection.allCases {
            XCTAssertEqual(SettingsSection(rawValue: section.rawValue), section,
                           """
                           C6 失败：section .\(section.rawValue) 的 rawValue 必须可往返 \
                           （持久化兼容，旧值仍能解析）
                           """)
        }
    }

    // MARK: - Helpers

    /// 强制 view 加载（触发 loadView + viewDidLoad）。
    private func forceLoadView(_ vc: NSViewController) {
        _ = vc.view
    }

    /// 从 SettingsWindowController 取 SettingsSplitViewController。
    /// splitVC 作 host 的 child（非 contentViewController），经 wc.splitViewController 取。
    private func makeSplitVC() -> SettingsSplitViewController {
        let wc = SettingsWindowController()
        guard wc.window != nil else {
            XCTFail("SettingsWindowController.window 必须存在（实例化即建窗）")
            fatalError("unreachable — XCTFail 已挂")
        }
        guard let splitVC = wc.splitViewController else {
            XCTFail("SettingsWindowController.splitViewController 必须存在")
            fatalError("unreachable — XCTFail 已挂")
        }
        return splitVC
    }
}
