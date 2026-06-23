import AppKit
import ServiceManagement

/// 「通用」设置分类：音效开关 + 总是显示标签开关 + 开机自启。
///
/// 音效/标签开关从 SkinGalleryViewController 迁出（T4），UserDefaults key 不变：
///   - 音效：`SoundManager.shared.isEnabled`（内部 key `soundEnabled`）
///   - 标签：`alwaysShowLabel`
/// 属 UI 位置迁移非逻辑回归（契约 5，SC-14 验证）。
final class GeneralSettingsViewController: NSViewController {

    private let soundSwitch = NSSwitch()
    private let soundLabel = NSTextField(labelWithString: "音效")
    private let alwaysShowLabelSwitch = NSSwitch()
    private let alwaysShowLabelLabel = NSTextField(labelWithString: "总是显示会话标签")
    private let launchAtLoginSwitch = NSSwitch()
    private let launchAtLoginLabel = NSTextField(labelWithString: "登录时自动启动")

    override func loadView() {
        // 固定初始 frame + 默认 autoresize（防 fittingSize 缩 0，patterns/2026-06-16）
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 580, height: 480))
        setupLayout(in: container)
        self.view = container
    }

    private func setupLayout(in container: NSView) {
        setupToggleRow(container: container,
                       label: soundLabel,
                       labelText: "音效",
                       switchControl: soundSwitch,
                       action: #selector(soundToggleChanged),
                       initialState: SoundManager.shared.isEnabled,
                       yOffset: -60)

        setupToggleRow(container: container,
                       label: alwaysShowLabelLabel,
                       labelText: "总是显示会话标签",
                       switchControl: alwaysShowLabelSwitch,
                       action: #selector(alwaysShowLabelToggleChanged),
                       initialState: UserDefaults.standard.bool(forKey: "alwaysShowLabel"),
                       yOffset: -100)

        setupToggleRow(container: container,
                       label: launchAtLoginLabel,
                       labelText: "登录时自动启动",
                       switchControl: launchAtLoginSwitch,
                       action: #selector(launchAtLoginToggleChanged),
                       initialState: LaunchAtLogin.isEnabled,
                       yOffset: -140)
    }

    /// 通用 toggle 行布局（label 左 + switch 右）。
    private func setupToggleRow(container: NSView,
                                label: NSTextField,
                                labelText: String,
                                switchControl: NSSwitch,
                                action: Selector,
                                initialState: Bool,
                                yOffset: CGFloat) {
        label.stringValue = labelText
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)

        switchControl.target = self
        switchControl.action = action
        switchControl.state = initialState ? .on : .off
        switchControl.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(switchControl)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 32),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 60 - yOffset),

            switchControl.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -32),
            switchControl.centerYAnchor.constraint(equalTo: label.centerYAnchor),
        ])
    }

    // MARK: - Actions（UserDefaults key 不变，契约 5 / SC-14）

    @objc private func soundToggleChanged(_ sender: NSSwitch) {
        SoundManager.shared.isEnabled = sender.state == .on
    }

    @objc private func alwaysShowLabelToggleChanged(_ sender: NSSwitch) {
        UserDefaults.standard.set(sender.state == .on, forKey: "alwaysShowLabel")
    }

    @objc private func launchAtLoginToggleChanged(_ sender: NSSwitch) {
        LaunchAtLogin.isEnabled = sender.state == .on
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
                NSLog("[LaunchAtLogin] toggle failed: \(error)")
            }
        }
    }
}
