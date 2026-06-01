# AI 路由器 system prompt 拼 user message 前缀 + 强约束输出 — provider 协议无 system 字段的稳健替代

<!-- tags: ai-router, system-prompt, llm-routing, user-message-prefix, plugin-selection, anthropic, structured-output, hallucinate-fallback, provider-abstraction, narrowcandidates -->
**Scenario**: task 005 实现 LauncherRouter — keyword 缩候选 → AI 选 1 个 plugin（或 directChat）。挑战：项目 LauncherProvider 协议（task 002）`send(messages:tools:model:)` 不暴露独立的 Anthropic API `system` 字段（top-level message）。系统 prompt（router 指令 + 可用候选列表）无处放置；如果让 Provider 协议加 `system: String?` 是跨接口扩展，工作量大且影响所有现有 send 调用方。
**Lesson**: 解决方案：**把 system prompt 拼成 user message 的前缀**，同一消息内追加 user query：
```
User-Message Content:
  You are a router. Given a user query, decide which plugin to use (or none for direct chat).
  Available plugins:
  - translate: 中英文翻译插件 (keywords: 翻译, translate)
  - weather: 天气查询 (keywords: 天气, weather)

  Reply ONLY with the plugin name (e.g. "translate"), or "NONE" for direct chat. No other text.

  User query: 请翻译这段：Hello world
```
配合 **3 层稳健性兜底**：① "Reply ONLY with..." 强约束输出格式 ② 响应后 `trimmingCharacters(in: .whitespacesAndNewlines)` 去空白 ③ `candidates.first(where: { $0.name == answer })` 不匹配则 fallback `.directChat`（LLM hallucinate 不存在 plugin 名时不卡死）。trade-off：claude-haiku/sonnet 级别模型对 system 字段 vs user 前缀差异不显著（router 仅做分类，不是复杂推理），可接受；超大规模或精确 routing 任务可未来给 Provider 协议加 `system: String?` 字段（YAGNI 留 v2+）。**关键**：测试 mutation 探针必须覆盖 `XCTAssertEqual(provider.callCount, 0)` for empty candidates（不浪费 token）+ `XCTAssertEqual(decision, .directChat)` for hallucinate 兜底场景。
**Evidence**: task 005 LauncherRouter.aiSelect 实现 + 注释完整 trade-off 文档；LauncherRouterAiSelectTests 6 场景全覆盖（empty/NONE/选中/hallucinate/trim/empty 字符串）；qa-reviewer 简化版自审通过；contract-checker 0 mismatches；qa Wave 1.5 9/9 真实场景含中文 query 验证。
