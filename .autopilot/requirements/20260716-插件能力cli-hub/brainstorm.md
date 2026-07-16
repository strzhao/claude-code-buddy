# brainstorm — 统一 CLI hub 暴露所有启用插件能力（给 AI 用）

## 探索的目的与约束

**用户目标**：做一个 CLI 工具，把每一个**已安装且启用**的 plugin 能力都暴露出来。用户（AI 或人类）只通过这一个 CLI 的子命令执行所有开启的 plugins 能力；plugins 侧零适配，框架自动把所有开启的 plugins 动态注入/移除到统一的 CLI hub。

**项目上下文探索关键发现（已读码确认，非命名推断）**：

1. **能力声明 schema 已存在** —— `PluginManifest.swift:3-17`：`plugin.json` 含 `name/version/summary/description/keywords/mode(cmd)/args/timeout/deps` + 可选 `parameters`(JSON Schema，opt-in，`decodeIfPresent` 向后兼容旧 plugin.json)。

2. **能力→结构化 tool schema 转换已存在** —— `PluginManifest+AgentTool.swift:13-38` 的 `toAgentTool()` 已能把任意外部 plugin 转成 `{name, description, inputSchema}`，现喂给 in-app AI 路由（`LauncherRouter.selectWithTools`）。`description` 由 `synthesizeToolDescription()`（`PluginManifest+ToolDescription.swift`）合成枚举式锚点；`inputSchema` 优先 `manifest.parameters`（强制顶层 `type:object`），缺失回退固定 `{query}`。

3. **具名执行任意 plugin 已存在** —— CLI 已有 `buddy launcher run <name> --input "..." [--json]`（dry-run 直跑具名插件，不经候选路由），经 socket IPC action `launcher_debug_run_plugin` → app 侧 `PluginDispatcher` 执行。当前返回 `{name, stdout, stderr, exit_code, duration_ms}`（**不含 image/candidates/actions**）。

4. **动态发现启用插件已存在** —— `PluginManager.list()` 扫 `~/.buddy/launcher-plugins/`，跳过含 `.disabled` 标记的目录；每次 list 重扫，`add/remove/enable/disable` 即时生效。内置插件开关另走 `UserDefaults` key `buddy.launcher.builtin.<id>.disabled`（`BuiltinPluginEnabledStore`）。

5. **三种执行 mode + 通用输出通道已存在** —— `PluginDispatcher` 三路径：stdin（子进程 stdout 回灌 LLM agent loop）/ prompt（LLM 单轮）/ command（零 LLM 子进程直产）。通用输出通道：`BUDDY_OUTPUT_IMAGE`（PNG）/ `BUDDY_OUTPUT_CANDIDATES`（候选 JSON 数组），`StdinExecutor` 注入环境变量，框架读文件填 `PluginResult.image/candidates`。`PluginInput={query,sessionId,cwd,selection}`，`PluginResult={stdout,stderr,exitCode,durationMs,image?,candidates?,actions?}`。

6. **buddy CLI 本体** —— `Sources/BuddyCLI/main.swift`（~2800 行），Foundation-only（不依赖 BuddyCore/AppKit，保低启动延迟），手写 arg parser（`parseArguments` line 364）+ `switch opts.command` 分发（line 938）；通信走 Unix socket `/tmp/claude-buddy.sock`，`sendMessage`（单向）/ `sendQuery`（请求-响应）。既有顶层命令：`ping/session/emit/status/inspect/click/label/test/launcher/log`。

7. **TOFU 安全模型** —— 首次执行弹 NSAlert，`trustKey=SHA256(cmd+args+sha256(exe bytes))`，任一改动失效重弹；mode 前缀隔离（`stdin:`/`command:`/`prompt:`）。现有 `launcher_debug_run_plugin` 已走 `TrustStore.checkAndPrompt`，CLI 驱动时不绕过。

**结论**：用户提的需求 gap 其实很窄——把「`toAgentTool()` 的 schema + `run` 执行器」从「只服务 in-app AI 路由」**升级成一个对外的、动态的 CLI 契约面**，同时服务外部 AI 与人类。plugins 侧 `plugin.json` 已够用，确实零适配。

**明确约束（用户确认）**：
- **AI 优先，人无所谓** —— 设计重心是 AI 如何发现+调用能力，人类友好子命令（`buddy qr "url"`）降为次要。
- **CLI + JSON manifest，不上 MCP** —— AI 的 harness 自己实现「读 manifest → shell-out 调 run」循环；不上 MCP server（端口/打包/维护成本）。
- **执行经 socket IPC 到运行中的 app** —— buddy 是常驻 Dock 应用，自然状态；执行权留在 app（TOFU/deps/图片通道全复用），CLI 只做适配层，零 duplication。
- **插件零适配** —— 纯读 `plugin.json` + 复用 `toAgentTool()`。
- **动态反映启停** —— manifest 每次调用 live 计算自 `PluginManager.list(enabled)`，启用自动出现 / 禁用自动消失。

