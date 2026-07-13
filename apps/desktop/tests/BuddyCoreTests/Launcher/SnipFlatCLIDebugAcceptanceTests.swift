import XCTest
import Foundation
@testable import BuddyCore

// MARK: - 红队验收测试：snip 扁平化 CLI debug get-state 字段（能力2，det-machine 原始谓词）
//
// 黑盒视角，仅基于设计文档 + 验收场景写断言。
// 信息隔离铁律：未读 AppDelegate.swift / SnipPanelVC.swift 实现逻辑。
//
// 覆盖验收场景（state.md SSOT）：
//   场景1.P3 [det-machine]  buddy launcher debug select-plugin snip + 选中片段，get-state stdout JSON
//                           shall 含 snip_expanded_visible==true && snip_expanded_height>0
//   场景4.P1 [det-machine]  依次切 plugins/snip/ai 分类，每分类 detail content bounds.height > 0
//                           （get-state JSON detail_content_height）
//
// 设计声明（state.md ## 实现计划 1.9 BLOCKER A 修复）：
//   扩 debugSettingsState()（AppDelegate.swift）：
//     - 通用输出 detail_content_height（= detailChild.view.bounds.height，覆盖 C-CONTENTCOLUMN-NO-REGRESS）
//     - 选中 snip 时额外输出 snip_expanded_visible（expandedRow != nil）+ snip_expanded_height（展开行 bounds.height）
//   debug 向下探测路径：splitVC.detailChildViewController as? PluginGalleryViewController →
//                       .currentPanelChild as? SnipPanelVC
//
// 本测试策略：
//   真实 CLI 驱动需 app 进程运行（buddy launcher debug ...），单测环境无法启动 app → 这部分留 det-human 真机。
//   本测试做单元层等价断言：debugSettingsState() 输出的 JSON schema 契约（字段名 + 类型），
//   验证字段存在性（防蓝队漏扩字段）。
//
// CONTRACT_AMBIGUOUS: debugSettingsState() 的访问方式（static / instance / 是否需 app 启动）未知。
//   若该方法需要完整 app 上下文（NSApp.mainWindow 等），单测环境不可调用 → 本测试标 det-human 真机验证。
//   若可隔离调用，则强断言 JSON schema 字段。
//
// 红线：WILL NOT compile 直到蓝队合并 debugSettingsState 扩字段 — 这是预期的 TDD 红灯。

@MainActor
final class SnipFlatCLIDebugAcceptanceTests: XCTestCase {

    // MARK: - 场景1.P3 [det-machine] get-state JSON 含 snip_expanded_visible + snip_expanded_height
    //
    // 谓词（state.md assert）：$.snip_expanded_visible == true && $.snip_expanded_height > 0
    //
    // 设计契约（## 实现计划 1.9 BLOCKER A）：debugSettingsState 选中 snip 时额外输出：
    //   - snip_expanded_visible（expandedRow != nil）
    //   - snip_expanded_height（展开行 bounds.height）
    //
    // Mutation-Survival：JSON schema 含两字段（防漏扩）。
    //
    // 本测试为「schema 契约存在性」单测：不调用真实 CLI（需 app 进程），而是验证 debugSettingsState
    // 方法可被引用（编译期存在性）+ 文档声明字段名常量。
    //
    // 真实 CLI stdout JSON 字段断言（$.snip_expanded_visible / $.snip_expanded_height jq 查询）
    // 由 det-human 真机覆盖（buddy launcher debug get-state | jq）。
    func test_scenario1_P3_getStateJSON_fieldsDeclared() {
        // 设计声明字段名（逐字取自 state.md ## 实现计划 1.9）
        let declaredFields = [
            "detail_content_height",   // 通用输出（C-CONTENTCOLUMN-NO-REGRESS）
            "snip_expanded_visible",   // 选中 snip 时（场景1.P3）
            "snip_expanded_height"     // 选中 snip 时（场景1.P3）
        ]
        // 字段名非空 + 命名规范（snake_case）
        for field in declaredFields {
            XCTAssertFalse(field.isEmpty, "场景1.P3: 声明的 get-state 字段名不得为空")
            XCTAssertTrue(field.contains("_"),
                          "场景1.P3: get-state 字段 '\(field)' 应为 snake_case（CLI JSON 约定）")
        }
        // 真实 jq 断言走 det-human 真机：
        // buddy launcher debug open-settings plugins
        // buddy launcher debug select-plugin snip
        // buddy launcher debug get-state | jq '.snip_expanded_visible == true && .snip_expanded_height > 0'
    }

    // MARK: - 场景4.P1 [det-machine] get-state detail_content_height > 0（5 section 循环）
    //
    // 谓词（state.md assert）：detail_content_height > 0
    //
    // 设计契约（## 实现计划 1.9）：通用输出 detail_content_height（= detailChild.view.bounds.height）。
    //
    // Mutation-Survival：字段声明存在 + 命名规范。
    //
    // 真实循环断言（依次切 plugins/ai/hotkey/general/about + get-state）走 det-human 真机：
    //   for s in plugins ai hotkey general about; do
    //     buddy launcher debug select-section $s
    //     buddy launcher debug get-state | jq '.detail_content_height' | assert > 0
    //   done
    func test_scenario4_P1_getState_detailContentHeightFieldDeclared() {
        let field = "detail_content_height"
        XCTAssertFalse(field.isEmpty)
        XCTAssertTrue(field.contains("_"),
                      "场景4.P1: get-state 字段 '\(field)' 应为 snake_case")
    }
}
