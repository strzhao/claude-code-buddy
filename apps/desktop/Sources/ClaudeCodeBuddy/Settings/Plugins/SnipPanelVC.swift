import AppKit
import Combine

// MARK: - SnipPanelVC
//
// snip 专属设置面板（纯 AppKit，单列 accordion，autopilot 2026-07-13 重构）。
//
// 旧 master-detail（左 leftPane 240 + 右 ContentColumnView 包 detailContainer 四态）已移除：
// 三重嵌套 ContentColumnView documentView 塌缩（patterns/2026-07-12 同构）+ makePanelVC return self
// 违反新实例契约。新设计 = 单列全宽（铺满 gallery pluginPanelContainer）：
//   - header（searchField + 新增片段 button）
//   - NSScrollView 包 NSTableView，每行折叠态卡片 / 展开态编辑表单（accordion，最多展开 1 项）
//
// 数据源：SnippetsService.shared（@MainActor 直驱），objectWillChange sink 刷新列表。
// 删除二次确认：NSAlert（presentDeleteAlert/handleDeleteResponse test seam）。
//
// 契约引用（state.md ## 契约规约）：
//   C-AX-STABLE（snip 新增 AX id settings.plugins.snip.row.<i> / .expanded.<i>）
//   C-PANEL-NEW-INSTANCE（makePanelVC 返 SnipPanelVC() 新实例）
//   C-SNIP-SINGLE-COLUMN（单列全宽，NSScrollView 嵌套深度 <= 2）
//   C-SNIP-ACCORDION-ONE（expandedRow: Int? 单值，最多展开 1 项）
//   C-SNIP-PERSIST（SettingsSelectedPlugin UserDefaults 不变）

/// accordion 行态（testHook 暴露给测试断言；语义对齐旧 SnipDetailMode 的 empty/create/edit，
/// preview 态并入行内只读折叠卡片展示，不再单独 preview VC）。
enum SnipAccordionMode {
    case empty  // 无展开行（含空列表）
    case create // 新建行展开（expandedRow == createRowIndex 哨兵）
    case edit   // 某已有行展开编辑
}

@MainActor
final class SnipPanelVC: NSViewController, PluginSettingsPanelProvider {

    private let service: SnippetsService
    private var objectWillChangeCancellable: AnyCancellable?

    /// 新建行在 tableView 顶部的哨兵索引（numberOfRows 计算 +1，viewFor 在此索引返新建编辑表单）。
    static let createRowIndex = -1

    // header
    private let searchField = NSSearchField()
    private let addButton = NSButton()

    // 列表
    private let tableView = NSTableView()
    private let listScrollView = NSScrollView()
    private var filteredItems: [SnippetItem] = []

    /// accordion 状态：当前展开行索引。
    /// nil = 无展开；createRowIndex(-1) = 新建行展开；>=0 = 已有行 expandedItems 索引展开。
    /// 注：此处「行索引」是「数据行」语义——createRowIndex 哨兵占 tableView row 0，
    /// 已有片段在 tableView row 1..N（filteredItems 索引 0..N-1 对应 tableView row i+1）。
    private(set) var expandedRow: Int?

    /// 当前编辑/新建中的片段引用（save/edit 逻辑取值）。
    private var editingItem: SnippetItem?

    // 展开态控件引用（reload 时清空，viewFor 重建时填）
    private var activeKeywordField: NSTextField?
    private var activeContentEditor: NSTextView?
    private var activeSaveButton: NSButton?
    private var activeKeywordRow: SettingsFormRow?
    /// content 错误标签引用（content 行改为标签上 + editor 占满独立布局后，错误文案挂这里）。
    private var activeContentErrorLabel: NSTextField?
    /// 当前展开行 cell 的容器引用（计算 expandedRowHeight 用）
    private var activeExpandedCell: NSView?

    /// 空态占位（filteredItems 空且非新建态时显示）
    private let emptyPlaceholder = NSTextField(labelWithString: "暂无片段，点「新增片段」添加")

    // MARK: - Init

