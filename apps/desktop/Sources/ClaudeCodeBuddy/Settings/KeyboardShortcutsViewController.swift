import AppKit
import KeyboardShortcuts

/// 热键设置 tab（Alfred 风格大 Recorder）。
///
/// 布局：标题「启动器热键」+ 大尺寸 RecorderCocoa + 当前 combo 大字回显 +「重置默认」按钮 + 冲突提示。
/// 遵循 SettingsTabClickReceiver 协议（虽然热键 tab 无点击转发需求，但保持一致性）。
///
/// 数据流：
///   - RecorderCocoa 录制 → 库 setShortcut → UserDefaults + 即时重注册 Carbon 热键
///   - 重置按钮 → KeyboardShortcuts.reset(.toggle)（回 default，非 setShortcut(nil)）
///   - combo 回显 → 观察 NotificationCenter.shortcutByNameDidChange → getShortcut
final class KeyboardShortcutsViewController: NSViewController {

    private let titleLabel = NSTextField(labelWithString: "启动器热键")
    private let subtitleLabel = NSTextField(labelWithString: "按下你想要的组合键来设置启动器全局热键")
    private let recorder: KeyboardShortcuts.RecorderCocoa
    private let comboLabel = NSTextField(labelWithString: "")
    private let defaultHintLabel = NSTextField(labelWithString: "")
    private let resetButton = NSButton(title: "重置默认 (Ctrl+Space)", target: nil, action: #selector(resetToDefault))
    private let conflictLabel = NSTextField(labelWithString: "")
    private var shortcutObserver: NSObjectProtocol?

    init() {
        // RecorderCocoa 的 onChange 闭包在 weak self 之外派发，避免 init 顺序问题
        self.recorder = KeyboardShortcuts.RecorderCocoa(for: LauncherHotkey.toggle, onChange: nil)
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
        // 固定初始 frame（对齐 SkinGalleryViewController 580x480）+ 默认 autoresize 填 panel。
        // 不设 translatesAutoresizingMaskIntoConstraints=false —— 否则 contentView 无尺寸约束会缩到
        // 子视图 fittingSize，导致热键 tab 显示区域过小、内容展示不全。
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 580, height: 480))
        view = container
        setupLayout(in: container)
        refreshComboDisplay()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // 观察 shortcut 变化（CLI/其他路径改键时同步回显）
        // 注：KeyboardShortcuts.shortcutByNameDidChange 是库 internal，用字符串字面量构造
        let notifName = Notification.Name("KeyboardShortcuts_shortcutByNameDidChange")
        shortcutObserver = NotificationCenter.default.addObserver(
            forName: notifName,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            // 仅当变化的是 launcher-toggle 时刷新
            if let name = notification.userInfo?["name"] as? KeyboardShortcuts.Name,
               name == LauncherHotkey.toggle {
                // queue:.main 保证主线程，assumeIsolated 安全
                MainActor.assumeIsolated { self.refreshComboDisplay() }
            }
        }
    }

    // MARK: - Layout

    private func setupLayout(in container: NSView) {
        // 标题样式
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(titleLabel)

        // 副标题
        subtitleLabel.font = .systemFont(ofSize: 13)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(subtitleLabel)

        // Recorder（大尺寸：宽 280pt、高 44pt）
        recorder.translatesAutoresizingMaskIntoConstraints = false
        recorder.font = .systemFont(ofSize: 17, weight: .medium)
        container.addSubview(recorder)

        // combo 大字回显
        comboLabel.font = .systemFont(ofSize: 28, weight: .bold)
        comboLabel.textColor = .labelColor
        comboLabel.alignment = .center
        comboLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(comboLabel)

        // default hint（显示是否为默认值）
        defaultHintLabel.font = .systemFont(ofSize: 12)
        defaultHintLabel.textColor = .tertiaryLabelColor
        defaultHintLabel.alignment = .center
        defaultHintLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(defaultHintLabel)

        // 重置按钮
        resetButton.translatesAutoresizingMaskIntoConstraints = false
        resetButton.bezelStyle = .rounded
        resetButton.controlSize = .regular
        resetButton.target = self
        container.addSubview(resetButton)

        // 冲突提示（库 Recorder 自带 alert，此处仅静态提示文字）
        conflictLabel.font = .systemFont(ofSize: 11)
        conflictLabel.textColor = .systemRed
        conflictLabel.alignment = .center
        conflictLabel.stringValue = "若热键不响应，可能被其他应用占用（如部分第三方输入法），请改键"
        conflictLabel.cell?.truncatesLastVisibleLine = false
        conflictLabel.cell?.wraps = true
        conflictLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(conflictLabel)

        NSLayoutConstraint.activate([
            // 标题
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 40),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 40),

            // 副标题
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            subtitleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 40),

            // Recorder（居中）
            recorder.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 30),
            recorder.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            recorder.widthAnchor.constraint(equalToConstant: 280),
            recorder.heightAnchor.constraint(equalToConstant: 44),

            // combo 回显
            comboLabel.topAnchor.constraint(equalTo: recorder.bottomAnchor, constant: 24),
            comboLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 40),
            comboLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -40),

            // default hint
            defaultHintLabel.topAnchor.constraint(equalTo: comboLabel.bottomAnchor, constant: 6),
            defaultHintLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 40),
            defaultHintLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -40),

            // 重置按钮
            resetButton.topAnchor.constraint(equalTo: defaultHintLabel.bottomAnchor, constant: 20),
            resetButton.centerXAnchor.constraint(equalTo: container.centerXAnchor),

            // 冲突提示
            conflictLabel.topAnchor.constraint(equalTo: resetButton.bottomAnchor, constant: 24),
            conflictLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 40),
            conflictLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -40),
        ])
    }

    // MARK: - Display Refresh

    /// 刷新 combo 回显 + default hint。MainActor：Shortcut.description 标注 @MainActor。
    @MainActor
    private func refreshComboDisplay() {
        let shortcut = KeyboardShortcuts.getShortcut(for: LauncherHotkey.toggle)
        let combo: String
        if let shortcut {
            combo = shortcut.description
        } else if let defaultShortcut = LauncherHotkey.toggle.defaultShortcut {
            // 理论上 getShortcut 不会返回 nil（库 reset 后回 default），兜底显示 default
            combo = defaultShortcut.description
        } else {
            combo = "(未设置)"
        }
        comboLabel.stringValue = combo

        let isDefault = isShortcutDefault(shortcut)
        defaultHintLabel.stringValue = isDefault ? "当前为默认热键" : "已自定义"
    }

    private func isShortcutDefault(_ shortcut: KeyboardShortcuts.Shortcut?) -> Bool {
        guard let shortcut, let defaultShortcut = LauncherHotkey.toggle.defaultShortcut else {
            return false
        }
        return shortcut == defaultShortcut
    }

    // MARK: - Actions

    /// 重置默认：调用 KeyboardShortcuts.reset(.toggle)（回 default，非 setShortcut(nil) 后者清除）。
    /// 库 reset 内部调 setShortcut(defaultShortcut, for: name) → 即时重注册 Carbon 热键。
    @objc @MainActor
    private func resetToDefault() {
        KeyboardShortcuts.reset(LauncherHotkey.toggle)
        refreshComboDisplay()
    }
}

// MARK: - SettingsTabClickReceiver

/// 热键 tab 无 collectionView 点击转发需求，但保持协议一致性（空实现）。
extension KeyboardShortcutsViewController: SettingsTabClickReceiver {
    func handleClickAt(windowPoint: NSPoint) {
        // no-op：热键 tab 无点击转发
    }
}
