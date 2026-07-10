import AppKit

/// 「AI 配置」设置分类：提供者连接 + AI 工具。
///
/// 两组布局（自上而下，NSScrollView 包裹）：
/// - 分组1「提供者」（可编辑）：表单/JSON Tab 切换 + noThinking toggle + 连接测试
/// - 分组2「AI 工具」：Plugin 驱动的工具列表
///
/// 契约 C3：API Key 不落盘，仅通过 SecretStore 存储。
/// 契约 C4：表单↔JSON 双向同步，isSyncing 防递归。
/// 契约 C5：noThinking toggle 仅 openai-compatible 可见。
final class ProviderSettingsViewController: NSViewController {

    // MARK: - State

    private var config: LauncherConfig = .empty
    private let secretStore: SecretStore

    /// 当前正在编辑的提供者 ID（用于切换前保存）
    private var editingProviderID: String?

    /// 防止 populateUI 期间的控件变化触发 saveCurrentProvider（B1 防污染）
    private var isPopulating = false

    /// 防止 JSON ↔ 表单双向同步时的递归触发
    private var isSyncing = false

    /// 本地追踪 noThinking 状态（SettingsToggleRow 不暴露 isOn getter）
    private var noThinkingEnabled = false

    /// AI 工具列表分组数据（T6：弃 NSTableView，改 SettingsGroupView + ToolItemRow）
    private var toolGroups: [(title: String, items: [AIToolItem])] = []
    /// 「内置能力」分组容器（setupLayout 创建，renderToolGroups 填充行）
    private var builtinToolsGroup: SettingsGroupView!
    /// 「已装插件」分组容器（setupLayout 创建，renderToolGroups 填充行；无插件时整组隐藏）
    private var pluginsToolsGroup: SettingsGroupView!
    /// 「已装插件」分组标题（无插件时一并隐藏）
    private var pluginsToolsLabel: SettingsGroupLabel!

    // MARK: - Group 1 「提供者」控件