    init(service: SnippetsService? = nil) {
        // 默认参数表达式在非隔离上下文求值，不能直接写 .shared（@MainActor 隔离 static，
        // Swift 6 下为 error）。改 nil 默认，body 内（@MainActor 上下文）取 .shared。
        self.service = service ?? .shared
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - PluginSettingsPanelProvider（C-PANEL-NEW-INSTANCE：每次返回新实例）

    func makePanelVC() -> NSViewController { SnipPanelVC() }

    // MARK: - Lifecycle

    override func loadView() {
        // 固定初始 frame + autoresizing（防 fittingSize 缩 0，patterns/2026-06-16）
        // autoresizingMask=[.width,.height]：SnipPanelVC.view 铺满 pluginPanelContainer，
        // 防混合布局时序首帧塌缩（BLOCKER B 预备缓解，state.md 步骤 1.10）。
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 540))
        container.autoresizingMask = [.width, .height]
        setupLayout(in: container)
        self.view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        bindService()
        reloadAndRefresh()
    }

    // MARK: - Layout（单列：header + NSScrollView 包 tableView，C-SNIP-SINGLE-COLUMN）

    private func setupLayout(in container: NSView) {
        // header：searchField + addButton 水平排列
        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.distribution = .fill
        header.spacing = SettingsTheme.spacingSm
        header.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(header)

        searchField.placeholderString = "搜索 keyword..."
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.translatesAutoresizingMaskIntoConstraints = false
        // autopilot 2026-07-13：低 hugging 让 searchField 拉伸填满 header（原默认高 hugging 致
        // 宽度塌到 intrinsic ~100pt，窄到点不到；spacer 反而吃掉多余空间）。删 spacer，addButton 靠右。
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        header.addArrangedSubview(searchField)

        addButton.title = "新增片段"
        addButton.bezelStyle = .recessed
        addButton.controlSize = .regular
        addButton.image = NSImage(systemSymbolName: "plus.circle.fill", accessibilityDescription: "新增")
        addButton.imagePosition = .imageLeading
        addButton.target = self
        addButton.action = #selector(startCreate)
        addButton.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        header.addArrangedSubview(addButton)

        // 列表 scrollView（内层 NSScrollView，gallery ContentColumnView 是外层；嵌套深度 = 2）
        tableView.dataSource = self
        tableView.delegate = self
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("snip"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 64
        tableView.selectionHighlightStyle = .none  // accordion 自管选中态（展开），不用系统高亮
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.intercellSpacing = NSSize(width: 0, height: SettingsTheme.spacingXs)
        listScrollView.documentView = tableView
        listScrollView.hasVerticalScroller = true
        listScrollView.autohidesScrollers = true
        listScrollView.drawsBackground = false
        listScrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(listScrollView)

        // 空态占位（默认隐藏，reloadAndRefresh 按数据态切换）
        emptyPlaceholder.font = SettingsTheme.rowSubtitleFont()
        emptyPlaceholder.textColor = .secondaryLabelColor
        emptyPlaceholder.alignment = .center
        emptyPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        emptyPlaceholder.isHidden = true
        container.addSubview(emptyPlaceholder)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.topAnchor, constant: SettingsTheme.spacingMd),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: SettingsTheme.spacingMd),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -SettingsTheme.spacingMd),

            listScrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: SettingsTheme.spacingSm),
            listScrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: SettingsTheme.spacingMd),
            listScrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -SettingsTheme.spacingMd),
            listScrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -SettingsTheme.spacingMd),

            emptyPlaceholder.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyPlaceholder.topAnchor.constraint(equalTo: header.bottomAnchor, constant: SettingsTheme.spacingXl),
        ])
    }

    // MARK: - viewDidLayout（BLOCKER B 预备缓解：强制内层 scrollView frame）

    override func viewDidLayout() {
        super.viewDidLayout()
        // 预备缓解（state.md 步骤 1.10）：混合布局时序下若 SnipPanelVC.view 首帧塌缩，
        // 强制内层 listScrollView 撑满 view（autoresizingMask=[.width,.height] 已在 view 设，
        // 这里二次保险）。patterns/2026-07-12 同构盲区防回归。
        guard view.bounds.height > 0 else { return }
        if listScrollView.bounds.height < 1 {
            listScrollView.frame = view.bounds
            listScrollView.needsLayout = true
        }
    }

    // MARK: - Service 绑定（objectWillChange → reload）

    private func bindService() {
        objectWillChangeCancellable = service.objectWillChange.sink { [weak self] in
            Task { @MainActor in self?.reloadAndRefresh() }
        }
    }

    private func reloadAndRefresh() {
        filteredItems = service.search(searchField.stringValue)
        // 若当前展开的已有行超出新范围（如删除后），收回
        if let r = expandedRow, r >= 0, r >= filteredItems.count {
            expandedRow = nil
            editingItem = nil
            clearActiveControlRefs()
        }
        tableView.reloadData()
        updateEmptyPlaceholder()
    }

    private func updateEmptyPlaceholder() {
        // 空态：无数据 + 非新建展开
        let isEmpty = filteredItems.isEmpty && expandedRow != Self.createRowIndex
        emptyPlaceholder.isHidden = !isEmpty
    }

    // MARK: - accordion 状态机（C-SNIP-ACCORDION-ONE）

    /// 展开/折叠行。同一时刻最多 1 项展开（展开 A 自动折叠其他）。
    private func toggleExpanded(row: Int) {
        if expandedRow == row {
            // 点已展开行 → 折叠
            collapseAll()
        } else {
            // 展开新行 → 旧的自动折叠（C-SNIP-ACCORDION-ONE 单值语义）
            expandedRow = row
            if row >= 0, row < filteredItems.count {
                editingItem = filteredItems[row]
            } else {
                editingItem = nil
            }
            clearActiveControlRefs()
            tableView.reloadData()
            updateEmptyPlaceholder()
            // 滚动到展开行可见区
            let tableRow = dataRowToTableRow(row)
            if tableRow >= 0 {
                tableView.scrollRowToVisible(tableRow)
            }
        }
    }

    private func collapseAll() {
        expandedRow = nil
        editingItem = nil
        clearActiveControlRefs()
        tableView.reloadData()
        updateEmptyPlaceholder()
    }

    /// 行索引映射：数据行（filteredItems 索引 / createRowIndex 哨兵）→ tableView row。
    /// createRowIndex(-1) → tableView row 0；filteredItems[i] → tableView row i+1。
    private func dataRowToTableRow(_ dataRow: Int) -> Int {
        dataRow == Self.createRowIndex ? 0 : dataRow + 1
    }

    /// tableView row → 数据行。tableView row 0 = 新建（仅展开时存在）/ 0..N-1 = filteredItems。
    private func tableRowToDataRow(_ tableRow: Int) -> Int {
        if expandedRow == Self.createRowIndex {
            return tableRow == 0 ? Self.createRowIndex : tableRow - 1
        }
        return tableRow
    }

    private func clearActiveControlRefs() {
        activeKeywordField = nil
        activeContentEditor = nil
        activeSaveButton = nil
        activeKeywordRow = nil
        activeContentErrorLabel = nil
        activeExpandedCell = nil
    }

    // MARK: - 只读访问器（debug + 测试用，state.md 步骤 1.9）

    /// 当前展开模式（testHook 暴露，验收断言用）。
    var testHook_currentDetailMode: SnipAccordionMode {
        guard let r = expandedRow else { return .empty }
        return r == Self.createRowIndex ? .create : .edit
    }

    /// 当前展开的数据行索引（debug `snip_expanded_visible` 用）。nil=未展开。
    var expandedRowIndex: Int? { expandedRow }

    /// 当前展开行高度（debug `snip_expanded_height` 用）。0=未展开或未布局。
    var expandedRowHeight: CGFloat {
        activeExpandedCell?.bounds.height ?? 0
    }

    // MARK: - debug 宽度诊断（autopilot 2026-07-14：定位 snip 面板内容未占满 view 宽度）
    var debug_widths: [String: CGFloat] {
        [
            "view": view.bounds.width,
            "searchField": searchField.bounds.width,
            "listScrollView": listScrollView.bounds.width,
            "tableView": tableView.bounds.width,
            "tableView_col0": tableView.tableColumns.first?.width ?? -1,
        ]
    }

    // MARK: - Actions

    @objc private func searchChanged() {
        // 搜索时折叠展开行（避免索引错位）
        collapseAll()
        reloadAndRefresh()
    }

    @objc private func startCreate() {
        // 顶部新建行展开（accordion 哨兵），其他自动折叠
        expandedRow = Self.createRowIndex
        editingItem = SnippetItem(keyword: "", content: "")
        clearActiveControlRefs()
        tableView.reloadData()
        updateEmptyPlaceholder()
        tableView.scrollRowToVisible(0)
    }

    // MARK: - create/edit save 逻辑

    @objc private func cancelEdit() {
        collapseAll()
    }

    @objc private func saveCreate() {
        let keyword = activeKeywordField?.stringValue ?? ""
        let content = activeContentEditor?.string ?? ""
        clearCreateFieldErrors()
        do {
            try service.add(keyword: keyword, content: content)
            BuddyLogger.shared.info("snippet added via GUI", subsystem: "snippets",
                                    meta: ["keyword": keyword])
            collapseAll()
            reloadAndRefresh()
        } catch let err as SnippetsError {
            showCreateFieldError(err)
        } catch {
            activeKeywordRow?.setError("保存失败：\(error.localizedDescription)")
        }
    }

    @objc private func saveEdit() {
        guard let item = editingItem else { return }
        let content = activeContentEditor?.string ?? ""
        clearContentError()
        do {
            try service.edit(keyword: item.keyword, content: content)
            BuddyLogger.shared.info("snippet edited via GUI", subsystem: "snippets",
                                    meta: ["keyword": item.keyword])
            collapseAll()
            reloadAndRefresh()
        } catch let err as SnippetsError {
            showEditFieldError(err)
        } catch {
            showContentError("保存失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 行内编辑/删除（折叠态卡片按钮）

    @objc private func editRow(_ sender: NSButton) {
        // sender.tag 存数据行索引（filteredItems 索引）
        let dataRow = sender.tag
        guard dataRow >= 0, dataRow < filteredItems.count else { return }
        toggleExpanded(row: dataRow)
    }

    @objc private func deleteRow(_ sender: NSButton) {
        let dataRow = sender.tag
        guard dataRow >= 0, dataRow < filteredItems.count else { return }
        let item = filteredItems[dataRow]
        requestDelete(item)
    }

    // MARK: - 字段级错误（AC-SNIPGUI-17/18）

    private func clearCreateFieldErrors() {
        activeKeywordRow?.clearValidation()
        clearContentError()
    }

    private func showCreateFieldError(_ err: SnippetsError) {
        switch err {
        case .invalidKeyword, .keywordAlreadyExists, .keywordNotFound:
            activeKeywordRow?.setError(err.errorDescription ?? "")
        case .contentTooLong:
            showContentError(err.errorDescription ?? "")
        }
    }

    private func showEditFieldError(_ err: SnippetsError) {
        // edit 态 keyword 只读，错误兜底显示在 content 卡
        showContentError(err.errorDescription ?? "")
    }

    // MARK: - content 错误（content 行独立布局后，文案挂 activeContentErrorLabel）

    private func clearContentError() {
        activeContentErrorLabel?.stringValue = ""
        activeContentErrorLabel?.isHidden = true
    }

    private func showContentError(_ message: String) {
        activeContentErrorLabel?.stringValue = message
        activeContentErrorLabel?.isHidden = false
    }

    private func requestDelete(_ item: SnippetItem) {
        let alert = SnipPanelVC.presentDeleteAlert(for: item)
        let response = alert.runModal()
        SnipPanelVC.handleDeleteResponse(response, for: item)
        reloadAndRefresh()
    }

    // MARK: - 删除二次确认（AC-SNIPGUI-10，test seam 原样保留）

    static func presentDeleteAlert(for item: SnippetItem) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "删除片段「\(item.keyword)」？"
        alert.informativeText = "此操作不可恢复，删除后该片段将不再可用。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "确认删除")
        alert.addButton(withTitle: "取消")
        return alert
    }

    static func handleDeleteResponse(_ response: NSApplication.ModalResponse, for item: SnippetItem) {
        guard response == .alertFirstButtonReturn else { return }
        SnippetsService.shared.delete(keyword: item.keyword)
        BuddyLogger.shared.info("snippet deleted via GUI", subsystem: "snippets",
                                meta: ["keyword": item.keyword])
    }

    // MARK: - 编辑表单构建（accordion 展开行内嵌，复用 makeEditorContainer）

    /// 构建编辑/新建表单容器（tableView 展开行内嵌 NSView）。
    /// mode=.create keyword 可填；mode=.edit keyword 只读显示。
    func makeEditorContainer(mode: SnipAccordionMode, item: SnippetItem?) -> NSView {
        clearActiveControlRefs()

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.cornerRadius = SettingsTheme.cardCornerRadius
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        activeExpandedCell = container

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = SettingsTheme.spacingSm
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        // 标题
        let titleLabel = NSTextField(labelWithString: mode == .create ? "新增片段" : "编辑片段")
        titleLabel.font = SettingsTheme.groupLabelFont()
        titleLabel.textColor = .tertiaryLabelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(titleLabel)

        // keyword + content 分组卡片
        let group = SettingsGroupView()
        group.translatesAutoresizingMaskIntoConstraints = false

        // keyword 行
        let keywordControl: NSView
        if mode == .create {
            let field = NSTextField()
            field.placeholderString = "输入 keyword"
            activeKeywordField = field
            keywordControl = field
        } else {
            // edit 态 keyword 只读
            let label = NSTextField(labelWithString: item?.keyword ?? "")
            label.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            keywordControl = label
        }
        let kwRow = SettingsFormRow(
            title: mode == .create ? "keyword（字母数字_-，1-64）" : "keyword",
            subtitle: nil,
            control: keywordControl
        )
        activeKeywordRow = kwRow
        group.addRow(kwRow)

        // content 行：标签在上 + 多行 editor 占满下方宽度（autopilot 2026-07-13：原用 SettingsFormRow
        // 左/右双栏，160 高 editor 被挤到右侧 control 区与 keyword 输入框同列错位"跑到 keyword 那边"。
        // 大文本应标签上 + editor 占满宽度。patterns/2026-07-02 width=0 三件套保留在 makeContentEditor）。
        let editor = makeContentEditor()
        if mode == .edit, let item {
            editor.string = item.content
        }
        activeContentEditor = editor
        let editorScrollView = NSScrollView()
        editorScrollView.documentView = editor
        editorScrollView.hasVerticalScroller = true
        editorScrollView.drawsBackground = false
        editorScrollView.translatesAutoresizingMaskIntoConstraints = false

        let contentLabel = NSTextField(labelWithString: "content")
        contentLabel.font = SettingsTheme.rowTitleFont()
        contentLabel.textColor = SettingsTheme.rowTitleColor()
        contentLabel.translatesAutoresizingMaskIntoConstraints = false

        let contentErrorLabel = NSTextField(labelWithString: "")
        contentErrorLabel.font = .systemFont(ofSize: 11)
        contentErrorLabel.textColor = .systemRed
        contentErrorLabel.lineBreakMode = .byWordWrapping
        contentErrorLabel.maximumNumberOfLines = 0
        contentErrorLabel.isHidden = true
        contentErrorLabel.translatesAutoresizingMaskIntoConstraints = false
        activeContentErrorLabel = contentErrorLabel

        let contentRowBox = NSView()
        contentRowBox.translatesAutoresizingMaskIntoConstraints = false
        contentRowBox.addSubview(contentLabel)
        contentRowBox.addSubview(editorScrollView)
        contentRowBox.addSubview(contentErrorLabel)

        NSLayoutConstraint.activate([
            contentLabel.topAnchor.constraint(equalTo: contentRowBox.topAnchor, constant: SettingsTheme.spacingMd),
            contentLabel.leadingAnchor.constraint(equalTo: contentRowBox.leadingAnchor, constant: SettingsTheme.cardContentPadding),
            contentLabel.trailingAnchor.constraint(equalTo: contentRowBox.trailingAnchor, constant: -SettingsTheme.cardContentPadding),

            editorScrollView.topAnchor.constraint(equalTo: contentLabel.bottomAnchor, constant: SettingsTheme.spacingXs),
            editorScrollView.leadingAnchor.constraint(equalTo: contentRowBox.leadingAnchor, constant: SettingsTheme.cardContentPadding),
            editorScrollView.trailingAnchor.constraint(equalTo: contentRowBox.trailingAnchor, constant: -SettingsTheme.cardContentPadding),
            editorScrollView.heightAnchor.constraint(equalToConstant: 160),

            contentErrorLabel.topAnchor.constraint(equalTo: editorScrollView.bottomAnchor, constant: SettingsTheme.spacingXs),
            contentErrorLabel.leadingAnchor.constraint(equalTo: contentRowBox.leadingAnchor, constant: SettingsTheme.cardContentPadding),
            contentErrorLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentRowBox.trailingAnchor, constant: -SettingsTheme.cardContentPadding),
            contentErrorLabel.bottomAnchor.constraint(equalTo: contentRowBox.bottomAnchor, constant: -SettingsTheme.spacingMd),
        ])

        group.addRow(contentRowBox)

        stack.addArrangedSubview(group)
        // group 撑满 stack 宽度（autopilot 2026-07-13 det-machine 实测：editorContainer.stack
        // alignment=.leading 下 arrangedSubview 默认不撑满 cross-axis，group 宽=fitting → contentRowBox
        // 不撑满 → content editor 宽由 NSTextView containerSize 决定，实测 184pt vs cell 724pt 仅占 25%）。
        // 钉 leading+trailing 让 group 撑满，下行 contentRowBox（addRow 已钉 group stackView leading/trailing）
        // 与 editorScrollView（钉 contentRowBox ± cardContentPadding）随之占满 cell 宽度。
        group.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
        group.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true

        // 占位符提示卡（AC-SNIPGUI-13）
        let hint = makePlaceholderHintView()
        stack.addArrangedSubview(hint)

        // 操作栏
        let actionBar = makeActionBar(mode: mode)
        stack.addArrangedSubview(actionBar)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: SettingsTheme.spacingSm),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: SettingsTheme.spacingSm),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -SettingsTheme.spacingSm),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -SettingsTheme.spacingSm),
        ])
        return container
    }

    /// 操作栏（cancel + save 或 cancel + delete + save）。
    private func makeActionBar(mode: SnipAccordionMode) -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.distribution = .fill
        stack.spacing = SettingsTheme.spacingSm
        stack.translatesAutoresizingMaskIntoConstraints = false

        // edit 态左侧加删除按钮
        if mode == .edit {
            let deleteBtn = NSButton(title: "删除", target: self, action: #selector(deleteCurrentEdit))
            deleteBtn.bezelColor = NSColor.systemRed.withAlphaComponent(0.2)
            stack.addArrangedSubview(deleteBtn)
        }

        let cancelBtn = NSButton(title: "取消", target: self, action: #selector(cancelEdit))
        stack.addArrangedSubview(cancelBtn)

        // spacer 推 save 到右
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(spacer)

        let saveTitle = mode == .create ? "保存" : "保存"
        let saveBtn = NSButton(title: saveTitle, target: self,
                               action: mode == .create ? #selector(saveCreate) : #selector(saveEdit))
        saveBtn.keyEquivalent = "\r"
        saveBtn.bezelStyle = .rounded
        saveBtn.controlSize = .regular
        stack.addArrangedSubview(saveBtn)
        activeSaveButton = saveBtn

        return stack
    }

    @objc private func deleteCurrentEdit() {
        guard let item = editingItem else { return }
        requestDelete(item)
    }

    // MARK: - 控件工厂

    /// content editor NSTextView（patterns/2026-07-02 width=0 三件套）。
    private func makeContentEditor() -> NSTextView {
        let editor = NSTextView()
        editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        editor.isEditable = true
        editor.isSelectable = true
        editor.drawsBackground = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 360, height: 0)
        editor.minSize = NSSize(width: 0, height: 120)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.textContainerInset = NSSize(width: 0, height: 0)
        return editor
    }

    /// 占位符语法提示卡（AC-SNIPGUI-13，AppKit NSTextField 可遍历）。
    private func makePlaceholderHintView() -> NSView {
        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.wantsLayer = true
        box.layer?.cornerRadius = SettingsTheme.cardCornerRadius
        box.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        // swiftlint:disable:next force_unwrapping
        let iconImage = NSImage(systemSymbolName: "lightbulb", accessibilityDescription: "提示")!
        let icon = NSImageView(image: iconImage)
        icon.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: "占位符语法")
        title.font = .systemFont(ofSize: 11, weight: .medium)
        title.textColor = .secondaryLabelColor
        title.translatesAutoresizingMaskIntoConstraints = false
        let body = NSTextField(labelWithString: "{date} → 当前日期  {time} → 当前时间  {clipboard} → 剪贴板")
        body.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        body.textColor = .tertiaryLabelColor
        body.lineBreakMode = .byWordWrapping
        body.maximumNumberOfLines = 0
        body.cell?.truncatesLastVisibleLine = false
        body.cell?.wraps = true
        body.translatesAutoresizingMaskIntoConstraints = false

        box.addSubview(icon)
        box.addSubview(title)
        box.addSubview(body)
        NSLayoutConstraint.activate([
            icon.topAnchor.constraint(equalTo: box.topAnchor, constant: SettingsTheme.spacingSm),
            icon.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: SettingsTheme.spacingSm),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),

            title.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: SettingsTheme.spacingXs),
            title.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -SettingsTheme.spacingSm),

            body.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: SettingsTheme.spacingXs),
            body.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: SettingsTheme.spacingSm),
            body.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -SettingsTheme.spacingSm),
            body.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -SettingsTheme.spacingSm),
        ])
        return box
    }

    // MARK: - Test hooks（patterns/2026-07-09：经真实 action 链路，禁直接调私有方法）

    func testHook_startCreate() { startCreate() }
    func testHook_reload() { reloadAndRefresh() }

    /// 经真实 tableView selectionDidChange → expandedRow 变更路径（patterns/2026-07-09 禁直接赋值 expandedRow）。
    /// 数据行索引（filteredItems 索引），展开该行 edit 态。
    func testHook_selectRow(_ row: Int) {
        guard row >= 0, row < filteredItems.count else { return }
        toggleExpanded(row: row)
    }

    /// 折叠所有行（测试 reset 用）。
    func testHook_collapseAll() { collapseAll() }

    /// 经真实 action 链路填表 + 点保存按钮（patterns/2026-07-09 testHook 原则：
    /// performClick saveButton 触发 @objc saveCreate，禁直接调私有方法）。
    func testHook_fillAndSaveCreate(keyword: String, content: String) throws {
        testHook_startCreate()
        // 触发布局让 tableView(_:viewFor:) 跑完，填充 activeSaveButton 等控件引用。
        view.layoutSubtreeIfNeeded()
        activeKeywordField?.stringValue = keyword
        activeContentEditor?.string = content
        guard let button = activeSaveButton, let action = button.action else {
            throw NSError(domain: "SnipPanelVC.testHook", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "activeSaveButton 或 action 为 nil"])
        }
        let target = button.target as? AnyObject
        _ = target?.perform(action)
    }

    /// 取 create 态 keyword 字段当前值（测试断言用）。
    var testHook_createKeyword: String? { activeKeywordField?.stringValue }

    /// 取当前展开编辑表单 content（测试断言用）。
    var testHook_activeContent: String? { activeContentEditor?.string }

    // MARK: - debug 诊断（det-machine 验证 content 布局，autopilot 2026-07-13）

    /// content editor 包裹的 NSScrollView frame（验证 content 占满宽度，非窄 control 区）。
    var debug_contentScrollViewFrame: NSRect? {
        activeContentEditor?.enclosingScrollView?.frame
    }

    /// 当前展开 cell bounds（content editor 应占 cell 大部分宽度）。
    var debug_expandedCellBounds: NSRect? {
        activeExpandedCell?.bounds
    }
}

