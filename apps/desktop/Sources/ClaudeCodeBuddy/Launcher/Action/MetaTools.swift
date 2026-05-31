import Foundation

/// 框架内置的 render-only meta tools。
///
/// 这些工具自动注入给 prompt mode 的 LLM 调用（含默认流和所有 prompt 插件），插件无需声明、白拿。
/// 语义关键点：调用 tool ≠ 立即执行动作 —— 它只是「声明一个按钮」，UI 渲染成可点击入口，
/// 用户点击后才真正朗读/复制。这与 agent/stdin mode 的「真执行 + 回灌结果」工具语义相反。
enum MetaTools {

    /// `attach_action`：为回答附加可点击按钮（speak 朗读 / copy 复制）。
    /// description 采用枚举式锚点风格 —— 本地 qwen 等较弱模型在「列触发准则」下比「讲抽象原则」更稳
    /// （见 dry-run 结论：内核式原则写法会导致该挂不挂、不该挂乱挂）。后续加 kind 只需补一行。
    ///
    /// 刻意【不暴露 label 字段】：label 是纯表现层，由 UI 侧 `LauncherActionKind.defaultLabel`
    /// 固定提供（🔊 朗读 / 📋 复制）。dry-run 实测：一旦在 schema 里给出 label 的 emoji+文案示例，
    /// 弱模型会把这套词汇抄进正文（如「📋 复制译文：…」），属于把按钮表现泄漏成内容。模型只决定
    /// kind + text，字段越少越稳，按钮文案也因此统一、可控、有品牌一致性。
    static let attachAction = AgentTool(
        name: "attach_action",
        description: """
        为回答里【可被反复使用的具体产物】附加可点击按钮。这不会立即执行，只渲染按钮，用户点击才触发。可多次调用以附加多个按钮。

        何时调用：
        - 朗读(speak)：回答里出现的每一段英文（单词、译文、例句）都值得配一个朗读按钮。
        - 复制(copy)：用户大概率会拿去用的成品——译文、改写后的句子、代码、命令、计算结果。

        何时【不要】调用：
        - 没有具体产物时（如闲聊、安慰、追问、纯解释、操作步骤说明），不要附加任何按钮。
        - 不要为零碎片段（半句话、单个数字、解释性文字）附加复制按钮。

        只通过本工具产出按钮：不要在正文里写任何 <action> 标签，也不要在正文里描述或罗列这些按钮。
        """,
        inputSchema: [
            "type": AnyCodable("object"),
            "properties": AnyCodable([
                "kind": [
                    "type": "string",
                    "enum": ["speak", "copy"],
                    "description": "speak=朗读英文(TTS)；copy=复制到剪贴板"
                ] as [String: Any],
                "text": [
                    "type": "string",
                    "description": "按钮触发时作用的文本：speak 时为要朗读的英文，copy 时为要复制的内容"
                ] as [String: Any]
            ] as [String: Any]),
            "required": AnyCodable(["kind", "text"])
        ]
    )

    /// prompt mode 默认注入的全部 meta tools。
    static let all: [AgentTool] = [attachAction]
}

/// 默认流（directChat）的 system prompt —— Buddy 万能输入框人格。
/// 用户未命中任何插件、或路由判定直接对话时使用。极简单一指令骨架（不枚举场景），
/// 让模型自适应翻译/查词/问答/改写/代码等任意输入；attach_action meta tool 负责按钮。
enum DefaultAgentPrompt {
    static let system = """
    你是 Buddy——一个 AI 助手，一个万能输入框：用户把任何东西丢进来——一个问题、一段要改的文字、一道题、一段代码、一个要查的词、一句要翻的话、一个临时的念头——你看懂他要什么，直接给最有用的结果。

    # 核心
    - 先判断意图，直接交付。不复述输入、不寒暄、不预告你要做什么。
    - 拿不准时按最常见的意图做，不反问。
    - 输出为 markdown，用加粗和分条让结果一眼可扫；不堆砌格式。

    # 语言
    - 用用户的语言回答（默认中文）。
    - 涉及中英互译/查词时：中文给地道英文，英文给中文释义与例句。

    # 长度
    - 直接给答案，不写前言后语；能一句话说清就别用三句。
    - 简单查询控制在 100 字内，需要展开再展开。
    """
}
