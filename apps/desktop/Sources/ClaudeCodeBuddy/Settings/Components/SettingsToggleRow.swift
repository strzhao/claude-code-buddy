import AppKit

// MARK: - SettingsToggleRow

/// 统一 toggle 行（A3）：左标题 + 副标题说明，右 SageSwitch（自绘 sage 开态）。
///
/// 替代 GeneralSettings 的 yOffset 硬编码手算布局。用 SettingsTheme 字体层级 token。
/// switch 用 SageSwitch（完全自绘 NSView）—— NSSwitch 无 tint API，自绘是 sage 唯一可靠方案。
///
/// C6 扩展：`configurePlugin(...)` 支持 summary 副标题 + 可展开详情 description + 来源徽标 + tooltip。
final class SettingsToggleRow: NSView {

    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let sourceBadgeLabel = NSTextField(labelWithString: "")
    private let toggleSwitch = SageSwitch(isOn: false)

    /// 可展开详情（C6）：点击标题区切换展开/收起 description。
    private let detailLabel = NSTextField(labelWithString: "")
    private var detailHeightConstraint: NSLayoutConstraint?
    private var isDetailExpanded = false
    private var hasDetail = false

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

        // C6 来源徽标（内置/社区/侧载）
        sourceBadgeLabel.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        sourceBadgeLabel.textColor = NSColor.secondaryLabelColor
        sourceBadgeLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sourceBadgeLabel)

        // C6 可展开详情
        detailLabel.font = SettingsTheme.rowSubtitleFont()
        detailLabel.textColor = SettingsTheme.rowSubtitleColor()
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.maximumNumberOfLines = 0
        detailLabel.cell?.truncatesLastVisibleLine = false
        detailLabel.cell?.wraps = true
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.isHidden = true
        addSubview(detailLabel)

        toggleSwitch.onChange = { [weak self] isOn in
            self?.onToggle?(isOn)
        }
        toggleSwitch.translatesAutoresizingMaskIntoConstraints = false
        addSubview(toggleSwitch)

        // 点击标题区切换详情展开（C6）
        let clickGesture = NSClickGestureRecognizer(target: self, action: #selector(handleTitleClick))
        titleLabel.addGestureRecognizer(clickGesture)

        // 详情高度约束（动态调整，收起时 = 0）
        detailHeightConstraint = detailLabel.heightAnchor.constraint(equalToConstant: 0)

        var constraints: [NSLayoutConstraint] = [
            // 标题：左对齐 cardContentPadding，距顶 10
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SettingsTheme.cardContentPadding),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: sourceBadgeLabel.leadingAnchor, constant: -8),

            // 来源徽标：标题右侧
            sourceBadgeLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            sourceBadgeLabel.trailingAnchor.constraint(lessThanOrEqualTo: toggleSwitch.leadingAnchor, constant: -8),

            // 副标题：标题下方 2pt
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: toggleSwitch.leadingAnchor, constant: -12),

            // 详情：副标题下方 4pt（展开时显示，收起时高度 0 隐藏）
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 4),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: toggleSwitch.leadingAnchor, constant: -12),
            detailLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),

            // switch：右对齐 cardContentPadding，垂直居中；自绘开关尺寸 32×20
            toggleSwitch.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SettingsTheme.cardContentPadding),
            toggleSwitch.centerYAnchor.constraint(equalTo: centerYAnchor),
            toggleSwitch.widthAnchor.constraint(equalToConstant: 32),
            toggleSwitch.heightAnchor.constraint(equalToConstant: 20),
        ]
        // detailHeightConstraint 在上方已赋值，安全追加（避免 force unwrap）
        if let detailHeight = detailHeightConstraint {
            constraints.append(detailHeight)
        }
        NSLayoutConstraint.activate(constraints)
    }

    /// 配置标题/副标题/初始状态。
    func configure(title: String, subtitle: String?, isOn: Bool) {
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle ?? ""
        subtitleLabel.isHidden = (subtitle == nil)
        sourceBadgeLabel.isHidden = true
        toggleSwitch.setState(isOn)
        hasDetail = false
        detailLabel.isHidden = true
        detailHeightConstraint?.constant = 0
    }

    /// C6：插件行配置（标题 + summary 副标题 + 可展开 description + 来源徽标 + tooltip）。
    func configurePlugin(
        title: String,
        summary: String,
        description: String?,
        source: String?,
        isOn: Bool,
        tooltip: String? = nil
    ) {
        titleLabel.stringValue = title
        subtitleLabel.stringValue = summary
        subtitleLabel.isHidden = false

        // 来源徽标
        if let source, !source.isEmpty {
            sourceBadgeLabel.stringValue = "[\(source)]"
            sourceBadgeLabel.isHidden = false
        } else {
            sourceBadgeLabel.isHidden = true
        }

        // 可展开详情
        if let description, !description.isEmpty, description != summary {
            detailLabel.stringValue = description
            hasDetail = true
            // 默认收起；展开由点击标题触发
            detailLabel.isHidden = true
            detailHeightConstraint?.constant = 0
        } else {
            hasDetail = false
            detailLabel.isHidden = true
            detailHeightConstraint?.constant = 0
        }

        // tooltip（Paste 关闭语义说明等）
        self.toolTip = tooltip

        toggleSwitch.setState(isOn)
    }

    /// 外部同步开关状态（不触发 onToggle）。
    func setSwitchState(_ isOn: Bool) {
        toggleSwitch.setState(isOn)
    }

    // MARK: - 详情展开（C6）

    @objc private func handleTitleClick() {
        guard hasDetail else { return }
        isDetailExpanded.toggle()
        if isDetailExpanded {
            detailLabel.isHidden = false
            // 自适应高度（最多 4 行）：用 fittingWidth 估算
            detailLabel.preferredMaxLayoutWidth = detailLabel.bounds.width
            detailHeightConstraint?.constant = 0  // 让 intrinsicContentSize 撑开（bottomAnchor 约束接管）
            detailLabel.setContentHuggingPriority(.defaultLow, for: .vertical)
            detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        } else {
            detailLabel.isHidden = true
            detailHeightConstraint?.constant = 0
        }
        // 触发父视图重新布局（SettingsGroupView stackView 自适应高度）
        superview?.needsLayout = true
        window?.contentViewController?.view.needsLayout = true
    }
}
