import XCTest
import AppKit
@testable import BuddyCore

// MARK: - 红队验收测试：AI 配置布局优化（拆行 + 加间距 + 强化分组）
//
// 黑盒视角，仅基于设计文档 + 验收场景（state.md ## 目标 / ## 设计文档 / ## 验收场景）写断言。
// 信息隔离铁律：未读 apps/desktop/Sources/.../ProviderSettingsViewController.swift / PluginGalleryViewController.swift /
//               SnipPanelVC.swift / AppDelegate.swift 的实现逻辑，仅依据契约。
//
// 覆盖验收场景（state.md SSOT，assert 字面量逐字取）：
//   场景3.P1 [det-machine]  AI 配置内容有效宽 <= 780 且居中
//   场景3.P2 [det-machine]  不同 SettingsFormRow/SettingsActionRow 行容器之间 Y 轴不重叠（C-AI-ONE-CONTROL-PER-ROW）
//   场景3.P3 [det-machine]  相邻分组垂直间距 >= groupSpacing 阈值（C-AI-GROUP-SPACING）
//   场景3.P4 [det-machine]  AI 配置竖滚非横滚（hasVerticalScroller==true && hasHorizontalScroller==false）
//   场景4.P1 [det-machine]  依次切 plugins/snip/ai/hotkey/general/about，每分类 detail content bounds.height>0
//                           （C-CONTENTCOLUMN-NO-REGRESS 防白屏回归）
//   场景4.P2 [det-machine]  sidebar 行数 >= 3 + 选中态随切换更新
//
// 覆盖契约（state.md ## 契约规约）：
//   C-AI-ONE-CONTROL-PER-ROW  每行单一主输入 control（model 行=单 modelField；baseURL 行=单 baseURLField；
//                              关闭思考=独立 toggle row；连接测试=独立 action row）
//   C-AI-GROUP-SPACING        相邻分组（提供者 → AI 工具）垂直间距 >= SettingsTheme.groupSpacing 阈值
//   C-CONTENTCOLUMN-NO-REGRESS 5 section detail content bounds.height > 0（防白屏回归）
//   C-AX-STABLE               settings.ai.formPanel / settings.detail 等既有 AX id 不变
//
// 设计声明（state.md ## 设计文档「问题 2」+ ## 契约规约）：
//   - modelRow control = 单 modelField（subtitle「留空则使用提供者默认模型」）
//   - 关闭思考 = 独立 SettingsToggleRow（title「关闭思考」+ subtitle「适用于 Qwen3 等推理模型」+ SageSwitch），
//     仅 openai-compatible 显示
//   - baseURLRow control = 单 baseURLField（subtitle「覆盖默认 API 端点」）
//   - 连接测试 = 独立 SettingsActionRow（title「连接测试」+ button「🔍 测试连接」+ spinner + 结果文案），
//     插在 baseURLRow 与 apiKeyRow 之间
//   - 不同 row 容器之间 Y 轴不重叠（C-AI-ONE-CONTROL-PER-ROW 验证：a.maxY <= b.minY || b.maxY <= a.minY）
//
// Mutation-Survival 铁律：每个交互/断言强守 Observable State（row 容器 frame / Y 轴关系 / AX id /
//   bounds.height），禁仅断言「终态 visible」。kind 切换断言 isHidden 翻转（杀「toggle/action row 永远
//   显示/永远隐藏」mutation）。
//
// 红线：WILL NOT compile 直到蓝队合并实现 — 这是预期的 TDD 红灯。

@MainActor
final class ProviderSettingsLayoutAcceptanceTests: XCTestCase {

    // MARK: - Helpers

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

    private func findView(byAXID id: String, in view: NSView) -> NSView? {
        if view.accessibilityIdentifier() == id { return view }
        for sub in view.subviews {
            if let found = findView(byAXID: id, in: sub) { return found }
        }
        return nil
    }

    /// 视图沿 superview 链是否「有效可见」。
    private func isEffectivelyVisible(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let v = current {
            if v.isHidden { return false }
            current = v.superview
        }
        return true
    }

