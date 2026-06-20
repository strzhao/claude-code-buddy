import AppKit
import KeyboardShortcuts

/// 自定义快捷键录制器，不依赖 KeyboardShortcuts 库的 RecorderCocoa（避免 Bundle.module 崩溃）。
///
/// 用法：
/// ```swift
/// let recorder = HotkeyRecorderView(for: .toggleUnicornMode, onChange: { shortcut in
///     print("New shortcut: \(shortcut?.description ?? "nil")")
/// })
/// ```
final class HotkeyRecorderView: NSView {

    // MARK: - Types

    enum State {
        case idle       // 显示当前快捷键，等待点击
        case recording  // 等待用户按下组合键
    }

    // MARK: - Properties

    private let name: KeyboardShortcuts.Name
    private let onChange: ((KeyboardShortcuts.Shortcut?) -> Void)?

    private var state: State = .idle {
        didSet {
            updateAppearance()
        }
    }

    private let label = NSTextField(labelWithString: "")
    private let clearButton = NSButton(title: "✕", target: nil, action: nil)
    private var shortcutObserver: NSObjectProtocol?

    // MARK: - Init

    init(
        for name: KeyboardShortcuts.Name,
        onChange: ((KeyboardShortcuts.Shortcut?) -> Void)? = nil
    ) {
        self.name = name
        self.onChange = onChange
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 44))
        setupView()
        refreshDisplay()
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

    // MARK: - View Setup

    private func setupView() {
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 2

        // 标签：显示当前快捷键
        label.font = .systemFont(ofSize: 17, weight: .medium)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isBezeled = false
        label.isEditable = false
        label.drawsBackground = false
        label.backgroundColor = .clear
        label.textColor = .labelColor
        addSubview(label)

        // 清除按钮
        clearButton.bezelStyle = .inline
        clearButton.isBordered = false
        clearButton.font = .systemFont(ofSize: 13, weight: .bold)
        clearButton.target = self
        clearButton.action = #selector(clearShortcut)
        clearButton.toolTip = "清除快捷键"
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        clearButton.isHidden = true
        addSubview(clearButton)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(lessThanOrEqualTo: clearButton.leadingAnchor, constant: -4),

            clearButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            clearButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            clearButton.widthAnchor.constraint(equalToConstant: 24),
            clearButton.heightAnchor.constraint(equalToConstant: 24),
        ])

        updateAppearance()

        // 点击进入/退出录制状态
        let clickGesture = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
        addGestureRecognizer(clickGesture)

        // 观察外部 shortcut 变更（CLI 等路径）
        // 注意：KeyboardShortcuts.shortcutByNameDidChange 是 internal，用字符串字面量
        shortcutObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("KeyboardShortcuts_shortcutByNameDidChange"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let changedName = notification.userInfo?["name"] as? KeyboardShortcuts.Name,
                  changedName == self.name else { return }
            self.refreshDisplay()
        }
    }

    // MARK: - Responder Chain

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            state = .recording
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        state = .idle
        return result
    }

    override func keyDown(with event: NSEvent) {
        guard state == .recording else {
            super.keyDown(with: event)
            return
        }

        // Escape 取消录制
        if event.keyCode == 53 { // kVK_Escape
            state = .idle
            window?.makeFirstResponder(nil)
            return
        }

        // 需要至少一个 modifier key
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard !modifiers.isEmpty else {
            // 纯字母/数字键无 modifier，忽略（匹配 RecorderCocoa 行为）
            return
        }

        guard let shortcut = KeyboardShortcuts.Shortcut(event: event) else {
            return
        }

        KeyboardShortcuts.setShortcut(shortcut, for: name)
        onChange?(shortcut)
        refreshDisplay()
        state = .idle
        window?.makeFirstResponder(nil)
    }

    override func mouseDown(with event: NSEvent) {
        guard state == .idle else {
            super.mouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
    }

    // MARK: - Actions

    @objc private func handleClick() {
        if state == .idle {
            window?.makeFirstResponder(self)
        } else {
            state = .idle
            window?.makeFirstResponder(nil)
        }
    }

    @objc private func clearShortcut() {
        KeyboardShortcuts.setShortcut(nil, for: name)
        onChange?(nil)
        refreshDisplay()
    }

    // MARK: - Display

    private func refreshDisplay() {
        let shortcut = KeyboardShortcuts.getShortcut(for: name)
        switch state {
        case .idle:
            if let shortcut {
                label.stringValue = shortcut.description
                clearButton.isHidden = false
            } else {
                label.stringValue = "点击录制快捷键"
                clearButton.isHidden = true
            }
        case .recording:
            label.stringValue = "按下组合键..."
            clearButton.isHidden = true
        }
        onChange?(shortcut)
    }

    private func updateAppearance() {
        switch state {
        case .idle:
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
            label.textColor = KeyboardShortcuts.getShortcut(for: name) != nil
                ? .labelColor
                : .secondaryLabelColor
        case .recording:
            layer?.backgroundColor = NSColor.controlBackgroundColor.blended(withFraction: 0.3, of: .systemBlue)?.cgColor
                ?? NSColor.controlBackgroundColor.cgColor
            layer?.borderColor = NSColor.systemBlue.cgColor
            label.textColor = .labelColor
        }
    }
}
