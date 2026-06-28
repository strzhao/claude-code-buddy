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

    /// AI 工具列表数据
    private var toolItems: [String] = []
    private let toolsTableView = NSTableView()
    private let emptyToolsLabel = NSTextField(labelWithString: "暂无工具")

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

    /// noThinking toggle 行（仅 openai-compatible 时可见）
    private let noThinkingToggleRow = SettingsToggleRow(title: "关闭 LLM 思考模式", subtitle: "适用于 Qwen3 等支持 chat_template_kwargs 的推理模型", isOn: false)

    // JSON 面板控件
    private let jsonTextView = NSTextView()
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
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 580, height: 560))
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 580, height: 560))
        contentView.translatesAutoresizingMaskIntoConstraints = false

        setupLayout(in: contentView)

        scrollView.documentView = contentView
        // 固定文档宽度等于 clipView 宽度（水平不滚动）
        contentView.widthAnchor.constraint(equalTo: scrollView.widthAnchor).isActive = true

        self.view = scrollView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        loadConfig()
        populateUI()
        loadToolItems()
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
        container.addSubview(formPanel)

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

        // test row: button + spinner + result 左到右排列
        let testRow = NSView()
        testRow.translatesAutoresizingMaskIntoConstraints = false
        testRow.addSubview(testButton)
        testRow.addSubview(testSpinner)
        testRow.addSubview(testResultLabel)
        NSLayoutConstraint.activate([
            testRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
            testButton.leadingAnchor.constraint(equalTo: testRow.leadingAnchor, constant: SettingsTheme.cardContentPadding),
            testButton.centerYAnchor.constraint(equalTo: testRow.centerYAnchor),
            testSpinner.leadingAnchor.constraint(equalTo: testButton.trailingAnchor, constant: 8),
            testSpinner.centerYAnchor.constraint(equalTo: testRow.centerYAnchor),
            testResultLabel.leadingAnchor.constraint(equalTo: testSpinner.trailingAnchor, constant: 8),
            testResultLabel.centerYAnchor.constraint(equalTo: testRow.centerYAnchor),
            testResultLabel.trailingAnchor.constraint(lessThanOrEqualTo: testRow.trailingAnchor, constant: -SettingsTheme.cardContentPadding),
            testResultLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 280),
        ])

        // 表单行
        let providerRow = SettingsFormRow(title: "激活提供者", subtitle: nil, control: providerPopup)
        let kindRow = SettingsFormRow(title: "类型", subtitle: nil, control: kindPopup)
        let modelRow = SettingsFormRow(title: "模型", subtitle: "留空则使用提供者默认模型", control: modelField)
        let baseURLRow = SettingsFormRow(title: "API 地址", subtitle: "覆盖默认 API 端点", control: baseURLField)
        let apiKeyRow = SettingsFormRow(title: "API 密钥", subtitle: "存储于钥匙串，不落盘", control: apiKeyField)

        providerGroup.addRow(providerRow)
        providerGroup.addRow(kindRow)
        providerGroup.addRow(modelRow)
        providerGroup.addRow(baseURLRow)
        providerGroup.addRow(apiKeyRow)
        providerGroup.addRow(testRow)

        // delegate 绑定（controlTextDidEndEditing 即时保存）
        modelField.delegate = self
        baseURLField.delegate = self
        apiKeyField.delegate = self

        // noThinking toggle（B3：仅 openai-compatible 时可见）
        noThinkingToggleRow.translatesAutoresizingMaskIntoConstraints = false
        noThinkingToggleRow.onToggle = { [weak self] isOn in
            self?.noThinkingEnabled = isOn
            self?.saveCurrentProvider()
        }
        formPanel.addSubview(noThinkingToggleRow)

        // 表单面板约束
        NSLayoutConstraint.activate([
            providerGroup.topAnchor.constraint(equalTo: formPanel.topAnchor),
            providerGroup.leadingAnchor.constraint(equalTo: formPanel.leadingAnchor, constant: SettingsTheme.contentPadding),
            providerGroup.trailingAnchor.constraint(equalTo: formPanel.trailingAnchor, constant: -SettingsTheme.contentPadding),

            noThinkingToggleRow.topAnchor.constraint(equalTo: providerGroup.bottomAnchor, constant: 8),
            noThinkingToggleRow.leadingAnchor.constraint(equalTo: formPanel.leadingAnchor, constant: SettingsTheme.contentPadding),
            noThinkingToggleRow.trailingAnchor.constraint(equalTo: formPanel.trailingAnchor, constant: -SettingsTheme.contentPadding),
            noThinkingToggleRow.bottomAnchor.constraint(equalTo: formPanel.bottomAnchor),
        ])

        // ── JSON 面板 ──
        jsonPanel.translatesAutoresizingMaskIntoConstraints = false
        jsonPanel.isHidden = true
        container.addSubview(jsonPanel)

        // JSON 编辑器（monospaced 12pt，最小高度 200pt）
        let jsonScrollView = NSScrollView()
        jsonScrollView.translatesAutoresizingMaskIntoConstraints = false
        jsonScrollView.hasVerticalScroller = true
        jsonScrollView.borderType = .bezelBorder
        jsonScrollView.documentView = jsonTextView
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

        NSLayoutConstraint.activate([
            jsonScrollView.topAnchor.constraint(equalTo: jsonPanel.topAnchor),
            jsonScrollView.leadingAnchor.constraint(equalTo: jsonPanel.leadingAnchor, constant: SettingsTheme.contentPadding),
            jsonScrollView.trailingAnchor.constraint(equalTo: jsonPanel.trailingAnchor, constant: -SettingsTheme.contentPadding),
            jsonScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),

            prettyPrintButton.topAnchor.constraint(equalTo: jsonScrollView.bottomAnchor, constant: 6),
            prettyPrintButton.leadingAnchor.constraint(equalTo: jsonPanel.leadingAnchor, constant: SettingsTheme.contentPadding),

            jsonValidationLabel.centerYAnchor.constraint(equalTo: prettyPrintButton.centerYAnchor),
            jsonValidationLabel.leadingAnchor.constraint(equalTo: prettyPrintButton.trailingAnchor, constant: 10),
            jsonValidationLabel.trailingAnchor.constraint(lessThanOrEqualTo: jsonPanel.trailingAnchor, constant: -SettingsTheme.contentPadding),
            jsonValidationLabel.bottomAnchor.constraint(equalTo: jsonPanel.bottomAnchor),
        ])

        // ── 分组2「AI 工具」──
        let toolsLabel = SettingsGroupLabel(title: "AI 工具")
        toolsLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(toolsLabel)

        let toolsGroup = SettingsGroupView()
        toolsGroup.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(toolsGroup)

        // 工具列表 TableView（Step 4：Plugin 驱动）
        toolsTableView.translatesAutoresizingMaskIntoConstraints = false
        toolsTableView.headerView = nil
        toolsTableView.selectionHighlightStyle = .none
        toolsTableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tools")))
        toolsTableView.rowHeight = 24
        toolsTableView.intercellSpacing = NSSize(width: 0, height: 4)
        toolsTableView.backgroundColor = .clear
        toolsTableView.dataSource = self
        toolsTableView.delegate = self
        toolsGroup.addSubview(toolsTableView)

        // 空状态占位 label
        emptyToolsLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyToolsLabel.font = SettingsTheme.rowSubtitleFont()
        emptyToolsLabel.textColor = SettingsTheme.rowSubtitleColor()
        emptyToolsLabel.isHidden = true
        toolsGroup.addSubview(emptyToolsLabel)

        NSLayoutConstraint.activate([
            toolsTableView.topAnchor.constraint(equalTo: toolsGroup.topAnchor, constant: 8),
            toolsTableView.leadingAnchor.constraint(equalTo: toolsGroup.leadingAnchor, constant: SettingsTheme.cardContentPadding),
            toolsTableView.trailingAnchor.constraint(equalTo: toolsGroup.trailingAnchor, constant: -SettingsTheme.cardContentPadding),
            toolsTableView.heightAnchor.constraint(greaterThanOrEqualToConstant: 60),

            emptyToolsLabel.centerXAnchor.constraint(equalTo: toolsGroup.centerXAnchor),
            emptyToolsLabel.centerYAnchor.constraint(equalTo: toolsTableView.centerYAnchor),

            emptyToolsLabel.bottomAnchor.constraint(equalTo: toolsGroup.bottomAnchor, constant: -12),
        ])

        // ── 整体约束 ──
        let bottomAnchor = toolsGroup.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -SettingsTheme.groupTopInset)
        bottomAnchor.priority = .defaultLow

        NSLayoutConstraint.activate([
            // 提供者标签
            providerLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: SettingsTheme.groupTopInset),
            providerLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: SettingsTheme.contentPadding),
            providerLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -SettingsTheme.contentPadding),

            // Tab 控件
            tabSegmentedControl.topAnchor.constraint(equalTo: providerLabel.bottomAnchor, constant: 6),
            tabSegmentedControl.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: SettingsTheme.contentPadding),
            tabSegmentedControl.widthAnchor.constraint(equalToConstant: 120),

            // 表单面板
            formPanel.topAnchor.constraint(equalTo: tabSegmentedControl.bottomAnchor, constant: 8),
            formPanel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 0),
            formPanel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: 0),

            // JSON 面板（与表单面板共享位置）
            jsonPanel.topAnchor.constraint(equalTo: formPanel.topAnchor),
            jsonPanel.leadingAnchor.constraint(equalTo: formPanel.leadingAnchor),
            jsonPanel.trailingAnchor.constraint(equalTo: formPanel.trailingAnchor),

            // AI 工具
            toolsLabel.topAnchor.constraint(equalTo: formPanel.bottomAnchor, constant: SettingsTheme.groupSpacing),
            toolsLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: SettingsTheme.contentPadding),
            toolsLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -SettingsTheme.contentPadding),

            toolsGroup.topAnchor.constraint(equalTo: toolsLabel.bottomAnchor, constant: 6),
            toolsGroup.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: SettingsTheme.contentPadding),
            toolsGroup.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -SettingsTheme.contentPadding),

            bottomAnchor,
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

    /// 加载 AI 工具列表：Plugin 驱动（收集已安装插件的工具）+ 内置 meta tools 兜底
    private func loadToolItems() {
        var items: [String] = []

        // 内置 meta tools（兜底）
        items.append("attach_action — speak（朗读 TTS）")
        items.append("attach_action — copy（复制到剪贴板）")

        // 从已安装插件收集工具信息（预留扩展）
        do {
            let manifests = try PluginManager.shared.list()
            for m in manifests {
                switch m.modeConfig {
                case .stdin:
                    items.append("\(m.name) — stdin 工具执行")
                case .command:
                    items.append("\(m.name) — command 直接产出")
                case .prompt:
                    items.append("\(m.name) — prompt LLM 单轮")
                }
            }
        } catch {
            BuddyLogger.shared.warn("provider settings: failed to load plugin manifests for tools list", subsystem: "settings", meta: ["error": "\(error)"])
        }

        toolItems = items
        toolsTableView.reloadData()
        emptyToolsLabel.isHidden = !toolItems.isEmpty
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

        // noThinking toggle（C5：仅 openai-compatible 可见）
        let isOpenAICompat = provider.kind == "openai-compatible"
        noThinkingToggleRow.isHidden = !isOpenAICompat
        noThinkingEnabled = provider.noThinking ?? false
        noThinkingToggleRow.setSwitchState(noThinkingEnabled)
    }

    private func clearProviderFields() {
        editingProviderID = nil
        kindPopup.selectItem(at: 0)
        modelField.stringValue = ""
        baseURLField.stringValue = ""
        apiKeyField.stringValue = ""
        noThinkingToggleRow.isHidden = true
        noThinkingEnabled = false
        noThinkingToggleRow.setSwitchState(false)
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

        // C5：noThinking toggle 仅 openai-compatible 可见
        let isOpenAI = selectedKind == "openai-compatible"
        noThinkingToggleRow.isHidden = !isOpenAI
        if !isOpenAI {
            noThinkingEnabled = false           // B1: 同步本地状态，避免切回时 UI/存储不一致
            noThinkingToggleRow.setSwitchState(false)
        } else {
            noThinkingToggleRow.setSwitchState(noThinkingEnabled)
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
        testResultLabel.isHidden = true

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
        testResultLabel.isHidden = false
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
            // 切换到 JSON：表单 → JSON 同步
            saveCurrentProvider()
            syncToJSON()
            validateJSON()
            formPanel.isHidden = true
            jsonPanel.isHidden = false
        }
    }

    // MARK: - JSON Sync

    /// 表单 → JSON：将当前 provider 配置序列化为 JSON 显示在编辑器中
    private func syncToJSON() {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        guard let id = editingProviderID, let provider = config.providers[id] else {
            jsonTextView.string = ""
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
        noThinkingToggleRow.setSwitchState(noThinkingEnabled)
        noThinkingToggleRow.isHidden = (kind != "openai-compatible")

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

// MARK: - AI 工具列表 TableView 数据源

extension ProviderSettingsViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return toolItems.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < toolItems.count else { return nil }
        let item = toolItems[row]

        let cellIdentifier = NSUserInterfaceItemIdentifier("ToolCell")
        let cell: NSTableCellView
        if let existing = tableView.makeView(withIdentifier: cellIdentifier, owner: nil) as? NSTableCellView {
            cell = existing
        } else {
            cell = NSTableCellView()
            cell.identifier = cellIdentifier

            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.font = .systemFont(ofSize: 12)
            textField.textColor = .labelColor
            cell.addSubview(textField)
            cell.textField = textField

            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                textField.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
            ])
        }
        cell.textField?.stringValue = item
        return cell
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
