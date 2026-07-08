import AppKit

// MARK: - PluginGalleryViewController
//
// 「插件」设置分类（NSSplitView 双栏布局，T3）：
//   - 左栏：插件列表（NSTableView + 自定义 PluginListRow：title + summary + 来源徽标 + 开关）
//     首行「插件设置」虚拟项 → 右栏展示全局区面板（autoUpdate + depInstall + docs cell 三组）
//   - 右栏：选中插件的 detail 面板（PluginPanelRegistry 路由 / 空态）
//
// 面板路由（C3）：
//   - PluginPanelRegistry 查命中（如 snip）→ provider.makePanelVC()
//   - 未命中 → EmptyPluginStateVC（无可配置面板空态）
//
// 选中态持久化：UserDefaults key `SettingsSelectedPlugin`（AC-SNIPGUI-05）
//
// 四态状态机（保留，仅左栏 tableView 渲染受影响）：
//   - .loading / .normal / .empty / .error
//
// DI（保留 B3）：MarketplaceInspecting + PluginToggling 协议注入。
// state internal private(set)（@testable import 可断言，保留 M2）。
final class PluginGalleryViewController: NSViewController, SettingsTabClickReceiver, NSTableViewDataSource, NSTableViewDelegate {

    // MARK: - State

    /// C6 统一视图模型：内置 / 社区 / 侧载三来源统一展示。
    struct PluginEntry: Equatable {
        let name: String
        /// C6：一句话人话摘要（首屏展示）。
        let summary: String
        /// C6：详细说明（详情展开看）。
        let description: String
        let version: String
        /// C6：来源徽标 "builtin" | "community" | "sideloaded" | "settings"（虚拟设置项）。
        let source: String
        let enabled: Bool
        /// 兼容旧逻辑（侧载判断），保留供测试断言。
        var isSideloaded: Bool { source == "sideloaded" }

        /// 虚拟「插件设置」项（全局区面板入口）：左栏列表首行，
        /// 选中后右栏展示 autoUpdate / depInstall / docs 三组全局区。
        /// source == "settings" 标记虚拟项，不参与 toggle / enable / disable 路由。
        static let settingsEntry = PluginEntry(
            name: "插件设置",
            summary: "自动更新 · 依赖安装 · 开发文档",
            description: "插件系统通用设置：自动更新官方插件、自动安装依赖、查看开发文档",
            version: "—",
            source: "settings",
            enabled: true
        )
    }

    enum State: Equatable {
        case loading
        case normal(plugins: [PluginEntry])
        case empty
        case error(message: String)
    }

    /// M2：internal private(set) 暴露给测试 target，外部不可写。
    internal private(set) var state: State = .loading

    // MARK: - DI（B3 + C6）

    private let marketplace: MarketplaceInspecting
    private let plugins: PluginToggling
    /// C6：内置插件注册表（提供 builtin 数据源 + enabled 查询）。
    private let builtinRegistry: BuiltinPluginRegistry
    /// C6：内置插件开关存储（开关分派 builtin 分支）。
    private let builtinEnabledStore: BuiltinPluginEnabledStore
    /// C4：官方插件自动更新开关存储（顶部 switch 绑定）。
    private let autoUpdateStore: MarketplaceAutoUpdateStore

    // MARK: - UI：双栏容器

    /// 左栏：插件列表（NSTableView）
    private let sidebarTableView = NSTableView()
    private let sidebarScrollView = NSScrollView()
    /// 右栏：detail 容器（顶部全局区 + 下方插件面板）
    private let detailContainer = NSView()
    /// 全局区容器（autoUpdate + depInstall + docs button）
    private let globalHeaderContainer = NSView()
    /// 插件面板容器（detailContainment 切换 child VC）
    private let pluginPanelContainer = NSView()

    /// 当前展示的 plugin panel child VC
    private(set) var currentPanelChild: NSViewController?

