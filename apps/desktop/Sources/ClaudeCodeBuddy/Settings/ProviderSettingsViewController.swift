import AppKit

/// 「AI 配置」设置分类：提供者连接 + 系统提示词 + AI 工具。
///
/// 三组布局（自上而下，NSScrollView 包裹）：
/// - 分组1「提供者」（可编辑）：激活提供者/类型/模型/地址/密钥 + 连接测试
/// - 分组2「系统提示词」（只读）：虚线边框卡片 + NSTextView
/// - 分组3「AI 工具」（只读）：attach_action speak/copy + 注入策略
///
/// 契约 C3：API Key 不落盘，仅通过 SecretStore 存储。
/// 契约 C4：只读区域 isEditable=false + "只读"视觉标识。
/// 契约 C5：连接测试不影响持久化（临时构造不写盘，失败不清空字段）。
final class ProviderSettingsViewController: NSViewController {

    // MARK: - State

    private var config: LauncherConfig = .empty
    private let secretStore: SecretStore

    /// 当前正在编辑的提供者 ID（用于切换前保存）
    private var editingProviderID: String?

    // MARK: - Group 1 「提供者」控件

    private let providerPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let kindPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let modelField = NSTextField()
    private let baseURLField = NSTextField()
    private let apiKeyField = NSSecureTextField()
    private let testButton = NSButton(title: "🔍 测试连接", target: nil, action: nil)
    private let testSpinner = NSProgressIndicator()
    private let testResultLabel = NSTextField(labelWithString: "")

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
    }

    // MARK: - Layout

    private func setupLayout(in container: NSView) {
        // ── 分组1「提供者」──
        let providerLabel = SettingsGroupLabel(title: "提供者")
        providerLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(providerLabel)

        let providerGroup = SettingsGroupView()
        providerGroup.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(providerGroup)

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

        // ── 分组2「系统提示词」（只读）──
        let promptLabel = SettingsGroupLabel(title: "系统提示词")
        promptLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(promptLabel)

        let promptCard = readOnlyCard()
        promptCard.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(promptCard)

        // 系统提示词内容
        let promptTextView = NSTextView()
        promptTextView.string = DefaultAgentPrompt.system
        promptTextView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        promptTextView.textColor = .labelColor
        promptTextView.isEditable = false
        promptTextView.isSelectable = true
        promptTextView.backgroundColor = .textBackgroundColor
        promptTextView.translatesAutoresizingMaskIntoConstraints = false
        promptTextView.heightAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        promptCard.addSubview(promptTextView)

        // footer
        let promptFooter = NSTextField(labelWithString: "当前使用默认系统提示词 · 后续支持自定义覆盖")
        promptFooter.font = SettingsTheme.footnoteFont()
        promptFooter.textColor = SettingsTheme.footnoteColor()
        promptFooter.translatesAutoresizingMaskIntoConstraints = false
        promptCard.addSubview(promptFooter)

        // "只读" badge
        let promptReadOnlyBadge = readOnlyBadge()
        promptCard.addSubview(promptReadOnlyBadge)

        NSLayoutConstraint.activate([
            promptReadOnlyBadge.topAnchor.constraint(equalTo: promptCard.topAnchor, constant: 8),
            promptReadOnlyBadge.trailingAnchor.constraint(equalTo: promptCard.trailingAnchor, constant: -SettingsTheme.cardContentPadding),

            promptTextView.topAnchor.constraint(equalTo: promptReadOnlyBadge.bottomAnchor, constant: 6),
            promptTextView.leadingAnchor.constraint(equalTo: promptCard.leadingAnchor, constant: SettingsTheme.cardContentPadding),
            promptTextView.trailingAnchor.constraint(equalTo: promptCard.trailingAnchor, constant: -SettingsTheme.cardContentPadding),

            promptFooter.topAnchor.constraint(equalTo: promptTextView.bottomAnchor, constant: 6),
            promptFooter.leadingAnchor.constraint(equalTo: promptCard.leadingAnchor, constant: SettingsTheme.cardContentPadding),
            promptFooter.trailingAnchor.constraint(equalTo: promptCard.trailingAnchor, constant: -SettingsTheme.cardContentPadding),
            promptFooter.bottomAnchor.constraint(equalTo: promptCard.bottomAnchor, constant: -8),
        ])

        // ── 分组3「AI 工具」（只读）──
        let toolsLabel = SettingsGroupLabel(title: "AI 工具")
        toolsLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(toolsLabel)

        let toolsGroup = SettingsGroupView()
        toolsGroup.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(toolsGroup)

        // "只读" badge
        let toolsReadOnlyBadge = readOnlyBadge()
        toolsReadOnlyBadge.translatesAutoresizingMaskIntoConstraints = false
        toolsGroup.addSubview(toolsReadOnlyBadge)

        // 工具说明
        let toolsInfo = NSTextField(labelWithString: "当前框架内置 1 个 meta tool：\n• attach_action — speak（朗读 TTS）/ copy（复制到剪贴板）\n\n注入策略：prompt mode 全量注入，模型可调用以附加按钮")
        toolsInfo.font = SettingsTheme.rowSubtitleFont()
        toolsInfo.textColor = SettingsTheme.rowSubtitleColor()
        toolsInfo.lineBreakMode = .byWordWrapping
        toolsInfo.maximumNumberOfLines = 0
        toolsInfo.translatesAutoresizingMaskIntoConstraints = false
        toolsGroup.addSubview(toolsInfo)

        NSLayoutConstraint.activate([
            toolsReadOnlyBadge.topAnchor.constraint(equalTo: toolsGroup.topAnchor, constant: 8),
            toolsReadOnlyBadge.trailingAnchor.constraint(equalTo: toolsGroup.trailingAnchor, constant: -SettingsTheme.cardContentPadding),

            toolsInfo.topAnchor.constraint(equalTo: toolsReadOnlyBadge.bottomAnchor, constant: 6),
            toolsInfo.leadingAnchor.constraint(equalTo: toolsGroup.leadingAnchor, constant: SettingsTheme.cardContentPadding),
            toolsInfo.trailingAnchor.constraint(equalTo: toolsGroup.trailingAnchor, constant: -SettingsTheme.cardContentPadding),
            toolsInfo.bottomAnchor.constraint(equalTo: toolsGroup.bottomAnchor, constant: -8),
        ])

        // ── 整体约束 ──
        let bottomAnchor = toolsGroup.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -SettingsTheme.groupTopInset)
        bottomAnchor.priority = .defaultLow

        NSLayoutConstraint.activate([
            // 提供者
            providerLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: SettingsTheme.groupTopInset),
            providerLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: SettingsTheme.contentPadding),
            providerLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -SettingsTheme.contentPadding),

            providerGroup.topAnchor.constraint(equalTo: providerLabel.bottomAnchor, constant: 6),
            providerGroup.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: SettingsTheme.contentPadding),
            providerGroup.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -SettingsTheme.contentPadding),

            // 系统提示词
            promptLabel.topAnchor.constraint(equalTo: providerGroup.bottomAnchor, constant: SettingsTheme.groupSpacing),
            promptLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: SettingsTheme.contentPadding),
            promptLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -SettingsTheme.contentPadding),

            promptCard.topAnchor.constraint(equalTo: promptLabel.bottomAnchor, constant: 6),
            promptCard.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: SettingsTheme.contentPadding),
            promptCard.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -SettingsTheme.contentPadding),

            // AI 工具
            toolsLabel.topAnchor.constraint(equalTo: promptCard.bottomAnchor, constant: SettingsTheme.groupSpacing),
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
    }

    private func clearProviderFields() {
        editingProviderID = nil
        kindPopup.selectItem(at: 0)
        modelField.stringValue = ""
        baseURLField.stringValue = ""
        apiKeyField.stringValue = ""
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
        // 更新激活提供者
        config.activeProvider = newID
        persistConfig()
    }

    /// 类型切换：清空模型 + 切换 baseURL 默认值。
    @objc private func kindDidChange(_ sender: NSPopUpButton) {
        let selectedKind = sender.titleOfSelectedItem ?? "anthropic"
        modelField.stringValue = ""

        if selectedKind == "anthropic" {
            baseURLField.stringValue = "https://api.anthropic.com"
        } else {
            baseURLField.stringValue = ""
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

        guard let url = URL(string: baseURL.hasSuffix("/") ? "\(baseURL)v1/models" : "\(baseURL)/v1/models") else {
            showTestResult("API 地址格式无效", isError: true)
            return
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
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
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
                case 200:
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

        // 更新内存模型
        let provider = ProviderConfig(
            kind: kind,
            baseURL: baseURL.isEmpty ? nil : baseURL,
            model: model,
            keyRef: keyRef
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

    // MARK: - Read-only helpers (C4)

    /// 创建虚线边框卡片（分组2「系统提示词」用，C4 只读标识）。
    private func readOnlyCard() -> NSView {
        let card = DashedBorderView()
        card.wantsLayer = true
        card.layer?.cornerRadius = SettingsTheme.cardCornerRadius
        card.layer?.backgroundColor = SettingsTheme.cardBackgroundColor.cgColor
        return card
    }

    /// "只读" 视觉标识 badge（C4）。
    private func readOnlyBadge() -> NSTextField {
        let badge = NSTextField(labelWithString: "只读")
        badge.font = SettingsTheme.badgeFont()
        badge.textColor = SettingsTheme.badgeColor()
        badge.alignment = .right
        badge.translatesAutoresizingMaskIntoConstraints = false
        return badge
    }
}

// MARK: - NSTextFieldDelegate (即时保存)

extension ProviderSettingsViewController: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        saveCurrentProvider()
    }
}

// MARK: - DashedBorderView (C4 只读卡片虚线边框)

/// 通过 CAShapeLayer 绘制虚线边框的 NSView 子类。
/// CALayer 无 borderDashPattern 属性，需 CAShapeLayer 描边实现。
private final class DashedBorderView: NSView {
    private let borderLayer = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        borderLayer.strokeColor = NSColor.separatorColor.cgColor
        borderLayer.lineWidth = 1
        borderLayer.lineDashPattern = [4, 4]
        borderLayer.fillColor = nil
        layer?.addSublayer(borderLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let path = CGMutablePath()
        let cornerRadius = SettingsTheme.cardCornerRadius
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        path.addRoundedRect(in: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius)
        borderLayer.path = path
        borderLayer.frame = bounds
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
