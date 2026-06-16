import AppKit
import KeyboardShortcuts

/// 热键参数映射器：socket/CLI 传入的字符串 key/modifiers → KeyboardShortcuts.Key / NSEvent.ModifierFlags。
///
/// 设计：结构化参数（对齐 HotkeyConfig{key,modifiers} 语义），非「任意键码」。
/// key 用小写可读名（如 "space"/"a"/"f1"）；modifiers ∈ {command,shift,control,option}。
///
/// 用途：QueryHandler hotkey_set 命令参数校验 + 转换。CLI（buddy-cli）不依赖 BuddyCore，
/// 故 CLI 侧仅做「字符串合法性校验」，真正的 Key 构造在 app 侧完成。
enum HotkeyKeyMapper {

    /// 字符串 key → KeyboardShortcuts.Key。
    /// 返回 nil 表示未知 key（hotkey_set 应返回 error）。
    /// 支持：字母 a-z、数字 zero-nine 或 0-9、space、return、tab、escape、delete、方向键、f1-f20 等。
    static func key(from string: String) -> KeyboardShortcuts.Key? {
        let normalized = string.lowercased()

        // 字母 a-z
        if normalized.count == 1, let char = normalized.first, char.isLetter, char.isASCII {
            return keyForLetter(char)
        }
        // 数字 0-9（支持 "0".."9" 或 "zero".."nine"）
        if let digit = normalized.first, normalized.count == 1, digit.isNumber {
            return keyForDigit(digit)
        }
        // 数字单词
        if let wordDigit = wordToDigit(normalized) {
            return keyForDigit(wordDigit)
        }

        // 命名键（与 KeyboardShortcuts.Key 静态属性对齐）
        switch normalized {
        case "space": return .space
        case "return", "enter": return .return
        case "tab": return .tab
        case "escape", "esc": return .escape
        case "delete", "backspace": return .delete
        case "deleteforward", "fn-delete": return .deleteForward
        case "home": return .home
        case "end": return .end
        case "pageup": return .pageUp
        case "pagedown": return .pageDown
        case "uparrow", "up": return .upArrow
        case "downarrow", "down": return .downArrow
        case "leftarrow", "left": return .leftArrow
        case "rightarrow", "right": return .rightArrow
        case "f1": return .f1
        case "f2": return .f2
        case "f3": return .f3
        case "f4": return .f4
        case "f5": return .f5
        case "f6": return .f6
        case "f7": return .f7
        case "f8": return .f8
        case "f9": return .f9
        case "f10": return .f10
        case "f11": return .f11
        case "f12": return .f12
        case "f13": return .f13
        case "f14": return .f14
        case "f15": return .f15
        case "f16": return .f16
        case "f17": return .f17
        case "f18": return .f18
        case "f19": return .f19
        case "f20": return .f20
        case "comma": return .comma
        case "period", "dot": return .period
        case "slash": return .slash
        case "semicolon": return .semicolon
        case "quote": return .quote
        case "equal", "equals": return .equal
        case "minus", "hyphen": return .minus
        case "backslash": return .backslash
        case "backtick", "grave": return .backtick
        case "leftbracket", "[": return .leftBracket
        case "rightbracket", "]": return .rightBracket
        default: return nil
        }
    }

    /// 字符串 modifiers 数组 → NSEvent.ModifierFlags。
    /// 返回 nil 表示存在非法修饰键名（hotkey_set 应返回 error）。
    /// 合法值：command, shift, control, option（大小写不敏感）。
    static func modifiers(from strings: [String]) -> NSEvent.ModifierFlags? {
        var flags: NSEvent.ModifierFlags = []
        for s in strings {
            switch s.lowercased() {
            case "command", "cmd", "super": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "control", "ctrl": flags.insert(.control)
            case "option", "opt", "alt": flags.insert(.option)
            default: return nil  // 非法修饰键名 → 整体校验失败
            }
        }
        return flags
    }

    /// CLI 侧纯字符串校验：key 非空 + modifiers 全部 ∈ {command,shift,control,option}。
    /// CLI 不依赖 KeyboardShortcuts 库，故无法构造 Key；仅做语法校验，真正语义校验在 app 侧。
    static func validateCLI(key: String, modifiers: [String]) -> Bool {
        guard !key.isEmpty else { return false }
        let validModifiers: Set<String> = ["command", "cmd", "super", "shift", "control", "ctrl", "option", "opt", "alt"]
        for m in modifiers where !validModifiers.contains(m.lowercased()) {
            return false
        }
        return true
    }

    // MARK: - Private letter/digit mapping

    private static func keyForLetter(_ char: Character) -> KeyboardShortcuts.Key? {
        switch char {
        case "a": return .a
        case "b": return .b
        case "c": return .c
        case "d": return .d
        case "e": return .e
        case "f": return .f
        case "g": return .g
        case "h": return .h
        case "i": return .i
        case "j": return .j
        case "k": return .k
        case "l": return .l
        case "m": return .m
        case "n": return .n
        case "o": return .o
        case "p": return .p
        case "q": return .q
        case "r": return .r
        case "s": return .s
        case "t": return .t
        case "u": return .u
        case "v": return .v
        case "w": return .w
        case "x": return .x
        case "y": return .y
        case "z": return .z
        default: return nil
        }
    }

    private static func keyForDigit(_ char: Character) -> KeyboardShortcuts.Key? {
        switch char {
        case "0": return .zero
        case "1": return .one
        case "2": return .two
        case "3": return .three
        case "4": return .four
        case "5": return .five
        case "6": return .six
        case "7": return .seven
        case "8": return .eight
        case "9": return .nine
        default: return nil
        }
    }

    private static func wordToDigit(_ s: String) -> Character? {
        switch s {
        case "zero": return "0"
        case "one": return "1"
        case "two": return "2"
        case "three": return "3"
        case "four": return "4"
        case "five": return "5"
        case "six": return "6"
        case "seven": return "7"
        case "eight": return "8"
        case "nine": return "9"
        default: return nil
        }
    }
}