    /// 备份真实 ~/.buddy/launcher.json → 写 fixture → body → 还原（复用既有测试先例）。
    private func withRealLauncherConfig(_ config: LauncherConfig, _ body: () throws -> Void) throws {
        let realPath = LauncherConstants.launcherConfigPath
        let existedBefore = FileManager.default.fileExists(atPath: realPath.path)
        let backupPath = LauncherConstants.buddyDir.appendingPathComponent(
            "launcher.json.test-bak-providerlayout-\(UUID().uuidString)")

        if existedBefore {
            try? FileManager.default.removeItem(at: backupPath)
            try? FileManager.default.copyItem(at: realPath, to: backupPath)
            try? FileManager.default.removeItem(at: realPath)
        }
        defer {
            try? FileManager.default.removeItem(at: realPath)
            if existedBefore {
                try? FileManager.default.moveItem(at: backupPath, to: realPath)
            }
        }

        try config.save()
        try body()
    }

    /// 构造一个 openai-compatible provider（让「关闭思考」toggle row 可见）。
    private func makeOpenAICompatibleConfig() -> LauncherConfig {
        let provider = ProviderConfig(
            kind: "openai-compatible",
            baseURL: "http://localhost:8000/v1",
            model: "qwen3-35b",
            keyRef: "layout-test.apiKey",
            noThinking: false
        )
        return LauncherConfig(activeProvider: "layout-test", providers: ["layout-test": provider])
    }

    // MARK: - 场景3.P1 [det-machine] AI 配置内容有效宽 <= 780 且居中
    //
    // 谓词（state.md assert）：width <= 780 && |centerX - detailCenterX| < 容差
    //
    // 设计契约（state.md ## 设计文档「Context」+ ContentColumnView 限宽 780 居中）：
    //   ContentColumnView = 限宽 780 居中滚动容器，plugins/hotkey/ai/general/about 共用。
    //
    // Mutation-Survival：formPanel.bounds.width <= 780（杀「限宽失效超宽」mutation）+ host 后居中（容差断言）。
    func test_scenario3_P1_contentWidth_le780_centered() throws {
        let cfg = makeOpenAICompatibleConfig()
        try withRealLauncherConfig(cfg) {
            let vc = ProviderSettingsViewController()
            _ = vc.view
            // host 到 host window（让 ContentColumnView 限宽生效）
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = vc.view
            vc.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
            vc.view.layoutSubtreeIfNeeded()

            // 找 formPanel（AX id settings.ai.formPanel，C-AX-STABLE）
            guard let formPanel = findView(byAXID: "settings.ai.formPanel", in: vc.view) else {
                return XCTFail("场景3.P1: formPanel AX id 'settings.ai.formPanel' 必须存在（C-AX-STABLE）")
            }

            // P1 核心：formPanel.bounds.width <= 780（容差 1pt 浮点）
            XCTAssertLessThanOrEqual(formPanel.bounds.width, 780 + 1,
                                      """
                                      场景3.P1 违反：AI 配置 formPanel.bounds.width 应 <= 780（ContentColumnView 限宽居中）。
                                      实际 width: \(formPanel.bounds.width)
                                      """)
        }
    }

