# brainstorm — 社区插件自动作为 LLM tool 被调用

> 本文是 `/autopilot:autopilot-brainstorm` 的产物。**dry-run 已先行**，方案选择基于实测结论，不是凭推断。
> 生成时间：2026-06-29。dry-run 探针（throwaway）在 `/tmp/buddy_dryrun.py`、`/tmp/buddy_scale.py`，不进 repo。

## 探索的目的与约束

**用户目标**：所有「开启的社区插件」自动作为 LLM tool 暴露——用户说「生成二维码 https://xxx」，LLM 自动选中 qr 插件并填对参数。核心硬指标是 **LLM 执行成功率**，tools 设计是关键变量。

**项目上下文探索关键发现**：
1. tool-use 地基**已存在**：`LauncherAgent` 有 while 循环 + `tool_use`/`tool_result` 回灌；`AnthropicProvider` 与 `OpenAICompatibleProvider`（含本地 qwen）请求体都带 `tools` 字段。
2. **致命现状**：`PluginManifest+AgentTool.toAgentTool()` 把**每个插件都硬编码成同一个 schema** `{query: string, "用户原始查询"}`——LLM 眼里 N 个插件长得一模一样，只能靠 name + 一句纯文本 description 猜。这正是成功率瓶颈。
3. 插件输入契约**固定**为 `{query, sessionId, cwd, selection?}`；qr-gen.sh 自己 `jq -r '.query'` 取整段 query 自解析。
4. 当前主路径是 `LauncherRouter`：keyword 缩候选 → 强匹配短路 → 弱匹配 AI「选 1」。`LauncherAgent` 的 tool-use 是另一条路径。
5. dispatch 是裸闭包 `toolExecutor`，无 permission gate（agent-harness-design.md 的 P0 缺口）——属落地层问题，与「tool 设计成功率」正交，单列。

**明确约束**：
- **瓶颈 LLM = 本地 qwen**（qwen3.6-35b @ llama.cpp :8001）。方案必须让弱模型选对；云端强模型天然兼容。
- **路由共存 = keyword 快路径 + tool-use 兜底**（用户选定）。keyword 强匹配仍短路；自然语言/模糊查询走 tool-use。
- dry-run 必须先排掉传输层根因，再比设计（用户要求 + 记忆「先定位根因再修」「以 dry-run 为准」）。

## dry-run 实测结论（方案选择的实证基础）

### Step 1 — 传输层 smoke test：✅ 通过
- qwen+llama.cpp 的 OpenAI 兼容端点**能可靠吐出标准 `tool_calls`**（`finish_reason=tool_calls`，name/args 解析正确）。
- **必须关 thinking**：开 thinking 5063ms / 324 completion tokens；`enable_thinking=False` 后 **449ms / 28 tokens**，正确率不变。launcher 延迟敏感，tool-use 路径**强制 noThinking**（与近期 `noThinking` commit 吻合）。
- 结论：**方案 C（客户端 raw-text 解析）不需要**，YAGNI 掉。

### Step 2 — A vs B 设计对照（3 真实插件 qr/qzh/hello，10 prompt × 3 次）
| 设计 | 选择正确 | 参数正确 |
|---|---|---|
| A：枚举 desc + 固定 `{query}` | 27/30 = 90% | 18/30 = 60%* |
| B：结构化参数（JSON Schema + enum） | 27/30 = 90% | 27/30 = 90% |

- **选择正确率两者相同**（90%），且失败的是**同一个 toy 用例**：「你好」→hello，qwen 倾向直接回答、不肯调 hello 工具（与 A/B 无关，是「默认聊天」倾向，可被 system prompt / description 矫正）。
- A 的「参数 60%」是**评分 artifact**：qzh 用例 A 正确地把原始 query（`"查看监控服务状态"`）整段交给插件脚本自解析——这是 A 的设计意图，不是失败（评分架按 B 的 `action=status` 匹配才显得低）。
- **真正的判据**：qr 类（内容提取）A/B 都 100%；差别只在**意图解析放哪**——A 丢给确定性插件代码（弱模型负担最小），B 丢给 LLM 做 enum 归一化（多一个出错面）。
- **克制测试全过**：计算/翻译两个「无可用工具」场景，A/B 都 3/3 不乱调工具。

### Step 3 — 规模扰动（8 工具，含 qr/shorten 近邻干扰）
- 选择 **21/21 = 100%**；近邻干扰「把这个链接做成扫码图」3/3 正确选 qr 而非 shorten；克制全过。
- 结论：**两阶段检索当前不需要**（YAGNI），≤数十工具内 qwen 选择不塌方。

## 候选方案与权衡

