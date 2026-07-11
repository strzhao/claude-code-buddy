import AppKit
import Combine

// MARK: - SnipPanelVC
//
// snip 专属设置面板（纯 AppKit，master-detail，stage-4）。
// 原 SwiftUI（SnipPanelView）与 NSHostingController + sizingOptions=[] hack 一并消除。
//
// 左栏：搜索 + 新增 + NSTableView（keyword + content 预览双行 cell）
// 右栏：ContentColumnView 包裹，containment 切 空/create/edit/preview 四态
//
// 数据源：SnippetsService.shared（@MainActor 直驱），objectWillChange sink 刷新列表。
// 删除二次确认：NSAlert（presentDeleteAlert/handleDeleteResponse test seam）。
//
// 契约引用：C1 / AC-SNIPGUI-01/10/13/23

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
        // 左栏固定宽
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

    // MARK: - Actions

    @objc private func searchChanged() {
        reloadAndRefresh()
    }

    @objc private func startCreate() {
        // Task 11 实现 create 态
        editingItem = SnippetItem(keyword: "", content: "")
        isCreating = true
        showEmptyState()  // 占位，Task 11 替换为 showCreateForm
    }

    // MARK: - Detail 切换（本 task 仅空态，Task 11 补 create/edit/preview）

    private func showEmptyState() {
        transitionDetail(to: makeEmptyStateChild())
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

// MARK: - NSTableViewDataSource / Delegate（Task 10 基础列表）

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
        previewItem = filteredItems[row]
        // Task 11 实现 preview 态
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
