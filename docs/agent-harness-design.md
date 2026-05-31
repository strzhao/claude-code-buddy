# Agent Harness 设计宪法

> 本文是 Claude Code Buddy 实现 agent（首要落地点：Launcher 的 AI 路由 / 插件 agent）的**设计原则与工业对照参考**。
>
> 两个一手来源（均为本仓库在 workspace 下的**兄弟仓库**，下文统一记作 `<workspace>/`，即 `~/workspace/`），二者互为印证：
>
> 1. **`<workspace>/learn-everything/topics/agent-harness-engineering/`** —— 从 v1 到 v12 逐个手写 harness 子系统的教学库（mini 实现 + 对照工业源码验证）。每个 artifact 含 `lesson.md` / `notes.md` / `excerpts.md` / `agent-vN-*.ts` / `run-log-*.txt`。
> 2. **`<workspace>/claude-code/src/`** —— Anthropic Claude Code CLI 工业级源码快照（~1900 文件，512K 行），harness 核心约 10K 行。
>
> **0 假设原则**（沿用 learn-everything 的铁律）：本文所有 `file:line` 引用均来自上述两个源码库的实读，不是凭命名推断。日后引用这些行号前，若涉及具体行为，请回源码核实——快照会漂移。下文标注的工业行号来自 2026-03-31 的 claude-code 快照与 learn-everything lesson 的引用。

---

## 目录

