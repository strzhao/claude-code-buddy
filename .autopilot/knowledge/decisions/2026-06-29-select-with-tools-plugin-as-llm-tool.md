# 社区插件作 LLM tool — selectWithTools 选择 pass 不执行

**日期**: 2026-06-29
**tags**: launcher, select-with-tools, llm-tool, tool-use, routing, openai-compatible, qwen, plugin, manifest-parameters, dry-run, enumerated-description

## 背景
要让所有「已开启社区插件」自动作为 LLM tool：用户输入自然语言（"生成二维码 https://example.com"），LLM 选对插件 + 提取参数 + 执行。硬指标=本地弱模型 qwen3.6-35b 执行成功率。

现状根因：`toAgentTool()` 把每个插件硬编码成同一个 `{query:"用户原始查询"}` schema；agent loop 只拿路由选中的 1 个插件作 tool。`pickWithAI`（旧路由第 2 阶段）是"reply with plugin name"弱文本提示，无法提取参数。

## 决策
1. **选择 pass 不执行**：`LauncherRouter.selectWithTools(query:plugins:)` 只返回 `(RouteDecision, extractedQuery:String?)`，**执行复用现有 withPlugin mode-switch**（已正确处理 command 图片/候选/stdin 回灌/prompt 单轮）。避免重造执行路径 + 解决 command 图片不能塞 `tool_result:String` 的张力。
2. **tool 集 = 所有开启的 stdin+command 插件**（非 keyword 缩窄子集），兑现"所有插件作 tool"。dry-run 证 8 工具含近邻干扰不塌方（选择 100%）。**prompt mode 暂排除**（自身 LLM 驱动，避免嵌套）。
3. **无 tool_use → .directChat**（tool_choice:"auto" 语义下模型不调 tool 即"无需插件"，不二次路由浪费 LLM 调用）；**hallucinate 名**（不在 plugins）→ .directChat。
4. **toAgentTool 重写**：description 用枚举模板（触发场景+何时不用+few-shot+参数填法，从 summary/description/keywords 合成）；inputSchema 优先 manifest 可选 `parameters`（强制顶层 type:object）否则回退固定 `{query}`。
5. **extractedQuery 映射**：固定 {query} 时 = `tool_call.input["query"]`，withPlugin 执行优先用它（`extractedQuery ?? stripKeywordPrefix(query)` 兜底）。

## 理由
dry-run 实测（探针打真实 qwen）：枚举式 description 选择正确率 90%（3 工具）/100%（8 工具）；固定 {query} 契约对弱模型足够（意图解析丢给确定性插件代码最稳）；tool-use 必须关 thinking（5s→0.45s）。

## 后果
- **附带修复**：P3.0 给非流式 `OpenAICompatibleProvider.send` 补 tools 通道，顺带修好 `LauncherAgent`（用 send）+ qwen 的 stdin tool-use loop（task 003 遗留的坏路径）。
- **延期**：空候选纯自然语言选插件（需折进 directChat 单轮）、prompt mode 作 tool、两阶段检索（>20 工具）、dispatch 完整 permission matrix。

## 关联
- 前置 dry-run 结论：`brainstorm.md` + 记忆 `local-qwen-needs-enumerated-tool-desc`
- BLOCKER-1 通道不对称教训：`patterns/2026-06-29-openai-send-tools-channel-asymmetry.md`
- 同类 launcher 路由决策：`2026-06-19-command-mode-image-channel-bypass-agent-loop.md`、`2026-06-20-command-mode-candidates-channel-submit-callback.md`
