import AppKit
import Combine

// MARK: - SnipPanelVC
//
// snip 专属设置面板（纯 AppKit，master-detail，stage-4）。
// 原 SwiftUI（SnipPanelView）与 NSHostingController 包装层已消除（迁纯 AppKit NSViewController）。
//
// 左栏：搜索 + 新增 + NSTableView（keyword + content 预览双行 cell）
// 右栏：ContentColumnView 包裹，containment 切 空/create/edit/preview 四态
//
// 数据源：SnippetsService.shared（@MainActor 直驱），objectWillChange sink 刷新列表。
// 删除二次确认：NSAlert（presentDeleteAlert/handleDeleteResponse test seam）。
//
// 契约引用：C1 / AC-SNIPGUI-01/10/13/23

/// 右栏 detail 四态（testHook 暴露给测试断言）。
enum SnipDetailMode {
    case empty, create, edit, preview
}

@MainActor
final class SnipPanelVC: NSViewController, PluginSettingsPanelProvider {

    private let service: SnippetsService = .shared
    private var objectWillChangeCancellable: AnyCancellable?

    // 左栏
    private let leftPane = NSView()
    private let searchField = NSSearchField()
    private let addButton = NSButton()
    private let tableView = NSTableView()
    private let tableScrollView = NSScrollView()
    private var filteredItems: [SnippetItem] = []

    // 右栏
    private(set) var detailContainer: NSView!
    private var currentDetailChild: NSViewController?

    // 编辑/选中状态
    private var editingItem: SnippetItem?
    private var isCreating = false
    private var previewItem: SnippetItem?

    /// 当前 detail 模式（testHook 暴露，验收断言用）。
    private(set) var testHook_currentDetailMode: SnipDetailMode = .empty

    // create 态控件引用（Task 12 save 逻辑取值 + testHook performClick）
    private var createKeywordField: NSTextField?
    private var createContentEditor: NSTextView?
    private var createSaveButton: NSButton?
    private var createKeywordRow: SettingsFormRow?
    private var createContentRow: SettingsFormRow?

    // edit 态控件引用
    private var editContentEditor: NSTextView?
    private var editSaveButton: NSButton?
    private var editContentRow: SettingsFormRow?

