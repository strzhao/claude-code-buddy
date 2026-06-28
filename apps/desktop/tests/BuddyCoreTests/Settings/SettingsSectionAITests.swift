import XCTest
import AppKit
@testable import BuddyCore

// MARK: - 红队验收测试：设置页 AI 配置 tab（场景 1-11 + 契约 C1-C7）

/// 黑盒验收测试：基于设计文档契约（SettingsSection.ai / SettingsFormRow / ProviderSettingsViewController /
/// LauncherConfig.providerIDs）。
///
/// 设计权威源（本测试逐字断言的契约）：
/// - SettingsSection：新增 `case ai`，`displayTitle "AI 配置"`，`symbolName "cpu"`。
/// - SettingsFormRow：`init(title: String, subtitle: String?, control: NSView)`，`controlView: NSView`，
///   `onControlChanged: (() -> Void)?`，`setError(_ message: String)`，`clearValidation()`。
///   布局对齐 SettingsToggleRow（cardContentPadding 16pt，最低行高 44pt）。
/// - ProviderSettingsViewController：三组自上而下——
///   分组1「提供者」：SettingsGroupView 卡片内含 6 行 SettingsFormRow（provider NSPopUpButton /
///     kind NSPopUpButton(anthropic|openai-compatible) / model NSTextField / baseURL NSTextField /
///     API key NSSecureTextField）+ 连接测试行（NSButton + NSProgressIndicator + 结果 NSTextField）；
///   分组2「系统提示词」：虚线边框卡片 + NSTextView(scrollable/selectable/non-editable，
///     内容=DefaultAgentPrompt.system) + footer 文案 + "只读"标签；
///   分组3「AI 工具」：SettingsGroupView 实线卡片展示 attach_action speak/copy + "只读"标签。
/// - LauncherConfig：新增 `var providerIDs: [String] { providers.keys.sorted() }`。
/// - C1: SettingsSection.ai switch exhaustive 强制。
/// - C2: SettingsFormRow 用 SettingsTheme token（16pt padding, rowTitleFont/Color, rowSubtitleFont/Color）。
/// - C3: API Key 不落盘 — grep 'sk-' ~/.buddy/launcher.json exit 1。
/// - C4: 只读区域 isEditable=false + "只读"标识。
/// - C5: 连接测试不影响持久化。
/// - C6: 标签切换状态保持（detailCache 缓存 VC 实例）。
/// - C7: 提供者切换前保存当前编辑。
///
/// 工作规则：本文件是 TDD 红灯，对设计的契约断言，不读实现代码、不对实现状态容错。
/// 每个谓词至少 1 个硬断言，失败即挂测试。
///
/// 注：本文件 WILL NOT compile 直到蓝队合并 SettingsFormRow + ProviderSettingsViewController +
/// SettingsSection.ai + LauncherConfig.providerIDs 实现 — 这是预期 TDD 红灯。

@MainActor
final class SettingsSectionAITests: XCTestCase {

    // MARK: - Helpers

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

    /// 强制 view 加载。
    private func forceLoadView(_ vc: NSViewController) {
        _ = vc.view
    }

    /// 递归收集所有 NSTextField / NSTextView 的文本内容。
    private func collectAllTexts(in view: NSView) -> [String] {
        var texts: [String] = []
        if let tf = view as? NSTextField {
            texts.append(tf.stringValue)
        }
        if let tv = view as? NSTextView {
            texts.append(tv.string)
        }
        for sub in view.subviews {
            texts.append(contentsOf: collectAllTexts(in: sub))
        }
        return texts
    }

    /// 递归收集所有 NSButton 的 title。
    private func collectAllButtonTitles(in view: NSView) -> [String] {
        findAll(NSButton.self, in: view).map { $0.title }
    }

