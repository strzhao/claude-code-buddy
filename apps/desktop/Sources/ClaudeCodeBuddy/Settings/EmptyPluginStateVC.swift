import AppKit

// MARK: - EmptyPluginStateVC
//
// 无可配置面板插件的空态 VC（AC-SNIPGUI-03/27）。
//
// 显示：
//   - 居中图标（SF Symbol "puzzlepiece" 或 plugin-specific）
//   - 「此插件无可配置面板」标题
//   - manifest.description / summary 摘要（人话说明）
//   - 启用状态徽标（已启用 / 已关闭）
//
// 调用方：PluginGalleryViewController 当 PluginPanelRegistry 未命中选中插件时构造此 VC。
final class EmptyPluginStateVC: NSViewController {

    private let name: String
    private let summary: String
    private let pluginDescription: String
    private let enabled: Bool

    init(name: String, summary: String, description: String, enabled: Bool) {
        self.name = name
        self.summary = summary
        self.pluginDescription = description
        self.enabled = enabled
        super.init(nibName: nil, bundle: nil)
    }

    /// Convenience init（红队 test 契约同步）：仅传 pluginName，summary/description 留空。
    /// 用于 test 验证空态 VC 渲染含「无可配置」文本（AC-SNIPGUI-03/27），
    /// 生产路径走完整 init（带 manifest 信息）。
    convenience init(pluginName: String) {
        self.init(name: pluginName, summary: "", description: "", enabled: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        // 固定初始 frame + autoresize（防 fittingSize 缩 0，patterns/2026-06-16）；实际尺寸由父容器撑满
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 540))
        container.autoresizingMask = [.width, .height]

        // 居中竖向栈：图标 + 标题 + 摘要 + 启用徽标
        let icon = NSTextField(labelWithString: "")
        // SF Symbol 作 icon（NSImage(swiftSymbolName:) macOS 11+）
        let iconView = NSImageView()
        iconView.image = NSImage(
            systemSymbolName: "puzzlepiece",
            accessibilityDescription: "插件"
        )
        iconView.contentTintColor = .secondaryLabelColor
        iconView.symbolConfiguration = .init(pointSize: 48, weight: .regular)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(iconView)

        let titleLabel = NSTextField(labelWithString: "此插件无可配置面板")
        titleLabel.font = SettingsTheme.titleFont()
        titleLabel.textColor = SettingsTheme.titleColor()
        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(titleLabel)

        let summaryLabel = NSTextField(labelWithString: summary.isEmpty ? name : summary)
        summaryLabel.font = SettingsTheme.rowTitleFont()
        summaryLabel.textColor = SettingsTheme.rowSubtitleColor()
        summaryLabel.alignment = .center
        summaryLabel.maximumNumberOfLines = 0
        summaryLabel.lineBreakMode = .byWordWrapping
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(summaryLabel)

        let descLabel = NSTextField(labelWithString: pluginDescription)
        descLabel.font = SettingsTheme.rowSubtitleFont()
        descLabel.textColor = SettingsTheme.footnoteColor()
        descLabel.alignment = .center
        descLabel.maximumNumberOfLines = 0
        descLabel.lineBreakMode = .byWordWrapping
        descLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(descLabel)

        // 启用状态徽标（胶囊 NSTextField）
        let badgeText = enabled ? "已启用" : "已关闭"
        let badgeColor: NSColor = enabled
            ? SettingsTheme.accent
            : SettingsTheme.footnoteColor()
        let badge = NSTextField(labelWithString: badgeText)
        badge.font = SettingsTheme.groupLabelFont()
        badge.textColor = badgeColor
        badge.alignment = .center
        badge.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(badge)

        NSLayoutConstraint.activate([
            // 图标水平居中 + 垂直居中于容器上半部（响应式，不再固定 96pt top）
            iconView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: -SettingsTheme.spacingSection),

            titleLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: SettingsTheme.spacingLg),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: SettingsTheme.spacingXxl),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -SettingsTheme.spacingXxl),
            titleLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),

            summaryLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: SettingsTheme.spacingSm),
            summaryLabel.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: SettingsTheme.spacingXxl),
            summaryLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -SettingsTheme.spacingXxl),
            summaryLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),

            descLabel.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: SettingsTheme.spacingSm),
            descLabel.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: SettingsTheme.spacingSection),
            descLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -SettingsTheme.spacingSection),
            descLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),

            badge.topAnchor.constraint(equalTo: descLabel.bottomAnchor, constant: SettingsTheme.spacingMd),
            badge.centerXAnchor.constraint(equalTo: container.centerXAnchor),
        ])

        // AX：让红队可读「无可配置」文本（AC-SNIPGUI-03/27 断言）
        titleLabel.setAccessibilityIdentifier("empty_plugin.title")
        summaryLabel.setAccessibilityIdentifier("empty_plugin.summary")
        container.setAccessibilityIdentifier("settings.detail")

        self.view = container
    }
}
