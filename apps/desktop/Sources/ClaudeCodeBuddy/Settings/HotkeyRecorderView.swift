import AppKit
import Carbon.HIToolbox
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

    /// 自定义快捷键显示字符串，**不访问** KeyboardShortcuts.Shortcut.description（避免触发
    /// `keyToCharacter()` → `presentableDescription` → `"space_key".localized` → `Bundle.module` 崩溃）。
    private func displayString(for shortcut: KeyboardShortcuts.Shortcut) -> String {
        let modifierSymbols = modifierDisplayString(shortcut.modifiers)
        let keyChar = keyCodeToDisplayChar(shortcut.carbonKeyCode)
        return modifierSymbols + keyChar
    }

    /// 修饰键 → 符号字符串（⌘⌥⌃⇧）
    private func modifierDisplayString(_ flags: NSEvent.ModifierFlags) -> String {
        var result = ""
        if flags.contains(.control) { result += "⌃" }
        if flags.contains(.option) { result += "⌥" }
        if flags.contains(.shift) { result += "⇧" }
        if flags.contains(.command) { result += "⌘" }
        return result
    }

    /// Carbon key code → 显示字符（直接调 Carbon API，不走 KeyboardShortcuts 库的 keyToCharacter）
    private func keyCodeToDisplayChar(_ keyCode: Int) -> String {
        // 特殊键映射（不依赖库的 SpecialKey.presentableDescription / .localized）
        switch keyCode {
        case kVK_Space:          return "␣"
        case kVK_Return:         return "↩"
        case kVK_Delete:         return "⌫"
        case kVK_ForwardDelete:  return "⌦"
        case kVK_Escape:         return "⎋"
        case kVK_Tab:            return "⇥"
        case kVK_Home:           return "↖"
        case kVK_End:            return "↘"
        case kVK_PageUp:         return "⇞"
        case kVK_PageDown:       return "⇟"
        case kVK_UpArrow:        return "↑"
        case kVK_DownArrow:      return "↓"
        case kVK_LeftArrow:      return "←"
        case kVK_RightArrow:     return "→"
        case kVK_Help:           return "?⃝"
        case kVK_F1:  return "F1"
        case kVK_F2:  return "F2"
        case kVK_F3:  return "F3"
        case kVK_F4:  return "F4"
        case kVK_F5:  return "F5"
        case kVK_F6:  return "F6"
        case kVK_F7:  return "F7"
        case kVK_F8:  return "F8"
        case kVK_F9:  return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_F13: return "F13"
        case kVK_F14: return "F14"
        case kVK_F15: return "F15"
        case kVK_F16: return "F16"
        case kVK_F17: return "F17"
        case kVK_F18: return "F18"
        case kVK_F19: return "F19"
        case kVK_F20: return "F20"
        case kVK_ANSI_Keypad0: return "0⃣"
        case kVK_ANSI_Keypad1: return "1⃣"
        case kVK_ANSI_Keypad2: return "2⃣"
        case kVK_ANSI_Keypad3: return "3⃣"
        case kVK_ANSI_Keypad4: return "4⃣"
        case kVK_ANSI_Keypad5: return "5⃣"
        case kVK_ANSI_Keypad6: return "6⃣"
        case kVK_ANSI_Keypad7: return "7⃣"
        case kVK_ANSI_Keypad8: return "8⃣"
        case kVK_ANSI_Keypad9: return "9⃣"
        case kVK_ANSI_KeypadClear:    return "☒⃣"
        case kVK_ANSI_KeypadDecimal:  return ".⃣"
        case kVK_ANSI_KeypadDivide:   return "/⃣"
        case kVK_ANSI_KeypadEnter:    return "↩⃣"
        case kVK_ANSI_KeypadEquals:   return "=⃣"
        case kVK_ANSI_KeypadMinus:    return "-⃣"
        case kVK_ANSI_KeypadMultiply: return "*⃣"
        case kVK_ANSI_KeypadPlus:     return "+⃣"
        default: break
        }

        // 通用键：使用 UCKeyTranslate（Carbon API，不走 KeyboardShortcuts 库内路径）
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutDataPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return "�"
        }
        let layoutData = unsafeBitCast(layoutDataPointer, to: CFData.self)
        let keyLayout = unsafeBitCast(CFDataGetBytePtr(layoutData), to: UnsafePointer<UCKeyboardLayout>.self)
        var deadKeyState: UInt32 = 0
        let maxLength = 4
        var length = 0
        var characters = [UniChar](repeating: 0, count: maxLength)

        let error = UCKeyTranslate(
            keyLayout,
            UInt16(keyCode),
            UInt16(kUCKeyActionDisplay),
            0,
            UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            maxLength,
            &length,
            &characters
        )

        guard error == noErr, length > 0 else { return "�" }
        let string = String(utf16CodeUnits: characters, count: length)
        return string.capitalized
    }

    private func refreshDisplay() {
        let shortcut = KeyboardShortcuts.getShortcut(for: name)
        switch state {
        case .idle:
            if let shortcut {
                label.stringValue = displayString(for: shortcut)
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
