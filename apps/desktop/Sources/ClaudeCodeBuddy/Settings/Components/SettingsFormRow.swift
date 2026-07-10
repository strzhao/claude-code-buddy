import AppKit

// MARK: - SettingsFormRow

/// 通用表单行（A4）：左 label + 右任意 NSView 控件。
///
/// 对标 SettingsToggleRow 的布局体系但右侧控件可插拔（NSTextField / NSPopUpButton / NSSecureTextField 等），
/// 用于 AI 配置 tab 的提供者/模型/地址/密钥等行。
///
/// 布局：title leading cardContentPadding(16pt) top 10pt；
/// subtitle title 下方 2pt；右控件 trailing cardContentPadding centerY；最低 44pt 行高。
/// 字体/颜色用 SettingsTheme.rowTitleFont/Color、rowSubtitleFont/Color。
final class SettingsFormRow: NSView {

    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let errorLabel = NSTextField(labelWithString: "")
    private let controlContainer = NSView()

    /// 右侧控件变更回调（NSTextField delegate / NSPopUpButton target-action 等）。
    var onControlChanged: (() -> Void)?

    /// 暴露右侧控件容器，调用方通过 `controlView` 获取已添加的控件。
    private(set) var controlView: NSView

    // MARK: - Init

    /// 创建表单行。
    /// - Parameters:
    ///   - title: 左侧标题（必填）。
    ///   - subtitle: 左侧副标题（可选，nil 时隐藏）。
    ///   - control: 右侧任意 NSView 控件（调用方负责设 target/action/delegate，通过 onControlChanged 桥接保存逻辑）。
    init(title: String, subtitle: String?, control: NSView) {
        self.controlView = control
        super.init(frame: .zero)
        setupView()
        configure(title: title, subtitle: subtitle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// LSUIElement 兼容：非 key window 下的首次点击仍需传递到嵌套控件（NSTextField/NSPopUpButton 等）。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    // MARK: - Setup

    private func setupView() {
        // 最低行高 44pt
        heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true

        // 标题
        titleLabel.font = SettingsTheme.rowTitleFont()
        titleLabel.textColor = SettingsTheme.rowTitleColor()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        // 副标题
        subtitleLabel.font = SettingsTheme.rowSubtitleFont()
        subtitleLabel.textColor = SettingsTheme.rowSubtitleColor()
        subtitleLabel.lineBreakMode = .byWordWrapping
        subtitleLabel.maximumNumberOfLines = 0
        subtitleLabel.cell?.truncatesLastVisibleLine = false
        subtitleLabel.cell?.wraps = true
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(subtitleLabel)

        // 错误标签（默认隐藏）
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.lineBreakMode = .byWordWrapping
        errorLabel.maximumNumberOfLines = 0
        errorLabel.isHidden = true
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(errorLabel)

        // 右侧控件容器
        controlContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(controlContainer)

        // 右侧控件嵌入容器
        controlView.translatesAutoresizingMaskIntoConstraints = false
        controlContainer.addSubview(controlView)

        NSLayoutConstraint.activate([
            // 最低行高 44pt（HIG）
            heightAnchor.constraint(greaterThanOrEqualToConstant: SettingsTheme.minRowHeight),

            // 标题：左对齐 cardContentPadding，距顶 spacingMd
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SettingsTheme.cardContentPadding),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: SettingsTheme.spacingMd),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: controlContainer.leadingAnchor, constant: -SettingsTheme.spacingMd),

            // 副标题：标题下方 spacingXs
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: SettingsTheme.spacingXs),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: controlContainer.leadingAnchor, constant: -SettingsTheme.spacingMd),

            // 错误标签：副标题下方 spacingXs
            errorLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            errorLabel.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: SettingsTheme.spacingXs),
            errorLabel.trailingAnchor.constraint(lessThanOrEqualTo: controlContainer.leadingAnchor, constant: -SettingsTheme.spacingMd),
            errorLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -SettingsTheme.spacingSm),

            // 右侧控件容器：trailing cardContentPadding，垂直居中
            controlContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SettingsTheme.cardContentPadding),
            controlContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
            controlContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),

            // 右侧控件填满容器
            controlView.leadingAnchor.constraint(equalTo: controlContainer.leadingAnchor),
            controlView.trailingAnchor.constraint(equalTo: controlContainer.trailingAnchor),
            controlView.topAnchor.constraint(equalTo: controlContainer.topAnchor),
            controlView.bottomAnchor.constraint(equalTo: controlContainer.bottomAnchor),
        ])
    }

    private func configure(title: String, subtitle: String?) {
        titleLabel.stringValue = title
        if let subtitle, !subtitle.isEmpty {
            subtitleLabel.stringValue = subtitle
            subtitleLabel.isHidden = false
        } else {
            subtitleLabel.isHidden = true
        }
    }

    // MARK: - Validation

    /// 显示错误信息（红色文字，副标题下方）。
    func setError(_ message: String) {
        errorLabel.stringValue = message
        errorLabel.isHidden = false
    }

    /// 清除验证错误状态。
    func clearValidation() {
        errorLabel.isHidden = true
        errorLabel.stringValue = ""
    }
}
