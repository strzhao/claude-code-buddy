import AppKit

// MARK: - ToolItemRow

/// AI 工具列表的只读行（T6 重构，2026-07-02）。
///
/// 复用 `SettingsToggleRow.configurePlugin` 的视觉语言（title + summary 副标题 +
/// source 徽标 + SettingsTheme token），但**只读无 toggle**（契约 C4）。
/// 左侧多一个 symbol 图标位（emoji / SF Symbol 文本）。
///
/// 与 SettingsToggleRow 的区别：
/// - 无 SageSwitch（纯展示，不可交互）
/// - 左侧 symbol 图标（🔊 朗读 / 📋 复制 等）
/// - source 徽标在标题右侧（与 SettingsToggleRow.configurePlugin 同位）
final class ToolItemRow: NSView {

    private let symbolLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let sourceBadgeLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    init(item: AIToolItem) {
        super.init(frame: .zero)
        setupView()
        configure(item: item)
    }

    private func setupView() {
        // symbol 图标（emoji 或 SF Symbol 文本，居中 16pt）
        symbolLabel.font = .systemFont(ofSize: 16)
        symbolLabel.alignment = .center
        symbolLabel.translatesAutoresizingMaskIntoConstraints = false
        symbolLabel.textColor = .labelColor
        addSubview(symbolLabel)

        titleLabel.font = SettingsTheme.rowTitleFont()
        titleLabel.textColor = SettingsTheme.rowTitleColor()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        subtitleLabel.font = SettingsTheme.rowSubtitleFont()
        subtitleLabel.textColor = SettingsTheme.rowSubtitleColor()
        subtitleLabel.lineBreakMode = .byWordWrapping
        subtitleLabel.maximumNumberOfLines = 0
        subtitleLabel.cell?.truncatesLastVisibleLine = false
        subtitleLabel.cell?.wraps = true
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(subtitleLabel)

        // 来源徽标（与 SettingsToggleRow.configurePlugin 同样式：monospaced 10pt medium）
        sourceBadgeLabel.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        sourceBadgeLabel.textColor = NSColor.secondaryLabelColor
        sourceBadgeLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sourceBadgeLabel)

        NSLayoutConstraint.activate([
            // symbol：左 16pt，垂直居中，固定 24pt 宽
            symbolLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SettingsTheme.cardContentPadding),
            symbolLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            symbolLabel.widthAnchor.constraint(equalToConstant: 24),

            // 标题：symbol 右 8pt
            titleLabel.leadingAnchor.constraint(equalTo: symbolLabel.trailingAnchor, constant: 8),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: sourceBadgeLabel.leadingAnchor, constant: -8),

            // 来源徽标：标题右侧
            sourceBadgeLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            sourceBadgeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SettingsTheme.cardContentPadding),

            // 副标题：标题下方 2pt
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -SettingsTheme.cardContentPadding),
            subtitleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }

    /// 用 AIToolItem 配置行内容。
    func configure(item: AIToolItem) {
        symbolLabel.stringValue = item.symbol
        titleLabel.stringValue = item.title
        subtitleLabel.stringValue = item.summary
        if !item.source.isEmpty {
            sourceBadgeLabel.stringValue = "[\(item.source)]"
            sourceBadgeLabel.isHidden = false
        } else {
            sourceBadgeLabel.isHidden = true
        }
    }
}
