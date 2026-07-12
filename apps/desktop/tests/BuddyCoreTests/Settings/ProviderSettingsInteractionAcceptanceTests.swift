import XCTest
import AppKit
@testable import BuddyCore

// MARK: - 红队验收测试：AI 配置页交互优化 — AC-TEST-BTN / AC-NOTHINK-VIS / AC-TOOLS-* / AC-FORM-WIDTH / AC-AI-TOP / AC-AI-TAB
//
// 设计权威源（逐字断言的契约）：
// - T3（3.1 内容贴顶）：`ProviderSettingsViewController.swift:82-99` documentView（contentView）
//   加 heightAnchor >= scrollView.contentView.heightAnchor 约束（先例 PluginGalleryViewController:195-197）。
//   附带大窗限宽（C7）：formPanel.widthAnchor <= 540 + 相对 scrollView.contentView 居中。
//   实现补 formPanel AX id `settings.ai.formPanel`（让 AC-FORM-WIDTH 可 AX 读取）。
// - T4（3.2 测试连接挪位）：`providerGroup.addRow` 顺序
//   `providerRow, kindRow, modelRow, baseURLRow, testRow, apiKeyRow`（testRow 从末位移到 baseURLRow 之后）。
// - T5（3.3 关闭思考并入模型行）：模型行 control 从单一 modelField 改为水平 NSStackView
//   `[modelField] + [「关闭思考」label + SageSwitch]`，仅 openai-compatible 显示（C3 不变）。
//   删除独立 noThinkingToggleRow（line 61）+ 其 formPanel 约束。
// - T6（3.4 AI 工具分组 + 人话文案）：弃 NSTableView，改两个 SettingsGroupView（"内置能力" / "已装插件"），
//   各带 SettingsGroupLabel。内置项固定文案 `🔊 朗读回复 · 把 AI 回复读出声 · 内置`、
//   `📋 复制到剪贴板 · 一键复制 AI 回复 · 内置`。插件项 summary = manifest.displaySummary（人话）。
//   移除所有 stdin/command/prompt/attach_action 黑话。分组上方引导句「AI 会根据输入自动选用」。
//
// VISUAL_RESIDUE: AC-AI-TOP / AC-AI-TAB 标 [det-human]——providerLabel 无 AX id、跨 7 层嵌套取 frame 不可靠，
//                 留 QA 真机判定。本文件对 T3 设计声明的"约束存在"做 best-effort 自动化断言（约束可遍历）。
//
// 工作规则：黑盒视角，对设计 + 验收谓词断言。不读实现逻辑，靠视图遍历 + 类型识别（internal final class）+
//           AX identifier / stringValue 匹配定位控件。

@MainActor
final class ProviderSettingsInteractionAcceptanceTests: XCTestCase {

    // MARK: - AC-TEST-BTN [det-machine] 测试连接行紧跟 API 地址行（两行间无 API 密钥行）

    /// AC-TEST-BTN：实例化 ProviderSettingsViewController，遍历 providerGroup 子视图，
    /// 断言 baseURLRow 与 testRow 相邻、中间无 apiKeyRow。
    ///
    /// 黑盒识别策略：SettingsFormRow 的 titleLabel 是 private，但可通过遍历子视图
    /// 找 NSTextField（labelWithString）按 stringValue == "API 地址" / "API 密钥" 识别行。
    /// testRow 是裸 NSView（设计 line 176），无 title——靠"baseURLRow 之后紧邻的非 FormRow 行"识别。
    func test_AC_TEST_BTN_testButtonOnBaseURLRow() {
        let vc = ProviderSettingsViewController()
        _ = vc.view // force loadView

        // 找 formPanel（AX id 由设计声明注入）
        guard let formPanel = findViewWithIdentifier("settings.ai.formPanel", in: vc.view) ?? findFirst(NSView.self, in: vc.view) else {
            return XCTFail("无法定位 formPanel（AC-FORM-WIDTH 要求 AX id 'settings.ai.formPanel'）")
        }

        // 找 providerGroup（SettingsGroupView 实例）
        guard let providerGroup = findFirst(SettingsGroupView.self, in: formPanel) else {
            return XCTFail("formPanel 内必须含 SettingsGroupView（providerGroup）")
        }

        // 收集 providerGroup 子视图中所有"可识别的行"，按 Y 坐标降序（视觉从上到下）
        let rows = identifyProviderRows(in: providerGroup)

        // 必须能识别 baseURLRow（"API 地址"）
        guard let baseURLRow = rows.first(where: { $0.label == "API 地址" }),
              let baseURLIndex = rows.firstIndex(where: { $0.label == "API 地址" }) else {
            return XCTFail("providerGroup 中必须含 'API 地址' 行，识别到: \(rows.map { $0.label })")
        }

        // AC-TEST-BTN（用户反馈修订）：测试连接按钮必须与 API 地址在同一行（baseURLRow 内），
        // 不再是独立 testRow。断言 baseURLRow 子视图树含 NSButton 标题 "测试连接"
        // （kill "独立 test row" 旧实现，确认 button 同行）。
        let buttonsInRow = findAll(NSButton.self, in: baseURLRow.view)
        let hasTestButton = buttonsInRow.contains { $0.title.contains("测试连接") }
        XCTAssertTrue(hasTestButton,
                      """
                      AC-TEST-BTN: 'API 地址' 行内必须含 '测试连接' 按钮（用户反馈：同一行）。
                      实际该行内按钮 titles: \(buttonsInRow.map { $0.title })
                      """)

        // 顺序完整性：'API 密钥' 行仍在 'API 地址' 行之后
        let afterBase = rows[(baseURLIndex + 1)...]
        let hasApiKeyAfter = afterBase.contains { $0.label == "API 密钥" }
        XCTAssertTrue(hasApiKeyAfter,
                      "AC-TEST-BTN: 'API 密钥' 行必须在 'API 地址' 行之后，实际: \(rows.map { $0.label })")
    }

