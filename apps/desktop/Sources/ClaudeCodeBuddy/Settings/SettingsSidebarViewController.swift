import AppKit

/// Settings sidebar 列表 VC。
///
/// 数据驱动（契约 2）：分类来自 `SettingsSection.allCases` 单一数据源，
/// `numberOfRows`/cell 全部从 `allCases` 取。加分类=加一个 case，骨架不动（SC-12）。
///
/// AX 命名（契约 7）：每个 cell 设 `settings.sidebar.\(section.rawValue)`。
/// 选中态由外部（SettingsSplitViewController）通过 `selectSection(_:animateScroll:)` 驱动，
/// 本 VC 通过 tableView selection delegate 通知外部。
final class SettingsSidebarViewController: NSViewController {

    /// 选中变化回调（splitVC 据此切换 detail VC）。
    var onSelectSection: ((SettingsSection) -> Void)?

    private var tableView: NSTableView!
    private let cellIdentifier = NSUserInterfaceItemIdentifier("SettingsSidebarCell")

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 540))
        container.autoresizingMask = [.width, .height]

        let scrollView = NSScrollView()
        scrollView.documentView = makeTableView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        self.view = container
    }

    private func makeTableView() -> NSTableView {
        tableView = NSTableView()
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.rowSizeStyle = .default
        tableView.style = .sourceList
        tableView.dataSource = self
        tableView.delegate = self

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        return tableView
    }

    /// 外部驱动选中（splitVC 初始化/恢复持久化时调）。
    func selectSection(_ section: SettingsSection, animateScroll: Bool = false) {
        let row = SettingsSection.allCases.firstIndex(of: section) ?? 0
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        if animateScroll {
            tableView.scrollRowToVisible(row)
        }
    }

    /// 测试钩子：暴露内部 tableView 供断言 numberOfRows/cell。
    var testHook_tableView: NSTableView { tableView }
}

// MARK: - NSTableViewDataSource

extension SettingsSidebarViewController: NSTableViewDataSource {

    func numberOfRows(in tableView: NSTableView) -> Int {
        SettingsSection.allCases.count
    }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard row >= 0, row < SettingsSection.allCases.count else { return nil }
        let section = SettingsSection.allCases[row]
        // 手动创建 cell（NSView 子类不走 nib 注册路径）
        let cell = SettingsSidebarCellView()
        cell.identifier = cellIdentifier
        cell.configure(with: section)
        return cell
    }
}

// MARK: - NSTableViewDelegate

extension SettingsSidebarViewController: NSTableViewDelegate {

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0, row < SettingsSection.allCases.count else { return }
        let section = SettingsSection.allCases[row]
        onSelectSection?(section)
    }

    func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
        // 契约 7：AXRow 层设 id（真机 AX row.identifier 透传；cellView 的 id 在 row 层读不到）
        guard row >= 0, row < SettingsSection.allCases.count else { return }
        let section = SettingsSection.allCases[row]
        rowView.setAccessibilityIdentifier("settings.sidebar.\(section.rawValue)")
    }
}

// MARK: - SettingsSidebarCellView

/// sidebar 单元格：SF Symbol 图标 + 中文标题，AX identifier 遵循契约 7。
final class SettingsSidebarCellView: NSTableCellView {

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupSubviews() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.symbolConfiguration = .init(pointSize: 15, weight: .regular)
        iconView.contentTintColor = SettingsTheme.rowSubtitleColor()
        addSubview(iconView)

        titleLabel.font = SettingsTheme.rowTitleFont()
        titleLabel.textColor = SettingsTheme.rowTitleColor()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        self.textField = titleLabel

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
        ])
    }

    func configure(with section: SettingsSection) {
        titleLabel.stringValue = section.displayTitle
        iconView.image = NSImage(systemSymbolName: section.symbolName,
                                 accessibilityDescription: section.displayTitle)
        // 契约 7：sidebar item = `settings.sidebar.\(section.rawValue)`
        setAccessibilityIdentifier("settings.sidebar.\(section.rawValue)")
    }
}