### 方案 A：枚举式 description + 固定 `{query}` 契约
- 做法：不改插件 manifest、不改输入契约；重写 `toAgentTool()`，把 description 升级为「枚举触发场景 + 何时不用 + few-shot 示例 + query 填法说明」。
- 优势：**零插件侧改动**，立即可上线；弱模型负担最小（只选工具 + 传 query，意图解析交给确定性插件代码）；与 qr-gen.sh 现有自解析模式完全一致。
- 劣势：query 是「万能袋」，复杂多字段意图（如「二维码，尺寸 300，纠错 H」）需插件自己 parse；表达力靠插件脚本。

### 方案 B：结构化参数（manifest 声明 JSON Schema）
- 做法：plugin.json 加 `parameters` 字段（qr→`{content}`、qzh→`{action: enum}`）；`toAgentTool()` 用声明的 schema；LLM 填 slot。
- 优势：LLM 有明确 slot；插件收到干净结构化输入，逻辑更简。
- 劣势：弱模型填多字段/enum 多一个出错面；**要改 manifest + 输入契约 + 全部插件**，落地重；dry-run 显示其选择正确率并不优于 A。

### 方案 C：客户端解析 raw-text tool-call（绕开 llama.cpp 内置解析）
- 已被 smoke test 证伪：内置解析可靠，无需自写 parser。仅在未来传输层退化时重启。

## 选择与理由

**选定方案：A 为默认 + manifest 可选 `parameters` 字段（opt-in B）的混合**
- A 作为**默认路径**：现有 3 插件全部命中、零改动、弱模型最稳、与现有插件自解析模式一致。dry-run 已证其足够。
- manifest 增加一个**可选** `parameters`（JSON Schema）字段：当某插件确实需要多字段结构化输入时，插件作者 opt-in 声明，`toAgentTool()` 优先用它、否则回退固定 `{query}`。**默认不强制任何插件改动**，YAGNI 但留好口子。
- 排除 B（作为强制）：dry-run证明其不优于 A，却要改 manifest+契约+全部插件，性价比负。
- 排除 C：传输层可靠，无需。
- 排除「两阶段检索」：8 工具 100%，当前规模 YAGNI；阈值 >约 20 工具或出现近邻误选时再引入。

**dry-run 验证的 tool description 模板**（qr 实测 100% 的写法，含近邻干扰）：
```
<一句话功能>。当用户想<触发场景枚举>时使用。
<参数字段>填<具体填法>。例：「<few-shot 输入>」→ <字段>=<值>。
不要用于：<反例 / 近邻干扰项>。
```

## 待主 SKILL 接力的设计决策

1. **采纳 A 默认 + opt-in `parameters`**：`toAgentTool()` 重写——优先读 manifest 可选 `parameters`，无则回退固定 `{query}`；description 按上述模板生成（从 manifest 现有 `summary`/`description`/`keywords` 合成，缺则回退）。
2. **tool-use 路径强制 `enable_thinking=False`**：OpenAICompatibleProvider 走 qwen 时，带 tool 的请求必须关 thinking（实测 11× 提速、正确率不变）。
3. **路由接法**：keyword 强匹配短路保留（零延迟零 token）；未短路时进 `LauncherAgent` tool-use，tools = 所有「开启 + 已 trust」的社区插件（prompt mode 插件另议，它本就是 LLM 驱动）。
4. **内置 4 插件**：暂不并入 tool-use（它们走即时候选管线，语义不同）；仅社区插件作 tool。是否统一抽象留作 P2。
5. **「默认聊天」倾向**（hello toy 用例暴露）：通过 system prompt 引导「有匹配插件时优先用工具」+ description 强化；**实现期再做一次定向 dry-run 验证**，不阻塞当前方案。
6. **dispatch 同权切面（P0，正交但相邻）**：把所有插件 tool 化后，`toolExecutor` 需补统一 dispatch（存在性/trust 校验 + 超时 + deps 检查 + 错误回灌）。这是 agent-harness-design.md 的 P0，建议与本需求同批或紧随落地——否则 tool 数量上来后裸闭包不安全。
7. **可观测**：复用 BuddyLogger 记录每次 tool-use 的（选中工具 / 参数 / 命中与否），便于线上成功率回归。
8. **dry-run 留作回归基线**：把 `/tmp` 探针沉淀成 app 内测试（用 `providerFactoryOverride` 注入 mock 或打真实 qwen），作为「tool 设计变更」的回归门禁。

**未决、需在设计文档深化的点**：
- description 自动合成的回退策略（manifest 字段不全时如何不退化成现状的「用户原始查询」）。
- opt-in `parameters` 的 manifest 版本兼容（旧插件无此字段时如何不破坏加载）。
- prompt mode 插件是否/如何并入 tool 集（它自身已调 LLM，避免嵌套 loop）。
