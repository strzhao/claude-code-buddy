import AppKit

/// 「关于」设置分类：版本号 + 反馈链接 + 开源地址。
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
        appNameLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        appNameLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(appNameLabel)

        versionLabel.font = .systemFont(ofSize: 13)
        versionLabel.textColor = .secondaryLabelColor
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
            appNameLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 60),
            appNameLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),

            versionLabel.topAnchor.constraint(equalTo: appNameLabel.bottomAnchor, constant: 8),
            versionLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),

            feedbackButton.topAnchor.constraint(equalTo: versionLabel.bottomAnchor, constant: 24),
            feedbackButton.centerXAnchor.constraint(equalTo: container.centerXAnchor),

            repoButton.topAnchor.constraint(equalTo: feedbackButton.bottomAnchor, constant: 12),
            repoButton.centerXAnchor.constraint(equalTo: container.centerXAnchor),
        ])
    }

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }

    @objc private func openFeedback() {
        if let url = URL(string: "https://github.com/stringzhao/claude-code-buddy/issues") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openRepo() {
        if let url = URL(string: "https://github.com/stringzhao/claude-code-buddy") {
            NSWorkspace.shared.open(url)
        }
    }
}
