import AppKit

/// 「关于」设置分类：App 图标 + 名称 + 版本号 + 反馈链接 + 开源地址。
///
/// 重构（A4）：补 appIconView 显示 AppIcon（修复一直空位），间距栅格化替代 60/8/24/12 混乱常量，
/// 字体层级 → SettingsTheme token。
final class AboutSettingsViewController: NSViewController {

    private let appIconView = NSImageView()
    private let appNameLabel = NSTextField(labelWithString: "Claude Code Buddy")
    private let versionLabel = NSTextField(labelWithString: "")
    private let feedbackButton = NSButton(title: "反馈问题", target: nil, action: #selector(openFeedback))
    private let repoButton = NSButton(title: "开源地址", target: nil, action: #selector(openRepo))

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 580, height: 480))
        setupLayout(in: container)
        self.view = container
    }

    private func setupLayout(in container: NSView) {
        // App 图标（补全，A4 修复空位）
        appIconView.imageScaling = .scaleProportionallyUpOrDown
        appIconView.image = Self.appIcon
        appIconView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(appIconView)

        // App 名称（title token）
        appNameLabel.font = SettingsTheme.titleFont()
        appNameLabel.textColor = SettingsTheme.titleColor()
        appNameLabel.alignment = .center
        appNameLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(appNameLabel)

        // 版本号（rowSubtitle token）
        versionLabel.font = SettingsTheme.rowSubtitleFont()
        versionLabel.textColor = SettingsTheme.rowSubtitleColor()
        versionLabel.alignment = .center
        versionLabel.stringValue = "版本 \(Self.appVersion)"
        versionLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(versionLabel)

        feedbackButton.bezelStyle = .rounded
        feedbackButton.target = self
        feedbackButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(feedbackButton)

        repoButton.bezelStyle = .rounded
        repoButton.target = self
        repoButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(repoButton)

        NSLayoutConstraint.activate([
            // 图标：顶部 groupTopInset + 8，居中，96x96
            appIconView.topAnchor.constraint(equalTo: container.topAnchor,
                                             constant: SettingsTheme.groupTopInset + 8),
            appIconView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            appIconView.widthAnchor.constraint(equalToConstant: 96),
            appIconView.heightAnchor.constraint(equalToConstant: 96),

            // 名称：图标下方 SettingsTheme.rowSpacing * 2
            appNameLabel.topAnchor.constraint(equalTo: appIconView.bottomAnchor,
                                              constant: SettingsTheme.rowSpacing * 2),
            appNameLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            appNameLabel.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor,
                                                  constant: SettingsTheme.contentPadding),
            appNameLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor,
                                                   constant: -SettingsTheme.contentPadding),

            // 版本：名称下方 rowSpacing
            versionLabel.topAnchor.constraint(equalTo: appNameLabel.bottomAnchor,
                                              constant: SettingsTheme.rowSpacing),
            versionLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            versionLabel.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor,
                                                  constant: SettingsTheme.contentPadding),
            versionLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor,
                                                   constant: -SettingsTheme.contentPadding),

            // 反馈按钮：版本下方 groupSpacing + 4
            feedbackButton.topAnchor.constraint(equalTo: versionLabel.bottomAnchor,
                                                constant: SettingsTheme.groupSpacing + 4),
            feedbackButton.centerXAnchor.constraint(equalTo: container.centerXAnchor),

            // 开源按钮：反馈按钮下方 rowSpacing
            repoButton.topAnchor.constraint(equalTo: feedbackButton.bottomAnchor,
                                            constant: SettingsTheme.rowSpacing),
            repoButton.centerXAnchor.constraint(equalTo: container.centerXAnchor),
        ])
    }

    /// App 图标（从 Asset Catalog / Bundle 取）。
    private static var appIcon: NSImage? {
        NSImage(named: "AppIcon")
            ?? NSApplication.shared.applicationIconImage
    }

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }

    @objc private func openFeedback() {
        if let url = URL(string: "https://github.com/strzhao/claude-code-buddy/issues") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openRepo() {
        if let url = URL(string: "https://github.com/strzhao/claude-code-buddy") {
            NSWorkspace.shared.open(url)
        }
    }
}