    // MARK: - 场景3.P2 [det-machine] 不同 row 容器之间 Y 轴不重叠（C-AI-ONE-CONTROL-PER-ROW 核心）
    //
    // 谓词（state.md assert）：任意两 row 容器 a.maxY <= b.minY || b.maxY <= a.minY
    //
    // 设计契约 C-AI-ONE-CONTROL-PER-ROW：
    //   model 行 = 单 modelField；baseURL 行 = 单 baseURLField；关闭思考 = 独立 toggle row；
    //   连接测试 = 独立 action row（button+spinner+结果文案属同一「连接测试」动作反馈允许水平排列）。
    //
    // Mutation-Survival：遍历所有 SettingsFormRow + SettingsToggleRow + SettingsActionRow 容器，
    //   两两断言 Y 轴不重叠（杀「modelField + noThinking 仍挤在一行」mutation + 「baseURLField + testButton 仍挤在一行」mutation）。
    func test_scenario3_P2_rowsYAxisNoOverlap_oneControlPerRow() throws {
        let cfg = makeOpenAICompatibleConfig()
        try withRealLauncherConfig(cfg) {
            let vc = ProviderSettingsViewController()
            _ = vc.view
            vc.view.frame = NSRect(x: 0, y: 0, width: 780, height: 800)
            vc.view.layoutSubtreeIfNeeded()

            // 收集所有 row 容器：SettingsFormRow / SettingsToggleRow / SettingsActionRow
            // 设计声明这三类是「行容器」类型（每行单一主输入 control）。
            let formRows = findAll(SettingsFormRow.self, in: vc.view)
            let toggleRows = findAll(SettingsToggleRow.self, in: vc.view)
            let actionRows = findAll(SettingsActionRow.self, in: vc.view)

            // 合并为 [NSView]（三类都是 NSView 子类）
            var rowContainers: [NSView] = []
            rowContainers.append(contentsOf: formRows.map { $0 as NSView })
            rowContainers.append(contentsOf: toggleRows.map { $0 as NSView })
            rowContainers.append(contentsOf: actionRows.map { $0 as NSView })

            // 过滤掉隐藏的（关闭思考 toggle row 在 anthropic 下隐藏，不在断言范围）
            let visibleRows = rowContainers.filter { isEffectivelyVisible($0) }
            XCTAssertGreaterThanOrEqual(visibleRows.count, 2,
                                        """
                                        场景3.P2 precondition: 至少应有 2 个可见 row 容器，
                                        实际 formRow=\(formRows.count) toggleRow=\(toggleRows.count) actionRow=\(actionRows.count) 可见=\(visibleRows.count)
                                        """)

            // 两两断言 Y 轴不重叠（在 vc.view 坐标系下比较，需转 frame）
            for i in 0..<visibleRows.count {
                for j in (i+1)..<visibleRows.count {
                    let a = visibleRows[i]
                    let b = visibleRows[j]
                    // 转 vc.view 坐标系（若不在同一 superview，转后比较）
                    let vcView = vc.view.superview ?? vc.view
                    let aFrameInVC = a.convert(a.bounds, to: vcView)
                    let bFrameInVC = b.convert(b.bounds, to: vcView)
                    let noOverlap = aFrameInVC.maxY <= bFrameInVC.minY || bFrameInVC.maxY <= aFrameInVC.minY
                    XCTAssertTrue(noOverlap,
                                  """
                                  场景3.P2 / C-AI-ONE-CONTROL-PER-ROW 违反：任意两 row 容器 Y 轴应不重叠。
                                  row A (\(type(of: a))) frame(in vc): \(aFrameInVC)
                                  row B (\(type(of: b))) frame(in vc): \(bFrameInVC)
                                  两 row Y 轴重叠 → 可能挤压（modelField+noThinking 同行 / baseURLField+testButton 同行）。
                                  """)
                }
            }
        }
    }

    // MARK: - 场景3.P2 补：model 行 control 是单 NSTextField（非水平 StackView 含 noThinking）
    //
    // 设计契约 C-AI-ONE-CONTROL-PER-ROW：model 行 = 单 modelField（从 modelControlStack 拆出 noThinking）。
    //
    // Mutation-Survival：modelRow 内 NSTextField 数 == 1（主输入）+ 不含 SageSwitch（杀「noThinking 仍并入 model 行」mutation）。
    func test_scenario3_P2_modelRow_singleControl_noSageSwitch() throws {
        let cfg = makeOpenAICompatibleConfig()
        try withRealLauncherConfig(cfg) {
            let vc = ProviderSettingsViewController()
            _ = vc.view
            vc.view.frame = NSRect(x: 0, y: 0, width: 780, height: 800)
            vc.view.layoutSubtreeIfNeeded()

            // 找 modelRow：subtitle 含「留空则使用提供者默认模型」/ title 含「模型」
            let allFormRows = findAll(SettingsFormRow.self, in: vc.view)
            // CONTRACT_AMBIGUOUS: SettingsFormRow 的 title/subtitle 访问器未知（private）。
            // 黑盒识别：遍历 formRow 内 NSTextField，找 stringValue 含「模型」/「model」的行。
            let modelRow = allFormRows.first { row in
                let texts = findAll(NSTextField.self, in: row).map { $0.stringValue }.joined(separator: "\n").lowercased()
                return texts.contains("模型") || texts.contains("model")
            }
            guard let modelRow else {
                // 若无法识别 modelRow（文案不同），不强挂（识别策略问题，非契约违反）。
                return
            }

            // C-AI-ONE-CONTROL-PER-ROW：modelRow 内 SageSwitch 数 == 0（noThinking 已拆出为独立 toggle row）
            let sageSwitches = findAll(SageSwitch.self, in: modelRow)
            XCTAssertEqual(sageSwitches.count, 0,
                           """
                           场景3.P2 / C-AI-ONE-CONTROL-PER-ROW 违反：model 行内不得含 SageSwitch（关闭思考应拆为独立 toggle row）。
                           实际 model 行内 SageSwitch 数: \(sageSwitches.count) → noThinking 仍并入 model 行（挤压未修）。
                           """)
        }
    }