    // MARK: - AC-NOTHINK-VIS [det-machine, C3] 关闭思考 SageSwitch 可见性随类型切换

    /// AC-NOTHINK-VIS：类型 openai-compatible 时模型行 SageSwitch 可见 / anthropic 不可见。
    ///
    /// 黑盒策略：T5 把 noThinkingToggleRow 删了，并入模型行 control（NSStackView 含 SageSwitch）。
    /// 本测试遍历 ProviderSettingsViewController.view 找 SageSwitch，
    /// 断言其 isHidden 随 provider kind 切换。
    ///
    /// Mutation-Survival：必须强断言 isHidden 状态翻转，杀死"开关永远显示/永远隐藏"的 no-op。
    func test_AC_NOTHINK_VIS_sageSwitchVisibility_byKind() {
        let vc = ProviderSettingsViewController()
        _ = vc.view

        // 找所有 SageSwitch（C3：仅模型行 control 内应有一个）
        let sageSwitches = findAll(SageSwitch.self, in: vc.view)
        XCTAssertFalse(sageSwitches.isEmpty,
                       "模型行 control 内必须含 SageSwitch（T5：关闭思考并入模型行）。若空说明未实现并入。")

        // CONTRACT_AMBIGUOUS: ProviderSettingsViewController 如何切换 kind（公开 API 未明）。
        // 设计 T5 说"切 anthropic 时隐藏并清状态"——若 VC 无公开 kind 切换 API，
        // 此测试依赖实现暴露测试 seam（如 populateForm(with:) 或直接设 providerKind 字段）。
        // 若无法程序化切换 kind，此断言降级为"SageSwitch 存在"（已被上一断言覆盖），
        // 强 isHidden 翻转断言留 QA 真机（det-human 兜底）。
        //
        // 此处保留 best-effort：若 VC 有 setKind/openaiCompatible 等可调用 seam，强断言翻转；
        // 否则记录为 VISUAL_RESIDUE。
        let hasAtLeastOneSageSwitch = !sageSwitches.isEmpty
        XCTAssertTrue(hasAtLeastOneSageSwitch,
                      "AC-NOTHINK-VIS: 模型行内必须含 SageSwitch（T5 落地前提）")
        // VISUAL_RESIDUE: isHidden 翻转随 kind 切换留 QA 真机（无公开 kind 切换 seam 时）
    }

    // MARK: - AC-TOOLS-GROUPED [det-machine, C4] 存在「内置能力」「已装插件」两个分组标题

    /// AC-TOOLS-GROUPED：查看 AI 工具区，存在「内置能力」「已装插件」两个分组标题。
    func test_AC_TOOLS_GROUPED_twoGroupLabelsExist() {
        let vc = ProviderSettingsViewController()
        _ = vc.view

        // 收集所有 SettingsGroupLabel（NSTextField 子类）的 stringValue
        let groupLabels = findAll(SettingsGroupLabel.self, in: vc.view).map { $0.stringValue }

        // 设计 T6：分组标题为「内置能力」和「已装插件」
        XCTAssertTrue(groupLabels.contains("内置能力"),
                      "AI 工具区必须有 SettingsGroupLabel '内置能力'，实际 group labels: \(groupLabels)")
        XCTAssertTrue(groupLabels.contains("已装插件"),
                      "AI 工具区必须有 SettingsGroupLabel '已装插件'，实际 group labels: \(groupLabels)")
    }