- [第一部分 · 元原则](#第一部分--元原则贯穿全系列)
- [第二部分 · 12 个子系统逐个拆解](#第二部分--12-个子系统逐个拆解)
- [第三部分 · 工业 harness 全景（claude-code）](#第三部分--工业-harness-全景claude-code)
- [第四部分 · Launcher agent 现状对照与演进路线](#第四部分--launcher-agent-现状对照与演进路线)
- [第五部分 · 落地检查清单](#第五部分--落地检查清单)

---

## 第一部分 · 元原则（贯穿全系列）

这些原则不属于任何单一子系统，而是整套 harness 反复兑现的设计律。**实现任何 agent 功能前先内化这五条。**

### 元原则 1：架构正交性 —— 每加一个子系统，前面的几乎字面不动

这是 learn-everything 全系列的主线，被显式编号验证了 **6 次**：

| 次 | 新增子系统 | 对既有子系统的改动 |
|---|---|---|
| 1 | v8 streaming | dispatch/hook/obs/compact/role-mode **零修改**，只在 `runRounds` 加一个分支 |
| 2 | v9 MCP | dispatch 只加 6 行 `name.startsWith(MCP_PREFIX)` 分流，其余 9 段**字面 0 修改**；obs「完全不知道 MCP 存在但自然命中」 |
| 3 | v10 system prompt cache | 新增 159 行，v9 核心不动 |
| 4 | v11 skill | 新增 ~165 行，5 个子系统字面不动；OBS 自动给 `tool_name=Skill` 打全 cardinality 标签 |
| 5-6 | v12 TodoWrite | 新增 115 行，dispatch/permission/hook/obs/compaction **一行核心都没改** |

**本质**：正交性来自三件事的组合——

1. **dispatch 同权**：所有 tool（内置 / MCP / Skill / TodoWrite）走同一条 dispatch 路径，没有特殊分支。
2. **旁路广播（hook）**：cross-cutting concern 通过统一事件总线挂载，不侵入核心。
3. **单一切面注入**：新维度（如 MCP 的外部来源）只穿过最小切面，其余管道自动覆盖。

> ⭐ **对本工程的指令**：先把 dispatch 同权切面固化下来（见元原则 2），此后每个新能力都是「加法」而非「改造」。如果你发现实现一个新 tool 需要改 dispatch 的核心逻辑，那是设计有问题的信号。

### 元原则 2：判决与执行分离（decide ≠ execute）

贯穿 permission（02）、mode matrix（03）、fork（04）：

- `decide()` 是**纯函数**：输入 `(tool, mode, role, input)`，输出 `{behavior, decisionReason}`。可单测、跨环境（CLI / IDE / swarm）共享。
- `execute()` / `askFn` 是**多态注入**：同一个 decide 结果，在不同 role 下注入不同的执行器（interactive 用 stdin，swarm-worker 用 mailbox 路由到 leader）。

工业证据：`permissions.ts:1262-1281` 返回 `{behavior:'allow', decisionReason:{type:'mode',mode}}`——**决定是行为、依据是数据，两层分开传 audit**。

### 元原则 3：安全不依赖 model 自觉

- v1（暴露 `ask_user` 工具 + 软引导 prompt）在 prompt injection 下 **1/4 次被绕过**——model 把决定权「还给」了注入的用户指令。
- v2（harness 在 dispatch 阶段强制拦截，model 完全不知情）100% 强制、可形式化审计。
- 工业同时保留两者（`src/hooks/toolPermission/` = v2 骨架，`AskUserQuestion` 工具 = v1 协作）——**不是冗余，是分工**：v2 拦不可逆动作（安全底线），v1 让 model 主动澄清语义模糊（多步组合攻击）。

> 推论：对一切外部输入（user / model / MCP server / plugin）永远当 untrusted。client 侧 permission gate 是补充不是替代 server 侧输入清洗（MCP 路径注入陷阱，见子系统 09）。

### 元原则 4：runtime 强契约 vs prompt 软契约

这是 LLM agent 工程独有的设计抉择：

- **可靠性关键**（permission 拦截、compact 删消息、tool 不可逆动作）→ 必须 **runtime 强制**，代码里硬拦。
- **行为纪律**（一次只做一件事、不谎报完成、持续用 todo）→ 用 **prompt 软契约**：文字引导 + reinforcement schedule + **保留 model agency**，runtime 不强制。

工业铁证：`TodoWriteTool.ts:65-103` 的 `call()` **零 validation**——「最多一个 in_progress」不变量 runtime 完全不强制，只在 prompt（`prompt.ts:158`）里写。`TodoListSchema` 也无 list-level refinement。

> 误用这条 = 要么把该硬拦的交给 prompt（破防），要么把该留 agency 的写死（model 变僵硬、学不会泛化）。

### 元原则 5：cross-cutting concern 走单一入口 + 机制层注入

fan-out / redact / cardinality 控制 **1 处实现**，杜绝「靠每个调用点自觉」的失败模式：

- 单一入口：`permissionLogging.ts:181` 注释字面 "Single entry point for all permission decision logging"。
- redact 在 sink 包装层 1 处（`events.ts:13-19`），不是业务层 N 处——否则与 v1 permission「靠 model 自觉」同源失败。

附带两条配套律：

- **必填 `reason` 字段**贯穿 hook handler / `DANGEROUS_uncached` cache / skill——强制 review-time disclaimer，runtime 不消费，逼开发者说清「为什么」。
- **dynamic 内容隔离**在 cache boundary 之后或走 attachment / `<system-reminder>`，避免污染长期命中的 prompt cache。

---

## 第二部分 · 12 个子系统逐个拆解

每个子系统按统一格式：**核心原则 → 工业对照（file:line）→ 教学简化差距 → 可复用 takeaway**。源码根：mini 版在 `../learn-everything/.../artifacts/`，工业版在 `../claude-code/src/`。

### 01 · Minimal Agent Loop —— 三角骨架

**核心原则**
- agent loop 的物理本质 = `fetch` + `messages` 拼接 + `while`，**无需任何 SDK**。「harness 不是 SDK，是协议 + 拼接」。
- 唯一终止信号是协议字段：`if (res.stop_reason !== "tool_use") break;`——Anthropic 协议规定的唯一退出条件。
- 工具的能力边界塑造 agent 行为：calculator 只允许 `{a,op,b}` 二元运算，就强制 "23×47+100" 分两轮 tool_use。

**工业对照**：SDK（`@anthropic-ai/sdk`）封装了这套拼接，代价是看不见 messages 每轮如何「长出来」。`tool_use.id` ↔ 下一轮 `tool_result.tool_use_id` 回引是模型配对调用与结果的物理依据。

**教学简化**：mini 版砍掉 SDK、抽象类、错误处理、流式。

**Takeaway**：实现 agent 前先手写一遍裸 loop（观察→反馈→决策三角）再用封装。messages 数组是**唯一真相源**——N 轮 loop = 2N 条消息（user/assistant 交替）。

> ✅ **Launcher 已实现**：`LauncherAgent.swift`（注释直写「v1 76 行 Swift 翻译」）。while + tool_use 早停 + `AsyncStream` 增量 yield，与本节完全对应。

### 02 · Permission Gate —— 双层正交权限

**核心原则**
- 安全不能依赖 model 自觉（见元原则 3）。
- harness gate 是骨架：dispatch 阶段强制拦截，model 不知情，100% 强制 + 可审计。
- `is_error: true` 是协议反馈通道：harness 拒绝后把 `{is_error:true, content:"User denied..."}` 拼回 messages，model 凭训练分布自然把拒绝转成诚实汇报——「harness 的 NO 给 model 一个明确锚点」。

**工业对照**：`src/hooks/toolPermission/`（harness gate）+ `AskUserQuestion` 工具（主动澄清），分工不冗余。

**教学简化**：v2 把双层正交压成「一个 if + 一个 readline」；`delete_file` 永远 mock 不真删。

**Takeaway**：production harness 必须双层正交。去掉 harness gate → injection 破防；去掉 ask tool → model 只能机械撞 gate。

### 03 · Mode Matrix —— `(tool × mode) → policy`

**核心原则**
- policy 是 runtime 决策不是 config 数据：「config 是行为的输入，dispatch 是行为本身」。
- 矩阵实现是**有序 if 链 + 早返回**，不是 M×N 查表：hard-block 优先 → ask_user 永远放行 → read 类永远安全 → bypass 放过其余 → acceptEdits 放过 edit → default 兜底 ask。
- **hard-block 防的是 user 自己**（不是 model、不是 injection）：user 开 bypass 万能开关时，harness 替其兜底极端路径（如 `/Library/...`），且 bypass-immune。

**工业对照**（lesson 照搬）
- `sdk-tools.d.ts:337` — mode 是 string union（工业 mode 不止 3 种：acceptEdits / auto / bypassPermissions / default / dontAsk / plan）
- `permissions.ts:1252-1260` — `safetyCheck` bypass-immune（返回 `ask` 而非直接拒绝）
- `permissions.ts:1230-1236` — `tool.requiresUserInteraction?.()` 钩子让每个工具自声明 bypass-immune（比硬编码工具名通用）
- `permissions.ts:1262-1281` — 决定与依据分两层传 audit
- `permissionLogging.ts:181` — 单一入口多维结构化事件
- `constants/prompts.ts:189` — system prompt 只说 "a user-selected permission mode"，model 对具体 mode 字符串无感

**教学简化**：v3 是 196 行扁平 dispatch + is_error；工业是 10+ 步有序 if 链 + 多维 `decisionReason`。

**Takeaway**：把 dispatch 拆成 `decide() → {behavior, decisionReason}` + `executeWithDecision()`。audit 升级为结构化事件，`source` 字段区分 `config` / `user_temporary` / `user_permanent` / `hard-block`。**bypass 模式下 audit 是灵魂——无 audit = 不可观测黑洞。**

### 04 · Subagent Fork —— agent-role 维度

**核心原则**
- agent-role 是**物理约束**维度（非软约束）：swarm-worker 的 tools schema 字面就没有 `ask_user` / `spawn_swarm`——model 训练分布里想调也调不到。
- 判决统一、执行多态：三种 role 共享同一 `modeMatrix`（role 参数加下划线前缀、不参与 policy），差异只在执行层注入不同 `askFn`。
- **context 从深度变广度**：每个 worker 独立 messages 数组、与 coordinator 无引用关系，只返回 summary string。worker 内部从 3 轮涨到 30 轮，coordinator 增量≈0。
- ask 向上路由：worker 无 stdin，`makeRoutedAsk(swarmId, parentAsk)` 把 ask 请求路由到 coordinator（mailbox + permission callback）。

**工业对照**
- `AgentTool`（`subagent_type=general-purpose`）= v4 fork sub-agent；`createSubagentContext({messages})` 独立 messages 数组 + 工具裁剪
- `swarmWorkerHandler.ts:67-123` — mailbox + Promise + callback registry（`createResolveOnce` + `claim` 做多回调竞争原子保证）
- `useCanUseTool.tsx:95-165` — 三层 handler 串行 try（coordinator / swarm / interactive）
- `coordinatorMode.ts:213` — 「Parallelism is your superpower... multiple tool calls in a single message」（并行是 model 在同一轮 emit 多个 spawn，`runRounds` 的 `Promise.all` 自然并发，**非 harness 显式编排**）

> **命名澄清**（lesson 2026-05-30 修订）：工业 "swarm" 字面 = "team" = **多进程持久化**协作（mailbox + 共享 task list + idle 状态机，`TeamCreateTool` / `utils/swarm/constants.ts:2`）。v4 实际是**同进程 fork sub-agent**（对应 `AgentTool`）。代码里 `swarm-worker`/`spawn_swarm`/`swarmId` 仅为 historical identifier。

**教学简化**：v4 用 in-process Promise + closure 替代跨进程 mailbox；省掉多回调原子竞争、callback 先注册防 race、跨进程通道。

**Takeaway**：`askFn` 参数注入是关键扩展点——in-process Promise 与工业 mailbox 接口语义一致，未来切跨进程只需替换 `makeRoutedAsk`，dispatch 和 runLoop 不动。**multi-agent 把 context 问题从深度爆变广度爆，同源同解。**

### 05 · Context Compactor —— token 经济 + 独立 sub-system

**核心原则**
- compaction 必须是**独立 sub-system** 不是 dispatch 一部分：只在 `runRounds` 末尾单点 `await maybeCompact(...)` 钩入。
- **round 是压缩的原子单位**：tool_use ↔ tool_result 由 `tool_use_id` 指针绑定，边界切错 → 「悬空 tool_result」API 报错。
- **事实 ≠ 原文（microCompact）**：旧 tool_result 原文是「冷状态」，model 已把信息融入后续 reasoning，可替换为 `[Old tool result content cleared]` 占位。
- **专用 compaction LLM call（fullCompact）**：传空 tools 数组 + `NO_TOOLS_PREAMBLE`，输出 `<analysis>+<summary>` 双段。
- 优先级链 **小→大、便宜→贵、留多→少**：先 microCompact（无 LLM 成本）再 fullCompact。

**工业对照**（`src/services/compact/`）
- `autoCompact.ts:62-90` — 3 层阈值 + 熔断器 `MAX_CONSECUTIVE_AUTOCOMPACT_FAILURES=3`；`AUTOCOMPACT_BUFFER_TOKENS=13_000`
- `autoCompact.ts:160-239` — sessionMemoryCompact → microCompact → autoCompact → apiMicrocompact 四级链
- `grouping.ts:22-63` — `groupMessagesByApiRound` 用 `assistant.message.id` 边界
- `microCompact.ts:36` — `TIME_BASED_MC_CLEARED_MESSAGE='[Old tool result content cleared]'`（mini 版一字不差引用）
- `prompt.ts:19-26` — `NO_TOOLS_PREAMBLE`（4.6 上 2.79% vs 4.5 上 0.01% 会违规调工具）
- `postCompactCleanup.ts:31-39` — `isMainThreadCompact` 按 querySource 分级清理，防 swarm compact 污染主线程

**教学简化 + 关键修正**：阈值静态 `MAX_ROUNDS_BEFORE_FULL_COMPACT=4`（工业按 token 估算）。⚠️ **v5 legacy microCompact 必炸 Anthropic byte-level prefix cache**（改了 client messages 内容）；工业有第二条路径 `microCompact.ts:295-303` cached microcompact（不动 client messages，请求加 `cache_edits` 协议块在 server KV 删，同时省 token + 保 cache，**仅 Anthropic 内部**）。公开 API 用户用 legacy 必炸 cache 是 inherent 局限。

**实测**：micro 释放率 ~4%（无 LLM 成本），full 释放率 ~20-28%（多一次 LLM call）。

**Takeaway**：messages 加 `isCompactSummary` meta；`callModel` 抽象成可注入接口（compaction 用更便宜 model）。三种 compaction 失败模式：(A) compaction call 自身耗光预算（防御：截断 6000 chars + 熔断器）；(B) compaction 后行为漂移（缓解：`KEEP_RECENT_ROUNDS` + boundary marker）；(C) 触发抖动（缓解：token buffer）。

### 06 · Hook Engine —— 事件总线（hook ≠ sub-system）

**核心原则**
- **hook ≠ sub-system**，判断准则：失败必须改变核心行为 → sub-system；失败只影响旁路观察 → hook。permission/compact 是 sub-system，audit/lint 是 hook。
- `Promise.allSettled` 做**失败隔离**：`emit = Promise.allSettled(handlers.map(runHandler))`——单 handler 失败不影响其他、emit 永不 throw；调用方再加 `.catch(()=>[])` 双重保险。
- **hook 是叠加不是替代**：`maybeCompact`（sub-system 入口）不动，在其内部 emit `PreCompact`/`PostCompact`（旁路广播）。去掉 hook compact 仍工作；去掉 `maybeCompact` compact 完全不发生。
- emit 是 **fire-and-forget**：dispatch 不消费 emit 返回值。

**工业对照**（`src/utils/hooks/`）
- `coreTypes.ts:25-53` — 精确 27 个 `HOOK_EVENTS`（PreToolUse / PostToolUse / PostToolUseFailure / PreCompact / PostCompact / PermissionRequest / SubagentStart / TaskCreated ... 7 大类）
- `AsyncHookRegistry.ts:28` — `Map<processId, PendingAsyncHook>`（hook 是异步 shell command，每次 emit 启独立 process）；`:144` 失败隔离
- 3 种 handler 形态：`execPromptHook.ts:21-30`（单轮 LLM JSON / 30s）、`execHttpHook.ts:123-150`（POST + SSRF guard / 10min）、`execAgentHook.ts:36-50`（多轮 LLM + tools / 60s）
- `ssrfGuard.ts` — DNS lookup 时校验防 DNS rebinding（含云元数据 `169.254.169.254`）

**实测黄金证据**（run-log-failing-hook）：5 个 handler 中 throws-immediately + slow-loris(300ms timeout) 失败，其余成功，**核心 dispatch 完整执行 ROUND 自然完成**——`Promise.allSettled` + `Promise.race(timeout)` + `.catch` 三层保险。

**Takeaway**：cross-cutting concern 统一为 `HookRegistry`（`Map<event, handler[]>`）+ critical path 单行 `await hooks.emit(event, ctx).catch(()=>[])`。0 注册时 zero overhead。**audit 从硬编码 console.error 重构为 `hooks.register("PostToolUse", logToOTel)`，是 Observability（07）的入口。**

### 07 · Observability —— logs / metrics / traces 三形态

**核心原则**
- 三形态（logs 异步导出 / metrics 异步聚合 / context map 同步 inspect）**消费时机不同 → 必须并存**，不是选一个。
- fan-out 必须在**单一入口**（见元原则 5）。
- redact 在 sink 包装层 1 处而非业务层 N 处。

**工业对照**
- 三 SDK 并存：`instrumentation.ts:14-26`（sdk-logs + sdk-metrics + sdk-trace-base）
- 单一入口：`permissionLogging.ts:181-235`，字面 "Single entry point"
- cardinality：`events.ts:49` "prompt ID to events but not metrics"，`events.ts:56-58` "filesystem paths too high-cardinality"
- privacy：`events.ts:13-19`，`OTEL_LOG_USER_PROMPTS` + `<REDACTED>`

**教学简化**：cardinality 工业用「代码约定 + code review」，v7 加强为 runtime 白名单强制拒绝。

**Takeaway**：metric label 只放低基数白名单（`tool_name/role/decision/mode/event/is_error`），高基数字段（file_path/user_question）只进 logs + context map。**obs 只观察不决策**，critical-path 决策本身仍是可靠 sub-system。

### 08 · Streaming —— pipelining

**核心原则**
- streaming = pipelining：model 输出与 tool 执行重叠，延迟从 `model + Σtool` 降到 `max(model, max tool)`。
- **yield order ≠ concat order**：下游用 `tool_use_id` 配对、`message.id` 做 round 边界，**绝不依赖数组位置**。
- `isConcurrencySafe` 区分可并行 vs 必须独占（Bash 失败 abort 兄弟）。

**工业对照**
- pipelining：`query.ts:838-843` `streamingToolExecutor.addTool(toolBlock, message)` 在 streaming loop 内调用
- yield order 字面证据：`grouping.ts:29-31` "interleaves tool_results... yield order, not concat order — see query.ts:613"
- abort drain 保协议完整：`query.ts:1019` 为未完成 tool 生成 synthetic error tool_result
- 工业 `StreamingToolExecutor.ts`（531 行）：addTool 立即启动 + isConcurrencySafe 并发控制 + abort/discard

**教学简化**：v8 先同步 callModel 再逐块 yield，model 阶段无法物理重叠 → savings≈0；真实 SSE 下 5-tool/500ms 可达 1.25x。

**Takeaway**：协议层 `tool_use_id` 配对是 streaming 能存在的前提——发送任意顺序、接收按 id 配对。tool mock 换真实 I/O 后 streaming 收益才显著。

> 🟡 **Launcher 部分实现**：`AgentEvent` AsyncStream + `OpenAICompatibleProvider.sendStream`（v0.5.0 SSE 流式）是 streaming 雏形，但只在单 tool 串行下跑，无 `isConcurrencySafe` 并发执行器。

### 09 · MCP —— 工具定义权外移

**核心原则**
- MCP = **工具定义权外移**（USB 时刻）：harness 只负责协议解析 + dispatch，tool 定义在外部 server。
- MCP tool 与内置 tool **同权复用全管道**：穿过 PreToolUse hook + permission gate + PostToolUse + obs fan-out。
- 3 层架构：transport(stdio) / 协议(JSON-RPC) / 集成(merge registry)；`initialize` lifecycle 不能跳过（version + capability 协商，类比 TLS ClientHello）。

**工业对照**
- stdio transport：`src/services/mcp/client.ts:944-958`
- `inputSchema` JSON Schema 规定：`spec.types.d.ts:1182-1189`（`type:"object"` + properties + required），与 Anthropic `input_schema` **零转换**复用
- dispatch 无 isMcp 分支：`MCPTool.call()` 签名与内置 tool 完全一样（对象多态）
- 三层 timeout 常量：`DEFAULT_MCP_TOOL_TIMEOUT_MS=100_000_000` / `MCP_REQUEST_TIMEOUT_MS=60000` / `getConnectionTimeoutMs=30000`；重连阈值 `MAX_ERRORS_BEFORE_RECONNECT=3`

**教学简化**：工业用 `@modelcontextprotocol/sdk`；v9 手写砍掉 Zod validation / 重连 / 多 transport / Progress / Elicitation / 三层 timeout——**最大代价：subprocess 死掉无法恢复**。

**Takeaway**：MCP server 是外部黑盒，**协议层不管 server 内部安全**（路径注入陷阱）。对外部输入永远当 untrusted。

> 💡 **与 Launcher 高度相关**：Launcher 的 plugin 体系（`Plugin/PluginManager`、`PromptExecutor`、stdin 协议）本质就是「工具定义权外移」的另一种形态。MCP 的「同权复用全管道」原则直接适用于 plugin agent——plugin tool 应与内置能力走同一条 dispatch / permission / obs 管道。

### 10 · System Prompt Assembly —— 动态装配 + cache 分割

**核心原则**
- system prompt 不是字符串，是 **build artifact**：拆 6 section，按变化频率独立缓存（webpack chunk 类比）。
- **memoization 默认开 + `DANGEROUS_uncached` 显式 opt-out**：易变 section（mcp_instructions）每轮重算；`_reason` 是 review-time 强制 disclaimer（runtime 不消费）。
- `DANGEROUS_uncached` **不绕过写入只跳过读取**（cache 始终有副本，「不是不缓存，是永远新鲜」）。

**工业对照**
- BOUNDARY sentinel 是 cache 物理分割点，`splitSysPromptPrefix` 返回 `{prefix, suffix}`；前缀 `scope:global` 跨组织共享，后缀会话隔离（`prompts.ts:106-115`）
- compact 后 `clearSystemPromptSections` 位于 post 阶段末尾：`postCompactCleanup.ts:62`（避免浪费已建立的 cache）

**教学简化**：v10 把 5 段放 BOUNDARY 之前是为让 cache hit/miss 在 audit 一目了然；**工业 dynamic sections 全在 BOUNDARY 之后**。

**Takeaway**：cache 边界切分让固定 prefix 长期命中 API prompt cache，易变内容隔离在 boundary 之后。**compact 改了 messages 必须 clear section cache**（语义因果链，非优化技巧：section compute 可能依赖旧上下文 → cached value stale）。

### 11 · Skill System —— 运行时行为策略注入

**核心原则**
- skill = **运行时可热插拔的行为策略注入**：丢 `SKILL.md` 到目录、重启即生效，内核不改一行（VSCode extension 类比）。
- 三种注入物：新 Skill tool + user-role text 注入（inline 返回 tool_result.content）+ 临时 allowed-tools merge 进 `skillAlwaysAllow`（`finally` 恢复是契约级安全网）。
- **shell 模板 = 加载期注入**（在 `getPromptForCommand` 内主进程跑），与 inline/fork **运行期隔离正交**。

**工业对照**
- 加载器：`loadSkillsDir.ts:407-480`；`context:fork` frontmatter：`loadSkillsDir.ts:260`
- skill_listing 走 **attachment 通道**（非 system prompt）：`attachments.ts:2661-2751` + `messages.ts:3097`，`wrapInSystemReminder` 包成 `<system-reminder>` prepend 进 user content；`sentSkillNames` Set 做 delta-dedup（首轮列全，后续只列新增）
- shell 模板：`promptShellExecution.ts:49-143`，**function replacer** 防 `$$/$&/$\`` 被解释
- MCP skill 强制跳过 shell 执行（`loadSkillsDir.ts:371-374`）= untrusted remote 安全边界

**inline vs fork**：inline = skill 内容注入主对话流，model 接续工作；fork = 子 agent 独立 context 跑完只返回摘要，避免大量 tool_result 污染主 agent（与 05 context-compactor 同源动机）。

**Takeaway**：dynamic listing 走 system-reminder/attachment 而非 cacheable system prompt（与 10 mcp_instructions DANGEROUS 同源）。五步流水线顺序不可换：Base dir 前缀 → `${CLAUDE_SKILL_DIR}` → `$ARGUMENTS` → shell → 分叉。

### 12 · TodoWrite —— 极简 state-set + 三层 reinforcement

**核心原则**
- 极简 state-set tool：`call()` **零 validation**（见元原则 4），行为全在 184 行 description。
- 自律是 prompt 软契约非 runtime validation——保留 model agency。
- **三层 reinforcement schedule** 对抗三种不同失败：

| 层 | 触发条件 | 载体 | 对抗的失败 |
|---|---|---|---|
| continuous | 每次调用 | tool_result 钉 "continue to use the todo list" | 即时跑偏 |
| fixed-interval | 缺席 N 轮 | 注入 `<system-reminder>` | 长程遗忘 |
| event-triggered | 收尾 3+ 项无 verification | 追加 verify nudge | 谎报完成 |

**工业对照**
- 哑执行体：`TodoWriteTool.ts:65-103` `call()`；`:69-70` allDone 清空；`types.ts` `TodoListSchema` **无 list-level refinement**
- fixed-interval 阈值：`attachments.ts:254-257`（`TURNS_SINCE_WRITE:10` / `TURNS_BETWEEN_REMINDERS:10`）
- **messages 数组即数据库无文件持久化**：`extractTodosFromTranscript` 倒扫 transcript 还原，不读任何 `.json`（与 05「messages 即真相」同精神）
- **per-agent 隔离**：`todoKey = agentId ?? sessionId`（与 04 multi-agent context 二分同源）

**Takeaway**：reminder 是 "gentle reminder, ignore if not applicable"——**提醒非命令**。区分点是「调用才触发」vs「缺席才触发」。

---

## 第三部分 · 工业 harness 全景（claude-code）

把 12 节子系统装进一个 production harness，claude-code 的实际拓扑（harness 核心约 10K 行）：

| # | 子系统 | 入口文件 | 规模 | 职责 |
|---|---|---|---|---|
| 1 | Query Loop | `query.ts` | 1729 行 | 主 agentic 循环：API 调用 → tool 执行 → token 预算 → 恢复路径 |
| 2 | QueryEngine | `QueryEngine.ts` | 1295 行 | 单会话生命周期 + message threading + 权限拒绝跟踪 |
| 3 | Tool 契约 | `Tool.ts` | 792 行 | discriminated union；`description()` 异步 context-aware + `execute()` streaming-first + `progressType` |
| 4 | Tool Registry | `tools.ts` | - | feature gate + `USER_TYPE` 条件加载 + lazy require 破循环依赖 + MCP runtime merge |
| 5 | Permission | `hooks/toolPermission/` | 150+ 行 | 4 层组合：config → hooks → classifier → dialog |
| 6 | Compaction | `services/compact/` | 1705 行 | eager(过阈值即发) + speculative + 子进程隔离 |
| 7 | Hooks | `utils/hooks.ts` | 3394+ 行 | 27+ 事件，async + 解耦，结果走 attachment |
| 8 | Multi-agent | `coordinator/` `tools/AgentTool/` | - | 隔离 context fork + coordinator/worker + team mailbox |
| 9 | MCP | `services/mcp/` | - | 外部 server 规整成内部 Tool 接口 |
| 10 | Skills | `skills/loadSkillsDir.ts` | - | 按 discovery 懒加载，prefetch 与 model 工作并发 |
| 11 | Memory | `memdir/` | - | `MEMORY.md` ≤200 行/25K 字节，按相关性懒加载 |

### query() 主循环每轮流程（`query.ts`）

`query()` 是 async generator，state 对象（`messages` / `toolUseContext` / `autoCompactTracking` / `maxOutputTokensOverride` / turn count）贯穿迭代，params 不可变：

1. **Skill prefetch**（`:331-335`）—— 在 model streaming 时并发触发
2. **API call**（`:337`）via `queryModelWithStreaming()`
3. **Tool 执行**（`:98` `runTools()`）—— streaming executor 编排
4. **Token 预算检查**（`:111` `checkTokenBudget()`）—— 触发 auto-compact 或 max-output-tokens 恢复
5. **Post-sampling hooks**（`:92`）
6. **Stop hooks**（`:93`）

7 个 continue 站点（reactive compact / microcompact / max-output-tokens 恢复 / tool retries），transition 用 `state.transition` 跟踪。

### 工业级横切模式

| 模式 | 实现 | 收益 |
|---|---|---|
| Feature Gates | `feature()`（bun:bundle dead code 消除） | 一份代码多变体，无运行时分支 |
| Async + Generator | `async function*` yield 事件 | 非阻塞，事件到达即消费，无缓冲 |
| Forked Subprocess | compaction / subagent 用 `runForkedAgent()` | 隔离 state 防污染主 context |
| Lazy Loading | 条件 require + skill prefetch | 启动快，按需加载 |
| Permission 组合 | config → hooks → classifier → dialog | 每层可独立满足决策，不阻塞下一层 |
| Attachment Deltas | compact 后只重注入新文件/skill | token 效率，避免冗余重注入 |

---

## 第四部分 · Launcher agent 现状对照与演进路线

> 首要落地点。当前实现位于 `apps/desktop/Sources/ClaudeCodeBuddy/Launcher/`。

### 现状盘点

| Harness 子系统 | Launcher 现状 | 实现位置 |
|---|---|---|
| 01 Agent loop | ✅ 已有（v1 翻译，while + tool_use 早停 + AsyncStream） | `Agent/LauncherAgent.swift`（105 行） |
| Tool 定义 | ✅ 三件套（name/description/input_schema） | `Agent/AgentTool.swift` |
| 08 Streaming | 🟡 雏形（AgentEvent AsyncStream + SSE，单 tool 串行） | `Agent/AgentEvent.swift` / `Provider/OpenAICompatibleProvider.swift` |
| Router/dispatch | ✅ keyword 缩候选 → 短路 → AI 选 1 | `LauncherRouter.swift`（140 行） |
| Provider 抽象 | ✅ 多 provider（Anthropic / OpenAI-compatible） | `Provider/` |
| 09 MCP-like（plugin 工具外移） | 🟡 plugin 体系已有 TOFU 信任，但 plugin tool **未走 agent dispatch 同权管道** | `Plugin/` |
| 02 双层 permission | ❌ agent 内 `toolExecutor` 无 permission gate | — |
| 03 Mode matrix | ❌ 无 | — |
| 04 Multi-agent fork | ❌ 无 | — |
| 05 Compaction | ❌ 靠 `maxIterations=10` 硬截断 | — |
| 06 Hook 总线 | ❌ 无（hook 是 Claude Code 插件方向，与 launcher agent 不同层） | — |
| 07 Observability | ❌ 无统一 fan-out | — |
| 10 System prompt 装配 | ❌ system 是裸字符串（router 里拼） | — |
| 11 Skill | ❌ 无（plugin 是最接近的形态） | — |
| 12 TodoWrite | ❌ 无 | — |

### 关键观察

1. **Launcher 已经走完 v1，停在 v1.5（带 streaming 的裸 loop + router）。** 这正是 learn-everything 路线图的起点。
2. **当前最大的架构缺口是「dispatch 同权切面」未成型**：`LauncherAgent` 的 `toolExecutor: (String, [String: AnyCodable]) async throws -> String` 是一个裸闭包，没有 permission gate、没有 hook emit、没有 obs fan-out。这意味着按元原则 1，**现在每加一个能力都要改这个闭包，而不是「加法」**。
3. **plugin 体系 ≈ MCP 的 Launcher 版**：`PluginManager` + `PromptExecutor` + stdin 协议已经做到「工具定义权外移」，但 plugin 当前是 router 选中后**整段替代** agent，而非作为 agent 的一个 tool 走同权 dispatch。

### 推荐演进路线（按 ROI 排序，对齐 v1→v12）

**P0 —— 固化 dispatch 同权切面**（元原则 1+2 的物理前提，一切后续的地基）

把 `LauncherAgent` 里裸闭包 `toolExecutor` 升级为一条显式管道：

```
decide(tool, mode, input) → permission gate
  → emit(.preToolUse)   // hook 总线（先留空注册表，zero overhead）
  → execute             // 多态注入
  → emit(.postToolUse)
  → fanOut(obsEvent)    // 单一入口
  → 拼 tool_result (含 is_error 反馈通道)
```

即使 hook/obs 注册表暂时是空的，**先把切面留出来**——这样 v2/v6/v7 都是加法。

**P1 —— 双层 permission（子系统 02+03）**：agent 执行 plugin tool / 系统命令（如锁屏）前，过 `decide()` 纯函数 + harness gate。复用现有 TOFU 信任作为 config 层。Launcher 已有锁屏这类不可逆动作，permission gate 是刚需。

**P2 —— plugin tool 同权化（子系统 09 精神）**：让 plugin 成为 agent 的一个可调 tool（走 P0 管道），而非 router 整段替代。router 的「短路」逻辑保留作为性能优化（明确场景跳过 agent loop）。

**P3 —— system prompt 装配（子系统 10）**：当前 system 在 router 里裸拼。拆成 section（core 指令 static / plugin 描述 per-session / 用户偏好 per-user），为 prompt cache 命中铺路（translate 插件性能彻查已证明 prompt 风格对 TTFT 影响巨大）。

**P4+ —— compaction / observability / multi-agent**：当 agent 开始处理长对话（多轮工具调用）时引入 05；当需要诊断线上 agent 行为时引入 07；当单 query 需要并行子任务时引入 04。

> ⚠️ **不要做的事**：不要在 Launcher 这种「召唤即用、短任务为主」的场景过早引入 hook 总线（06）和 multi-agent（04）——naive 截断在 CLI 短任务里反而比 hybrid compaction 更合适（lesson 05 Socratic Q1 结论）。**任务驱动而非架构驱动地引入子系统。**

---

## 第五部分 · 落地检查清单

实现/审查 Launcher agent（或任何本工程 agent）时逐条对照：

- [ ] **裸 loop 先行**：先有 while + tool_use 早停 + messages 拼接，再谈封装。`stop_reason` 是唯一退出条件。
- [ ] **dispatch 同权切面存在**：所有 tool 走同一条 decide → permission → hook → execute → obs 管道，新 tool 是加法不是改造。
- [ ] **判决与执行分离**：`decide()` 是纯函数可单测，`execute`/`askFn` 多态注入。
- [ ] **安全 runtime 强制**：不可逆动作（删除/锁屏/写文件）过 harness gate，不依赖 prompt。
- [ ] **拒绝走 `is_error` 反馈通道**：harness 的 NO 拼回 messages 让 model 诚实汇报。
- [ ] **行为纪律用 prompt 软契约**：保留 model agency，配 reinforcement，runtime 不写死。
- [ ] **cross-cutting 单一入口**：fan-out / redact / cardinality 1 处实现。
- [ ] **reason 字段强制**：hook / cache opt-out / 危险动作必填 reason，逼说清「为什么」。
- [ ] **dynamic 内容隔离 cache 边界**：易变 prompt 走 boundary 之后或 attachment。
- [ ] **外部输入全 untrusted**：plugin / MCP server / model 输出都要清洗，client gate 是补充非替代。
- [ ] **任务驱动引入子系统**：短任务别上 multi-agent / hook 总线；长对话才上 compaction。
- [ ] **教学/简化处显式 disclaimer**：mini 实现的 inherent 局限（如 legacy microCompact 炸 cache）写清楚，别悄悄滑过。

---

## 附录 · 源码导航

**learn-everything 教学库**（mini 实现，每节可独立运行；`<workspace>` = `~/workspace`）
```
<workspace>/learn-everything/topics/agent-harness-engineering/artifacts/
├── 01-minimal-agent-loop/      # agent loop 三角骨架
├── 02-permission-gate/         # 双层正交权限
├── 03-*/                       # mode matrix
├── 04-subagent-fork/           # agent-role 维度
├── 05-context-compactor/       # token 经济 + compaction
├── 06-*/                       # hook engine
├── 07-*/                       # observability
├── 08-*/                       # streaming
├── 09-*/                       # MCP mini client
├── 10-*/                       # system prompt assembly
├── 11-*/                       # skill system
└── 12-*/                       # TodoWrite
```
每个目录的 `lesson.md`（认知流主线）→ `notes.md`（工业对照深挖）→ `excerpts.md`（源码引用）→ `agent-vN-*.ts`（可运行实现）→ `run-log-*.txt`（实测证据）。

**claude-code 工业源码**（`<workspace>/claude-code/src/`，只读快照，0 假设原则下回源核实）
```
QueryEngine.ts  query.ts  Tool.ts  tools.ts          # 核心循环 + tool 契约
hooks/toolPermission/                                 # permission 4 层
utils/hooks/  utils/hooks.ts                          # hook 总线 27 事件
services/compact/  services/mcp/                      # compaction + MCP
coordinator/  tools/AgentTool/  tools/TeamCreateTool/ # multi-agent
skills/loadSkillsDir.ts  memdir/                      # skill + memory
```

**Launcher agent 现状**（`apps/desktop/Sources/ClaudeCodeBuddy/Launcher/`）
```
Agent/LauncherAgent.swift    # v1 loop（升级目标：dispatch 同权切面）
Agent/AgentTool.swift        # tool 三件套
LauncherRouter.swift         # keyword + 短路 + AI 选 1
Plugin/  Provider/           # 工具外移 + provider 抽象
```