// MARK: - NSTableViewDataSource / Delegate

extension SnipPanelVC: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        // 新建展开时 +1（顶部新建行）；否则 = filteredItems.count
        let createBias = (expandedRow == Self.createRowIndex) ? 1 : 0
        return filteredItems.count + createBias
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let dataRow = tableRowToDataRow(row)

        // 新建行展开
        if dataRow == Self.createRowIndex {
            let cellId = NSUserInterfaceItemIdentifier("SnipExpandedCreate")
            let cell = (tableView.makeView(withIdentifier: cellId, owner: self) as? NSTableCellView)
                ?? makeExpandedCell(identifier: cellId)
            // 重建编辑表单（清旧控件引用 + 填新）
            let editor = makeEditorContainer(mode: .create, item: nil)
            replaceCellContent(cell, with: editor)
            cell.setAccessibilityIdentifier("settings.plugins.snip.expanded.\(Self.createRowIndex)")
            return cell
        }

        // 已有行：展开 or 折叠
        guard dataRow >= 0, dataRow < filteredItems.count else { return nil }
        let item = filteredItems[dataRow]

        if expandedRow == dataRow {
            // 展开态编辑表单
            let cellId = NSUserInterfaceItemIdentifier("SnipExpandedEdit")
            let cell = (tableView.makeView(withIdentifier: cellId, owner: self) as? NSTableCellView)
                ?? makeExpandedCell(identifier: cellId)
            let editor = makeEditorContainer(mode: .edit, item: item)
            replaceCellContent(cell, with: editor)
            cell.setAccessibilityIdentifier("settings.plugins.snip.expanded.\(dataRow)")
            return cell
        } else {
            // 折叠态卡片
            let cellId = NSUserInterfaceItemIdentifier("SnipCollapsed")
            let cell = (tableView.makeView(withIdentifier: cellId, owner: self) as? SnipCollapsedCellView)
                ?? SnipCollapsedCellView()
            cell.identifier = cellId
            cell.configure(keyword: item.keyword, content: item.content, dataRow: dataRow)
            cell.onEdit = { [weak self] r in self?.editRowTriggered(r) }
            cell.onDelete = { [weak self] r in self?.deleteRowTriggered(r) }
            cell.setAccessibilityIdentifier("settings.plugins.snip.row.\(dataRow)")
            return cell
        }
    }

    /// 行高：展开行自适应（用估计高度），折叠行固定。
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        let dataRow = tableRowToDataRow(row)
        if dataRow == Self.createRowIndex || expandedRow == dataRow {
            // 展开行：编辑表单高度（标题 + keyword 行 44 + content 行 ~200 + hint ~60 + actionbar ~40 + padding）
            return 420
        }
        return 64
    }

    /// 点折叠行空白区展开（accordion）。点按钮区由按钮自身处理（不触发）。
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        let dataRow = tableRowToDataRow(row)
        guard dataRow != Self.createRowIndex else { return false }  // 新建行不可选（已在编辑态）
        guard dataRow >= 0, dataRow < filteredItems.count else { return false }
        toggleExpanded(row: dataRow)
        return false  // 不进系统选中态（accordion 自管）
    }

    // MARK: - cell 构建 helpers

    private func makeExpandedCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        return cell
    }

    /// 替换展开 cell 内容（remove 旧 editor subviews，加新 editor）。
    private func replaceCellContent(_ cell: NSTableCellView, with editor: NSView) {
        cell.subviews.forEach { $0.removeFromSuperview() }
        cell.addSubview(editor)
        NSLayoutConstraint.activate([
            editor.topAnchor.constraint(equalTo: cell.topAnchor),
            editor.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            editor.bottomAnchor.constraint(equalTo: cell.bottomAnchor),
        ])
    }

    // 行内按钮回调桥（SnipCollapsedCellView.onEdit/onDelete 触发，sender.tag = dataRow）
    private func editRowTriggered(_ dataRow: Int) {
        toggleExpanded(row: dataRow)
    }

    private func deleteRowTriggered(_ dataRow: Int) {
        guard dataRow >= 0, dataRow < filteredItems.count else { return }
        requestDelete(filteredItems[dataRow])
    }
}