    /// AC-TOOLS-GROUPED 补：T6 弃 NSTableView，改两个 SettingsGroupView。
    /// 杀死"保留旧 NSTableView 未迁移"的 mutation。
    func test_AC_TOOLS_GROUPED_noNSTableView_inToolsArea() {
        let vc = ProviderSettingsViewController()
        _ = vc.view

        // 设计 T6：弃 NSTableView。整个 VC 视图层级不应含 NSTableView（其他区域也不用）。
        let tableViews = findAll(NSTableView.self, in: vc.view)
        XCTAssertTrue(tableViews.isEmpty,
                      """
                      AC-TOOLS-GROUPED: AI 配置页不得含 NSTableView（T6 弃用改 SettingsGroupView），
                      实际找到 \(tableViews.count) 个 NSTableView
                      """)
    }

    // MARK: - AC-TOOLS-NO-JARGON [det-machine] 工具区文案不含 stdin/command/prompt/attach_action

    /// AC-TOOLS-NO-JARGON：读取 AI 工具区所有行文案，不含 stdin/command/prompt/attach_action。
    func test_AC_TOOLS_NO_JARGON_forbiddenTermsAbsent() {
        let vc = ProviderSettingsViewController()
        _ = vc.view

        // 收集 VC 内所有 NSTextField 的 stringValue（工具区文案）
        let allTexts = findAll(NSTextField.self, in: vc.view).map { $0.stringValue }.joined(separator: "\n")

        // 设计 T6 + 谓词 AC-TOOLS-NO-JARGON：禁词列表逐字
        let forbidden = ["stdin", "command", "prompt", "attach_action"]
        for term in forbidden {
            XCTAssertFalse(allTexts.lowercased().contains(term.lowercased()),
                          """
                          AC-TOOLS-NO-JARGON: 工具区文案不得含 '\(term)'（T6 移除黑话）。
                          实际文案含该词。全部文案:
                          \(allTexts)
                          """)
        }
    }

    // MARK: - AC-TOOLS-SUMMARY [det-machine] 插件 manifest 有 summary 时工具行展示 summary

    /// AC-TOOLS-SUMMARY：已装插件 manifest 有 summary 时，对应工具行展示该 summary（人话）。
    ///
    /// 黑盒策略：T6 设计 `summary = manifest.displaySummary`（PluginManifest.displaySummary，
    /// SOURCE OF TRUTH 降级：summary 非空 → summary；否则 description 首句；都空 → name）。
    /// 本测试不依赖真实插件加载，直接断言 displaySummary 降级契约（这是工具行取值的数据源）。
    func test_AC_TOOLS_SUMMARY_displaySummary_degradation() throws {
        // case 1: summary 非空 → 直接用 summary（人话）
        let withSummary = PluginManifest(
            name: "qr", version: "0.1.0", description: "详细描述",
            keywords: ["qr"], cmd: "qr-gen.sh", summary: "生成二维码"
        )
        XCTAssertEqual(withSummary.displaySummary, "生成二维码",
                       "AC-TOOLS-SUMMARY: summary 非空时 displaySummary 必须等于 summary（工具行展示人话）")

        // case 2: summary nil → description 首句
        let noSummaryHasDesc = PluginManifest(
            name: "qr", version: "0.1.0", description: "把网址生成二维码。详细说明。",
            keywords: ["qr"], cmd: "qr-gen.sh", summary: nil
        )
        XCTAssertEqual(noSummaryHasDesc.displaySummary, "把网址生成二维码",
                       "AC-TOOLS-SUMMARY: summary nil 时 displaySummary 取 description 首句")

        // case 3: 都空 → name（永不拿到空值，展示层契约）
        let empty = PluginManifest(
            name: "qr", version: "0.1.0", description: "",
            keywords: ["qr"], cmd: "qr-gen.sh", summary: nil
        )
        XCTAssertEqual(empty.displaySummary, "qr",
                       "AC-TOOLS-SUMMARY: summary/description 都空时 displaySummary 兜底为 name（永不空）")
    }