    override func loadView() {
        // 固定初始 frame + autoresize（防 fittingSize 缩 0，patterns/2026-06-16）
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 540))
        container.autoresizingMask = [.width, .height]
        setupLayout(in: container)
        self.view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        bindService()
        reloadAndRefresh()
        showEmptyState()
    }

    // MARK: - Layout（master-detail：左固定 240 + 右 ContentColumnView）

    private func setupLayout(in container: NSView) {
        leftPane.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(leftPane)

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "搜索 keyword..."
        searchField.target = self
        searchField.action = #selector(searchChanged)
        leftPane.addSubview(searchField)

        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.title = "新增片段"
        addButton.bezelStyle = .recessed
        addButton.controlSize = .regular
        addButton.image = NSImage(systemSymbolName: "plus.circle.fill", accessibilityDescription: "新增")
        addButton.imagePosition = .imageLeading
        addButton.target = self
        addButton.action = #selector(startCreate)
        leftPane.addSubview(addButton)

        tableView.dataSource = self
        tableView.delegate = self
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("snip"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 56
        tableView.selectionHighlightStyle = .regular
        tableScrollView.documentView = tableView
        tableScrollView.hasVerticalScroller = true
        tableScrollView.autohidesScrollers = true
        tableScrollView.drawsBackground = false
        tableScrollView.translatesAutoresizingMaskIntoConstraints = false
        leftPane.addSubview(tableScrollView)

        // 右栏 ContentColumnView（限宽居中 + 滚动，stage-1 内置组件）
        let rightColumn = ContentColumnView()
        rightColumn.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(rightColumn)
        detailContainer = rightColumn.contentColumn

        NSLayoutConstraint.activate([
            leftPane.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            leftPane.topAnchor.constraint(equalTo: container.topAnchor),
            leftPane.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            leftPane.widthAnchor.constraint(equalToConstant: SettingsTheme.pluginListWidth),

            searchField.topAnchor.constraint(equalTo: leftPane.topAnchor, constant: SettingsTheme.spacingMd),
            searchField.leadingAnchor.constraint(equalTo: leftPane.leadingAnchor, constant: SettingsTheme.spacingMd),
            searchField.trailingAnchor.constraint(equalTo: leftPane.trailingAnchor, constant: -SettingsTheme.spacingMd),

            addButton.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: SettingsTheme.spacingSm),
            addButton.leadingAnchor.constraint(equalTo: leftPane.leadingAnchor, constant: SettingsTheme.spacingMd),
            addButton.trailingAnchor.constraint(equalTo: leftPane.trailingAnchor, constant: -SettingsTheme.spacingMd),

            tableScrollView.topAnchor.constraint(equalTo: addButton.bottomAnchor, constant: SettingsTheme.spacingSm),
            tableScrollView.leadingAnchor.constraint(equalTo: leftPane.leadingAnchor),
            tableScrollView.trailingAnchor.constraint(equalTo: leftPane.trailingAnchor),
            tableScrollView.bottomAnchor.constraint(equalTo: leftPane.bottomAnchor),

            rightColumn.leadingAnchor.constraint(equalTo: leftPane.trailingAnchor),
            rightColumn.topAnchor.constraint(equalTo: container.topAnchor),
            rightColumn.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            rightColumn.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    // MARK: - Service 绑定（objectWillChange → reload）

    private func bindService() {
        objectWillChangeCancellable = service.objectWillChange.sink { [weak self] in
            Task { @MainActor in self?.reloadAndRefresh() }
        }
    }

    private func reloadAndRefresh() {
        filteredItems = service.search(searchField.stringValue)
        tableView.reloadData()
    }

    // MARK: - PluginSettingsPanelProvider

    func makePanelVC() -> NSViewController { self }

    // MARK: - Test hooks（patterns/2026-07-09：经真实 action 链路，禁直接调私有方法）

    func testHook_startCreate() { startCreate() }
    func testHook_reload() { reloadAndRefresh() }
    func testHook_selectRow(_ row: Int) {
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }
    var testHook_previewItem: SnippetItem? { previewItem }

    // MARK: - Actions

    @objc private func searchChanged() {
        reloadAndRefresh()
    }

    @objc private func startCreate() {
        editingItem = SnippetItem(keyword: "", content: "")
        isCreating = true
        transitionDetail(to: makeCreateFormChild())
        testHook_currentDetailMode = .create
    }

    private func startEdit(_ item: SnippetItem) {
        editingItem = item
        isCreating = false
        transitionDetail(to: makeEditFormChild(item: item))
        testHook_currentDetailMode = .edit
    }

    // MARK: - Detail 切换

    private func showEmptyState() {
        transitionDetail(to: makeEmptyStateChild())
        testHook_currentDetailMode = .empty
    }

    private func makeEmptyStateChild() -> NSViewController {
        let vc = NSViewController()
        let label = NSTextField(labelWithString: "选择片段查看或预览，或点新增")
        label.font = SettingsTheme.rowSubtitleFont()
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        vc.view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: vc.view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: vc.view.centerYAnchor),
        ])
        return vc
    }

    // MARK: - Create 态子 VC（keyword TextField + content TextEditor + 占位符提示 + 操作栏）

    private func makeCreateFormChild() -> NSViewController {
        // 清旧控件引用
        createKeywordField = nil
        createContentEditor = nil
        createSaveButton = nil
        createKeywordRow = nil
        createContentRow = nil

        let vc = NSViewController()
        let title = makeSectionTitle("新增片段")
        vc.view.addSubview(title)

        // keyword 卡
        let kwGroup = SettingsGroupView()
        let keywordField = NSTextField()
        keywordField.placeholderString = "输入 keyword"
        createKeywordField = keywordField
        let kwRow = SettingsFormRow(title: "keyword（字母数字_-，1-64）", subtitle: nil, control: keywordField)
        createKeywordRow = kwRow
        kwGroup.addRow(kwRow)
        vc.view.addSubview(kwGroup)

        // content 卡（NSTextView 包 NSScrollView + patterns/2026-07-02 width=0 三件套）
        let contentGroup = SettingsGroupView()
        let editor = makeContentEditor()
        createContentEditor = editor
        let editorScrollView = NSScrollView()
        editorScrollView.documentView = editor
        editorScrollView.hasVerticalScroller = true
        editorScrollView.drawsBackground = false
        editorScrollView.translatesAutoresizingMaskIntoConstraints = false
        // 显式高度（SettingsFormRow controlContainer 无 height 约束，须给 scrollView 钉高）
        editorScrollView.heightAnchor.constraint(equalToConstant: 160).isActive = true
        let contentRow = SettingsFormRow(title: "content", subtitle: nil, control: editorScrollView)
        createContentRow = contentRow
        contentGroup.addRow(contentRow)
        vc.view.addSubview(contentGroup)

        // 占位符提示卡（AC-SNIPGUI-13）
        let hint = makePlaceholderHintView()
        vc.view.addSubview(hint)

        // 操作栏
        let actionBar = makeActionBar(cancelTitle: "取消", cancelAction: #selector(cancelEdit),
                                      saveTitle: "保存", saveAction: #selector(saveCreate))
        if let save = actionBar.saveButton { createSaveButton = save }
        vc.view.addSubview(actionBar.view)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: vc.view.topAnchor),
            title.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor),
            title.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor),

            kwGroup.topAnchor.constraint(equalTo: title.bottomAnchor, constant: SettingsTheme.spacingSm),
            kwGroup.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor),
            kwGroup.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor),

            contentGroup.topAnchor.constraint(equalTo: kwGroup.bottomAnchor, constant: SettingsTheme.groupSpacing),
            contentGroup.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor),
            contentGroup.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor),

            hint.topAnchor.constraint(equalTo: contentGroup.bottomAnchor, constant: SettingsTheme.groupSpacing),
            hint.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor),
            hint.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor),

            actionBar.view.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: SettingsTheme.spacingSm),
            actionBar.view.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor),
            actionBar.view.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor),
            actionBar.view.bottomAnchor.constraint(lessThanOrEqualTo: vc.view.bottomAnchor),
        ])
        return vc
    }

    // MARK: - Preview 态子 VC（只读 + 占位符展开 + 编辑/删除）

    private func makePreviewChild(item: SnippetItem) -> NSViewController {
        let vc = NSViewController()
        let title = makeSectionTitle("预览")
        vc.view.addSubview(title)

        let group = SettingsGroupView()
        // keyword 只读行
        let kwLabel = NSTextField(labelWithString: item.keyword)
        kwLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        let kwRow = SettingsFormRow(title: "keyword", subtitle: nil, control: kwLabel)
        group.addRow(kwRow)

        // content 原文（只读 NSTextView）
        let rawEditor = makeContentEditor(editable: false)
        rawEditor.string = item.content
        let rawScroll = NSScrollView()
        rawScroll.documentView = rawEditor
        rawScroll.hasVerticalScroller = true
        rawScroll.drawsBackground = false
        rawScroll.translatesAutoresizingMaskIntoConstraints = false
        rawScroll.heightAnchor.constraint(equalToConstant: 120).isActive = true
        let rawRow = SettingsFormRow(title: "content（原文）", subtitle: nil, control: rawScroll)
        group.addRow(rawRow)

        // 展开后（占位符展开，AC-SNIPGUI-23）
        let expandedEditor = makeContentEditor(editable: false)
        expandedEditor.string = SnippetsService.expandPlaceholders(item.content)
        let expandedScroll = NSScrollView()
        expandedScroll.documentView = expandedEditor
        expandedScroll.hasVerticalScroller = true
        expandedScroll.drawsBackground = false
        expandedScroll.translatesAutoresizingMaskIntoConstraints = false
        expandedScroll.heightAnchor.constraint(equalToConstant: 120).isActive = true
        let expandedRow = SettingsFormRow(title: "展开后（占位符）", subtitle: nil, control: expandedScroll)
        group.addRow(expandedRow)
        vc.view.addSubview(group)

        let actionBar = makeActionBar(leadingTitle: "编辑", leadingAction: #selector(editCurrentPreview),
                                      trailingTitle: "删除", trailingAction: #selector(deleteCurrentPreview),
                                      trailingDestructive: true)
        vc.view.addSubview(actionBar.view)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: vc.view.topAnchor),
            title.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor),
            title.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor),

            group.topAnchor.constraint(equalTo: title.bottomAnchor, constant: SettingsTheme.spacingSm),
            group.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor),
            group.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor),

            actionBar.view.topAnchor.constraint(equalTo: group.bottomAnchor, constant: SettingsTheme.spacingSm),
            actionBar.view.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor),
            actionBar.view.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor),
            actionBar.view.bottomAnchor.constraint(lessThanOrEqualTo: vc.view.bottomAnchor),
        ])
        return vc
    }

    // MARK: - Edit 态子 VC（keyword 只读 + content 编辑 + 操作栏）

    private func makeEditFormChild(item: SnippetItem) -> NSViewController {
        editContentEditor = nil
        editSaveButton = nil
        editContentRow = nil

        let vc = NSViewController()
        let title = makeSectionTitle("编辑片段")
        vc.view.addSubview(title)

        let group = SettingsGroupView()
        // keyword 只读
        let kwLabel = NSTextField(labelWithString: item.keyword)
        kwLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        let kwRow = SettingsFormRow(title: "keyword", subtitle: nil, control: kwLabel)
        group.addRow(kwRow)

        // content 编辑
        let editor = makeContentEditor()
        editor.string = item.content
        editContentEditor = editor
        let editorScroll = NSScrollView()
        editorScroll.documentView = editor
        editorScroll.hasVerticalScroller = true
        editorScroll.drawsBackground = false
        editorScroll.translatesAutoresizingMaskIntoConstraints = false
        editorScroll.heightAnchor.constraint(equalToConstant: 160).isActive = true
        let contentRow = SettingsFormRow(title: "content", subtitle: nil, control: editorScroll)
        editContentRow = contentRow
        group.addRow(contentRow)
        vc.view.addSubview(group)

        let hint = makePlaceholderHintView()
        vc.view.addSubview(hint)

        let actionBar = makeActionBar(leadingTitle: "删除", leadingAction: #selector(deleteCurrentEdit),
                                      leadingDestructive: true,
                                      cancelTitle: "取消", cancelAction: #selector(cancelEdit),
                                      saveTitle: "保存", saveAction: #selector(saveEdit))
        if let save = actionBar.saveButton { editSaveButton = save }
        vc.view.addSubview(actionBar.view)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: vc.view.topAnchor),
            title.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor),
            title.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor),

            group.topAnchor.constraint(equalTo: title.bottomAnchor, constant: SettingsTheme.spacingSm),
            group.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor),
            group.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor),

            hint.topAnchor.constraint(equalTo: group.bottomAnchor, constant: SettingsTheme.groupSpacing),
            hint.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor),
            hint.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor),

            actionBar.view.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: SettingsTheme.spacingSm),
            actionBar.view.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor),
            actionBar.view.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor),
            actionBar.view.bottomAnchor.constraint(lessThanOrEqualTo: vc.view.bottomAnchor),
        ])
        return vc
    }

    // MARK: - 控件工厂

    /// content editor NSTextView（patterns/2026-07-02 width=0 三件套）。
    /// autoresizingMask=.width + widthTracksTextView=true + containerSize 显式 + minSize + 可竖不可横缩。
    private func makeContentEditor(editable: Bool = true) -> NSTextView {
        let editor = NSTextView()
        editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        editor.isEditable = editable
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

    private func makeSectionTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = SettingsTheme.groupLabelFont()
        label.textColor = .tertiaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
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

    /// 操作栏（action bar）。支持：cancel + save（create/edit）或 leading + trailing（preview）。
    private struct ActionBar {
        let view: NSView
        let saveButton: NSButton?
    }

    private func makeActionBar(leadingTitle: String? = nil, leadingAction: Selector? = nil,
                               leadingDestructive: Bool = false,
                               cancelTitle: String? = nil, cancelAction: Selector? = nil,
                               saveTitle: String? = nil, saveAction: Selector? = nil,
                               trailingTitle: String? = nil, trailingAction: Selector? = nil,
                               trailingDestructive: Bool = false) -> ActionBar {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.distribution = .fill
        stack.spacing = SettingsTheme.spacingSm

        var saveBtn: NSButton?

        if let leadingTitle, let leadingAction {
            let btn = NSButton(title: leadingTitle, target: self, action: leadingAction)
            if leadingDestructive { btn.bezelColor = NSColor.systemRed.withAlphaComponent(0.2) }
            stack.addArrangedSubview(btn)
        }
        if let cancelTitle, let cancelAction {
            stack.addArrangedSubview(NSButton(title: cancelTitle, target: self, action: cancelAction))
        }
        // spacer 推 save/trailing 到右侧
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(spacer)
        if let saveTitle, let saveAction {
            let save = NSButton(title: saveTitle, target: self, action: saveAction)
            save.keyEquivalent = "\r"
            save.bezelStyle = .rounded
            save.controlSize = .regular
            stack.addArrangedSubview(save)
            saveBtn = save
        }
        if let trailingTitle, let trailingAction {
            let btn = NSButton(title: trailingTitle, target: self, action: trailingAction)
            if trailingDestructive { btn.bezelColor = NSColor.systemRed.withAlphaComponent(0.2) }
            stack.addArrangedSubview(btn)
        }
        return ActionBar(view: stack, saveButton: saveBtn)
    }

    /// containment 切换右栏 child（对齐 PluginGalleryViewController pluginPanelContainer 机制）
    private func transitionDetail(to newChild: NSViewController) {
        if let old = currentDetailChild {
            old.view.removeFromSuperview()
            old.removeFromParent()
        }
        addChild(newChild)
        newChild.view.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.addSubview(newChild.view)
        NSLayoutConstraint.activate([
            newChild.view.topAnchor.constraint(equalTo: detailContainer.topAnchor),
            newChild.view.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),
            newChild.view.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor),
            newChild.view.bottomAnchor.constraint(equalTo: detailContainer.bottomAnchor),
        ])
        currentDetailChild = newChild
    }

    // MARK: - 操作（create/edit save 逻辑 Task 12 补全，本 task 占位）

    @objc private func cancelEdit() {
        editingItem = nil
        isCreating = false
        showEmptyState()
    }

    @objc private func saveCreate() {
        // Task 12 实现真实保存逻辑（取 keyword/content → service.add + 校验）
        cancelEdit()
    }

    @objc private func saveEdit() {
        // Task 12 实现
        cancelEdit()
    }

    @objc private func editCurrentPreview() {
        guard let item = previewItem else { return }
        startEdit(item)
    }

    @objc private func deleteCurrentPreview() {
        guard let item = previewItem else { return }
        requestDelete(item)
    }

    @objc private func deleteCurrentEdit() {
        guard let item = editingItem else { return }
        requestDelete(item)
    }

    private func requestDelete(_ item: SnippetItem) {
        let alert = SnipPanelVC.presentDeleteAlert(for: item)
        let response = alert.runModal()
        SnipPanelVC.handleDeleteResponse(response, for: item)
        reloadAndRefresh()
        showEmptyState()
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
}