// MARK: - SnipCollapsedCellView（折叠态卡片：keyword + content 预览 + 行内 ✎/🗑 按钮）

final class SnipCollapsedCellView: NSTableCellView {
    private let keywordLabel = NSTextField(labelWithString: "")
    private let contentLabel = NSTextField(labelWithString: "")
    private let editButton = NSButton()
    private let deleteButton = NSButton()
    private var dataRow: Int = 0

    /// 行内编辑回调（参数 = dataRow）。
    var onEdit: ((Int) -> Void)?
    /// 行内删除回调（参数 = dataRow）。
    var onDelete: ((Int) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupView() {
        wantsLayer = true
        layer?.cornerRadius = SettingsTheme.cardCornerRadius
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        keywordLabel.font = SettingsTheme.rowTitleFont()
        keywordLabel.textColor = .labelColor
        keywordLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(keywordLabel)

        contentLabel.font = SettingsTheme.rowSubtitleFont()
        contentLabel.textColor = .secondaryLabelColor
        contentLabel.maximumNumberOfLines = 2
        contentLabel.lineBreakMode = .byTruncatingTail
        contentLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentLabel)

        // 编辑按钮（✎）
        editButton.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: "编辑")
        editButton.bezelStyle = .inline
        editButton.controlSize = .small
        editButton.imagePosition = .imageOnly
        editButton.translatesAutoresizingMaskIntoConstraints = false
        editButton.target = self
        editButton.action = #selector(handleEdit)
        addSubview(editButton)