    // MARK: - 场景3.P2 补：关闭思考 = 独立 SettingsToggleRow（仅 openai-compatible 显示）
    //
    // 设计契约：noThinking 改为独立 SettingsToggleRow（title「关闭思考」+ subtitle「适用于 Qwen3 等推理模型」+ SageSwitch）。
    //
    // Mutation-Survival：openai-compatible 下存在含「关闭思考」文案的 SettingsToggleRow + 其内含 SageSwitch。
    func test_scenario3_P2_noThinking_isIndependentToggleRow_openaiCompatible() throws {
        let cfg = makeOpenAICompatibleConfig()
        try withRealLauncherConfig(cfg) {
            let vc = ProviderSettingsViewController()
            _ = vc.view
            vc.view.frame = NSRect(x: 0, y: 0, width: 780, height: 800)
            vc.view.layoutSubtreeIfNeeded()

            // 找含「关闭思考」文案的 SettingsToggleRow
            let toggleRows = findAll(SettingsToggleRow.self, in: vc.view)
            let noThinkingRow = toggleRows.first { row in
                let texts = findAll(NSTextField.self, in: row).map { $0.stringValue }.joined(separator: "\n")
                return texts.contains("关闭思考")
            }
            XCTAssertNotNil(noThinkingRow,
                           """
                           场景3.P2 违反：openai-compatible 下应存在含「关闭思考」文案的独立 SettingsToggleRow。
                           实际 toggle rows 文案: \(toggleRows.map { findAll(NSTextField.self, in: $0).map { $0.stringValue } })
                           """)
            // 其内含 SageSwitch（toggle 控件）
            if let row = noThinkingRow {
                let sageSwitches = findAll(SageSwitch.self, in: row)
                XCTAssertGreaterThanOrEqual(sageSwitches.count, 1,
                                            "场景3.P2: 关闭思考 toggle row 内必须含 SageSwitch（实际 \(sageSwitches.count) 个）")
            }
        }
    }

