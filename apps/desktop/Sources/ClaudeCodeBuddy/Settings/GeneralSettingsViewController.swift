import AppKit
import ServiceManagement

/// 「通用」设置分类：音效开关 + 总是显示标签开关 + 开机自启。
///
/// 音效/标签开关从 SkinGalleryViewController 迁出（T4），UserDefaults key 不变：
///   - 音效：`SoundManager.shared.isEnabled`（内部 key `soundEnabled`）
///   - 标签：`alwaysShowLabel`
/// 属 UI 位置迁移非逻辑回归（契约 5，SC-14 验证）。
///
/// 布局重构（A4）：删旧手算坐标 → SettingsGroupView + SettingsToggleRow 垂直堆叠，
/// 分两组「通用」(音效/标签) +「系统」(开机自启)，每 toggle 加副标题说明。
final class GeneralSettingsViewController: NSViewController {

    private let soundRow = SettingsToggleRow(
        title: "音效",
        subtitle: "开启猫咪状态切换与交互音效",
        isOn: SoundManager.shared.isEnabled
    )
    private let alwaysShowLabelRow = SettingsToggleRow(
        title: "总是显示会话标签",
        subtitle: "为每个会话猫咪永久显示名字标签，方便区分",
        isOn: UserDefaults.standard.bool(forKey: "alwaysShowLabel")
    )
    private let launchAtLoginRow = SettingsToggleRow(
        title: "登录时自动启动",
        subtitle: "开机后自动运行 Claude Code Buddy",
        isOn: LaunchAtLogin.isEnabled
    )

    override func loadView() {
        // 固定初始 frame + 默认 autoresize（防 fittingSize 缩 0，patterns/2026-06-16）
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 580, height: 480))
        setupLayout(in: container)
        self.view = container
    }

    private func setupLayout(in container: NSView) {
        // 绑定 toggle 回调（SC-SET-11 持久化）
        soundRow.onToggle = { isOn in
            SoundManager.shared.isEnabled = isOn
        }
        alwaysShowLabelRow.onToggle = { isOn in
            UserDefaults.standard.set(isOn, forKey: "alwaysShowLabel")
        }
        launchAtLoginRow.onToggle = { isOn in
            LaunchAtLogin.isEnabled = isOn
        }

        // 分组标题：通用
        let generalLabel = SettingsGroupLabel(title: "通用")
        generalLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(generalLabel)

        // 分组卡片：通用（音效 + 标签）
        let generalGroup = SettingsGroupView()
        generalGroup.translatesAutoresizingMaskIntoConstraints = false
        generalGroup.addRow(soundRow)
        generalGroup.addRow(alwaysShowLabelRow)
        container.addSubview(generalGroup)

        // 分组标题：系统
        let systemLabel = SettingsGroupLabel(title: "系统")
        systemLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(systemLabel)

        // 分组卡片：系统（开机自启）
        let systemGroup = SettingsGroupView()
        systemGroup.translatesAutoresizingMaskIntoConstraints = false
        systemGroup.addRow(launchAtLoginRow)
        container.addSubview(systemGroup)

        NSLayoutConstraint.activate([
            // 通用标题
            generalLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: SettingsTheme.groupTopInset),
            generalLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: SettingsTheme.contentPadding),
            generalLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -SettingsTheme.contentPadding),

            // 通用卡片
            generalGroup.topAnchor.constraint(equalTo: generalLabel.bottomAnchor, constant: 6),
            generalGroup.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: SettingsTheme.contentPadding),
            generalGroup.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -SettingsTheme.contentPadding),

            // 系统标题
            systemLabel.topAnchor.constraint(equalTo: generalGroup.bottomAnchor, constant: SettingsTheme.groupSpacing),
            systemLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: SettingsTheme.contentPadding),
            systemLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -SettingsTheme.contentPadding),

            // 系统卡片
            systemGroup.topAnchor.constraint(equalTo: systemLabel.bottomAnchor, constant: 6),
            systemGroup.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: SettingsTheme.contentPadding),
            systemGroup.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -SettingsTheme.contentPadding),
        ])
    }
}

// MARK: - LaunchAtLogin

/// 开机自启 helper（SMAppService 封装，macOS 13+）。
enum LaunchAtLogin {
    static var isEnabled: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                BuddyLogger.shared.warn("launchAtLogin toggle failed", subsystem: "settings", meta: ["error": "\(error)"])
            }
        }
    }
}
