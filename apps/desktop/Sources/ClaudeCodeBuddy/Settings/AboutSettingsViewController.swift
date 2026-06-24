import AppKit
import Combine

/// 「关于」设置分类：App 图标 + 名称 + 版本号 + 更新区域 + 反馈链接 + 开源地址。
///
/// 重构（A4）：补 appIconView 显示 AppIcon（修复一直空位），间距栅格化替代 60/8/24/12 混乱常量，
/// 字体层级 → SettingsTheme token。
///
/// 更新功能（task 自动升级优化）：在 versionLabel 和 feedbackButton 之间插入更新区域，
/// 包含「检查更新」按钮、「立即升级」按钮、NSProgressIndicator、状态标签。
final class AboutSettingsViewController: NSViewController {

    private let appIconView = NSImageView()
    private let appNameLabel = NSTextField(labelWithString: "Claude Code Buddy")
    private let versionLabel = NSTextField(labelWithString: "")
    private let feedbackButton = NSButton(title: "反馈问题", target: nil, action: #selector(openFeedback))
    private let repoButton = NSButton(title: "开源地址", target: nil, action: #selector(openRepo))

    // MARK: - Update UI

    private let checkUpdateButton = NSButton(title: "检查更新", target: nil, action: nil)
    private let upgradeButton = NSButton(title: "立即升级", target: nil, action: nil)
    private let progressIndicator = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private var cancellables = Set<AnyCancellable>()

    /// 跟踪当前升级阶段，驱动 UI 状态。
    private var currentPhase: UpgradePhase = .idle {
        didSet { updateUIForPhase() }
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 580, height: 480))
        setupLayout(in: container)
        self.view = container
        subscribeToUpgradeProgress()
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

        // -- 更新区域 --
        // 「检查更新」按钮
        checkUpdateButton.bezelStyle = .rounded
        checkUpdateButton.target = self
        checkUpdateButton.action = #selector(checkForUpdates)
        checkUpdateButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(checkUpdateButton)

        // 「立即升级」按钮
        upgradeButton.bezelStyle = .rounded
        upgradeButton.target = self
        upgradeButton.action = #selector(startUpgrade)
        upgradeButton.isHidden = true
        upgradeButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(upgradeButton)

        // 进度指示器（indeterminate spinning style）
        progressIndicator.style = .spinning
        progressIndicator.isIndeterminate = true
        progressIndicator.controlSize = .small
        progressIndicator.isHidden = true
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(progressIndicator)

        // 状态标签
        statusLabel.font = SettingsTheme.footnoteFont()
        statusLabel.textColor = SettingsTheme.footnoteColor()
        statusLabel.alignment = .center
        statusLabel.isHidden = true
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(statusLabel)

        // 反馈按钮
        feedbackButton.bezelStyle = .rounded
        feedbackButton.target = self
        feedbackButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(feedbackButton)

        // 开源按钮
        repoButton.bezelStyle = .rounded
        repoButton.target = self
        repoButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(repoButton)

        // 更新区域顶部约束引用（根据状态切换上锚点）
        let updateTopAnchor = checkUpdateButton.topAnchor.constraint(
            equalTo: versionLabel.bottomAnchor,
            constant: SettingsTheme.groupSpacing + 4
        )

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

            // 更新区域
            updateTopAnchor,
            checkUpdateButton.centerXAnchor.constraint(equalTo: container.centerXAnchor),

            upgradeButton.topAnchor.constraint(equalTo: versionLabel.bottomAnchor,
                                               constant: SettingsTheme.groupSpacing + 4),
            upgradeButton.centerXAnchor.constraint(equalTo: container.centerXAnchor),

            progressIndicator.topAnchor.constraint(equalTo: versionLabel.bottomAnchor,
                                                   constant: SettingsTheme.groupSpacing + 4),
            progressIndicator.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            progressIndicator.widthAnchor.constraint(equalToConstant: 24),
            progressIndicator.heightAnchor.constraint(equalToConstant: 24),

            statusLabel.topAnchor.constraint(equalTo: progressIndicator.bottomAnchor,
                                             constant: SettingsTheme.rowSpacing),
            statusLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor,
                                                 constant: SettingsTheme.contentPadding),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor,
                                                  constant: -SettingsTheme.contentPadding),

            // 反馈按钮
            feedbackButton.topAnchor.constraint(equalTo: checkUpdateButton.bottomAnchor,
                                                constant: SettingsTheme.groupSpacing + 4),
            feedbackButton.centerXAnchor.constraint(equalTo: container.centerXAnchor),

            // 开源按钮
            repoButton.topAnchor.constraint(equalTo: feedbackButton.bottomAnchor,
                                            constant: SettingsTheme.rowSpacing),
            repoButton.centerXAnchor.constraint(equalTo: container.centerXAnchor),
        ])
    }

    // MARK: - Update Progress Subscription

    private func subscribeToUpgradeProgress() {
        UpdateChecker.shared.upgradeProgress
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in
                self?.currentPhase = phase
            }
            .store(in: &cancellables)
    }

    /// 根据当前 UpgradePhase 驱动按钮/进度条/状态标签的可见性和文案。
    private func updateUIForPhase() {
        switch currentPhase {
        case .idle:
            progressIndicator.stopAnimation(nil)
            progressIndicator.isHidden = true
            statusLabel.isHidden = true
            checkUpdateButton.isHidden = false
            checkUpdateButton.isEnabled = true
            upgradeButton.isHidden = true

            // 检查是否已有 pending update，有则显示升级按钮
            if UpdateChecker.shared.hasPendingUpdate {
                checkUpdateButton.isHidden = true
                upgradeButton.isHidden = false
                upgradeButton.isEnabled = true
                upgradeButton.title = "立即升级"
            }

        case .checking:
            progressIndicator.isHidden = false
            progressIndicator.startAnimation(nil)
            statusLabel.isHidden = false
            statusLabel.stringValue = "正在检查更新..."
            statusLabel.textColor = SettingsTheme.footnoteColor()
            checkUpdateButton.isHidden = true
            upgradeButton.isHidden = true

        case .downloading:
            progressIndicator.isHidden = false
            progressIndicator.startAnimation(nil)
            statusLabel.isHidden = false
            statusLabel.stringValue = "正在下载..."
            statusLabel.textColor = SettingsTheme.footnoteColor()
            checkUpdateButton.isHidden = true
            upgradeButton.isHidden = true

        case .installing:
            progressIndicator.isHidden = false
            progressIndicator.startAnimation(nil)
            statusLabel.isHidden = false
            statusLabel.stringValue = "正在安装..."
            statusLabel.textColor = SettingsTheme.footnoteColor()
            checkUpdateButton.isHidden = true
            upgradeButton.isHidden = true

        case .done:
            progressIndicator.stopAnimation(nil)
            progressIndicator.isHidden = true
            statusLabel.isHidden = false
            statusLabel.stringValue = "✓ 安装完成，请重启应用"
            statusLabel.textColor = NSColor(red: 0.2, green: 0.78, blue: 0.35, alpha: 1)
            checkUpdateButton.isHidden = true
            upgradeButton.isHidden = true

        case .failed(let error):
            progressIndicator.stopAnimation(nil)
            progressIndicator.isHidden = true
            statusLabel.isHidden = false
            statusLabel.stringValue = "✗ 更新失败：\(error.localizedDescription)"
            statusLabel.textColor = SettingsTheme.warningColor
            checkUpdateButton.isHidden = false
            checkUpdateButton.isEnabled = true
            upgradeButton.isHidden = true
        }
    }

    // MARK: - Update Actions

    @objc private func checkForUpdates() {
        BuddyLogger.shared.info("manual check for updates", subsystem: "settings")
        UpdateChecker.shared.forceCheckForUpdates()

        // 检查完成后显示结果
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.updateUIForPhase()
        }
    }

    @objc private func startUpgrade() {
        BuddyLogger.shared.info("manual start upgrade", subsystem: "settings")
        UpdateChecker.shared.startUpgrade()
    }

    // MARK: - Helpers

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
