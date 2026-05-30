<!-- tags: llm, markdown, action-tag, ui-interaction, plugin, launcher, swiftui, button, tts, copy, prompt-engineering, protocol-design, structured-output -->
# [2026-05-31] LLM 输出内嵌 `<action:*>` 标签 + 前端 MarkdownActionParser 渲染为 SwiftUI Button

## 场景
launcher plugin 输出 markdown 时，需要让用户对结果中的特定文本做交互动作（点击朗读英文、点击复制译文等）。

## 方案对比
| 方案 | 描述 | 问题 |
|---|---|---|
| A — 前端后处理 | LLM 输出纯 markdown，前端正则识别"英文段落"挂朗读按钮 | 启发式脆弱：哪段算"英文"？多语言混排时漏挂/错挂 |
| B — LLM 内嵌标签 ✓ | LLM 在 markdown 中显式标注 `<action:speak text="...">🔊</action>`，前端解析为按钮 | LLM 一次性输出含语义 + 交互；前端只做无逻辑渲染 |
| C — tool_use round-trip | 每个按钮一次 tool call | 多次往返，延迟 ×N，prompt mode 不适用 |

## 协议
LLM 输出形如：
```
**buddy** /ˈbʌdi/ <action:speak text="buddy">🔊</action>
n. 朋友；伙伴 <action:copy text="朋友；伙伴">📋</action>
```

前端 `MarkdownActionParser` 把每个 `<action:TYPE attr="...">label</action>` 解析成 `ActionSegment(type, attrs, label)`，由 `ActionSegmentsView` 渲染：`.speak` → `SpeechService.speak(text)`，`.copy` → `CopyService.copy(text)`。非 action 段保留为纯 markdown 渲染。

## 严格语法
- 闭合 XML：`<action:type attr="...">label</action>`
- 属性双引号，内部 `"` 写 `&quot;`
- type 枚举 `speak` / `copy`（白名单），未知 type → 渲染为字面文本（graceful failure）
- 嵌套不支持

## Why（关键好处）
1. **意图与交互同源**：哪段英文该读、哪段译文该复制——LLM 拥有完整语义上下文，前端没有；让 LLM 直接标注比前端启发式准确。
2. **prompt mode 友好**：无需 tool_use round-trip，一次 LLM 调用搞定输出 + 交互按钮，延迟与纯翻译相同。
3. **可扩展**：后续加 `<action:search>` `<action:open-url>` 只需新增 service + ActionSegment case，LLM 通过 systemPrompt few-shot 学新动作。
4. **graceful failure**：解析失败的标签退化为纯文本，不阻塞主输出（MarkdownActionParserGracefulFailureAcceptanceTests 覆盖）。

## How to apply
- 任何 LLM 输出需要"可点击交互"且**交互目标依赖语义**（不是固定 UI 元素）的场景，优先方案 B。
- 后处理（方案 A）只在交互目标可由语法/位置确定时（如"渲染所有 URL 为可点击链接"）才合适。
- systemPrompt 必须用 few-shot 示例教 LLM 输出 action 标签（见 [[2026-05-31-llm-fewshot-vs-template-placeholders]]），否则模型会忘标或写错语法。
- 与 [[2026-05-27-ai-router-system-prompt-prefix]] 配对：router prompt + plugin prompt 都遵循"LLM 直出结构化结果"思路。

## 代码锚点
- `apps/desktop/Sources/ClaudeCodeBuddy/Launcher/Action/MarkdownActionParser.swift`
- `apps/desktop/Sources/ClaudeCodeBuddy/Launcher/Action/ActionSegmentsView.swift`
- `apps/desktop/Sources/ClaudeCodeBuddy/Launcher/Service/SpeechService.swift`
- `apps/desktop/Sources/ClaudeCodeBuddy/Marketplace/plugins/translate/plugin.json` (systemPrompt 示范)
