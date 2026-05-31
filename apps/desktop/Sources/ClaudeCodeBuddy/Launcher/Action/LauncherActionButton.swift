import Foundation

/// 按钮种类（render-only meta tool 闭集，后续渐增 kind）
enum LauncherActionKind: String, Equatable {
    case speak    // 朗读文本（TTS）
    case copy     // 复制到剪贴板

    /// 解析模型返回的 kind 字符串；未知 kind 返回 nil（soft-fail 丢弃）
    init?(rawValue raw: String) {
        switch raw {
        case "speak": self = .speak
        case "copy":  self = .copy
        default:      return nil
        }
    }

    /// 无 label 时的默认按钮文字
    var defaultLabel: String {
        switch self {
        case .speak: return "🔊 朗读"
        case .copy:  return "📋 复制"
        }
    }
}

/// 模型通过 `attach_action` meta tool 声明的一个交互按钮（render-only）。
/// 调用 tool ≠ 立即执行；它只是声明「在结果下方渲染一个按钮」，用户点击才触发。
struct LauncherActionButton: Equatable, Identifiable {
    let id = UUID()
    let kind: LauncherActionKind
    let text: String       // 按钮触发时作用的文本（要朗读的英文 / 要复制的内容）
    let label: String      // 按钮显示文字

    init(kind: LauncherActionKind, text: String, label: String? = nil) {
        self.kind = kind
        self.text = text
        if let label, !label.isEmpty {
            self.label = label
        } else {
            self.label = kind.defaultLabel
        }
    }

    /// 从 tool_call 的 JSON arguments 解析。text 缺失或 kind 未知时返回 nil（soft-fail）。
    static func from(argumentsJSON json: String) -> LauncherActionButton? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kindRaw = obj["kind"] as? String,
              let kind = LauncherActionKind(rawValue: kindRaw),
              let text = obj["text"] as? String, !text.isEmpty
        else { return nil }
        let label = obj["label"] as? String
        return LauncherActionButton(kind: kind, text: text, label: label)
    }

    // Equatable 忽略 id（基于内容比较，便于测试）
    static func == (lhs: LauncherActionButton, rhs: LauncherActionButton) -> Bool {
        lhs.kind == rhs.kind && lhs.text == rhs.text && lhs.label == rhs.label
    }
}
