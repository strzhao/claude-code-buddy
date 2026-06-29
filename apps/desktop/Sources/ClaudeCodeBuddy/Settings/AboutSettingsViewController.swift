import AppKit
import Combine

/// 「关于」页更新区域的 UI 状态机：覆盖「检查」与「升级」两条路径，单一数据源驱动渲染。
enum UpdateAreaState {
    case idle                      // 显示「检查更新」按钮
    case checking                  // 正在检查（进度 + 「正在检查更新...」）
    case updateAvailable(String)   // 发现新版本（「发现新版本 X」+ 「立即升级」按钮）
    case upToDate                  // 已是最新版本
    case checkFailed(String)       // 检查失败（可重试）
    case upgrading(UpgradePhase)   // 升级流程中（downloading/installing/done/failed）
}

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

    /// 更新区域 UI 状态（单一数据源）。检查/升级两条路径都通过它驱动渲染。
    var updateAreaState: UpdateAreaState = .idle {
        didSet { renderUpdateArea() }
    }

    // MARK: - Internal（测试可观察的渲染结果）

    /// 当前更新区域状态文案。
    var updateAreaStatusText: String { statusLabel.stringValue }
    /// 检查更新按钮是否隐藏。
    var isCheckUpdateButtonHidden: Bool { checkUpdateButton.isHidden }
    /// 立即升级按钮是否隐藏。
    var isUpgradeButtonHidden: Bool { upgradeButton.isHidden }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 580, height: 480))
        setupLayout(in: container)
        self.view = container
        subscribeToUpgradeProgress()
        subscribeToCheckResult()
        // 初始状态：后台检查若已发现新版本，直接显示可升级；否则显示「检查更新」
        if let version = UpdateChecker.shared.pendingNewVersion {
            updateAreaState = .updateAvailable(version)
        } else {
            updateAreaState = .idle
        }
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
                guard let self = self else { return }
                // 升级流的 .idle 表示中止/重置；其余阶段映射到 .upgrading
                self.updateAreaState = (phase == .idle) ? .idle : .upgrading(phase)
            }
            .store(in: &cancellables)
    }

    /// 订阅检查结果流，事件驱动切换检查态 UI（修复「检查更新无反馈」）。
    private func subscribeToCheckResult() {
        UpdateChecker.shared.checkResult
            .receive(on: RunLoop.main)
            .sink { [weak self] outcome in
                guard let self = self else { return }
                switch outcome {
                case .available(let event):
                    self.updateAreaState = .updateAvailable(event.newVersion)
                case .upToDate:
                    self.updateAreaState = .upToDate
                case .failed(let error):
                    self.updateAreaState = .checkFailed(error.localizedDescription)
                }
            }
            .store(in: &cancellables)
    }

    /// 根据 updateAreaState 渲染更新区域：按钮/进度条/状态标签的可见性与文案。
    private func renderUpdateArea() {
        switch updateAreaState {
        case .idle:
            progressIndicator.stopAnimation(nil)
            progressIndicator.isHidden = true
            statusLabel.isHidden = true
            checkUpdateButton.isHidden = false
            checkUpdateButton.isEnabled = true
            upgradeButton.isHidden = true

        case .checking:
            progressIndicator.isHidden = false
            progressIndicator.startAnimation(nil)
            statusLabel.isHidden = false
            statusLabel.stringValue = "正在检查更新..."
            statusLabel.textColor = SettingsTheme.footnoteColor()
            checkUpdateButton.isHidden = true
            upgradeButton.isHidden = true

        case .updateAvailable(let version):
            progressIndicator.stopAnimation(nil)
            progressIndicator.isHidden = true
            statusLabel.isHidden = false
            statusLabel.stringValue = "发现新版本 \(version)"
            statusLabel.textColor = SettingsTheme.footnoteColor()
            checkUpdateButton.isHidden = true
            upgradeButton.isHidden = false
            upgradeButton.isEnabled = true
            upgradeButton.title = "立即升级"

        case .upToDate:
            progressIndicator.stopAnimation(nil)
            progressIndicator.isHidden = true
            statusLabel.isHidden = false
            statusLabel.stringValue = "✓ 已是最新版本"
            statusLabel.textColor = SettingsTheme.footnoteColor()
            checkUpdateButton.isHidden = false
            checkUpdateButton.isEnabled = true
            upgradeButton.isHidden = true

        case .checkFailed(let message):
            progressIndicator.stopAnimation(nil)
            progressIndicator.isHidden = true
            statusLabel.isHidden = false
            statusLabel.stringValue = "✗ 检查失败：\(message)"
            statusLabel.textColor = SettingsTheme.warningColor
            checkUpdateButton.isHidden = false
            checkUpdateButton.isEnabled = true
            upgradeButton.isHidden = true

        case .upgrading(let phase):
            renderUpgradePhase(phase)
        }
    }

    /// 渲染升级流程阶段（由 .upgrading 委托）。
    private func renderUpgradePhase(_ phase: UpgradePhase) {
        switch phase {
        case .idle:
            progressIndicator.stopAnimation(nil)
            progressIndicator.isHidden = true
            statusLabel.isHidden = true
            checkUpdateButton.isHidden = false
            checkUpdateButton.isEnabled = true
            upgradeButton.isHidden = true

        case .checking:
            progressIndicator.isHidden = false
            progressIndicator.startAnimation(nil)
            statusLabel.isHidden = false
            statusLabel.stringValue = "准备升级..."
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
        // 即时反馈：立即进入「正在检查」态，结果由 checkResult 事件驱动回显（不再静默/写死 2s 延迟）
        updateAreaState = .checking
        UpdateChecker.shared.forceCheckForUpdates()
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