    /// 全局区控件（autoUpdate / depInstall / docs 三组，作「插件设置」panel content）
    private let autoUpdateLabel = SettingsGroupLabel(title: "自动更新")
    private let autoUpdateGroup = SettingsGroupView()
    private let autoUpdateRow = SettingsToggleRow(
        title: "官方插件自动更新",
        subtitle: "检测到新版本时自动覆盖安装，无需手动重装",
        isOn: MarketplaceAutoUpdateStore.shared.isEnabled
    )
    private let depInstallLabel = SettingsGroupLabel(title: "依赖安装")
    private let depInstallGroup = SettingsGroupView()
    private let depInstallRow = SettingsToggleRow(
        title: "自动安装插件依赖",
        subtitle: "首次运行插件时自动通过 Homebrew 安装声明的外部依赖",
        isOn: DependencySettingsStore.shared.isEnabled
    )
    private let docsLabel = SettingsGroupLabel(title: "更多")
    private let docsGroup = SettingsGroupView()
    private let docsRow = SettingsActionRow(
        title: "插件开发文档",
        subtitle: "查看如何开发自己的插件",
        buttonTitle: "打开"
    )
    private let reseedButton = NSButton(title: "重新初始化", target: nil, action: nil)
    private let placeholderLabel = NSTextField(labelWithString: "")

    // MARK: - 持久化 key

    static let selectedPluginDefaultsKey = "SettingsSelectedPlugin"

    // MARK: - Init

    @MainActor
    init(
        marketplace: MarketplaceInspecting? = nil,
        plugins: PluginToggling? = nil,
        builtinRegistry: BuiltinPluginRegistry? = nil,
        builtinEnabledStore: BuiltinPluginEnabledStore? = nil,
        autoUpdateStore: MarketplaceAutoUpdateStore? = nil
    ) {
        self.marketplace = marketplace ?? MarketplaceManager.shared
        self.plugins = plugins ?? PluginManager.shared
        self.builtinRegistry = builtinRegistry ?? .shared
        self.builtinEnabledStore = builtinEnabledStore ?? .shared
        self.autoUpdateStore = autoUpdateStore ?? .shared
        super.init(nibName: nil, bundle: nil)

        // T2：注册 snip 面板 provider（C3，snip 首个实现）
        PluginPanelRegistry.shared.register(SnipPanelVC(), for: "snip")
    }

