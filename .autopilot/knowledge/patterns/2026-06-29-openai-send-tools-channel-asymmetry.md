# OpenAICompatibleProvider 非流式 send 与流式 sendStream 的 tools 支持不对称

**日期**: 2026-06-29
**tags**: launcher, openai-compatible-provider, tool-use, send-vs-sendstream, tool-calls, dry-run, verify-before-assume, plan-reviewer, blocker, qwen, launcher-agent, hidden-bug

## 教训（Lesson）
`OpenAICompatibleProvider` 有两条 send 路径，**tools 支持不对称**：
- **流式 `sendStream`**（OpenAICompatibleProvider.swift:95-158）：支持 tools（:129 `tools.map(OAITool.init)`）+ 解析 tool_calls，但映射成 render-only `.action` 按钮（speak/copy）。
- **非流式 `send`**（:22-91）：**完全不支持 tools**——`OAIRequestBody`（:246-267）无 tools/tool_choice 字段，:90 只返回 `[.text(text)]`，`OAIResponseChoice.message`（:349-357）连 tool_calls 字段都没声明。tools 参数被**静默丢弃**。

## 触发场景（Choice that triggered）
实现 selectWithTools 时，我（和 explore agent）**假设** `provider.send` 支持 tools——因为流式 sendStream 支持、且 dry-run 探针证实 qwen 端点能吐 tool_calls。plan-reviewer 第 1 轮独立读源码才发现 BLOCKER-1：selectWithTools 复用 send 传 tools 会被静默丢弃 → LLM 收不到工具 → 永不返回 tool_calls → 硬指标必然失败。

## 失败模式（Failure）
1. **dry-run 结论不能外推到未读的代码通道**：dry-run 探针直接打 qwen HTTP 端点（`/v1/chat/completions` + tools），证实端点能吐 tool_calls。但这 ≠ app 内 `provider.send` 的代码路径会序列化 tools + 解析 tool_calls。探针绕过了被测代码。
2. **附带暴露隐藏 bug**：`LauncherAgent`（调 send）+ qwen 的 stdin tool-use loop **一直坏着**（:34 注释"tool_calls 留 task 003"），因为 send 丢 tools，loop 永远走不到 tool_use 早停。该 bug 长期未被发现（只对 Anthropic provider 有效）。

## 应用（How to apply）
- 新增任何 tool-use 调用路径前，**grep 核实目标 provider.send 真的序列化 tools + 解析 tool_calls**（看 RequestBody 有无 tools CodingKey + Response 有无 tool_calls 解码），不要因"流式支持/端点支持"就假设非流式也支持。
- dry-run 探针打的是协议端点，**不能替代对 app 内 provider 代码路径的核实**——dry-run 验证的是"模型+端点能力"，代码路径核实验证的是"app 真把 tools 发出去且解析回来"。两者都要。
- 关联记忆 `root-cause-before-fixes`（先实测根因再修）+ `local-qwen-needs-enumerated-tool-desc`（dry-run 为准）。