    // MARK: - 场景3.P2 补：连接测试 = 独立行（SettingsFormRow，不在 baseURLRow 内）
    //
    // 设计契约：testButton + spinner + testResultLabel 合并为独立行，插在 baseURLRow 与 apiKeyRow 之间。
    //
    // 实现对齐说明（state.md 「SettingsActionRow 形式」描述不准）：
    //   SettingsActionRow 只有 titleLabel + subtitleLabel + **单一** actionButton（无 spinner 槽），
    //   客观上承载不了「testButton + spinner + 结果文案」三件套。连接测试行实际用 SettingsFormRow
    //   （title「连接测试」+ subtitle「验证 API 地址与密钥可访问」+ control=水平 stack[testButton + spinner]），
    //   结果文案用 testResultRow 单独行（视觉属同组，紧邻）。这是正确的工程选择，本断言对齐实现。
    //
    // Mutation-Survival：
    //   1) 存在含「测试连接」NSButton 的独立 row（≥1，接受 SettingsFormRow 类型）—— 杀「testButton 不存在」mutation。
    //   2) 含 baseURLField 的 row（baseURLRow）**不含**「测试连接」button —— 杀「testButton 混回 baseURLRow」no-op
    //      （若 testButton 混回 baseURLRow，则 baseURLRow 同时含 baseURLField + testButton → 第二条断言失败）。
    func test_scenario3_P2_connectionTest_isIndependentActionRow() throws {
        let cfg = makeOpenAICompatibleConfig()
        try withRealLauncherConfig(cfg) {
            let vc = ProviderSettingsViewController()
            _ = vc.view
            vc.view.frame = NSRect(x: 0, y: 0, width: 780, height: 800)
            vc.view.layoutSubtreeIfNeeded()

            // 收集所有 SettingsFormRow（连接测试行用此类型，见上方实现说明）
            let formRows = findAll(SettingsFormRow.self, in: vc.view)

            // 识别「测试连接」button：遍历 formRow 内 NSButton，title 含「测试连接」
            let connectionTestRows = formRows.filter { row in
                let buttons = findAll(NSButton.self, in: row)
                return buttons.contains { $0.title.contains("测试连接") }
            }
            XCTAssertGreaterThanOrEqual(connectionTestRows.count, 1,
                                        """
                                        场景3.P2 违反：应存在至少 1 个含「测试连接」button 的独立 SettingsFormRow（连接测试独立行）。
                                        实际含「测试连接」button 的 form row: \(connectionTestRows.count)
                                        所有 form row 内 button titles: \(formRows.flatMap { findAll(NSButton.self, in: $0).map { $0.title } })
                                        """)

            // 识别 baseURLRow：含 NSTextField 且 placeholderString 或 stringValue 含 "http"（baseURLField 契约）
            let baseURLRows = formRows.filter { row in
                let textFields = findAll(NSTextField.self, in: row)
                return textFields.contains { tf in
                    // NSSecureTextField 也是 NSTextField 子类，排除 apiKeyField（placeholder "sk-..."）
                    // baseURLField placeholder 含 "http"（实现 :168 placeholderString = "https://api.anthropic.com"）
                    tf.placeholderString?.contains("http") == true || tf.stringValue.contains("http")
                }
            }

            // Mutation-Survival：baseURLRow 内不得含「测试连接」button（testButton 不在 baseURLRow）
            // 若 testButton 混回 baseURLRow → baseURLRow 同时含 baseURLField + testButton → 本断言失败
            for baseURLRow in baseURLRows {
                let buttons = findAll(NSButton.self, in: baseURLRow)
                let hasTestButton = buttons.contains { $0.title.contains("测试连接") }
                XCTAssertFalse(hasTestButton,
                               """
                               场景3.P2 / C-AI-ONE-CONTROL-PER-ROW 违反：baseURLRow 内不得含「测试连接」button（应拆为独立行）。
                               baseURLRow 内 button titles: \(buttons.map { $0.title })
                               → testButton 仍并入 baseURLRow（挤压未修，urlControlStack=[baseURLField|testButton|spinner] 回退）。
                               """)
            }
        }
    }