    @MainActor
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not used")
    }

    // MARK: - Lifecycle

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 780, height: 540))
        setupSplitLayout(in: container)
        self.view = container
        renderState()
        // 初始选中（从 UserDefaults 恢复，AC-SNIPGUI-05）
        restoreSelectionIfPossible()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        Task { @MainActor in
            await refresh()
            // refresh 后若 selection 落空，默认选中第 0 项（AC-SNIPGUI-02）
            if case .normal(let plugins) = state, !plugins.isEmpty,
               sidebarTableView.selectedRow < 0 || sidebarTableView.selectedRow >= plugins.count {
                sidebarTableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            }
        }
    }

    // MARK: - Setup：NSSplitView 双栏布局

    private func setupSplitLayout(in container: NSView) {
        // NSSplitView（垂直分隔：左=插件列表 sidebar，右=detail 容器）
        let splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(splitView)

        // 左栏：sidebar scroll + tableView
        setupSidebarTableView()

        let sidebarView = NSView()
        sidebarView.translatesAutoresizingMaskIntoConstraints = false
        sidebarScrollView.documentView = sidebarTableView
        sidebarScrollView.hasVerticalScroller = true
        sidebarScrollView.drawsBackground = false
        sidebarScrollView.translatesAutoresizingMaskIntoConstraints = false
        sidebarView.addSubview(sidebarScrollView)

        // 左栏 table identifier 守卫（imp-82：避免 SettingsWindow.forwardSidebarClick
        // 在右栏 SnipPanel SwiftUI List 上误命中）
        sidebarTableView.identifier = NSUserInterfaceItemIdentifier(rawValue: "settings.plugins.sidebar")

        NSLayoutConstraint.activate([
            sidebarScrollView.topAnchor.constraint(equalTo: sidebarView.topAnchor),
            sidebarScrollView.leadingAnchor.constraint(equalTo: sidebarView.leadingAnchor),
            sidebarScrollView.trailingAnchor.constraint(equalTo: sidebarView.trailingAnchor),
            sidebarScrollView.bottomAnchor.constraint(equalTo: sidebarView.bottomAnchor),
        ])

        // 右栏：detail 容器（顶部全局区 + 下方插件面板）
        setupDetailContainer()

        // NSSplitView 加左右两栏
        splitView.addSubview(sidebarView)
        splitView.addSubview(detailContainer)

        // 设置左右栏 hold（不收缩）+ 左栏宽度约束
        // NSSplitView 无 NSSplitViewItem 抽象（那是 NSSplitViewController 子类专用），这里用约束控制宽度
        sidebarView.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        sidebarView.widthAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true
        // 让 sidebar 优先收缩，detail 撑住
        sidebarView.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        sidebarView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailContainer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        detailContainer.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        // 默认比例：左 1/3，右 2/3（setPosition 控制分隔条）
        // 在 viewDidLayout 中通过 setPosition 调整（避免 frame=0 时 setPosition 失效）

        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: container.topAnchor),
            splitView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // AX：让红队可识别（AC-SNIPGUI-01 AXSplitGroup 子树）
        splitView.setAccessibilityIdentifier("settings.plugins.splitview")
        detailContainer.setAccessibilityIdentifier("settings.plugins.detail")
        sidebarTableView.setAccessibilityIdentifier("settings.plugins.sidebar.table")
    }

    private func setupSidebarTableView() {
        sidebarTableView.headerView = nil
        sidebarTableView.backgroundColor = .clear
        sidebarTableView.rowHeight = 56
        sidebarTableView.intercellSpacing = NSSize(width: 0, height: 0)
        sidebarTableView.dataSource = self
        sidebarTableView.delegate = self
        sidebarTableView.allowsEmptySelection = true
        sidebarTableView.allowsMultipleSelection = false
        sidebarTableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(rawValue: "plugin"))
        column.resizingMask = .autoresizingMask
        sidebarTableView.addTableColumn(column)
    }

    private func setupDetailContainer() {
        // 右栏 detail = pluginPanelContainer（containment 切换 child VC）。
        // 「插件设置」panel content（globalHeaderContainer）由 showPanel settings 分支包装注入。
        detailContainer.translatesAutoresizingMaskIntoConstraints = false

        // —— 自动更新分组 ——
        autoUpdateLabel.translatesAutoresizingMaskIntoConstraints = false
        globalHeaderContainer.addSubview(autoUpdateLabel)
        autoUpdateGroup.translatesAutoresizingMaskIntoConstraints = false
        globalHeaderContainer.addSubview(autoUpdateGroup)
        autoUpdateGroup.addRow(autoUpdateRow)
        autoUpdateRow.onToggle = { [weak self] isOn in
            self?.autoUpdateStore.setEnabled(isOn)
            BuddyLogger.shared.info("marketplace autoUpdate toggled", subsystem: "settings", meta: ["enabled": isOn])
        }

        // —— 依赖安装分组 ——
        depInstallLabel.translatesAutoresizingMaskIntoConstraints = false
        globalHeaderContainer.addSubview(depInstallLabel)
        depInstallGroup.translatesAutoresizingMaskIntoConstraints = false
        globalHeaderContainer.addSubview(depInstallGroup)
        depInstallGroup.addRow(depInstallRow)
        depInstallRow.onToggle = { isOn in
            DependencySettingsStore.shared.setEnabled(isOn)
            BuddyLogger.shared.info("plugin autoInstallDeps toggled", subsystem: "settings", meta: ["enabled": isOn])
        }

        // —— 文档分组（cell 形式：title + subtitle + 打开按钮）——
        docsLabel.translatesAutoresizingMaskIntoConstraints = false
        globalHeaderContainer.addSubview(docsLabel)
        docsGroup.translatesAutoresizingMaskIntoConstraints = false
        globalHeaderContainer.addSubview(docsGroup)
        docsGroup.addRow(docsRow)
        docsRow.onAction = { [weak self] in
            self?.handleDocsButton()
        }

        reseedButton.bezelStyle = .rounded
        reseedButton.target = self
        reseedButton.action = #selector(handleReseedButton)
        reseedButton.translatesAutoresizingMaskIntoConstraints = false
        globalHeaderContainer.addSubview(reseedButton)

        placeholderLabel.font = SettingsTheme.rowSubtitleFont()
        placeholderLabel.textColor = SettingsTheme.rowSubtitleColor()
        placeholderLabel.alignment = .center
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        globalHeaderContainer.addSubview(placeholderLabel)

        // globalHeaderContainer 作「插件设置」panel content，经 showPanel settings 分支包装进 pluginPanelContainer。
        // 内部三组垂直堆叠（autoUpdate / depInstall / docs），对齐 GeneralSettingsViewController 标准模式：
        //   label.top → group.top(label.bottom+6) → 下一 label.top(group.bottom+groupSpacing)
        //   最后一个 group【不钉底】——containment 会把 globalHeaderContainer 四边撑满 pluginPanelContainer，
        //   若再写 globalHeaderContainer.bottom == lastGroup.bottom 会反向把 group 拉伸到容器底部（高度异常根因）。
        globalHeaderContainer.translatesAutoresizingMaskIntoConstraints = false

        pluginPanelContainer.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.addSubview(pluginPanelContainer)

        NSLayoutConstraint.activate([
            // 自动更新
            autoUpdateLabel.topAnchor.constraint(equalTo: globalHeaderContainer.topAnchor),
            autoUpdateLabel.leadingAnchor.constraint(equalTo: globalHeaderContainer.leadingAnchor),
            autoUpdateLabel.trailingAnchor.constraint(equalTo: globalHeaderContainer.trailingAnchor),

            autoUpdateGroup.topAnchor.constraint(equalTo: autoUpdateLabel.bottomAnchor, constant: 6),
            autoUpdateGroup.leadingAnchor.constraint(equalTo: globalHeaderContainer.leadingAnchor),
            autoUpdateGroup.trailingAnchor.constraint(equalTo: globalHeaderContainer.trailingAnchor),

            // 依赖安装
            depInstallLabel.topAnchor.constraint(equalTo: autoUpdateGroup.bottomAnchor, constant: SettingsTheme.groupSpacing),
            depInstallLabel.leadingAnchor.constraint(equalTo: globalHeaderContainer.leadingAnchor),
            depInstallLabel.trailingAnchor.constraint(equalTo: globalHeaderContainer.trailingAnchor),

            depInstallGroup.topAnchor.constraint(equalTo: depInstallLabel.bottomAnchor, constant: 6),
            depInstallGroup.leadingAnchor.constraint(equalTo: globalHeaderContainer.leadingAnchor),
            depInstallGroup.trailingAnchor.constraint(equalTo: globalHeaderContainer.trailingAnchor),

            // 文档（cell 形式）
            docsLabel.topAnchor.constraint(equalTo: depInstallGroup.bottomAnchor, constant: SettingsTheme.groupSpacing),
            docsLabel.leadingAnchor.constraint(equalTo: globalHeaderContainer.leadingAnchor),
            docsLabel.trailingAnchor.constraint(equalTo: globalHeaderContainer.trailingAnchor),

            docsGroup.topAnchor.constraint(equalTo: docsLabel.bottomAnchor, constant: 6),
            docsGroup.leadingAnchor.constraint(equalTo: globalHeaderContainer.leadingAnchor),
            docsGroup.trailingAnchor.constraint(equalTo: globalHeaderContainer.trailingAnchor),

            // error 态占位（默认隐藏，renderState .error 显式 isHidden=false）
            placeholderLabel.centerXAnchor.constraint(equalTo: globalHeaderContainer.centerXAnchor),
            placeholderLabel.topAnchor.constraint(equalTo: docsGroup.bottomAnchor, constant: 24),

            reseedButton.centerXAnchor.constraint(equalTo: globalHeaderContainer.centerXAnchor),
            reseedButton.topAnchor.constraint(equalTo: placeholderLabel.bottomAnchor, constant: 12),

            // pluginPanelContainer 占满 detailContainer
            pluginPanelContainer.topAnchor.constraint(equalTo: detailContainer.topAnchor, constant: SettingsTheme.groupTopInset),
            pluginPanelContainer.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor, constant: SettingsTheme.contentPadding),
            pluginPanelContainer.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor, constant: -SettingsTheme.contentPadding),
            pluginPanelContainer.bottomAnchor.constraint(equalTo: detailContainer.bottomAnchor, constant: -SettingsTheme.contentPadding),
        ])
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // 调整分隔条位置（左栏 220pt 或 1/3 视窗宽，取较小）
        if let splitView = self.view as? NSSplitView, splitView.subviews.count == 2 {
            let targetWidth: CGFloat = min(220, splitView.bounds.width / 3)
            splitView.setPosition(targetWidth, ofDividerAt: 0)
        }
    }

    // MARK: - State machine

    @MainActor
    func refresh() async {
        state = .loading
        renderState()
        do {
            // C6：内置插件数据源（Registry，priority 降序，含 summary/description/enabled-via-C3）
            let builtinEntries: [PluginEntry] = builtinRegistry.plugins
                .sorted { $0.priority > $1.priority }
                .map { plugin in
                    PluginEntry(
                        name: plugin.id,
                        summary: plugin.summary,
                        description: plugin.description,
                        version: "内置",
                        source: "builtin",
                        enabled: builtinEnabledStore.isEnabled(id: plugin.id)
                    )
                }

            // C6：外部插件数据源（marketplace.inspect，M1 逐目录读 plugin.json）
            let inspection = try marketplace.inspect()
            let communityEntries: [PluginEntry] = inspection.plugins.map { p in
                PluginEntry(
                    name: p.name,
                    summary: p.summary,
                    description: p.description,
                    version: p.version,
                    source: "community",
                    enabled: p.enabled
                )
            }
            let sideloaded: [PluginEntry] = inspection.sideloadedPlugins.map { s in
                PluginEntry(
                    name: s.name,
                    summary: s.summary,
                    description: s.description,
                    version: "—",
                    source: "sideloaded",
                    enabled: s.enabled
                )
            }
            // 统一列表顺序：插件设置（虚拟） → 内置 → 社区 → 侧载
            // settingsEntry 永远是 row 0（全局区面板入口）
            let all = [PluginEntry.settingsEntry] + builtinEntries + communityEntries + sideloaded
            // settingsEntry 恒存在 → all 永远非空，empty 态在此分支不再可达（保留 .empty case 语义兼容）
            state = all.isEmpty ? .empty : .normal(plugins: all)
        } catch {
            state = .error(message: error.localizedDescription)
        }
        renderState()
        sidebarTableView.reloadData()
    }

    private func renderState() {
        guard isViewLoaded else { return }
        switch state {
        case .normal, .loading, .empty:
            // 左栏 tableView 由 dataSource 驱动；error 态时 dataSource 返回 0 行
            sidebarTableView.reloadData()
            placeholderLabel.isHidden = true
            reseedButton.isHidden = true
        case .error(let message):
            sidebarTableView.reloadData()
            placeholderLabel.stringValue = "插件初始化失败：\(message)"
            placeholderLabel.isHidden = false
            reseedButton.isHidden = false
            // error 态需展示 placeholderLabel + reseedButton，二者位于 globalHeaderContainer 内部；
            // 全局区已移至「插件设置」panel，故 error 态显式路由到 settings panel 保证可见（AT09 契约）
            if currentPanelChild?.view !== globalHeaderContainer {
                let settingsVC = NSViewController()
                settingsVC.view = globalHeaderContainer
                transitionPanel(to: settingsVC)
            }
        }
    }

    /// C6：来源徽标中文映射。
    private func sourceBadgeText(_ source: String) -> String {
        switch source {
        case "builtin": return "内置"
        case "community": return "社区"
        case "sideloaded": return "侧载"
        case "settings": return "设置"
        default: return source
        }
    }

    // MARK: - SettingsTabClickReceiver

    /// SettingsToggleRow 走自身 onToggle 闭包，不需要 hit-test 转发。
    /// 保留 no-op 兼容 SettingsWindow.sendEvent 的 forwardDetailClick（C3 点击兜底）。
    func handleClickAt(windowPoint: NSPoint) {
        // no-op
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        guard case .normal(let plugins) = state else { return 0 }
        return plugins.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard case .normal(let plugins) = state, row < plugins.count else { return nil }
        let entry = plugins[row]

        let cellId = NSUserInterfaceItemIdentifier(rawValue: "PluginListCell")
        let cell = tableView.makeView(withIdentifier: cellId, owner: self) as? PluginListCellView
            ?? PluginListCellView()
        cell.identifier = cellId
        let sourceBadge = sourceBadgeText(entry.source)
        let isSettings = entry.source == "settings"
        cell.configure(
            name: entry.name,
            summary: entry.summary,
            sourceBadge: sourceBadge,
            isOn: entry.enabled,
            isSettings: isSettings
        )
        cell.onToggle = { [weak self] isOn in
            // settings 虚拟项无 toggle 路由（toggleSwitch 已隐藏，回调理论上不触发；防御性 no-op）
            guard !isSettings else { return }
            self?.togglePlugin(name: entry.name, source: entry.source, enable: isOn)
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard case .normal(let plugins) = state else { return }
        let row = sidebarTableView.selectedRow
        guard row >= 0, row < plugins.count else {
            showEmptyPanel()
            return
        }
        let entry = plugins[row]
        // 持久化选中（AC-SNIPGUI-05）
        UserDefaults.standard.set(entry.name, forKey: Self.selectedPluginDefaultsKey)
        // 路由到对应面板
        showPanel(for: entry)
    }

    // MARK: - 面板路由（C3）

    private func showPanel(for entry: PluginEntry) {
        // settings 虚拟项路由：包装 globalHeaderContainer 为 settingsVC.view（pluginPanelContainer 填满后内部约束生效）
        if entry.source == "settings" {
            let settingsVC = NSViewController()
            settingsVC.view = globalHeaderContainer
            transitionPanel(to: settingsVC)
            BuddyLogger.shared.debug("plugin panel: routed", subsystem: "settings", meta: ["plugin": entry.name, "type": "settings"])
            return
        }
        // 查 PluginPanelRegistry（C3）：命中 → provider.makePanelVC()；未命中 → EmptyPluginStateVC
        let newChild: NSViewController
        if let provider = PluginPanelRegistry.shared.provider(for: entry.name) {
            newChild = provider.makePanelVC()
            BuddyLogger.shared.debug("plugin panel: routed", subsystem: "settings", meta: ["plugin": entry.name, "type": "custom"])
        } else {
            newChild = EmptyPluginStateVC(
                name: entry.name,
                summary: entry.summary,
                description: entry.description,
                enabled: entry.enabled
            )
            BuddyLogger.shared.debug("plugin panel: routed", subsystem: "settings", meta: ["plugin": entry.name, "type": "empty"])
        }
        transitionPanel(to: newChild)
    }

    private func showEmptyPanel() {
        let empty = NSViewController()
        empty.view = NSView(frame: .zero)
        transitionPanel(to: empty)
    }

    /// 通过 child containment 切换 plugin panel（参考 SettingsDetailContainerViewController.transition :148-172）
    private func transitionPanel(to newChild: NSViewController) {
        // 移除旧 child
        if let old = currentPanelChild {
            old.view.removeFromSuperview()
            old.removeFromParent()
        }
        // 加载新 child
        addChild(newChild)
        let childView = newChild.view
        childView.translatesAutoresizingMaskIntoConstraints = false
        pluginPanelContainer.addSubview(childView)
        NSLayoutConstraint.activate([
            childView.topAnchor.constraint(equalTo: pluginPanelContainer.topAnchor),
            childView.leadingAnchor.constraint(equalTo: pluginPanelContainer.leadingAnchor),
            childView.trailingAnchor.constraint(equalTo: pluginPanelContainer.trailingAnchor),
            childView.bottomAnchor.constraint(equalTo: pluginPanelContainer.bottomAnchor),
        ])
        currentPanelChild = newChild
    }

    private func restoreSelectionIfPossible() {
        guard case .normal(let plugins) = state, !plugins.isEmpty else { return }
        let savedName = UserDefaults.standard.string(forKey: Self.selectedPluginDefaultsKey) ?? ""
        if let idx = plugins.firstIndex(where: { $0.name == savedName }) {
            sidebarTableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        }
    }

    // MARK: - Actions

    /// 切换插件启用状态（SettingsToggleRow.onToggle 回调）。
    /// C6：开关分派 —— 内置 → C3 EnabledStore；外部 → PluginManager .disabled。
    private func togglePlugin(name: String, source: String, enable: Bool) {
        guard let safeName = sanitize(name) else {
            BuddyLogger.shared.warn("pluginGallery toggle invalid name", subsystem: "settings", meta: ["name": name])
            return
        }
        // C6：内置插件走 C3 EnabledStore（UserDefaults），不经 PluginManager（.disabled 文件是外部插件机制）
        if source == "builtin" {
            builtinEnabledStore.setEnabled(id: safeName, enabled: enable)
            BuddyLogger.shared.info("builtin plugin toggled", subsystem: "settings", meta: ["name": safeName, "enabled": enable])
            Task { @MainActor in await refresh() }
            return
        }
        // 外部插件（community / sideloaded）走 PluginManager .disabled
        Task { @MainActor in
            do {
                if enable {
                    try plugins.enable(name: safeName)
                } else {
                    try plugins.disable(name: safeName)
                }
                await refresh()
            } catch {
                BuddyLogger.shared.error("pluginGallery toggle failed", subsystem: "settings", meta: ["name": safeName, "error": "\(error)"])
            }
        }
    }

    @objc func handleReseedButton() {
        Task { @MainActor in
            do {
                // reseed 是 async throws（B2）
                try await marketplace.reseed()
                await refresh()
            } catch {
                state = .error(message: "重新初始化失败：\(error.localizedDescription)")
                renderState()
            }
        }
    }

    /// Test hook（旧 NSButton 路径兼容）：sender.identifier=plugin name, sender.tag=0→disable / 1→enable。
    /// 生产路径改走 PluginListCellView.onToggle → togglePlugin；此方法仅供测试验证 sanitize + enable/disable 逻辑链。
    /// 默认按 community（外部）走 PluginManager，保持旧行为。
    @objc func toggleButtonClicked(_ sender: NSButton) {
        let raw = sender.identifier?.rawValue ?? ""
        togglePlugin(name: raw, source: "community", enable: sender.tag == 1)
    }

    /// C6：「插件开发文档」入口按钮 → NSWorkspace 打开 web /plugin/docs。
    @objc func handleDocsButton() {
        // 生产文档站地址（与 web app 部署同源）。失败降级到 log，不崩。
        guard let url = URL(string: "https://buddy.stringzhao.life/plugin/docs") else {
            BuddyLogger.shared.warn("plugin docs url invalid", subsystem: "settings")
            return
        }
        NSWorkspace.shared.open(url)
        BuddyLogger.shared.info("opened plugin docs", subsystem: "settings", meta: ["url": url.absoluteString])
    }

    // MARK: - Helpers

    /// 路径白名单（深度防御，task 004 follow-up）。仅接受 `[a-z0-9-]+`。
    private func sanitize(_ name: String) -> String? {
        guard !name.isEmpty,
              name.range(of: "^[a-z0-9-]+$", options: .regularExpression) != nil else {
            return nil
        }
        return name
    }
}

