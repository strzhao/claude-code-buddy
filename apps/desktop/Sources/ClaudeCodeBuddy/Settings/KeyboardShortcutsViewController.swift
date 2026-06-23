import AppKit
import Carbon.HIToolbox
import KeyboardShortcuts

/// 热键设置 tab。
///
/// 布局：标题「启动器热键」+ 副标题说明 + 绿色录制器卡片 +「重置默认」按钮 + 冲突提示。
/// 录制器 idle 态直接显示当前热键，点击进入录制态显示「按下组合键...」，输入完成后回显热键。
///
/// 数据流：
///   - HotkeyRecorderView 录制 → 库 setShortcut → UserDefaults + 即时重注册 Carbon 热键
///   - 重置按钮 → KeyboardShortcuts.reset(.toggle)（回 default，非 setShortcut(nil)）
final class KeyboardShortcutsViewController: NSViewController {

    private let titleLabel = NSTextField(labelWithString: "启动器热键")
    private let subtitleLabel = NSTextField(labelWithString: "按下你想要的组合键来设置启动器全局热键")
    private let recorder: HotkeyRecorderView
    private lazy var resetButton: NSButton = {
        let btn = NSButton(title: "", target: nil, action: #selector(resetToDefault))
        btn.bezelStyle = .rounded
        btn.controlSize = .regular
        btn.target = self
        return btn
    }()
    private let conflictLabel = NSTextField(labelWithString: "")
    private var shortcutObserver: NSObjectProtocol?

    init() {
        self.recorder = HotkeyRecorderView(for: LauncherHotkey.toggle)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let observer = shortcutObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Lifecycle

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 580, height: 480))
        view = container
        setupLayout(in: container)
        refreshDisplay()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let notifName = Notification.Name("KeyboardShortcuts_shortcutByNameDidChange")
        shortcutObserver = NotificationCenter.default.addObserver(
            forName: notifName,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let name = notification.userInfo?["name"] as? KeyboardShortcuts.Name,
                  name == LauncherHotkey.toggle else { return }
            MainActor.assumeIsolated { self.refreshDisplay() }
        }
    }

    // MARK: - Layout

    private func setupLayout(in container: NSView) {
        titleLabel.font = SettingsTheme.titleFont()
        titleLabel.textColor = SettingsTheme.titleColor()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(titleLabel)

        subtitleLabel.font = SettingsTheme.rowSubtitleFont()
        subtitleLabel.textColor = SettingsTheme.rowSubtitleColor()
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(subtitleLabel)

        recorder.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(recorder)

        resetButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(resetButton)

        conflictLabel.font = SettingsTheme.footnoteFont()
        conflictLabel.textColor = SettingsTheme.warningColor
        conflictLabel.alignment = .center
        conflictLabel.stringValue = "当前未设置热键，启动器将无法通过快捷键唤起"
        conflictLabel.isHidden = true
        conflictLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(conflictLabel)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor,
                                            constant: SettingsTheme.groupTopInset + 20),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor,
                                                constant: SettingsTheme.contentPadding),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor,
                                               constant: SettingsTheme.rowSpacing),
            subtitleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor,
                                                   constant: SettingsTheme.contentPadding),

            recorder.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor,
                                          constant: SettingsTheme.groupSpacing),
            recorder.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            recorder.widthAnchor.constraint(equalToConstant: 280),
            recorder.heightAnchor.constraint(equalToConstant: 44),

            resetButton.topAnchor.constraint(equalTo: recorder.bottomAnchor,
                                             constant: SettingsTheme.groupSpacing),
            resetButton.centerXAnchor.constraint(equalTo: container.centerXAnchor),

            conflictLabel.topAnchor.constraint(equalTo: resetButton.bottomAnchor,
                                               constant: SettingsTheme.groupSpacing),
            conflictLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor,
                                                   constant: SettingsTheme.contentPadding),
            conflictLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor,
                                                    constant: -SettingsTheme.contentPadding),
        ])
    }

    // MARK: - Display Refresh

    @MainActor
    private func refreshDisplay() {
        let shortcut = KeyboardShortcuts.getShortcut(for: LauncherHotkey.toggle)

        // 重置按钮：动态构造默认值文案
        if let defaultShortcut = LauncherHotkey.toggle.defaultShortcut {
            let defaultCombo = Self.displayString(for: defaultShortcut)
            resetButton.title = "重置默认 (\(defaultCombo))"
        } else {
            resetButton.title = "重置默认"
        }

        // 冲突提示：仅当未设置（nil）时显示
        conflictLabel.isHidden = (shortcut != nil)
    }

    // MARK: - Safe Shortcut Display (delegates to HotkeyRecorderView)

    /// 自定义快捷键显示字符串，**不访问** Shortcut.description（避免 Bundle.module 崩溃）。
    static func displayString(for shortcut: KeyboardShortcuts.Shortcut) -> String {
        HotkeyRecorderView.modifierDisplayString(shortcut.modifiers)
            + HotkeyRecorderView.keyCodeToDisplayChar(shortcut.carbonKeyCode)
    }

    private func isShortcutDefault(_ shortcut: KeyboardShortcuts.Shortcut?) -> Bool {
        guard let shortcut, let defaultShortcut = LauncherHotkey.toggle.defaultShortcut else {
            return false
        }
        return shortcut == defaultShortcut
    }

    // MARK: - Actions

    /// 重置默认：调用 KeyboardShortcuts.reset(.toggle)（回 default，非 setShortcut(nil) 后者清除）。
    @objc @MainActor
    private func resetToDefault() {
        KeyboardShortcuts.reset(LauncherHotkey.toggle)
        refreshDisplay()
    }
}

// MARK: - SettingsTabClickReceiver

extension KeyboardShortcutsViewController: SettingsTabClickReceiver {
    func handleClickAt(windowPoint: NSPoint) {
        // no-op：热键 tab 无点击转发
    }
}