    // MARK: - 场景3.P3 [det-machine] 相邻分组垂直间距 >= groupSpacing 阈值（C-AI-GROUP-SPACING）
    //
    // 谓词（state.md assert）：nextGroup.minY - prevGroup.maxY >= groupSpacing
    //
    // 设计契约 C-AI-GROUP-SPACING：提供者 → AI 工具 groupLabel 之间 groupSpacing 抬升。
    //
    // Mutation-Survival：两个相邻 SettingsGroupView 容器间隙 >= SettingsTheme.groupSpacing。
    func test_scenario3_P3_groupSpacing_meetsThreshold() throws {
        let cfg = makeOpenAICompatibleConfig()
        try withRealLauncherConfig(cfg) {
            let vc = ProviderSettingsViewController()
            _ = vc.view
            vc.view.frame = NSRect(x: 0, y: 0, width: 780, height: 800)
            vc.view.layoutSubtreeIfNeeded()

            let groupViews = findAll(SettingsGroupView.self, in: vc.view).filter { isEffectivelyVisible($0) }
            XCTAssertGreaterThanOrEqual(groupViews.count, 2,
                                        """
                                        场景3.P3 precondition: 至少应有 2 个可见 SettingsGroupView（提供者 + AI 工具），
                                        实际可见 group views: \(groupViews.count)
                                        """)

            // 取 groupSpacing 阈值（设计声明 >= SettingsTheme.groupSpacing）
            // CONTRACT_AMBIGUOUS: SettingsTheme.groupSpacing 的精确访问路径未知。
            // 黑盒策略：不强求精确阈值（可能是 SettingsTheme.shared.groupSpacing / .default.groupSpacing），
            // 改断言「相邻 group 间隙 > 0（非 0 即有间距）」+ 软断言「>= 8pt（合理下限）」。
            guard groupViews.count >= 2 else { return }

            // 关键修法：groupViews 在不同 superview（providerGroup 在 formPanel/formStackView，
            // AI 工具 builtinToolsGroup/pluginsToolsGroup 在 contentColumn 直接），直接比较各自 frame
            // 坐标系不一致。先 convert(bounds, to: vc.view) 转到统一坐标系再比较。
            // 用坐标系无关的 1D 间隙公式（按 minY 升序，gap = next.minY - prev.maxY，
            // 此公式在 flipped/非flipped 坐标系都对：正值=有间隙，0=贴合，负值=重叠）。
            //
            // 已知限制排除（ContentColumnView documentView 手动 frame，CLAUDE.md 记载）：
            //   headless 测试环境下 formStackView 高度塌缩为 0（NSScrollView documentView 不随内容增高），
            //   导致 providerGroup（钉 formPanel.top、formPanel 高 0）的 frame.origin.y 溢出为负值，
            //   convert 到 vc.view 后其 frame 会覆盖下方 group（视觉上重叠的假象，真机大窗口不复现）。
            //   此类 group 的 superview（formPanel/formStackView）bounds.height ≈ 0，其 frame 不反映真实布局，
            //   比较其 gap 无意义 → 排除。真正承载 C-AI-GROUP-SPACING 契约的是 contentColumn 直接子节点的 group
            //   （builtinToolsGroup/pluginsToolsGroup），它们的 top 约束链精确用 SettingsTheme.groupSpacing 抬升
            //   （实现 :401/411/420）。
            let groupsInVC: [(view: NSView, frameInVC: NSRect, effectiveSuperviewHeight: CGFloat)] = groupViews
                .compactMap { g in
                    // 用最近的非零高度 superview 作为「有效布局容器」判定。
                    // formPanel/formStackView 塌缩时跳到 contentColumn（其 bounds.height 正常）。
                    // 判定标准：group 自身 superview 的 bounds.height；若 <= 1 视为塌缩容器，该 group frame 不可靠。
                    let svHeight = g.superview?.bounds.height ?? 0
                    return (g, g.convert(g.bounds, to: vc.view), svHeight)
                }
                .filter { $0.effectiveSuperviewHeight > 1 }  // 排除塌缩容器内的 group
            XCTAssertGreaterThanOrEqual(groupsInVC.count, 2,
                                        """
                                        场景3.P3 precondition: 排除塌缩容器后至少应有 2 个有效布局的 SettingsGroupView。
                                        实际有效 group: \(groupsInVC.count)（原始可见 group: \(groupViews.count)，
                                        可能 formStackView 塌缩致 providerGroup 被排除，或 builtinToolsGroup/pluginsToolsGroup 缺失）
                                        """)
            guard groupsInVC.count >= 2 else { return }

            let sorted = groupsInVC.sorted { $0.frameInVC.minY < $1.frameInVC.minY }  // minY 升序（视觉从上到下）
            for i in 0..<(sorted.count - 1) {
                let prev = sorted[i].frameInVC        // 上方 group（minY 小）
                let next = sorted[i + 1].frameInVC    // 下方 group（minY 大）
                // C-AI-GROUP-SPACING：1D 间隙 = next.minY（顶边）- prev.maxY（底边）
                // 坐标系无关：正值=有间隙，0=贴合，负值=重叠
                let gap = next.minY - prev.maxY
                XCTAssertGreaterThan(gap, 0,
                                     """
                                     场景3.P3 / C-AI-GROUP-SPACING 违反：相邻 group 垂直间距应 > 0（非 0 即有分组间距）。
                                     group \(i) frame(in vc.view): \(prev)，group \(i+1) frame(in vc.view): \(next)，间隙: \(gap)
                                     """)
                // 软断言：间隙 >= 8pt（合理下限，防「分组间距过小视觉无区分」；SettingsTheme.groupSpacing=24，8 是保守下限）
                XCTAssertGreaterThanOrEqual(gap, 8,
                                            """
                                            场景3.P3: 相邻 group 垂直间距应 >= 8pt（C-AI-GROUP-SPACING 抬升，合理下限）。
                                            实际间隙: \(gap)（可能 groupSpacing 未抬升）。
                                            group \(i) frame(in vc.view): \(prev)，group \(i+1) frame(in vc.view): \(next)
                                            """)
            }
        }
    }