## 候选方案与权衡

三方案共同基础：AI 优先 / JSON manifest / 无 MCP / IPC 到 app / 插件零适配 / 动态反映启停 / 都需 +1 IPC action `launcher_list_tools`。差异在**命名位置**、**输出富度**、**能力范围**。

### 方案 A：最小适配（YAGNI）

不新增顶层命令，仅在现有 `launcher` 组下加 `buddy launcher tools --json`，复用现有 `buddy launcher run`。
- 优势：改动最小（≈1 IPC action + 1 CLI 子命令），零命名变动，回归风险最低。
- 劣势：命令长（`buddy launcher tools/run`），AI 在 prompt/tool description 里反复引用烓烚；现有 `launcher run --json` 不含 image/candidates，需另升级输出。

### 方案 B：一等 hub ✅ 选定

提升为顶层稳定契约面：`buddy tools`（manifest）+ `buddy run <name>`（执行）；外部插件；全复用执行链；`run --json` 富输出（含 image/candidates/actions）；`launcher run` 降为 alias。
- 优势：命令短而稳定，AI tool description 里干净；富输出让 AI 拿到二维码图片/候选列表；有独立「AI 契约面」锚点，未来可挂 AI 专属能力（manifest 版本/hash、`--fresh`、每工具自描述 help）；执行链零改动、零 duplication。
- 劣势：需新增顶层路由（避开既有顶层命令命名冲突）；要决定 `launcher run` 去留；比 A 略多工作量（顶层路由 + 富 JSON 序列化）。

### 方案 C：全能力 hub（含内置）

B 基础上把 AI 友好的内置插件（Calculator/AppLauncher 等）也纳入 manifest 成 tool。
- 优势：最贴「每一个能力」字面。
- 劣势：内置是 instant-candidate 机制（query→多候选→perform N），不是「单输入→单输出」，强 tool 化语义别扭；需给 `BuiltinPlugin` 加 `toTool()` + 新 CLI 可达执行路径，工作量最大；YAGNI 风险高。

### 维度：内置是否入 manifest（B vs C 的分水岭）

读码确认 `BuiltinPluginRegistry` 当前注册 **5 个内置**（CLAUDE.md 过时漏了 Screenshot），逐个审判「AI tool 必要性」（口径：形状能否干净映射单入单出 / AI 是否已有等价手段 / 有无真实 AI 场景）：

| 内置 (priority) | action 形状 | AI 已有等价手段 | 真实 AI 场景 | 必要性 |
|---|---|---|---|---|
| Calculator (p200) | ✅ 单入单出 `{表达式}→{结果}` | LLM 本身就会算术（更可靠） | 无 | **冗余** |
| SystemCommand·lock (p100) | ✅ 关键词→单动作 | `pmset displaysleepnow`/CGSession | AI 几乎不替用户锁屏 | **低** |
| AppLauncher (p0) | ⚠️ 模糊匹配→多候选→选中 | `open -a "WeChat"` | 偶尔，bash 够用 | **低+形状不符** |
| Paste (p150) | ❌ 历史候选列表+GUI 选择 | `pbpaste`/`pbcopy` | 历史浏览是 GUI 交互 | **低+形状不符** |
| Screenshot (p90) | ❌ 全屏 overlay 框选+标注 | `screencapture` | 潜有(视觉)，但当前交互框选不能直返图 | **潜有/形状阻塞** |

**0 个高必要性** → C 不成立。clean 形状的俩（Calculator/lock）恰恰最冗余；唯一有潜力的 Screenshot 形状堵死（交互框选+标注，不能直返一张图给 AI）；Paste/AppLauncher 候选列表+GUI 选择语义别扭且 bash 已覆盖。

## 选择与理由

**选定**：方案 B（顶层 `buddy tools` + `buddy run <name>`，外部插件，`run --json` 富输出，IPC 到 app，动态反映启停）。

**选择理由**：
- AI 优先前提下，短而稳定的契约面（`buddy run qr` vs `buddy launcher run qr`）+ 富 JSON 输出（含 image/candidates）是实打实的 AI 体验增益；执行链零改动、零 duplication（复用 `toAgentTool` + 现有 run IPC 链）。
- 内置 tool 化（C）经逐个必要性审判后 0 高必要，纯 YAGNI。
- 满足「动态注入/移除」：manifest 每次 live 计算自 `PluginManager.list(enabled)`，启停即时反映；稳定 `run` verb + 动态 `<name>` arg + 动态 manifest，无需动态 CLI verb 解析（更简单更稳健）。

