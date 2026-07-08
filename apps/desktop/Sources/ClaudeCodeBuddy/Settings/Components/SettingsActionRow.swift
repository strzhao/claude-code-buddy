import AppKit

// MARK: - SettingsActionRow

/// 通用操作行 cell：左 title + subtitle，右动作按钮。
///
/// 与 SettingsToggleRow 视觉对称（同 SettingsTheme 字体层级 + cardContentPadding），
/// 用于「插件开发文档」等需要点击触发外部动作（非开关）的设置项。
///
/// 行高确定机制：subtitleLabel.bottomAnchor 钉到 row.bottom - 10
/// （与 SettingsToggleRow.detailLabel.bottomAnchor 同模式），避免在 NSStackView
/// arrangedSubview 中高度塌缩。
final class SettingsActionRow: NSView {

    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let actionButton = NSButton(title: "打开", target: nil, action: nil)

    /// 动作按钮点击回调。
    var onAction: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    init(title: String, subtitle: String, buttonTitle: String) {
        super.init(frame: .zero)
        setupView()
        configure(title: title, subtitle: subtitle, buttonTitle: buttonTitle)
    }

    private func setupView() {
        titleLabel.font = SettingsTheme.rowTitleFont()
        titleLabel.textColor = SettingsTheme.rowTitleColor()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        subtitleLabel.font = SettingsTheme.rowSubtitleFont()
        subtitleLabel.textColor = SettingsTheme.rowSubtitleColor()
        subtitleLabel.lineBreakMode = .byWordWrapping
        subtitleLabel.maximumNumberOfLines = 0
        subtitleLabel.cell?.wraps = true
        subtitleLabel.cell?.truncatesLastVisibleLine = false
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(subtitleLabel)

        actionButton.bezelStyle = .rounded
        actionButton.controlSize = .small
        actionButton.target = self
        actionButton.action = #selector(handleAction)
        actionButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(actionButton)

        NSLayoutConstraint.activate([
            // 标题：左 cardContentPadding + 距顶 10（与 SettingsToggleRow 一致）
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SettingsTheme.cardContentPadding),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: actionButton.leadingAnchor, constant: -12),

            // 副标题：标题下方 2pt
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: actionButton.leadingAnchor, constant: -12),
            // 钉底（确定行高，与 SettingsToggleRow detailLabel.bottom 同模式）
            subtitleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),

            // 按钮：右 cardContentPadding + 垂直居中
            actionButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SettingsTheme.cardContentPadding),
            actionButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(title: String, subtitle: String, buttonTitle: String) {
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle
        actionButton.title = buttonTitle
    }

    @objc private func handleAction() {
        onAction?()
    }
}
