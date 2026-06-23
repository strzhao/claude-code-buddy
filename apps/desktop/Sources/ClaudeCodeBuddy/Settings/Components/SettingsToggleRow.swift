import AppKit

// MARK: - SettingsToggleRow

/// 统一 toggle 行（A3）：左标题 + 副标题说明，右 SageSwitch（自绘 sage 开态）。
///
/// 替代 GeneralSettings 的 yOffset 硬编码手算布局。用 SettingsTheme 字体层级 token。
/// switch 用 SageSwitch（完全自绘 NSView）—— NSSwitch 无 tint API，自绘是 sage 唯一可靠方案。
final class SettingsToggleRow: NSView {

    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let toggleSwitch = SageSwitch(isOn: false)

    /// toggle 状态变化回调（newState: Bool）。
    var onToggle: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    init(title: String, subtitle: String?, isOn: Bool) {
        super.init(frame: .zero)
        setupView()
        configure(title: title, subtitle: subtitle, isOn: isOn)
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
        subtitleLabel.cell?.truncatesLastVisibleLine = false
        subtitleLabel.cell?.wraps = true
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(subtitleLabel)

        toggleSwitch.onChange = { [weak self] isOn in
            self?.onToggle?(isOn)
        }
        toggleSwitch.translatesAutoresizingMaskIntoConstraints = false
        addSubview(toggleSwitch)

        NSLayoutConstraint.activate([
            // 标题：左对齐 cardContentPadding，距顶 10
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SettingsTheme.cardContentPadding),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: toggleSwitch.leadingAnchor, constant: -12),

            // 副标题：标题下方 2pt
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: toggleSwitch.leadingAnchor, constant: -12),
            subtitleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),

            // switch：右对齐 cardContentPadding，垂直居中；自绘开关尺寸 32×20
            toggleSwitch.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SettingsTheme.cardContentPadding),
            toggleSwitch.centerYAnchor.constraint(equalTo: centerYAnchor),
            toggleSwitch.widthAnchor.constraint(equalToConstant: 32),
            toggleSwitch.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    /// 配置标题/副标题/初始状态。
    func configure(title: String, subtitle: String?, isOn: Bool) {
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle ?? ""
        subtitleLabel.isHidden = (subtitle == nil)
        toggleSwitch.setState(isOn)
    }

    /// 外部同步开关状态（不触发 onToggle）。
    func setSwitchState(_ isOn: Bool) {
        toggleSwitch.setState(isOn)
    }
}