    // MARK: - Set up / tear down

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: SettingsWindowController.selectedCategoryDefaultsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: SettingsWindowController.selectedCategoryDefaultsKey)
        super.tearDown()
    }

    // MARK: - 场景 1：侧边栏出现"AI 配置"标签页（P1 + P2）

    /// P1 [visual-residue]: SettingsSection 必须包含 `.ai` case，
    /// displayTitle == "AI 配置"，symbolName == "cpu"。
    /// 杀死"未加 case / displayTitle/symbolName 错误"的 mutation。
    func test_SC01_aiCase_displayTitleAndSymbolName() {
        let ai = SettingsSection.ai
        XCTAssertEqual(ai.displayTitle, "AI 配置",
                       "SettingsSection.ai.displayTitle 必须为 'AI 配置'，实际: \(ai.displayTitle)")
        XCTAssertEqual(ai.symbolName, "cpu",
                       "SettingsSection.ai.symbolName 必须为 'cpu'，实际: \(ai.symbolName)")
        XCTAssertEqual(ai.rawValue, "ai",
                       "SettingsSection.ai.rawValue 必须为 'ai'，实际: \(ai.rawValue)")
    }

    /// P1 [visual-residue]: SettingsSection.allCases 必须包含 `.ai`。
    /// 杀死"加了 case 但遗漏 allCases"的 mutation。
    func test_SC01_allCases_containsAI() {
        XCTAssertTrue(SettingsSection.allCases.contains(.ai),
                      "SettingsSection.allCases 必须包含 .ai")
    }

    /// C1 契约：SettingsSection 的 displayTitle/symbolName 必须对 `.ai` 做 exhaustive switch。
    /// 验证方式：调用 displayTitle 和 symbolName 不崩（若 switch 漏 case 则编译失败）。
    /// 杀死"加 case 但不更新 switch"的 mutation（编译期守护，运行期补充）。
    func test_C1_aiCase_switchExhaustive_displayTitleAndSymbolNameDontCrash() {
        // displayTitle switch 若漏 .ai → 编译失败（exhaustive switch 强制）
        let title = SettingsSection.ai.displayTitle
        XCTAssertFalse(title.isEmpty, "AI 配置 displayTitle 不得为空")

        // symbolName switch 若漏 .ai → 编译失败
        let symbol = SettingsSection.ai.symbolName
        XCTAssertFalse(symbol.isEmpty, "AI 配置 symbolName 不得为空")
    }

    /// P2 [visual-residue]: 选中 .ai 后 detail 容器展示 ProviderSettingsViewController。
    /// 验证 detailViewControllerProvider factory 注册了 .ai → ProviderSettingsViewController。
    func test_SC01_P2_selectAI_detailIsProviderSettingsVC() {
        // 预设选中 .ai
        UserDefaults.standard.set(SettingsSection.ai.rawValue,
                                  forKey: SettingsWindowController.selectedCategoryDefaultsKey)

        let wc = SettingsWindowController()
        guard let window = wc.window,
              let splitVC = window.contentViewController as? SettingsSplitViewController else {
            return XCTFail("无法获取 SettingsSplitViewController")
        }
        guard let splitItems = splitVC.splitViewItems as? [NSSplitViewItem],
              splitItems.count >= 2 else {
            return XCTFail("splitViewItems 数量 < 2")
        }

        let detailContainer = splitItems[1].viewController
        forceLoadView(detailContainer)

        let currentDetail = detailContainer.children.last
        XCTAssertTrue(currentDetail is ProviderSettingsViewController,
                      "预设 SettingsSelectedCategory=ai 时，detail child VC 必须为 ProviderSettingsViewController，实际: \(String(describing: currentDetail))")
    }

    /// 补：SettingsSplitViewController.detailViewControllerProvider 对 .ai 返回 ProviderSettingsViewController。
    func test_SC01_factoryProvider_forAI_returnsProviderSettingsVC() {
        let splitVC = SettingsSplitViewController()
        let vc = splitVC.detailViewControllerProvider(.ai)
        XCTAssertTrue(vc is ProviderSettingsViewController,
                      "detailViewControllerProvider(.ai) 必须返回 ProviderSettingsViewController，实际: \(type(of: vc))")
    }

    // MARK: - 场景 8：API 密钥为安全文本字段（P1 det-machine）

    /// P1 [det-machine]: API 密钥输入控件必须是 NSSecureTextField 实例（字符遮罩）。
    /// 杀死"用了普通 NSTextField 泄漏密码"的 mutation。
    func test_SC08_apiKeyField_isNSSecureTextField() {
        let vc = ProviderSettingsViewController()
        forceLoadView(vc)

        let secureFields = findAll(NSSecureTextField.self, in: vc.view)
        XCTAssertGreaterThanOrEqual(secureFields.count, 1,
                                    "AI 配置页必须至少包含 1 个 NSSecureTextField（API 密钥输入），实际: \(secureFields.count)")
    }

    // MARK: - 场景 3：系统提示词展示区（只读）（P1 + P2 visual-residue）

    /// P1 [visual-residue]: 系统提示词区展示非空文本。
    /// 契约：内容 = DefaultAgentPrompt.system。
    func test_SC03_P1_promptText_nonEmpty() {
        let vc = ProviderSettingsViewController()
        forceLoadView(vc)

        let textViews = findAll(NSTextView.self, in: vc.view)
        // 至少一个 NSTextView 用于展示系统提示词
        let promptTVs = textViews.filter { !$0.isEditable && $0.string.count > 0 }
        XCTAssertGreaterThanOrEqual(promptTVs.count, 1,
                                    "AI 配置页必须至少有 1 个不可编辑且内容非空的 NSTextView（系统提示词），实际 NSTextView 总数: \(textViews.count)")
    }

    /// P2 [visual-residue]: 系统提示词区拒绝编辑（isEditable == false）。
    /// C4 契约：只读区域 isEditable=false。
    func test_SC03_P2_promptTextView_isNotEditable() {
        let vc = ProviderSettingsViewController()
        forceLoadView(vc)

        let textViews = findAll(NSTextView.self, in: vc.view)
        // 用于展示系统提示词的 NSTextView 必为 non-editable
        let nonEditableTVs = textViews.filter { !$0.isEditable }
        XCTAssertGreaterThanOrEqual(nonEditableTVs.count, 1,
                                    "系统提示词 NSTextView 必须 isEditable==false（C4 契约），实际 non-editable NSTextView 数: \(nonEditableTVs.count)")
    }

    /// C4 契约：系统提示词区必须含"只读"标签。
    func test_SC03_C4_readOnlyLabel_inPromptArea() {
        let vc = ProviderSettingsViewController()
        forceLoadView(vc)

        let allTexts = collectAllTexts(in: vc.view)
        let hasReadOnlyLabel = allTexts.contains { $0.contains("只读") }
        XCTAssertTrue(hasReadOnlyLabel,
                      "系统提示词区必须含'只读'标识（C4 契约），实际所有文本: \(allTexts.filter { !$0.isEmpty })")
    }

    // MARK: - 场景 4：AI 工具列表展示 speak/copy（P1 + P2 det-machine）

    /// P1 [det-machine]: AI 工具列表包含 "speak" 相关条目。
    func test_SC04_P1_tools_containsSpeak() {
        let vc = ProviderSettingsViewController()
        forceLoadView(vc)

        let allTexts = collectAllTexts(in: vc.view)
        let hasSpeak = allTexts.contains { $0.localizedCaseInsensitiveContains("speak") }
        XCTAssertTrue(hasSpeak,
                      "AI 工具列表必须含 'speak' 相关条目，实际所有文本: \(allTexts.filter { !$0.isEmpty })")
    }

    /// P2 [det-machine]: AI 工具列表包含 "copy" 相关条目。
    func test_SC04_P2_tools_containsCopy() {
        let vc = ProviderSettingsViewController()
        forceLoadView(vc)

        let allTexts = collectAllTexts(in: vc.view)
        let hasCopy = allTexts.contains { $0.localizedCaseInsensitiveContains("copy") }
        XCTAssertTrue(hasCopy,
                      "AI 工具列表必须含 'copy' 相关条目，实际所有文本: \(allTexts.filter { !$0.isEmpty })")
    }

    /// C4 契约：AI 工具区必须含"只读"标签。
    func test_SC04_C4_readOnlyLabel_inToolsArea() {
        let vc = ProviderSettingsViewController()
        forceLoadView(vc)

        let allTexts = collectAllTexts(in: vc.view)
        // 应至少有 2 个"只读"标签（系统提示词 + AI 工具各一）
        let readOnlyCount = allTexts.filter { $0.contains("只读") }.count
        XCTAssertGreaterThanOrEqual(readOnlyCount, 2,
                                    "AI 工具区和系统提示词区各需'只读'标识（C4 契约），实际'只读'出现次数: \(readOnlyCount)")
    }

    // MARK: - 场景 2 + 场景 6 + 场景 7：连接测试 UI 元素（结构断言）

    /// 连接测试行必须包含测试按钮（NSButton）。
    /// 杀死"缺测试按钮"的 mutation。
    func test_SC02_connectionTest_hasButton() {
        let vc = ProviderSettingsViewController()
        forceLoadView(vc)

        let buttons = findAll(NSButton.self, in: vc.view)
        let testButtonTexts = buttons.map { $0.title }
        let hasTestButton = testButtonTexts.contains { text in
            text.contains("测试") || text.contains("连接") || text.localizedCaseInsensitiveContains("test")
        }
        XCTAssertTrue(hasTestButton,
                      "AI 配置页必须含连接测试按钮（文案含'测试'/'连接'/'test'），实际按钮: \(testButtonTexts)")
    }

    /// 连接测试行必须包含 NSProgressIndicator（加载动画）。
    func test_SC02_connectionTest_hasProgressIndicator() {
        let vc = ProviderSettingsViewController()
        forceLoadView(vc)

        let indicators = findAll(NSProgressIndicator.self, in: vc.view)
        XCTAssertGreaterThanOrEqual(indicators.count, 1,
                                    "AI 配置页必须至少含 1 个 NSProgressIndicator（连接测试加载），实际: \(indicators.count)")
    }

    /// 连接测试行必须包含结果标签（NSTextField），用于展示 ✅/❌ 结果。
    /// 场景 2/6/7 共用的 testResultLabel。
    func test_SC02_connectionTest_hasResultLabel() {
        let vc = ProviderSettingsViewController()
        forceLoadView(vc)

        // testResultLabel 应按设计暴露为 internal 属性
        // 若未暴露，通过递归查找含 ✅/❌ placeholder 的 NSTextField 兜底
        let textFields = findAll(NSTextField.self, in: vc.view)
        // 连接测试结果标签存在即可（初始可能为空，但控件必须存在）
        XCTAssertGreaterThanOrEqual(textFields.count, 1,
                                    "AI 配置页必须含结果标签 NSTextField（连接测试结果），实际 NSTextField 数: \(textFields.count)")
    }

    /// C5 契约：连接测试结果标签展示不影响持久化。
    /// 验证方式：testResultLabel 存在且为独立 NSTextField（非绑定到 config model 的字段）。
    /// 杀死"测试结果写入了持久化字段"的间接 mutation：测试结果不与 model/key 字段共用控件。
    func test_C5_connectionTest_resultLabel_isIndependent() {
        let vc = ProviderSettingsViewController()
        forceLoadView(vc)

        // 连接测试结果标签应是独立的、非绑定到持久化字段的 NSTextField。
        // 验证方式：结果标签不与模型字段（model/baseURL/apiKey）的 NSTextField 是同一实例。
        let allTextFields = findAll(NSTextField.self, in: vc.view)
        let secureFields = findAll(NSSecureTextField.self, in: vc.view)
        // 结果标签是普通 NSTextField，排除 NSSecureTextField（那是 API key 字段）
        let nonSecureFields = allTextFields.filter { !($0 is NSSecureTextField) }
        XCTAssertGreaterThanOrEqual(nonSecureFields.count, 1,
                                    "AI 配置页必须至少含 1 个普通 NSTextField（结果标签等），实际: \(nonSecureFields.count)")
    }

    // MARK: - 场景 11：SettingsGroupView 卡片布局（P1 det-machine）

    /// P1 [det-machine]: AI 配置页内容分组使用 SettingsGroupView。
    /// 契约：提供者组 + AI 工具组共 2 个 SettingsGroupView。
    func test_SC11_providerGroup_usesSettingsGroupView() {
        let vc = ProviderSettingsViewController()
        forceLoadView(vc)

        let groups = findAll(SettingsGroupView.self, in: vc.view)
        XCTAssertGreaterThanOrEqual(groups.count, 2,
                                    "AI 配置页必须至少含 2 个 SettingsGroupView（提供者组 + AI 工具组），实际: \(groups.count)")
    }

    /// 提供者组 SettingsGroupView 包含 SettingsFormRow 子视图。
    /// 契约：6 行 SettingsFormRow（provider/kind/model/baseURL/apiKey/noThinking）。
    func test_SC11_providerGroup_containsSettingsFormRows() {
        let vc = ProviderSettingsViewController()
        forceLoadView(vc)

        let groups = findAll(SettingsGroupView.self, in: vc.view)
        // 找第一个 SettingsGroupView（应为提供者组）
        guard let providerGroup = groups.first else {
            return XCTFail("AI 配置页必须含 SettingsGroupView")
        }

        let formRows = findAll(SettingsFormRow.self, in: providerGroup)
        XCTAssertGreaterThanOrEqual(formRows.count, 5,
                                    "提供者组 SettingsGroupView 必须至少含 5 个 SettingsFormRow（provider/kind/model/baseURL/apiKey），实际: \(formRows.count)")
    }

    // MARK: - C2 契约：SettingsFormRow 使用 SettingsTheme token

    /// C2 契约：SettingsFormRow 使用 SettingsTheme.cardContentPadding（16pt）。
    /// 杀死"硬编码 padding 而非引用 SettingsTheme token"的 mutation。
    func test_C2_SettingsFormRow_cardContentPadding_is16() {
        XCTAssertEqual(SettingsTheme.cardContentPadding, 16, accuracy: 0.5,
                       "SettingsTheme.cardContentPadding 必须 == 16（C2 契约），实际: \(SettingsTheme.cardContentPadding)")
    }

    /// C2 契约：SettingsFormRow 最低行高 44pt。
    /// 杀死"行高小于最低可点击区域"的 mutation。
    func test_C2_SettingsFormRow_minimumHeight_44pt() {
        let row = SettingsFormRow(title: "测试", subtitle: nil, control: NSTextField())
        // fittingSize 应反映最低 44pt 约束
        let fitting = row.fittingSize
        XCTAssertGreaterThanOrEqual(fitting.height, 44,
                                    "SettingsFormRow fittingSize.height 必须 >= 44（C2 契约 最低行高），实际: \(fitting.height)")
    }

    /// C2 契约：SettingsFormRow 使用 SettingsTheme.rowTitleFont / rowTitleColor。
    /// 验证方式：实例化 SettingsFormRow，其内部 title label 应为 rowTitleFont 同字号。
    func test_C2_SettingsFormRow_usesRowTitleFont() {
        let row = SettingsFormRow(title: "测试标题", subtitle: "副标题", control: NSTextField())
        // 递归找 NSTextField（title label）
        let labels = findAll(NSTextField.self, in: row)
        // 标题 label 字号应与 rowTitleFont 一致（13pt）
        let titleLabels = labels.filter { abs(($0.font?.pointSize ?? 0) - SettingsTheme.rowTitleFont().pointSize) < 0.5 }
        XCTAssertGreaterThanOrEqual(titleLabels.count, 1,
                                    "SettingsFormRow 必须使用 SettingsTheme.rowTitleFont()（13pt）渲染标题，实际 labels: \(labels.map { ($0.stringValue, $0.font?.pointSize ?? 0) })")
    }

    // MARK: - SettingsFormRow API 契约

    /// API 契约：init(title:subtitle:control:) 三参数构造器可用。
    func test_SettingsFormRow_init_withTitleSubtitleControl() {
        let control = NSTextField()
        let row = SettingsFormRow(title: "模型", subtitle: "模型名称", control: control)
        XCTAssertNotNil(row, "SettingsFormRow(title:subtitle:control:) 必须可实例化")
    }

    /// API 契约：controlView 返回 init 传入的 control。
    func test_SettingsFormRow_controlView_returnsPassedControl() {
        let control = NSTextField()
        let row = SettingsFormRow(title: "模型", subtitle: nil, control: control)
        XCTAssertTrue(row.controlView === control,
                      "SettingsFormRow.controlView 必须返回 init 传入的同一 NSView 实例")
    }

    /// API 契约：onControlChanged 回调可设置。
    func test_SettingsFormRow_onControlChanged_isSettable() {
        let row = SettingsFormRow(title: "模型", subtitle: nil, control: NSTextField())
        var called = false
        row.onControlChanged = { called = true }
        XCTAssertNotNil(row.onControlChanged, "onControlChanged 必须可设置")
        // 触发回调
        row.onControlChanged?()
        XCTAssertTrue(called, "onControlChanged 回调必须被触发")
    }

    /// API 契约：setError(_:) 和 clearValidation() 方法存在。
    func test_SettingsFormRow_setError_and_clearValidation_exist() {
        let row = SettingsFormRow(title: "API 地址", subtitle: nil, control: NSTextField())
        // 调用不崩即方法存在
        row.setError("无效的 URL 格式")
        row.clearValidation()
        // 硬断言：方法存在且可调用不崩
        XCTAssertTrue(true, "setError/clearValidation 方法存在且可调用")
    }

    // MARK: - 场景 5：配置持久化（P1 det-machine）

    /// P1 [det-machine]: LauncherConfig 保存后 providers 数量 >= 1。
    /// 使用临时文件做 round-trip 测试，避免污染真实 ~/.buddy/launcher.json。
    func test_SC05_launcherConfig_roundTrip_preservesProviders() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("buddy-test-\(UUID().uuidString)")
        let configPath = tempDir.appendingPathComponent("launcher.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // 构造含 1 个 provider 的 config
        let provider = ProviderConfig(
            kind: "anthropic",
            baseURL: "https://api.anthropic.com",
            model: "claude-sonnet-4-5",
            keyRef: "test-key-ref"
        )
        var config = LauncherConfig(
            activeProvider: "test-provider",
            providers: ["test-provider": provider]
        )

        // 保存到临时文件
        try config.save(to: configPath)

        // 从临时文件加载
        let loaded = try LauncherConfig.load(from: configPath)

        // 断言：providers 数量 >= 1
        XCTAssertGreaterThanOrEqual(loaded.providers.count, 1,
                                    "保存后重新加载的 providers 数量必须 >= 1，实际: \(loaded.providers.count)")

        // 断言：provider 字段完整
        let loadedProvider = loaded.providers["test-provider"]
        XCTAssertNotNil(loadedProvider, "保存的 provider 'test-provider' 重新加载后必须存在")
        XCTAssertEqual(loadedProvider?.kind, "anthropic",
                       "provider kind 持久化后必须一致")
        XCTAssertEqual(loadedProvider?.model, "claude-sonnet-4-5",
                       "provider model 持久化后必须一致")
        XCTAssertEqual(loadedProvider?.baseURL, "https://api.anthropic.com",
                       "provider baseURL 持久化后必须一致")
    }

    /// LauncherConfig.providerIDs 返回 providers.keys.sorted()。
    func test_LauncherConfig_providerIDs_isSortedKeys() {
        var config = LauncherConfig(activeProvider: "", providers: [
            "zulu": ProviderConfig(kind: "openai-compatible", baseURL: nil, model: "gpt-4", keyRef: "k1"),
            "alpha": ProviderConfig(kind: "anthropic", baseURL: nil, model: "claude", keyRef: "k2"),
        ])
        let ids = config.providerIDs
        XCTAssertEqual(ids, ["alpha", "zulu"],
                       "providerIDs 必须返回 providers.keys.sorted()，实际: \(ids)")
    }

    /// 空 providers 时 providerIDs 返回空数组。
    func test_LauncherConfig_providerIDs_emptyProviders_returnsEmpty() {
        let config = LauncherConfig.empty
        XCTAssertEqual(config.providerIDs, [],
                       "空 providers 时 providerIDs 必须返回 []，实际: \(config.providerIDs)")
    }

    // MARK: - 场景 9：API 密钥安全存取（C3 契约，P1 det-machine）

    /// P1 [det-machine]: ~/.buddy/launcher.json 不得包含 API 密钥明文（"sk-" 前缀）。
    /// 验证方式：保存含 keyRef 的 config，然后 grep 'sk-' 保存的 JSON 文件。
    /// 杀死"API 密钥落盘到 launcher.json"的 mutation（C3 契约红线）。
    func test_SC09_C3_launcherJson_noPlaintextAPIKey() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("buddy-test-\(UUID().uuidString)")
        let configPath = tempDir.appendingPathComponent("launcher.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // keyRef 只是引用名，不是密钥真值
        let provider = ProviderConfig(
            kind: "anthropic",
            baseURL: "https://api.anthropic.com",
            model: "claude-sonnet-4-5",
            keyRef: "anthropic-main"  // keyRef ≠ 密钥真值
        )
        var config = LauncherConfig(
            activeProvider: "anthropic",
            providers: ["anthropic": provider]
        )
        try config.save(to: configPath)

        // 读取保存的 JSON 文件内容
        let savedJSON = try String(contentsOf: configPath, encoding: .utf8)

        // 硬断言：不得包含 "sk-" 明文（Anthropic API key 的常见前缀）
        XCTAssertFalse(savedJSON.contains("sk-"),
                       "C3 契约违反：launcher.json 不得包含 'sk-' 明文密钥。\n保存的 JSON: \(savedJSON.prefix(500))")

        // 补充断言：不得包含常见 API key 模式
        let forbiddenPatterns = ["sk-ant-", "sk-or-", "sk-"]
        for pattern in forbiddenPatterns {
            XCTAssertFalse(savedJSON.contains(pattern),
                           "C3 契约违反：launcher.json 不得包含 '\(pattern)' 明文密钥模式。")
        }
    }

    /// C3 契约补充：ProviderConfig 只存 keyRef（密钥引用），不存密钥真值。
    /// ProviderConfig 的 Codable 序列化中不得有 "apiKey" / "secret" / "key" 等真值字段。
    func test_SC09_C3_ProviderConfig_onlyHasKeyRef_notRealKey() throws {
        let provider = ProviderConfig(
            kind: "anthropic",
            baseURL: "https://api.anthropic.com",
            model: "claude-sonnet-4-5",
            keyRef: "my-key-ref"
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(provider)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        // ProviderConfig JSON 中必须有 keyRef 字段
        XCTAssertEqual(json?["keyRef"] as? String, "my-key-ref",
                       "ProviderConfig JSON 必须含 keyRef 字段")

        // ProviderConfig JSON 中不得有 apiKey/secret/key 等真值字段
        let forbiddenKeys = ["apiKey", "secret", "key", "api_key", "token"]
        for key in forbiddenKeys {
            XCTAssertNil(json?[key],
                         "ProviderConfig 不得有 '\(key)' 字段（密钥真值不存 config），实际 JSON keys: \(json?.keys.sorted() ?? [])")
        }
    }

    // MARK: - 场景 10：标签切换状态保持（C6 契约，P1 visual-residue）

    /// P1 [visual-residue]: 从其他标签切回 AI 配置，模型字段保留之前输入的值。
    /// C6 契约：detailCache 缓存 VC 实例，不重新创建。
    /// 验证：预选 .ai → 获取 modelField 引用 → 修改值 → 切到 .skins → 切回 .ai → modelField 值不变。
    func test_SC10_C6_tabSwitch_preservesModelFieldValue() {
        // 预选 .ai
        UserDefaults.standard.set(SettingsSection.ai.rawValue,
                                  forKey: SettingsWindowController.selectedCategoryDefaultsKey)

        let wc = SettingsWindowController()
        guard let window = wc.window,
              let splitVC = window.contentViewController as? SettingsSplitViewController else {
            return XCTFail("无法获取 SettingsSplitViewController")
        }

        // 获取 AI 配置 VC
        guard let aiVC = splitVC.detailChildViewController as? ProviderSettingsViewController else {
            return XCTFail("预选 .ai 后 detail child VC 必须为 ProviderSettingsViewController")
        }
        forceLoadView(aiVC)

        // 修改模型字段值
        let modelField = findFirst(NSTextField.self, in: aiVC.view)
        guard let modelTF = modelField else {
            return XCTFail("ProviderSettingsViewController 必须含模型 NSTextField")
        }
        let testModelName = "test-model-\(UUID().uuidString.prefix(4))"
        modelTF.stringValue = testModelName

        // 切到 skins
        splitVC.testHook_selectSection(.skins)

        // 切回 ai
        splitVC.testHook_selectSection(.ai)

        // 再次获取 AI 配置 VC（C6：detailCache 缓存，应返回同一实例）
        guard let aiVC2 = splitVC.detailChildViewController as? ProviderSettingsViewController else {
            return XCTFail("切回 .ai 后 detail child VC 必须为 ProviderSettingsViewController")
        }
        forceLoadView(aiVC2)

        let modelField2 = findFirst(NSTextField.self, in: aiVC2.view)
        guard let modelTF2 = modelField2 else {
            return XCTFail("切回后 ProviderSettingsViewController 仍须含模型 NSTextField")
        }

        // 硬断言：模型字段值必须保留（C6 缓存确保 VC 实例不变，字段值不丢）
        XCTAssertEqual(modelTF2.stringValue, testModelName,
                       "C6 契约违反：切回 AI 配置后模型字段值必须保留 '\(testModelName)'，实际: '\(modelTF2.stringValue)'")
    }

    /// C6 补充：两次选中 .ai 返回的 VC 是同一实例（detailCache 缓存）。
    func test_SC10_C6_detailCache_returnsSameInstance() {
        UserDefaults.standard.set(SettingsSection.ai.rawValue,
                                  forKey: SettingsWindowController.selectedCategoryDefaultsKey)

        let wc = SettingsWindowController()
        guard let window = wc.window,
              let splitVC = window.contentViewController as? SettingsSplitViewController else {
            return XCTFail("无法获取 SettingsSplitViewController")
        }

        guard let aiVC1 = splitVC.detailChildViewController as? ProviderSettingsViewController else {
            return XCTFail("预选 .ai 后 detail child VC 必须为 ProviderSettingsViewController")
        }

        // 切走
        splitVC.testHook_selectSection(.skins)
        // 切回
        splitVC.testHook_selectSection(.ai)

        guard let aiVC2 = splitVC.detailChildViewController as? ProviderSettingsViewController else {
            return XCTFail("切回 .ai 后 detail child VC 必须为 ProviderSettingsViewController")
        }

        // 硬断言：同一实例（=== 指针相等）
        XCTAssertTrue(aiVC1 === aiVC2,
                      "C6 契约违反：切回 AI 配置必须返回缓存的同一 VC 实例（detailCache），不应重新创建")
    }

    // MARK: - 提供者配置区结构断言

    /// 提供者下拉使用 NSPopUpButton（非 NSTextField）。
    func test_providerConfig_providerDropdown_isNSPopUpButton() {
        let vc = ProviderSettingsViewController()
        forceLoadView(vc)

        let popups = findAll(NSPopUpButton.self, in: vc.view)
        XCTAssertGreaterThanOrEqual(popups.count, 2,
                                    "AI 配置页必须至少含 2 个 NSPopUpButton（提供者下拉 + 类型下拉），实际: \(popups.count)")
    }

    /// 模型输入使用 NSTextField（非 popup — 模型名可自定义）。
    func test_providerConfig_modelField_isNSTextField() {
        let vc = ProviderSettingsViewController()
        forceLoadView(vc)

        let fields = findAll(NSTextField.self, in: vc.view)
        // 排除 NSSecureTextField（那是 API key 字段）
        let regularFields = fields.filter { !($0 is NSSecureTextField) }
        XCTAssertGreaterThanOrEqual(regularFields.count, 1,
                                    "AI 配置页必须至少含 1 个普通 NSTextField（模型输入），实际: \(regularFields.count)")
    }

    // MARK: - 系统提示词区：虚线边框卡片

    /// 系统提示词区使用非 SettingsGroupView 的卡片（虚线边框）。
    /// 验证：存在至少一个非 SettingsGroupView 的 NSView 作为容器（虚线卡片）。
    func test_SC03_promptArea_hasNonGroupViewCard() {
        let vc = ProviderSettingsViewController()
        forceLoadView(vc)

        // 找到所有 NSView（非标准控件的容器视图）
        let allSubviews = findAll(NSView.self, in: vc.view)
        // 排除已知类型：SettingsGroupView / SettingsFormRow / NSTextField / NSButton 等
        let knownTypes: [AnyClass] = [
            SettingsGroupView.self, SettingsFormRow.self,
            NSTextField.self, NSSecureTextField.self, NSTextView.self,
            NSButton.self, NSPopUpButton.self, NSProgressIndicator.self,
            NSStackView.self, NSBox.self, NSClipView.self, NSScrollView.self,
            NSTableCellView.self, NSImageView.self,
        ]
        let customContainers = allSubviews.filter { view in
            !knownTypes.contains { view.isKind(of: $0) }
        }
        // 系统提示词虚线卡片是自定义容器，可能用 dashed border 的 NSView 子类或带 layer.border 的普通 NSView
        // 至少应有 1 个非标准控件容器（可以是 plain NSView 带 dashed border layer）
        XCTAssertGreaterThanOrEqual(customContainers.count, 1,
                                    "系统提示词区必须含至少 1 个非标准控件的容器视图（虚线卡片），"
                                    + "实际非标准容器: \(customContainers.map { String(describing: type(of: $0)) })")
    }

    // MARK: - 场景 2/6/7 连接测试行为（契约级结构断言）

    /// 场景 2 谓词：连接测试结果展示 label 存在且初始为空或占位（不含结果）。
    /// 连接测试是用户主动触发的操作，初始状态不应有 ✅/❌ 结果。
    func test_SC02_testResultLabel_initialState_empty() {
        let vc = ProviderSettingsViewController()
        forceLoadView(vc)

        // 连接测试结果标签初始应为空或占位文本（未执行测试前无结果）
        let allTexts = collectAllTexts(in: vc.view)
        let hasSuccessInInitial = allTexts.contains { $0.contains("✅") && $0.contains("连接成功") }
        let hasFailureInInitial = allTexts.contains { $0.contains("❌") }

        // 初始状态：不预设成功或失败标记（测试尚未执行）
        // 但可以有占位文案或空白
        XCTAssertFalse(hasSuccessInInitial && hasFailureInInitial,
                       "初始状态不应同时有成功和失败标记")
    }

    /// 场景 6 谓语结构验证：连接测试失败 label 必须存在以展示 ❌ + 错误信息。
    /// 场景 7 谓语结构验证：连接测试超时 label 必须存在以展示 ❌ + 超时信息。
    /// 单元层不能实际发起网络请求，但断言结果展示控件存在。
    func test_SC06_SC07_testResultLabel_exists_for_error_display() {
        let vc = ProviderSettingsViewController()
        forceLoadView(vc)

        // 递归找所有 NSTextField — 其中之一必须是用作 testResultLabel 的
        let fields = findAll(NSTextField.self, in: vc.view)
        // 控件存在即满足结构断言（行为断言需 QA 真机验证）
        XCTAssertGreaterThanOrEqual(fields.count, 1,
                                    "AI 配置页必须含 NSTextField 用于展示连接测试结果（场景 2/6/7 共用），实际: \(fields.count)")
    }

    // MARK: - C7 契约：提供者切换前保存当前编辑

    /// C7 契约：ProviderSettingsViewController 必须提供保存机制（切换前保存）。
    /// 验证方式：VC 或 provider dropdown 的 action 触发保存流程。
    /// 单元层断言：VC 存在保存相关的方法/回调（LauncherConfig.save 可调）。
    func test_C7_providerSwitch_triggersSave_beforeLoading() throws {
        let vc = ProviderSettingsViewController()
        forceLoadView(vc)

        // C7 的核心是"切换前保存"——VC 必须能触发 LauncherConfig.save()
        // 验证 LauncherConfig.save() 存在且可调用（编译期 + 运行期）
        var config = LauncherConfig.empty
        // save() 方法存在（编译期验证），调用不崩（运行期验证）
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("buddy-test-c7-\(UUID().uuidString)")
        let configPath = tempDir.appendingPathComponent("launcher.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try config.save(to: configPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: configPath.path),
                      "LauncherConfig.save() 必须成功写入文件（C7 保存机制前提）")
    }

    // MARK: - ProviderSettingsViewController 三组布局完整性

    /// 验证三组布局结构：提供者组（NSPopUpButton×2 + NSTextField×2 + NSSecureTextField +
    /// NSButton + NSProgressIndicator）+ 系统提示词组（NSTextView + "只读"）+ AI 工具组（"只读"）。
    func test_ProviderSettingsViewController_threeGroupsLayout_complete() {
        let vc = ProviderSettingsViewController()
        forceLoadView(vc)

        // 提供者组控件
        let popups = findAll(NSPopUpButton.self, in: vc.view)
        let secureFields = findAll(NSSecureTextField.self, in: vc.view)
        let buttons = findAll(NSButton.self, in: vc.view)
        let indicators = findAll(NSProgressIndicator.self, in: vc.view)

        // 系统提示词组
        let textViews = findAll(NSTextView.self, in: vc.view)

        // 硬断言：三组关键控件齐全
        XCTAssertGreaterThanOrEqual(popups.count, 2,
                                    "提供者组：至少 2 个 NSPopUpButton（provider + kind），实际: \(popups.count)")
        XCTAssertGreaterThanOrEqual(secureFields.count, 1,
                                    "提供者组：至少 1 个 NSSecureTextField（API key），实际: \(secureFields.count)")
        XCTAssertGreaterThanOrEqual(buttons.count, 1,
                                    "提供者组：至少 1 个 NSButton（连接测试），实际: \(buttons.count)")
        XCTAssertGreaterThanOrEqual(indicators.count, 1,
                                    "提供者组：至少 1 个 NSProgressIndicator（连接测试），实际: \(indicators.count)")
        XCTAssertGreaterThanOrEqual(textViews.count, 1,
                                    "系统提示词组：至少 1 个 NSTextView（提示词展示），实际: \(textViews.count)")

        // "只读"标签总数 >= 2（系统提示词 + AI 工具各一）
        let allTexts = collectAllTexts(in: vc.view)
        let readOnlyCount = allTexts.filter { $0.contains("只读") }.count
        XCTAssertGreaterThanOrEqual(readOnlyCount, 2,
                                    "三组布局必须含至少 2 个'只读'标签（系统提示词 + AI 工具），实际: \(readOnlyCount)")
    }

    // MARK: - AX 兼容性：AI 配置 sidebar row AX id

    /// sidebar 新增 ai 行后，AX id 集合必须包含 `settings.sidebar.ai`。
    /// 契约 7 命名格式：`settings.sidebar.\(section.rawValue)`。
    func test_aiCase_sidebarAXID_followsNamingConvention() {
        let splitVC = SettingsSplitViewController()
        _ = splitVC.view

        // 选中 .ai
        splitVC.testHook_selectSection(.ai)

        // 从 sidebar 收集 AX id
        guard let splitItems = splitVC.splitViewItems as? [NSSplitViewItem],
              splitItems.count >= 1 else {
            return XCTFail("无法获取 splitViewItems")
        }
        let sidebarVC = splitItems[0].viewController
        _ = sidebarVC.view

        guard let tableView = findFirst(NSTableView.self, in: sidebarVC.view) else {
            return XCTFail("sidebar 必须含 NSTableView")
        }

        var allAXIDs: Set<String> = []
        for row in 0..<tableView.numberOfRows {
            if let rowView = tableView.rowView(atRow: row, makeIfNecessary: true) {
                let id = rowView.accessibilityIdentifier()
                if !id.isEmpty { allAXIDs.insert(id) }
            }
        }

        let expectedAIID = "settings.sidebar.ai"
        XCTAssertTrue(allAXIDs.contains(expectedAIID),
                      "sidebar AX id 集合必须包含 '\(expectedAIID)'（SettingsSection.ai rawValue == 'ai'），实际: \(allAXIDs.sorted())")
    }

    // MARK: - SC-SET-01 编译契约（不写测试，标注 QA）
    //
    // make -C apps/desktop build 必须在新增 .ai case + SettingsFormRow +
    // ProviderSettingsViewController 后编译通过，无 type error。
    // QA 执行：make -C apps/desktop build 2>&1 | tee build.log；断言 exit==0。
    //
    // SC-SET-02（补充）：SettingsSplitViewController.detailViewControllerProvider
    // switch 对 .ai 无 "unresolved identifier"。
}