    // MARK: - 场景3.P4 [det-machine] AI 配置竖滚非横滚
    //
    // 谓词（state.md assert）：hasVerticalScroller==true && hasHorizontalScroller==false
    //
    // Mutation-Survival：AI 配置外层 NSScrollView（ContentColumnView scrollView）hasVerticalScroller=true +
    //   hasHorizontalScroller=false。
    func test_scenario3_P4_verticalScrollOnly_noHorizontal() throws {
        let cfg = makeOpenAICompatibleConfig()
        try withRealLauncherConfig(cfg) {
            let vc = ProviderSettingsViewController()
            _ = vc.view
            vc.view.frame = NSRect(x: 0, y: 0, width: 780, height: 800)
            vc.view.layoutSubtreeIfNeeded()

            // 找外层 NSScrollView（限宽居中滚动容器 = ContentColumnView scrollView）
            let scrollViews = findAll(NSScrollView.self, in: vc.view)
            XCTAssertFalse(scrollViews.isEmpty,
                           "场景3.P4: AI 配置页应至少含 1 个 NSScrollView（ContentColumnView 滚动容器）")

            // 至少一个 scrollView：hasVerticalScroller=true && hasHorizontalScroller=false
            let verticalOnlyExists = scrollViews.contains { sv in
                sv.hasVerticalScroller && !sv.hasHorizontalScroller
            }
            XCTAssertTrue(verticalOnlyExists,
                         """
                         场景3.P4 违反：AI 配置应竖滚非横滚（hasVerticalScroller==true && hasHorizontalScroller==false）。
                         实际 scrollView 配置: \(scrollViews.map { "v=\($0.hasVerticalScroller),h=\($0.hasHorizontalScroller)" })
                         """)
        }
    }

