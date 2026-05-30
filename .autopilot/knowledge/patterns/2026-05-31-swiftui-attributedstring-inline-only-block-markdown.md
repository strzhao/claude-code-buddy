<!-- tags: swiftui, attributedstring, markdown, inline-only, block, heading, list, parsing-options, rendering, preprocess, launcher -->
# [2026-05-31] SwiftUI `AttributedString.MarkdownParsingOptions.inlineOnly*` 不消化 block markdown，需预处理

## 现象
SwiftUI 用 `Text(AttributedString(markdown:options:))` 渲染 LLM 输出的 markdown，发现 `### 中文释义` 显示成**字面** `### 中文释义`，`- 朋友` 显示成 `- 朋友`，未被解析为标题/列表。但 `**buddy**` 加粗正常生效。

## 根因
`AttributedString.MarkdownParsingOptions.InterpretedSyntax` 只有两种：
- `.inlineOnly` / `.inlineOnlyPreservingWhitespace`：**只解析行内语法**（`**bold**` / `_italic_` / `[link]()`）；block 级（`#` heading、`-`/`*` list、`---` rule）**保留为字面文本**
- `.full`：解析所有；但 SwiftUI `Text` 视图**不**根据 `presentationIntent` attribute 自动渲染成大字号标题或缩进列表项，需要自定义渲染逻辑（极麻烦）

实务上：`.full` 视觉上和 `.inlineOnly` 区别不大，块级语法仍然不显示成「真正的标题样式」，且会丢失换行。

## 修复（行级预处理）
保持 `.inlineOnlyPreservingWhitespace`，先把 block 语法转成视觉等价的 inline：
```swift
private static func preprocessBlockMarkdown(_ raw: String) -> String {
    raw.components(separatedBy: "\n").map { line -> String in
        // ATX heading `### foo` (任意 #) → **foo**（粗体替代标题）
        if let m = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
            return "**\(String(line[m.upperBound...]).trimmingCharacters(in: .whitespaces))**"
        }
        // 无序列表 `- foo` / `* foo` → `• foo`（保留缩进）
        if let m = line.range(of: #"^(\s*)[-*]\s+"#, options: .regularExpression) {
            let indent = line.prefix { $0.isWhitespace }
            return "\(indent)• \(String(line[m.upperBound...]))"
        }
        // 分割线 `---` / `***` → `─────`
        if line.range(of: #"^\s*(-{3,}|\*{3,})\s*$"#, options: .regularExpression) != nil {
            return "─────"
        }
        // 数字列表 `1. foo` 保留（视觉上已 OK）
        return line
    }.joined(separator: "\n")
}
```

## 触发条件
- LLM 输出包含 block markdown（heading / list / rule）— 任何"自由发挥"型 systemPrompt 都极易触发，模型默认就爱用 `### 标题` 组织答案
- 之前 5-few-shot 模板下没暴露此 bug 是因为示例没用 block 语法，模型照搬

## How to apply
- 用 `AttributedString(markdown:)` + SwiftUI `Text` 渲染 LLM 输出 → **必须**在 parse 前预处理 block 语法
- 替代方案：换 swift-markdown-ui（外部依赖，支持完整 block 渲染），但本项目避依赖故选预处理
- 不要错以为 `.full` 能解决 — Apple `AttributedString` 的 block 渲染需 SwiftUI 自定义视图配合，单 `Text` 不行

## 关联
- 与 [[2026-05-31-llm-embedded-action-tag-protocol]] 配合：action 标签是 inline 自定义语法，已通过 MarkdownActionParser 在 parse 前切段，不冲突
- P0.5 prompt 极简化暴露此既存 bug — 模板时代被掩盖