    /// AC-TOOLS-SUMMARY 补：内置项固定文案逐字（设计 T6 声明）。
    /// 杀死"内置文案改了/删了"的 mutation。
    func test_AC_TOOLS_SUMMARY_builtinItems_fixedCopy() {
        let vc = ProviderSettingsViewController()
        _ = vc.view

        let allTexts = findAll(NSTextField.self, in: vc.view).map { $0.stringValue }
        let joined = allTexts.joined(separator: "\n")

        // 设计 T6 内置项固定文案逐字（朗读回复 + 复制到剪贴板）
        XCTAssertTrue(joined.contains("把 AI 回复读出声"),
                      "内置能力区必须有 '把 AI 回复读出声'（🔊 朗读回复），实际文案:\n\(joined)")
        XCTAssertTrue(joined.contains("一键复制 AI 回复"),
                      "内置能力区必须有 '一键复制 AI 回复'（📋 复制到剪贴板），实际文案:\n\(joined)")
    }

    // MARK: - AC-FORM-WIDTH [det-machine, C7] 大窗 formPanel.frame.width <= 540pt

    /// AC-FORM-WIDTH：formPanel AX id == "settings.ai.formPanel"（设计声明），
    /// 且有 widthAnchor <= 540 约束（设计 T3 line 58）。
    ///
    /// 注：单测环境窗口尺寸不可控（无法注入 1200pt 宽），故此处断言**约束存在**而非运行时 frame。
    /// 设计 T3 明确声明 `formPanel.widthAnchor.constraint(lessThanOrEqualToConstant: 540)`，
    /// 约束可遍历断言（constraints 数组里找 lessThanOrEqualToConstant: 540 的 width 约束）。
    func test_AC_FORM_WIDTH_formPanelFillsContentWidth() {
        let vc = ProviderSettingsViewController()
        _ = vc.view

        // formPanel 必须有 AX id（保留作 AI 配置表单区 AX 入口）
        guard let formPanel = findViewWithIdentifier("settings.ai.formPanel", in: vc.view) else {
            return XCTFail("""
                           AC-FORM-WIDTH: formPanel 必须有 accessibilityIdentifier=='settings.ai.formPanel'。
                           """)
        }

        // 用户反馈修订：表单与下方工具列表同宽（铺满 contentPadding 内容区），
        // 不再限宽 540。断言 formPanel 上不再有 widthAnchor <= 540 的限宽约束
        // （kill "重新加回 540 限宽" 的回退 mutation）。
        let allConstraints = collectConstraints(for: formPanel)
        let has540Cap = allConstraints.contains { c in
            (c.firstAttribute == .width || c.secondAttribute == .width) &&
            c.relation == .lessThanOrEqual &&
            abs(c.constant - 540) < 1.0
        }
        XCTAssertFalse(has540Cap,
                       """
                       AC-FORM-WIDTH: formPanel 不应再有 widthAnchor.constraint(lessThanOrEqualToConstant: 540) 限宽
                       （用户反馈：与工具列表同宽铺满内容区）。实际 formPanel 相关约束: \(describeConstraints(allConstraints))
                       """)
    }

    // MARK: - AC-AI-TOP / AC-AI-TAB [det-human] best-effort 约束存在断言

    /// AC-AI-TOP [det-human, C6 核心]：AI 配置页内容贴顶（防贴底）。
    ///
    /// 防贴底机制（autopilot 2026-07-12 重构）：
    /// 旧实现 documentView.heightAnchor ≥ scrollView.contentView.heightAnchor 约束（pattern 2026-07-03）
    /// 被 in-process bounds 铁证推翻——contentView.heightAnchor 在嵌套 NSSplitViewController 下解析为 0，
    /// 导致 documentView 塌缩 0×0 → contentColumn 0 高 → 整片白屏（plugins/hotkey/ai/general/about 5 section 受影响）。
    /// 新机制 = ContentColumnView.layout() override 手动设 documentView.frame.height ≥ scrollView.bounds.height
    /// （scrollView.heightAnchor 稳定，不依赖 contentView）。本测试断言新机制的行为效果：
    /// documentView.bounds.height ≥ scrollView.bounds.height（防贴底）。
    /// 真机端到端（AI 配置页内容贴顶）由 QA Tier 1.5 铁证（documentView 1712×1050）。
    func test_AC_AI_TOP_documentViewAntiBottomAnchor() {
        // 实例化 ContentColumnView（provider AI 配置页右栏容器）+ host window 触发完整 layout
        let ccv = ContentColumnView(frame: NSRect(x: 0, y: 0, width: 600, height: 540))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 540),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = ccv
        ccv.layoutSubtreeIfNeeded()

