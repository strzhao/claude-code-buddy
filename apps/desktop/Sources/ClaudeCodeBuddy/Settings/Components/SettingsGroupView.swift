import AppKit

// MARK: - SettingsGroupView

/// 分组卡片容器（A3，对标系统设置分组盒子）。
///
/// 圆角 10 + `controlBackgroundColor` 底色 + 内部行间极细分隔线。
/// 行通过 `addRow(_:)` 添加，自动在非首行顶部插入 separator。
///
/// 用法：
/// ```swift
/// let group = SettingsGroupView()
/// container.addSubview(group)
/// // 约束 group leading/trailing/top + 高度自适应
/// group.addRow(toggleRow1)
/// group.addRow(toggleRow2)
/// ```
final class SettingsGroupView: NSView {

    private let stackView = NSStackView()
    private var rowCount: Int = 0

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
        layer?.backgroundColor = SettingsTheme.cardBackgroundColor.cgColor

        // 外层加 1pt 边距让卡片与内容分离 + 卡片内 padding
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 0
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: topAnchor, constant: SettingsTheme.spacingXs),
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -SettingsTheme.spacingXs),
        ])
    }

    /// 添加一行。非首行自动在顶部插入分隔线（NSBox separator）。
    func addRow(_ row: NSView) {
        if rowCount > 0 {
            let separator = NSBox()
            separator.boxType = .separator
            separator.translatesAutoresizingMaskIntoConstraints = false
            stackView.addArrangedSubview(separator)
            // separator 撑满宽度
            separator.leadingAnchor.constraint(equalTo: stackView.leadingAnchor).isActive = true
            separator.trailingAnchor.constraint(equalTo: stackView.trailingAnchor).isActive = true
        }
        stackView.addArrangedSubview(row)
        row.leadingAnchor.constraint(equalTo: stackView.leadingAnchor).isActive = true
        row.trailingAnchor.constraint(equalTo: stackView.trailingAnchor).isActive = true
        rowCount += 1
    }

    /// 清空所有行（renderState 重建 group 用）。
    func clearRows() {
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rowCount = 0
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = SettingsTheme.cardBackgroundColor.cgColor
    }
}