// MARK: - NSTableViewDataSource / Delegate

extension SnipPanelVC: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { filteredItems.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = filteredItems[row]
        let cellId = NSUserInterfaceItemIdentifier("SnipListCell")
        let cell = (tableView.makeView(withIdentifier: cellId, owner: self) as? SnipListCellView)
            ?? SnipListCellView()
        cell.identifier = cellId
        cell.configure(keyword: item.keyword, content: item.content)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0, row < filteredItems.count else { return }
        let item = filteredItems[row]
        previewItem = item
        editingItem = nil
        isCreating = false
        transitionDetail(to: makePreviewChild(item: item))
        testHook_currentDetailMode = .preview
    }
}

// MARK: - SnipListCellView（keyword 主标题 + content 预览副标题）
//
// patterns/2026-07-09：自定义 NSView 作 cell 需显式 width/height 或 intrinsicContentSize，
// 这里作 NSTableCellView 子类由 tableView rowHeight(56) + 约束撑高，宽度由列宽撑满。

final class SnipListCellView: NSTableCellView {
    private let keywordLabel = NSTextField(labelWithString: "")
    private let contentLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupView() {
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

        NSLayoutConstraint.activate([
            keywordLabel.topAnchor.constraint(equalTo: topAnchor, constant: SettingsTheme.spacingSm),
            keywordLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SettingsTheme.spacingMd),
            keywordLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -SettingsTheme.spacingSm),

            contentLabel.topAnchor.constraint(equalTo: keywordLabel.bottomAnchor, constant: SettingsTheme.spacingXs),
            contentLabel.leadingAnchor.constraint(equalTo: keywordLabel.leadingAnchor),
            contentLabel.trailingAnchor.constraint(equalTo: keywordLabel.trailingAnchor),
            contentLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -SettingsTheme.spacingSm),
        ])
    }

    func configure(keyword: String, content: String) {
        keywordLabel.stringValue = keyword
        contentLabel.stringValue = content
    }
}