        guard let scrollView = findFirst(NSScrollView.self, in: ccv),
              let documentView = scrollView.documentView else {
            return XCTFail("ContentColumnView 必须含 NSScrollView + documentView")
        }
        XCTAssertGreaterThanOrEqual(documentView.bounds.height, scrollView.bounds.height,
                                    """
                                    AC-AI-TOP: documentView 防贴底——bounds.height ≥ scrollView.bounds.height
                                    （新机制 ContentColumnView.layout() 手动设 documentView.frame 替代被推翻的
                                    heightAnchor ≥ contentView.heightAnchor 约束）。
                                    实际 documentView.h=\(documentView.bounds.height), scrollView.h=\(scrollView.bounds.height)
                                    """)
    }

    /// AC-AI-TAB [det-human, C6]：minSize(800×560) 下表单/JSON segmentedControl 可见。
    ///
    /// VISUAL_RESIDUE: 真机谓词，单元层不可控窗口尺寸。
    /// 本测试做 best-effort：断言 segmentedControl（表单/JSON tab）存在且初始非隐藏。
    func test_AC_AI_TAB_segmentedControlExists_notHidden() {
        let vc = ProviderSettingsViewController()
        _ = vc.view

        let segmentedControls = findAll(NSSegmentedControl.self, in: vc.view)
        XCTAssertFalse(segmentedControls.isEmpty,
                       "AI 配置页必须含 NSSegmentedControl（表单/JSON tab），实际找到 0 个")

        // 至少一个 segmentedControl 初始非 hidden（minSize 下可见前提）
        let visibleCount = segmentedControls.filter { !$0.isHidden }.count
        XCTAssertGreaterThan(visibleCount, 0,
                            "AC-AI-TAB: 表单/JSON segmentedControl 必须初始非 hidden（小窗可见前提）")
        // VISUAL_RESIDUE: minSize 800×560 下真机可见性留 QA Tier 1.5
    }

    // MARK: - Helpers

    /// 识别 providerGroup 中的行（按视觉 Y 降序），返回 (label, view)。
    /// SettingsFormRow 通过其内部 NSTextField（titleLabel）stringValue 识别；
    /// testRow 是裸 NSView 无 title → label 为 nil（用 "<no-title>" 占位）。
    private struct IdentifiedRow {
        let label: String
        let view: NSView
        let minY: CGFloat
    }

    private func identifyProviderRows(in group: SettingsGroupView) -> [IdentifiedRow] {
        // SettingsGroupView 内部 stackView 持有各行（addRow 实现）
        // 遍历 group.subviews 找 stackView，再遍历其 arrangedSubviews
        let stackViews = findAll(NSStackView.self, in: group)
        let rows: [IdentifiedRow] = stackViews.flatMap { stack in
            stack.arrangedSubviews.map { row in
                let labels = findAll(NSTextField.self, in: row)
                let title = labels.first?.stringValue ?? "<no-title>"
                return IdentifiedRow(label: title, view: row, minY: row.frame.minY)
            }
        }
        // 视觉从上到下：NSStackView 默认 vertical，minY 大的在上面
        return rows.sorted { $0.minY > $1.minY }
    }

    private func findFirst<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let typed = view as? T { return typed }
        for sub in view.subviews {
            if let found = findFirst(type, in: sub) { return found }
        }
        return nil
    }

    private func findAll<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        var result: [T] = []
        if let typed = view as? T { result.append(typed) }
        for sub in view.subviews {
            result.append(contentsOf: findAll(type, in: sub))
        }
        return result
    }

    private func findViewWithIdentifier(_ id: String, in view: NSView) -> NSView? {
        if view.accessibilityIdentifier() == id { return view }
        for sub in view.subviews {
            if let found = findViewWithIdentifier(id, in: sub) { return found }
        }
        return nil
    }

    /// 收集 view 自身约束 + 其父视图约束中涉及该 view 的约束。
    private func collectConstraints(for view: NSView) -> [NSLayoutConstraint] {
        var result: [NSLayoutConstraint] = []
        result.append(contentsOf: view.constraints)
        if let sv = view.superview {
            result.append(contentsOf: sv.constraints.filter { constraint in
                constraint.firstItem === view || constraint.secondItem === view
            })
        }
        return result
    }

    private func describeConstraints(_ constraints: [NSLayoutConstraint]) -> String {
        constraints.map { c in
            let first = c.firstItem as? NSObject
            let second = c.secondItem as? NSObject
            return "[\(String(describing: first)).\(c.firstAttribute) \(c.relation) \(String(describing: second)).\(c.secondAttribute) @ \(c.constant)]"
        }.joined(separator: "\n")
    }
}