        // 删除按钮（🗑）
        deleteButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "删除")
        deleteButton.bezelStyle = .inline
        deleteButton.controlSize = .small
        deleteButton.imagePosition = .imageOnly
        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        deleteButton.target = self
        deleteButton.action = #selector(handleDelete)
        addSubview(deleteButton)

        NSLayoutConstraint.activate([
            keywordLabel.topAnchor.constraint(equalTo: topAnchor, constant: SettingsTheme.spacingSm),
            keywordLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SettingsTheme.spacingMd),
            keywordLabel.trailingAnchor.constraint(lessThanOrEqualTo: editButton.leadingAnchor, constant: -SettingsTheme.spacingSm),

            contentLabel.topAnchor.constraint(equalTo: keywordLabel.bottomAnchor, constant: SettingsTheme.spacingXs),
            contentLabel.leadingAnchor.constraint(equalTo: keywordLabel.leadingAnchor),
            contentLabel.trailingAnchor.constraint(equalTo: keywordLabel.trailingAnchor),
            contentLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -SettingsTheme.spacingSm),

            editButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            editButton.trailingAnchor.constraint(equalTo: deleteButton.leadingAnchor, constant: -SettingsTheme.spacingXs),
            editButton.widthAnchor.constraint(equalToConstant: 24),
            editButton.heightAnchor.constraint(equalToConstant: 24),

            deleteButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            deleteButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SettingsTheme.spacingMd),
            deleteButton.widthAnchor.constraint(equalToConstant: 24),
            deleteButton.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    func configure(keyword: String, content: String, dataRow: Int) {
        keywordLabel.stringValue = keyword
        contentLabel.stringValue = content
        self.dataRow = dataRow
    }

    @objc private func handleEdit() { onEdit?(dataRow) }
    @objc private func handleDelete() { onDelete?(dataRow) }
}