**被排除方案及原因**：
- A 最小适配：命名长，AI prompt 引用烓烚；无独立 AI 契约面锚点。
- C 全能力 hub：5 个内置 0 高必要（冗余/bash 等价/形状阻塞），额外工作量换不来价值。
- MCP server 传输：用户明确不上 MCP（维护/打包成本），CLI+JSON manifest 让任何 harness 都能用。
- 纯同构 shell-out（AI 也只靠 `--help` 文本发现）：与既有「弱模型需枚举式 schema description」结论相悖，AI 需结构化 manifest。
- 动态 CLI verb（`buddy <plugin>` 随启停出现）：手写 arg parser 要 catch-all 未知首参再查启用名，更繁且「人无所谓」无收益；稳定 `run` verb 已满足。

**重要伏笔（不破坏 B）**：将来若要「AI 能截图看屏幕」，正确做法是新建 **command mode 社区插件**（非交互 capture → 写 `$BUDDY_OUTPUT_IMAGE`），天然落 B 的外部插件模型，`buddy tools` 自动收录。**不要**把 GUI 内置 Screenshot 硬扭成 tool。

## 待主 SKILL 接力的设计决策

**已确认决策**：
1. AI 优先 / JSON manifest / 无 MCP / IPC 到 app / 插件零适配 / 动态反映启停。
2. 方案 B：顶层 `buddy tools`（manifest）+ `buddy run <name>`（执行）；外部插件；`run --json` 富输出；`launcher run` 降为 alias。
3. 内置插件不入 manifest（5 个 0 高必要）；future AI 截图走 command-mode 社区插件路径。

**需要在设计文档中深化的点**：

1. **新 IPC action `launcher_list_tools`**：app 侧返回 `PluginManager.list(enabled 外部).map { $0.toAgentTool() }` 为 JSON。CLI 是 Foundation-only 不能直接调 `toAgentTool()`（在 BuddyCore），必须 IPC 让 app 算。**待定**：manifest 收录哪些 mode——command/stdin 确定收；prompt mode（LLM 单轮）是否收？（收则 AI 可调但语义是「LLM 工具」非确定性函数，design doc 定边界。）

2. **manifest 条目形状**：`toAgentTool()` 给 `{name, description, inputSchema}`；给 AI 决策可能还要 `summary`/`mode`/`keywords`。design doc 定最终字段集（YAGNI：先 name+summary+inputSchema+mode，不过度膨胀）。

3. **顶层路由落点**：`buddy tools` / `buddy run` 加入 `main.swift:938` 的 `switch opts.command`，确认与既有顶层（ping/session/emit/status/inspect/click/label/test/launcher/log）无冲突（`tools`/`run` 均空闲）。`launcher run` 去留：建议保留作 alias（back-compat），内部转发 `buddy run`。

4. **`run --json` 富输出**：现 `launcher_debug_run_plugin` 返回 `{name, stdout, stderr, exit_code, duration_ms}`，需增 `image`(base64 PNG)、`candidates`(JSON 数组)、`actions`。复用 `PluginResult` 字段。**待定**：扩展现有 action 的 JSON 响应（back-compat 风险，旧调用方多字段忽略通常无害）vs 新增 `launcher_run_tool` action（隔离，零回归）。design doc 二选一。

5. **输入契约**：`buddy run <name> --input '<json>'`（JSON 须匹配该工具 inputSchema）。是否加 `--query "..."` 简写覆盖常见 `{query}` 回退场景（人无所谓，可 YAGNI，先只 `--input`）。

6. **TOFU 在 CLI 驱动下的呈现**：`buddy run` 经现有 run 路径 → `TrustStore.checkAndPrompt` 仍弹 NSAlert（在 app 窗口）。CLI 首次跑未信任插件 → app 弹框 → 用户在 app 批准 → CLI 拿结果（CLI 阻塞至解决）。trust 失败 → `{status:error,message:"not trusted"}` + CLI exit 非 0（现有契约）。design doc 明确「CLI 调用需 app 可见以处理 TOFU」。

7. **manifest 新鲜度**：AI 每会话/每轮调 `buddy tools`（live IPC，廉价，无需缓存）。版本/hash 留 YAGNI。

8. **AI 使用契约文档**：参考 `/plugin/docs`（插件开发文档，人类可读 + 复制给 AI），出一份自包含「AI 如何用 buddy」指南：`buddy tools --json` → 选 tool → 按 inputSchema 构造 `--input` → `buddy run <name> --json` → 读结果。可能挂 `buddy tools --guide` 人类可读模式或独立 doc。design doc 定交付形态。

9. **测试策略**：
   - IPC 层：`launcher_list_tools` 返回随启用集变化（enable/disable 后 manifest 增删）。
   - CLI 层：`buddy tools --json` schema 合法、`buddy run --json` 富输出含 image/candidates。
   - TOFU：CLI 驱动首跑未信任 → 触发 prompt（不绕过）。
   - 复用 `make test-only FILTER=<类>` 闭环；CLI e2e 走 `buddy launcher debug` 同款 socket 驱动模式。

10. **YAGNI 边界**：不做动态 CLI verb（`buddy <plugin>` sugar）、不做 manifest 版本/hash、不做内置 tool 化、不做 `--query` 简写（除非 design doc 证明必要）。
