import Foundation

/// action handler 闭集（v1）
enum ActionHandler: Equatable {
    case speak
    case copy
}

/// preprocess 后的段落单元：纯文本 or 可交互按钮
enum ActionSegment: Equatable {
    case text(String)
    case action(handler: ActionHandler, text: String, label: String)
}