    /// 「表单」/「JSON」分段控件
    private let tabSegmentedControl = NSSegmentedControl(
        labels: ["表单", "JSON"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    /// 表单面板容器
    private let formPanel = NSView()
    /// JSON 面板容器
    private let jsonPanel = NSView()

    // 表单控件
    private let providerPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let kindPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let modelField = NSTextField()
    private let baseURLField = NSTextField()
    private let apiKeyField = NSSecureTextField()
    private let testButton = NSButton(title: "🔍 测试连接", target: nil, action: nil)
    private let testSpinner = NSProgressIndicator()
    private let testResultLabel = NSTextField(labelWithString: "")
    /// 测试结果行容器（idle/检测中整行隐藏，SettingsGroupView stackView 自动塌缩不占位）
    private let testResultRow = NSView()

    /// 「关闭思考」SageSwitch（并入模型行，仅 openai-compatible 时可见，C3 不变）
    private let noThinkingSwitch = SageSwitch(isOn: false)
    /// 「关闭思考」label（与 SageSwitch 一同显示/隐藏）
    private let noThinkingLabel = NSTextField(labelWithString: "关闭思考")
    /// 「关闭思考」容器（label + switch），整组控制 isHidden 等同旧 noThinkingToggleRow.isHidden
    private let noThinkingContainer = NSStackView()

    // JSON 面板控件
    private let jsonTextView = NSTextView()
    private let jsonScrollView = NSScrollView()
    private let jsonValidationLabel = NSTextField(labelWithString: "")
    private let prettyPrintButton = NSButton(title: "格式化", target: nil, action: nil)

    // MARK: - Init

    init() {
        self.secretStore = (try? SecretStoreFactory.create()) ?? EncryptedFileSecretStore.fallback()
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func loadView() {
        // 内容列（限宽居中 + 内置滚动，复用 ContentColumnView）
        let column = ContentColumnView(frame: NSRect(x: 0, y: 0, width: 760, height: 720))
        let content = column.contentColumn
        setupLayout(in: content)

        self.view = column

        // T6: 在 loadView 末尾渲染工具分组（骨架已就绪），
        // 让测试仅触发 loadView（`_ = vc.view`）也能看到完整工具行；
        // viewDidLoad 会再调一次（幂等：renderToolGroups 先清空旧行再重建）。
        renderToolGroups()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        loadConfig()
        populateUI()
        renderToolGroups()
    }

    // MARK: - Layout

    private func setupLayout(in container: NSView) {
        // ── 分组1「提供者」──
        let providerLabel = SettingsGroupLabel(title: "提供者")
        providerLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(providerLabel)

        // Tab 切换控件（表单 / JSON）
        tabSegmentedControl.translatesAutoresizingMaskIntoConstraints = false
        tabSegmentedControl.segmentStyle = .capsule
        tabSegmentedControl.selectedSegment = 0
        tabSegmentedControl.target = self
        tabSegmentedControl.action = #selector(tabDidChange(_:))
        container.addSubview(tabSegmentedControl)

        // ── 表单面板 ──
        formPanel.translatesAutoresizingMaskIntoConstraints = false
        // AC-FORM-WIDTH AX 标识（表单区 AX 入口）
        formPanel.setAccessibilityIdentifier("settings.ai.formPanel")

        // formPanel + jsonPanel 共用 formStackView 槽位（NSStackView 自动塌缩隐藏项：
        // form tab 紧凑、JSON tab 可独立拉高，互不重叠/不留隙）。与下方工具列表同宽。
        let formStackView = NSStackView()
        formStackView.orientation = .vertical
        formStackView.alignment = .leading
        formStackView.distribution = .fill
        formStackView.spacing = 0
        formStackView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(formStackView)
        formStackView.addArrangedSubview(formPanel)
        formPanel.leadingAnchor.constraint(equalTo: formStackView.leadingAnchor).isActive = true
        formPanel.trailingAnchor.constraint(equalTo: formStackView.trailingAnchor).isActive = true

        let providerGroup = SettingsGroupView()
        providerGroup.translatesAutoresizingMaskIntoConstraints = false
        formPanel.addSubview(providerGroup)

        // 配置提供者下拉
        providerPopup.translatesAutoresizingMaskIntoConstraints = false
        providerPopup.target = self
        providerPopup.action = #selector(providerDidChange(_:))

        // 配置类型下拉
        kindPopup.translatesAutoresizingMaskIntoConstraints = false
        kindPopup.addItems(withTitles: ["anthropic", "openai-compatible"])
        kindPopup.target = self
        kindPopup.action = #selector(kindDidChange(_:))

        // 模型输入
        modelField.translatesAutoresizingMaskIntoConstraints = false
        modelField.placeholderString = "模型 ID，如 claude-sonnet-4-5"
        modelField.font = .systemFont(ofSize: 13)

        // 地址输入
        baseURLField.translatesAutoresizingMaskIntoConstraints = false
        baseURLField.placeholderString = "https://api.anthropic.com"
        baseURLField.font = .systemFont(ofSize: 13)

        // API Key 输入
        apiKeyField.translatesAutoresizingMaskIntoConstraints = false
        apiKeyField.placeholderString = "sk-..."

        // 连接测试行
        testButton.translatesAutoresizingMaskIntoConstraints = false
        testButton.bezelStyle = .rounded
        testButton.target = self
        testButton.action = #selector(testConnection(_:))

        testSpinner.translatesAutoresizingMaskIntoConstraints = false
        testSpinner.style = .spinning
        testSpinner.controlSize = .small
        testSpinner.isHidden = true

        testResultLabel.translatesAutoresizingMaskIntoConstraints = false
        testResultLabel.font = .systemFont(ofSize: 12)
        testResultLabel.textColor = .secondaryLabelColor
        testResultLabel.lineBreakMode = .byWordWrapping
        testResultLabel.maximumNumberOfLines = 0
        testResultLabel.isHidden = true

        // API 地址行 control：水平 stack [baseURLField 撑宽 | 测试连接 button | spinner]
        // （用户反馈：测试连接与 API 地址同一行；结果文案单起一行可换行长错误）
        baseURLField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        baseURLField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let urlControlStack = NSStackView()
        urlControlStack.orientation = .horizontal
        urlControlStack.spacing = 8
        urlControlStack.alignment = .centerY
        urlControlStack.distribution = .fill
        urlControlStack.translatesAutoresizingMaskIntoConstraints = false
        urlControlStack.addArrangedSubview(baseURLField)
        urlControlStack.addArrangedSubview(testButton)
        urlControlStack.addArrangedSubview(testSpinner)
        NSLayoutConstraint.activate([
            testSpinner.widthAnchor.constraint(equalToConstant: 16),
            testSpinner.heightAnchor.constraint(equalToConstant: 16),
            // baseURLField 保底宽度（用户反馈 round4：默认空字段无宽度看不见）——与 modelField 同思路给 min 宽
            baseURLField.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
        ])

        // 测试结果行（结果文案；idle/检测中整行隐藏，stackView 自动塌缩不占位）
        testResultRow.translatesAutoresizingMaskIntoConstraints = false
        testResultRow.addSubview(testResultLabel)
        NSLayoutConstraint.activate([
            testResultLabel.leadingAnchor.constraint(equalTo: testResultRow.leadingAnchor, constant: SettingsTheme.cardContentPadding),
            testResultLabel.topAnchor.constraint(equalTo: testResultRow.topAnchor, constant: 6),
            testResultLabel.trailingAnchor.constraint(lessThanOrEqualTo: testResultRow.trailingAnchor, constant: -SettingsTheme.cardContentPadding),
            testResultLabel.bottomAnchor.constraint(equalTo: testResultRow.bottomAnchor, constant: -6),
        ])
        testResultRow.isHidden = true

        // 表单行
        let providerRow = SettingsFormRow(title: "激活提供者", subtitle: nil, control: providerPopup)
        let kindRow = SettingsFormRow(title: "类型", subtitle: nil, control: kindPopup)

        // 模型行 control：水平 stack [modelField (撑宽) | 关闭思考 label + SageSwitch]
        // T5 关闭思考并入模型行。modelField 显式 hugging + minWidth 防被 label+switch 挤窄。
        modelField.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        modelField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        noThinkingLabel.font = .systemFont(ofSize: 12)
        noThinkingLabel.textColor = .secondaryLabelColor
        noThinkingLabel.translatesAutoresizingMaskIntoConstraints = false
        noThinkingSwitch.translatesAutoresizingMaskIntoConstraints = false
        noThinkingSwitch.onChange = { [weak self] isOn in
            self?.noThinkingEnabled = isOn
            self?.saveCurrentProvider()
        }
        let noThinkingStack = noThinkingContainer
        noThinkingStack.orientation = .horizontal
        noThinkingStack.spacing = 6
        noThinkingStack.alignment = .centerY
        noThinkingStack.translatesAutoresizingMaskIntoConstraints = false
        noThinkingStack.addArrangedSubview(noThinkingLabel)
        noThinkingStack.addArrangedSubview(noThinkingSwitch)
        // 初始隐藏（C3：仅 openai-compatible 显示，populateUI/loadProvider 会按 kind 切换）
        noThinkingStack.isHidden = true

        let modelControlStack = NSStackView()
        modelControlStack.orientation = .horizontal
        modelControlStack.spacing = 12
        modelControlStack.alignment = .centerY
        modelControlStack.distribution = .fill
        modelControlStack.translatesAutoresizingMaskIntoConstraints = false
        modelControlStack.addArrangedSubview(modelField)
        modelControlStack.addArrangedSubview(noThinkingStack)
        // modelField 撑宽：modelControlStack 内 modelField 宽 ≥ 180，stack 整体不被 noThinking 挤窄
        NSLayoutConstraint.activate([
            modelField.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
            // 给 SageSwitch 固定尺寸（与 SageSwitch 默认 frame 一致 32×20）
            noThinkingSwitch.widthAnchor.constraint(equalToConstant: 32),
            noThinkingSwitch.heightAnchor.constraint(equalToConstant: 20),
        ])

        let modelRow = SettingsFormRow(title: "模型", subtitle: "留空则使用提供者默认模型 · 关闭思考适用于 Qwen3 等推理模型", control: modelControlStack)
        let baseURLRow = SettingsFormRow(title: "API 地址", subtitle: "覆盖默认 API 端点", control: urlControlStack)
        let apiKeyRow = SettingsFormRow(title: "API 密钥", subtitle: "存储于钥匙串，不落盘", control: apiKeyField)

        providerGroup.addRow(providerRow)
        providerGroup.addRow(kindRow)
        providerGroup.addRow(modelRow)
        providerGroup.addRow(baseURLRow)
        providerGroup.addRow(testResultRow)
        providerGroup.addRow(apiKeyRow)

        // delegate 绑定（controlTextDidEndEditing 即时保存）
        modelField.delegate = self
        baseURLField.delegate = self
        apiKeyField.delegate = self

        // 表单面板约束（T5：noThinkingToggleRow 已并入模型行，formPanel 底部直接钉 providerGroup）
        NSLayoutConstraint.activate([
            providerGroup.topAnchor.constraint(equalTo: formPanel.topAnchor),
            providerGroup.leadingAnchor.constraint(equalTo: formPanel.leadingAnchor),
            providerGroup.trailingAnchor.constraint(equalTo: formPanel.trailingAnchor),
            // bottom 不钉：providerGroup 内容自适应、贴 formPanel 顶。formPanel 在 formStackView
            // distribution=.fill 撑满槽位时，卡片不被拉高（下方留白而非卡片空胀）。
        ])

        // ── JSON 面板 ──
        jsonPanel.translatesAutoresizingMaskIntoConstraints = false
        jsonPanel.isHidden = true
        formStackView.addArrangedSubview(jsonPanel)
        jsonPanel.leadingAnchor.constraint(equalTo: formStackView.leadingAnchor).isActive = true
        jsonPanel.trailingAnchor.constraint(equalTo: formStackView.trailingAnchor).isActive = true

        // JSON 编辑器（monospaced 12pt，最小高度 200pt）
        jsonScrollView.translatesAutoresizingMaskIntoConstraints = false
        jsonScrollView.hasVerticalScroller = true
        // 圆角编辑框（用户反馈：与表单卡片同款圆角）：去 bezel 直角边框，用 layer cornerRadius + masksToBounds。
        jsonScrollView.borderType = .noBorder
        jsonScrollView.drawsBackground = false
        jsonScrollView.wantsLayer = true
        jsonScrollView.layer?.cornerRadius = SettingsTheme.cardCornerRadius
        jsonScrollView.layer?.masksToBounds = true
        jsonScrollView.documentView = jsonTextView
        // documentView 用 autoresizing（非约束）：width 跟随 scrollView，否则 textView 宽度保持 0 致内容不可见。
        jsonTextView.autoresizingMask = [.width]
        jsonTextView.textContainer?.widthTracksTextView = true
        jsonTextView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        jsonTextView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        jsonTextView.isEditable = true
        jsonTextView.isSelectable = true
        jsonTextView.allowsUndo = true
        jsonTextView.isAutomaticQuoteSubstitutionEnabled = false
        jsonTextView.isAutomaticDashSubstitutionEnabled = false
        jsonPanel.addSubview(jsonScrollView)

        // 校验状态栏
        jsonValidationLabel.translatesAutoresizingMaskIntoConstraints = false
        jsonValidationLabel.font = .systemFont(ofSize: 11)
        jsonValidationLabel.lineBreakMode = .byWordWrapping
        jsonValidationLabel.maximumNumberOfLines = 2
        jsonPanel.addSubview(jsonValidationLabel)

        // Pretty Print 按钮
        prettyPrintButton.translatesAutoresizingMaskIntoConstraints = false
        prettyPrintButton.bezelStyle = .rounded
        prettyPrintButton.target = self
        prettyPrintButton.action = #selector(prettyPrintJSON(_:))
        jsonPanel.addSubview(prettyPrintButton)

        // JSON 编辑器高度：ContentColumnView 负责整体竖滚，jsonScrollView 给固定 min 高度保可用
        // （原 viewport-fill 拉伸逻辑随自建 scrollView 一并删除）。
        NSLayoutConstraint.activate([
            jsonScrollView.topAnchor.constraint(equalTo: jsonPanel.topAnchor),
            jsonScrollView.leadingAnchor.constraint(equalTo: jsonPanel.leadingAnchor),
            jsonScrollView.trailingAnchor.constraint(equalTo: jsonPanel.trailingAnchor),
            jsonScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 240),

            prettyPrintButton.topAnchor.constraint(equalTo: jsonScrollView.bottomAnchor, constant: SettingsTheme.spacingXs),
            // 格式化按钮左对齐编辑框（用户反馈）：与 jsonScrollView 同 leading
            prettyPrintButton.leadingAnchor.constraint(equalTo: jsonScrollView.leadingAnchor),

            jsonValidationLabel.centerYAnchor.constraint(equalTo: prettyPrintButton.centerYAnchor),
            jsonValidationLabel.leadingAnchor.constraint(equalTo: prettyPrintButton.trailingAnchor, constant: SettingsTheme.spacingSm),
            jsonValidationLabel.trailingAnchor.constraint(lessThanOrEqualTo: jsonPanel.trailingAnchor, constant: -SettingsTheme.contentPadding),
            jsonValidationLabel.bottomAnchor.constraint(equalTo: jsonPanel.bottomAnchor),
        ])

        // ── 分组2「AI 工具」（T6 重构：弃 NSTableView，改 SettingsGroupView 分组 + 只读 ToolItemRow）──
        let toolsLabel = SettingsGroupLabel(title: "AI 工具")
        toolsLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(toolsLabel)

        // 引导句（设计要求：分组上方加「AI 会根据输入自动选用」）
        let toolsIntroLabel = NSTextField(labelWithString: "AI 会根据输入自动选用")
        toolsIntroLabel.font = SettingsTheme.rowSubtitleFont()
        toolsIntroLabel.textColor = SettingsTheme.rowSubtitleColor()
        toolsIntroLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(toolsIntroLabel)

        // 「内置能力」分组
        let builtinLabel = SettingsGroupLabel(title: "内置能力")
        builtinLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(builtinLabel)

        let builtinToolsGroup = SettingsGroupView()
        builtinToolsGroup.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(builtinToolsGroup)

        // 「已装插件」分组
        let pluginsLabel = SettingsGroupLabel(title: "已装插件")
        pluginsLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(pluginsLabel)

        let pluginsToolsGroup = SettingsGroupView()
        pluginsToolsGroup.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(pluginsToolsGroup)

        // 保存引用供 renderToolGroups 填充行（属性在下方声明）
        self.builtinToolsGroup = builtinToolsGroup
        self.pluginsToolsGroup = pluginsToolsGroup
        self.pluginsToolsLabel = pluginsLabel

        // ── 整体约束 ──
        // ContentColumnView 负责整体竖滚 + 限宽居中，无需 tools 钉底（原 viewport-fill 删除）。
        NSLayoutConstraint.activate([
            // 提供者标签
            providerLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: SettingsTheme.groupTopInset),
            providerLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: SettingsTheme.contentPadding),
            providerLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -SettingsTheme.contentPadding),

            // Tab 控件
            tabSegmentedControl.topAnchor.constraint(equalTo: providerLabel.bottomAnchor, constant: SettingsTheme.spacingXs),
            tabSegmentedControl.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: SettingsTheme.contentPadding),
            tabSegmentedControl.widthAnchor.constraint(equalToConstant: 120),

            // formStackView 槽位（与下方工具列表同宽；form/JSON tab 各自高度，隐藏项自动塌缩）
            formStackView.topAnchor.constraint(equalTo: tabSegmentedControl.bottomAnchor, constant: SettingsTheme.spacingSm),
            formStackView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: SettingsTheme.contentPadding),
            formStackView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -SettingsTheme.contentPadding),

            // AI 工具区
            toolsLabel.topAnchor.constraint(equalTo: formStackView.bottomAnchor, constant: SettingsTheme.groupSpacing),
            toolsLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: SettingsTheme.contentPadding),
            toolsLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -SettingsTheme.contentPadding),

            // 引导句
            toolsIntroLabel.topAnchor.constraint(equalTo: toolsLabel.bottomAnchor, constant: SettingsTheme.spacingXs),
            toolsIntroLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: SettingsTheme.contentPadding),
            toolsIntroLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -SettingsTheme.contentPadding),

            // 「内置能力」分组
            builtinLabel.topAnchor.constraint(equalTo: toolsIntroLabel.bottomAnchor, constant: SettingsTheme.groupSpacing),
            builtinLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: SettingsTheme.contentPadding),
            builtinLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -SettingsTheme.contentPadding),

            builtinToolsGroup.topAnchor.constraint(equalTo: builtinLabel.bottomAnchor, constant: SettingsTheme.spacingXs),
            builtinToolsGroup.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: SettingsTheme.contentPadding),
            builtinToolsGroup.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -SettingsTheme.contentPadding),

            // 「已装插件」分组
            pluginsLabel.topAnchor.constraint(equalTo: builtinToolsGroup.bottomAnchor, constant: SettingsTheme.groupSpacing),
            pluginsLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: SettingsTheme.contentPadding),
            pluginsLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -SettingsTheme.contentPadding),

            pluginsToolsGroup.topAnchor.constraint(equalTo: pluginsLabel.bottomAnchor, constant: SettingsTheme.spacingXs),
            pluginsToolsGroup.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: SettingsTheme.contentPadding),
            pluginsToolsGroup.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -SettingsTheme.contentPadding),
        ])
    }

    // MARK: - Data

    private func loadConfig() {
        config = (try? LauncherConfig.load()) ?? .empty
    }

    private func populateUI() {
        isPopulating = true
        defer { isPopulating = false }

        // 重建提供者下拉
        providerPopup.removeAllItems()
        let ids = config.providerIDs
        if ids.isEmpty {
            providerPopup.addItem(withTitle: "（未配置）")
            clearProviderFields()
        } else {
            for id in ids {
                providerPopup.addItem(withTitle: id)
            }
            // 选中当前激活提供者
            if !config.activeProvider.isEmpty,
               let idx = ids.firstIndex(of: config.activeProvider) {
                providerPopup.selectItem(at: idx)
            } else {
                providerPopup.selectItem(at: 0)
            }
            loadProvider(id: providerPopup.titleOfSelectedItem ?? ids[0])
        }

        // 同步 JSON 编辑器
        syncToJSON()
    }

    /// 加载 AI 工具分组数据（T6：弃旧 toolItems:[String] + NSTableView）。
    ///
    /// 内置项固定 2 条（attach_action speak/copy → 人话化），插件项从 PluginManager.list() 收集，
    /// summary 用 `manifest.displaySummary`（人话降级），source 用 `manifest.name`。
    /// **移除所有 stdin/command/prompt mode 黑话**（AC-TOOLS-NO-JARGON）。
    ///
    /// - Returns: 分组数组 `[(title, [AIToolItem])]`，固定顺序：内置能力 → 已装插件。
    func loadToolGroups() -> [(title: String, items: [AIToolItem])] {
        // ── 内置能力 ──
        let builtin: [AIToolItem] = [
            AIToolItem(
                symbol: "🔊",
                title: "朗读回复",
                summary: "把 AI 回复读出声",
                source: "内置"
            ),
            AIToolItem(
                symbol: "📋",
                title: "复制到剪贴板",
                summary: "一键复制 AI 回复",
                source: "内置"
            ),
        ]

        // ── 已装插件 ──（summary 用 displaySummary 人话降级，禁 mode 黑话）
        var plugins: [AIToolItem] = []
        do {
            let manifests = try PluginManager.shared.list()
            for m in manifests {
                plugins.append(AIToolItem(
                    symbol: "🧩",
                    title: m.name,
                    summary: m.displaySummary,
                    source: m.name
                ))
            }
        } catch {
            BuddyLogger.shared.warn("provider settings: failed to load plugin manifests for tools list", subsystem: "settings", meta: ["error": "\(error)"])
        }

        return [
            ("内置能力", builtin),
            ("已装插件", plugins),
        ]
    }

    /// 把 loadToolGroups 的数据渲染进对应 SettingsGroupView。
    /// 无插件的分组（items 为空）整组隐藏（标题 + 容器）。
    private func renderToolGroups() {
        toolGroups = loadToolGroups()

        // 清空旧行（用 SettingsGroupView.clearRows，避免误清 stackView 容器本身）
        builtinToolsGroup.clearRows()
        pluginsToolsGroup.clearRows()

        for (title, items) in toolGroups {
            let targetGroup: SettingsGroupView
            switch title {
            case "内置能力":
                targetGroup = builtinToolsGroup
            case "已装插件":
                targetGroup = pluginsToolsGroup
                // 无插件时整组隐藏（标题 + 容器）
                if items.isEmpty {
                    pluginsToolsLabel.isHidden = true
                    pluginsToolsGroup.isHidden = true
                    continue
                } else {
                    pluginsToolsLabel.isHidden = false
                    pluginsToolsGroup.isHidden = false
                }
            default:
                targetGroup = builtinToolsGroup
            }

            for item in items {
                let row = ToolItemRow(item: item)
                row.translatesAutoresizingMaskIntoConstraints = false
                targetGroup.addRow(row)
            }
        }
    }

    private func loadProvider(id: String) {
        editingProviderID = id
        guard let provider = config.providers[id] else {
            clearProviderFields()
            return
        }

        // 类型
        if provider.kind == "openai-compatible" {
            kindPopup.selectItem(at: 1)
        } else {
            kindPopup.selectItem(at: 0)
        }

        // 模型
        modelField.stringValue = provider.model

        // 地址
        baseURLField.stringValue = provider.baseURL ?? ""

        // API Key（从 SecretStore 读取，不落盘 C3）
        do {
            if let key = try secretStore.load(key: provider.keyRef) {
                apiKeyField.stringValue = key
            } else {
                apiKeyField.stringValue = ""
            }
        } catch {
            apiKeyField.stringValue = ""
        }

        // noThinking toggle（C3：仅 openai-compatible 可见，T5 并入模型行）
        let isOpenAICompat = provider.kind == "openai-compatible"
        noThinkingContainer.isHidden = !isOpenAICompat
        noThinkingEnabled = provider.noThinking ?? false
        noThinkingSwitch.setState(noThinkingEnabled)
    }

    private func clearProviderFields() {
        editingProviderID = nil
        kindPopup.selectItem(at: 0)
        modelField.stringValue = ""
        baseURLField.stringValue = ""
        apiKeyField.stringValue = ""
        noThinkingContainer.isHidden = true
        noThinkingEnabled = false
        noThinkingSwitch.setState(false)
    }

    // MARK: - Actions

    /// 提供者下拉切换：保存当前字段 → 加载新提供者（C7）。
    @objc private func providerDidChange(_ sender: NSPopUpButton) {
        saveCurrentProvider()
        guard let newID = sender.titleOfSelectedItem, !newID.isEmpty,
              newID != "（未配置）" else {
            clearProviderFields()
            return
        }
        loadProvider(id: newID)
        // 更新激活提供者（saveCurrentProvider 已调 persistConfig，此处仅更新 activeProvider）
        config.activeProvider = newID
        try? config.save()
    }

    /// 类型切换：清空模型 + 切换 baseURL 默认值 + 更新 noThinking 可见性。
    @objc private func kindDidChange(_ sender: NSPopUpButton) {
        guard !isPopulating else { return }  // B1：populateUI 期间不触发保存
        let selectedKind = sender.titleOfSelectedItem ?? "anthropic"
        modelField.stringValue = ""

        if selectedKind == "anthropic" {
            baseURLField.stringValue = "https://api.anthropic.com"
        } else {
            baseURLField.stringValue = ""
        }

        // C3：noThinking toggle 仅 openai-compatible 可见（T5 并入模型行）
        let isOpenAI = selectedKind == "openai-compatible"
        noThinkingContainer.isHidden = !isOpenAI
        if !isOpenAI {
            noThinkingEnabled = false           // B1: 同步本地状态，避免切回时 UI/存储不一致
            noThinkingSwitch.setState(false)
        } else {
            noThinkingSwitch.setState(noThinkingEnabled)
        }

        // 即时保存
        saveCurrentProvider()
    }

    /// 连接测试（C5：不影响持久化，临时构造不写盘）。
    @objc private func testConnection(_ sender: NSButton) {
        // 先保存当前编辑
        saveCurrentProvider()

        let baseURL = baseURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseURL.isEmpty else {
            showTestResult("请输入 API 地址", isError: true)
            return
        }

        guard let base = URL(string: baseURL) else {
            showTestResult("API 地址格式无效", isError: true)
            return
        }
        // B4：用 appendingPathComponent 避免双 /v1（如 baseURL 已含 /v1 时拼接 "/v1/models" 产生 /v1/v1/models）
        // B2：用 lastPathComponent 正确处理 trailing slash（"/v1/" → "v1" 而非 ""）
        let url: URL
        if base.lastPathComponent == "v1" {
            url = base.appendingPathComponent("models")
        } else {
            url = base.appendingPathComponent("v1").appendingPathComponent("models")
        }

        let apiKey = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            showTestResult("请输入 API 密钥", isError: true)
            return
        }

        // 开始测试
        testButton.isEnabled = false
        testSpinner.isHidden = false
        testSpinner.startAnimation(nil)
        testResultRow.isHidden = true

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let kind = kindPopup.titleOfSelectedItem ?? "anthropic"
        if kind == "anthropic" {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            DispatchQueue.main.async {
                self?.testButton.isEnabled = true
                self?.testSpinner.stopAnimation(nil)
                self?.testSpinner.isHidden = true

                if let error = error {
                    let nsError = error as NSError
                    if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut {
                        self?.showTestResult("连接超时（15 秒）：请检查 API 地址可达性与网络", isError: true)
                    } else {
                        self?.showTestResult("连接失败：\(error.localizedDescription)", isError: true)
                    }
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    self?.showTestResult("无效响应", isError: true)
                    return
                }

                switch httpResponse.statusCode {
                case 200...299:
                    self?.showTestResult("连接成功 — API 可正常访问", isError: false)
                case 401:
                    self?.showTestResult("认证失败 (401)：API 密钥无效或已过期", isError: true)
                case 403:
                    self?.showTestResult("权限不足 (403)：API 密钥无权访问此端点", isError: true)
                case 404:
                    self?.showTestResult("端点不存在 (404)：API 地址可能不正确", isError: true)
                case 429:
                    self?.showTestResult("请求过于频繁 (429)：请稍后重试", isError: true)
                case 500...599:
                    self?.showTestResult("服务器错误 (\(httpResponse.statusCode))：API 服务暂时不可用", isError: true)
                default:
                    self?.showTestResult("HTTP \(httpResponse.statusCode)：未预期的响应状态", isError: true)
                }
            }
        }.resume()
    }

    private func showTestResult(_ message: String, isError: Bool) {
        testResultLabel.stringValue = message
        testResultLabel.textColor = isError ? .systemRed : .systemGreen
        testResultRow.isHidden = false
    }

    // MARK: - Tab Switching

    /// 表单 / JSON Tab 切换
    @objc private func tabDidChange(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 0 {
            // 切换到表单：JSON → 表单同步
            if !jsonPanel.isHidden {
                syncFromJSON()
            }
            jsonPanel.isHidden = true
            formPanel.isHidden = false
        } else {
            // 切换到 JSON：先显示面板再 syncToJSON。
            // NSScrollView 在 isHidden=true 时不计算 textContainer 布局，隐藏态下 set string
            // 会导致 containerSize 未刷新，切回可见后内容不可见（视觉空白但 string 有值）。
            saveCurrentProvider()
            formPanel.isHidden = true
            jsonPanel.isHidden = false
            syncToJSON()
            validateJSON()
            BuddyLogger.shared.debug("provider settings: switch to JSON tab", subsystem: "settings", meta: ["editingProviderID": editingProviderID ?? "nil"])
        }
    }

    // MARK: - JSON Sync

    /// 表单 → JSON：将当前 provider 配置序列化为 JSON 显示在编辑器中
    private func syncToJSON() {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        let panelIsHidden = jsonPanel.isHidden
        BuddyLogger.shared.debug("provider settings: syncToJSON enter", subsystem: "settings", meta: [
            "editingProviderID": editingProviderID ?? "nil",
            "panelIsHidden": panelIsHidden,
            "providersCount": config.providers.count,
        ])

        guard let id = editingProviderID, let provider = config.providers[id] else {
            jsonTextView.string = ""
            BuddyLogger.shared.warn("provider settings: syncToJSON empty (no provider)", subsystem: "settings", meta: [
                "editingProviderID": editingProviderID ?? "nil",
                "providersCount": config.providers.count,
            ])
            return
        }

        var dict: [String: Any] = [
            "kind": provider.kind,
            "model": provider.model,
            "keyRef": provider.keyRef,
        ]
        if let baseURL = provider.baseURL, !baseURL.isEmpty {
            dict["baseURL"] = baseURL
        }
        if let noThinking = provider.noThinking {
            dict["noThinking"] = noThinking
        }

        if let jsonData = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            jsonTextView.string = jsonString
            // 强制刷新布局：textContainer 在 panel 隐藏期间可能未 layout，
            // 滚到顶 + needsLayout 确保切回可见时内容立即可见（修复"经常看不到 JSON 内容"）。
            jsonTextView.scrollRangeToVisible(NSRange(location: 0, length: 0))
            jsonScrollView.needsLayout = true
            BuddyLogger.shared.info("provider settings: syncToJSON done", subsystem: "settings", meta: [
                "providerId": id,
                "jsonLength": jsonString.count,
            ])
        } else {
            BuddyLogger.shared.warn("provider settings: syncToJSON serialize failed", subsystem: "settings", meta: ["providerId": id])
        }
    }

    /// JSON → 表单：校验并解析 JSON 编辑器内容，更新内存模型 + 刷新表单
    private func syncFromJSON() {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        let text = jsonTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // 语法层校验
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            showJSONValidation("✗ JSON 语法错误：无法解析", isError: true)
            return
        }

        // Schema 层校验
        guard let kind = json["kind"] as? String,
              ["anthropic", "openai-compatible"].contains(kind) else {
            showJSONValidation("✗ 缺少有效 kind 字段（需为 anthropic 或 openai-compatible）", isError: true)
            return
        }
        guard let model = json["model"] as? String else {
            showJSONValidation("✗ 缺少 model 字段", isError: true)
            return
        }
        guard let keyRef = json["keyRef"] as? String else {
            showJSONValidation("✗ 缺少 keyRef 字段", isError: true)
            return
        }

        let baseURL = json["baseURL"] as? String
        let noThinking = json["noThinking"] as? Bool

        // 更新内存模型
        guard let id = editingProviderID, !id.isEmpty else { return }
        let provider = ProviderConfig(
            kind: kind,
            baseURL: (baseURL?.isEmpty ?? true) ? nil : baseURL,
            model: model,
            keyRef: keyRef,
            noThinking: noThinking
        )
        config.providers[id] = provider
        persistConfig()

        // 刷新表单面板
        isPopulating = true
        defer { isPopulating = false }

        if kind == "openai-compatible" {
            kindPopup.selectItem(at: 1)
        } else {
            kindPopup.selectItem(at: 0)
        }
        modelField.stringValue = model
        baseURLField.stringValue = baseURL ?? ""
        noThinkingEnabled = noThinking ?? false
        noThinkingSwitch.setState(noThinkingEnabled)
        noThinkingContainer.isHidden = (kind != "openai-compatible")

        showJSONValidation("✓ 格式正确", isError: false)
    }

    /// JSON 编辑器内容校验（语法 + Schema）
    private func validateJSON() {
        let text = jsonTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            jsonValidationLabel.stringValue = ""
            return
        }

        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            showJSONValidation("✗ JSON 语法错误：无法解析", isError: true)
            return
        }

        guard let kind = json["kind"] as? String,
              ["anthropic", "openai-compatible"].contains(kind) else {
            showJSONValidation("✗ 缺少有效 kind 字段（需为 anthropic 或 openai-compatible）", isError: true)
            return
        }
        guard json["model"] is String else {
            showJSONValidation("✗ 缺少 model 字段", isError: true)
            return
        }
        guard json["keyRef"] is String else {
            showJSONValidation("✗ 缺少 keyRef 字段", isError: true)
            return
        }

        showJSONValidation("✓ 格式正确", isError: false)
    }

    private func showJSONValidation(_ message: String, isError: Bool) {
        jsonValidationLabel.stringValue = message
        jsonValidationLabel.textColor = isError ? .systemRed : .systemGreen
    }

    /// Pretty Print：格式化 JSON 编辑器内容
    @objc private func prettyPrintJSON(_ sender: NSButton) {
        let text = jsonTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data),
              let prettyData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
              let prettyString = String(data: prettyData, encoding: .utf8) else {
            showJSONValidation("✗ JSON 格式无效，无法格式化", isError: true)
            return
        }

        jsonTextView.string = prettyString
        validateJSON()
    }

    // MARK: - Persistence

    /// 保存当前编辑的字段到内存模型 + 持久化（C7）。
    private func saveCurrentProvider() {
        guard let id = editingProviderID, !id.isEmpty else { return }

        let kind = kindPopup.titleOfSelectedItem ?? "anthropic"
        let model = modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = baseURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKeyValue = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let keyRef = "\(id).apiKey"

        // 保存 API Key 到 SecretStore（C3：不落盘）
        if !apiKeyValue.isEmpty {
            do {
                try secretStore.save(key: keyRef, value: apiKeyValue)
            } catch {
                BuddyLogger.shared.warn("provider settings: failed to save API key", subsystem: "settings", meta: ["keyRef": keyRef, "error": "\(error)"])
            }
        }

        // noThinking（C5：仅 openai-compatible 时有意义；nil 时 JSON 省略）
        let noThinkingValue: Bool?
        if kind == "openai-compatible" {
            // 读取本地追踪状态：开 = true，关 = nil（C3 省略）
            noThinkingValue = noThinkingEnabled ? true : nil
        } else {
            noThinkingValue = nil
        }
        let provider = ProviderConfig(
            kind: kind,
            baseURL: baseURL.isEmpty ? nil : baseURL,
            model: model,
            keyRef: keyRef,
            noThinking: noThinkingValue
        )
        config.providers[id] = provider
        persistConfig()
    }

    private func persistConfig() {
        do {
            try config.save()
        } catch {
            BuddyLogger.shared.warn("provider settings: failed to save config", subsystem: "settings", meta: ["error": "\(error)"])
        }
    }

}

// MARK: - NSTextFieldDelegate (即时保存)

extension ProviderSettingsViewController: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        saveCurrentProvider()
    }
}

// MARK: - EncryptedFileSecretStore fallback

private extension EncryptedFileSecretStore {
    /// 兜底构造：直接尝试从默认目录加载或创建。
    /// SecretStoreFactory.create() 的探针路径可能在内联测试等场景失败。
    static func fallback() -> SecretStore {
        do {
            return try EncryptedFileSecretStore.makeOrLoad(directory: LauncherConstants.buddyDir)
        } catch {
            // 终极兜底：返回一个内存态空实现（仅本次会话有效）
            return InMemorySecretStore()
        }
    }
}

/// 内存态兜底 SecretStore（仅当文件/钥匙串均不可用时）。
private final class InMemorySecretStore: SecretStore {
    private var store: [String: String] = [:]

    func save(key: String, value: String) throws {
        store[key] = value
    }

    func load(key: String) throws -> String? {
        return store[key]
    }

    func delete(key: String) throws {
        store.removeValue(forKey: key)
    }
}