// MARK: - PluginListCellView（左栏单元格）

/// 左栏插件列表单元格：name + summary + 来源徽标 + 开关。
/// 简化版 SettingsToggleRow（不展开 description，详情在右栏空态/面板里展示）。
final class PluginListCellView: NSTableCellView {

    private let nameLabel = NSTextField(labelWithString: "")
    private let summaryLabel = NSTextField(labelWithString: "")
    private let sourceBadge = NSTextField(labelWithString: "")
    // test seam：红队 AS-01/02 通过 @testable import 访问 frame 与触发 mouseDown（C-SWITCH-CLICK-PATH）。
    internal let toggleSwitch = SageSwitch(isOn: false)
    private var onToggleInternal: ((Bool) -> Void)?

    /// toggle 状态变化回调（newState: Bool）。
    var onToggle: ((Bool) -> Void)? {
        get { onToggleInternal }
        set {
            onToggleInternal = newValue
            toggleSwitch.onChange = { [weak self] isOn in
                self?.onToggleInternal?(isOn)
            }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupView() {
        nameLabel.font = SettingsTheme.rowTitleFont()
        nameLabel.textColor = SettingsTheme.rowTitleColor()
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameLabel)

        summaryLabel.font = SettingsTheme.footnoteFont()
        summaryLabel.textColor = SettingsTheme.rowSubtitleColor()
        summaryLabel.lineBreakMode = .byWordWrapping
        summaryLabel.maximumNumberOfLines = 1
        summaryLabel.cell?.truncatesLastVisibleLine = true
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(summaryLabel)

        sourceBadge.font = SettingsTheme.badgeFont()
        sourceBadge.textColor = SettingsTheme.footnoteColor()
        sourceBadge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sourceBadge)

        toggleSwitch.translatesAutoresizingMaskIntoConstraints = false
        addSubview(toggleSwitch)

        NSLayoutConstraint.activate([
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: toggleSwitch.leadingAnchor, constant: -8),

            sourceBadge.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 4),
            sourceBadge.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),

            summaryLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            summaryLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            summaryLabel.trailingAnchor.constraint(lessThanOrEqualTo: toggleSwitch.leadingAnchor, constant: -8),
            summaryLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8),

            toggleSwitch.centerYAnchor.constraint(equalTo: centerYAnchor),
            toggleSwitch.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            // 显式尺寸约束（契约 C-SWITCH-SIZE）：
            // SageSwitch init frame 32×20 在 translatesAutoresizingMaskIntoConstraints = false 下被忽略，
            // 必须给 width=32 + height=20 约束，否则 Auto Layout 解析为 0×0 → CALayer 无绘制区 + hitTest 不命中。
            toggleSwitch.widthAnchor.constraint(equalToConstant: 32),
            toggleSwitch.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    func configure(name: String, summary: String, sourceBadge: String, isOn: Bool, isSettings: Bool = false) {
        nameLabel.stringValue = name
        summaryLabel.stringValue = summary
        self.sourceBadge.stringValue = sourceBadge
        self.sourceBadge.isHidden = sourceBadge.isEmpty
        // settings 虚拟项隐藏开关（无 toggle 路由语义）
        toggleSwitch.isHidden = isSettings
        if !isSettings {
            toggleSwitch.setState(isOn)
        }
    }

    @objc private func handleToggle() {
        onToggleInternal?(toggleSwitch.isOn)
    }
}