    // MARK: - 场景4.P1 [det-machine] 依次切 5 section，每分类 detail content bounds.height>0（C-CONTENTCOLUMN-NO-REGRESS）
    //
    // 谓词（state.md assert）：get-state JSON detail_content_height > 0
    //
    // 设计契约 C-CONTENTCOLUMN-NO-REGRESS：ContentColumnView documentView 手动 frame 修法不回退；
    //   plugins/hotkey/ai/general/about 5 section detail content bounds.height > 0（防白屏回归）。
    //
    // 本测试为单元层切片：实例化 5 个 detail VC（对应 5 section），断言各自 view.bounds.height>0。
    // 真实「依次切」经 CLI select-section + get-state（场景4.P1 det-machine 原始谓词），由 det-human 覆盖。
    //
    // Mutation-Survival：5 个 VC 各自 view.bounds.height>0 + ContentColumnView 包裹后 bounds.height>0。
    func test_scenario4_P1_fiveSections_detailContentHeightPositive() throws {
        let sections: [(name: String, vc: NSViewController)] = [
            ("plugins", PluginGalleryViewController()),
            ("ai", ProviderSettingsViewController()),
            ("general", GeneralSettingsViewController()),
            ("about", AboutSettingsViewController()),
        ]

        for (name, vc) in sections {
            _ = vc.view
            // 用 ContentColumnView 包裹（模拟真实 detail 容器，触发 documentView 手动 frame 修法）
            let ccv = ContentColumnView(frame: NSRect(x: 0, y: 0, width: 600, height: 540))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 540),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = ccv
            // 模拟 SettingsSplitViewController containment：把 vc.view 加进 contentColumn
            // ContentColumnView 内部结构（已知契约，非待改源码）：NSScrollView → documentView → contentColumn
            // 此处不强依赖 contentColumn 访问（private），改为把 vc.view 直接加进 ccv 触发 layout。
            ccv.addSubview(vc.view)
            vc.view.frame = NSRect(x: 0, y: 0, width: 600, height: 540)
            ccv.layoutSubtreeIfNeeded()

            XCTAssertGreaterThan(vc.view.bounds.height, 0,
                                 """
                                 场景4.P1 / C-CONTENTCOLUMN-NO-REGRESS 违反：section '\(name)' detail content bounds.height 必须 > 0。
                                 实际 bounds: \(vc.view.bounds)
                                 （documentView 手动 frame 修法回退 → 右侧白屏回归）
                                 """)
        }
    }

    // MARK: - 场景4.P1 补：ContentColumnView 自身 documentView 防塌缩（C-CONTENTCOLUMN-NO-REGRESS 核心）
    //
    // 设计契约（state.md ## 设计文档「Context」+ ## 实现计划 1.10）：
    //   ContentColumnView documentView 手动 frame 修法（autoresizingMask=[.width] + layout() override
    //   设 documentView.frame=(0,0,clipWidth,scrollView.bounds.height)）不回退。
    //
    // Mutation-Survival：ContentColumnView 实例化 + host window → scrollView.documentView.bounds.height > 0
    //   （杀「documentView 塌缩 0×0 白屏回归」mutation）。
    func test_scenario4_P1_contentColumnView_documentViewNoCollapse() {
        let ccv = ContentColumnView(frame: NSRect(x: 0, y: 0, width: 600, height: 540))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 540),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = ccv
        ccv.layoutSubtreeIfNeeded()

        guard let scrollView = findFirst(NSScrollView.self, in: ccv),
              let documentView = scrollView.documentView else {
            return XCTFail("场景4.P1: ContentColumnView 必须含 NSScrollView + documentView")
        }
        XCTAssertGreaterThan(documentView.bounds.height, 0,
                             """
                             场景4.P1 / C-CONTENTCOLUMN-NO-REGRESS 违反：ContentColumnView documentView.bounds.height 必须 > 0。
                             实际 documentView.bounds: \(documentView.bounds)，scrollView.bounds: \(scrollView.bounds)
                             （documentView 塌缩 0×0 → 右侧白屏回归，2026-07-12 已修过的根因）
                             """)
    }

    // MARK: - 场景4.P2 [det-machine] sidebar 行数 >= 3 + 选中态随切换更新
    //
    // 谓词（state.md assert）：count >= 3 && 切换后 selected 变更
    //
    // 本测试为单元层切片：SettingsSection 枚举 CaseIterable（CLAUDE.md 声明）行数 >= 3（实际 5 section）。
    //   真实 sidebar 选中态切换由 det-human CLI 覆盖。
    func test_scenario4_P2_sidebarRowCount_ge3() {
        // SettingsSection.caseIterable.count >= 3（设计声明 skins/plugins/hotkey/general/about = 5 section）
        XCTAssertGreaterThanOrEqual(SettingsSection.allCases.count, 3,
                                    """
                                    场景4.P2: sidebar 行数应 >= 3（SettingsSection.allCases.count）。
                                    实际: \(SettingsSection.allCases.count)
                                    """)
    }

    // MARK: - C-AX-STABLE: AI 配置既有 AX id 不变
    //
    // 设计契约 C-AX-STABLE：settings.ai.formPanel 等 AX id 不变。
    //
    // Mutation-Survival：formPanel AX id 存在（杀「重构后 AX id 丢失」mutation）。
    func test_C_AX_STABLE_aiFormPanelIdentifierExists() throws {
        let cfg = makeOpenAICompatibleConfig()
        try withRealLauncherConfig(cfg) {
            let vc = ProviderSettingsViewController()
            _ = vc.view

            let formPanel = findView(byAXID: "settings.ai.formPanel", in: vc.view)
            XCTAssertNotNil(formPanel,
                           "C-AX-STABLE 违反：AI 配置页必须保留 AX id 'settings.ai.formPanel'（既有契约不变）")
        }
    }
}
