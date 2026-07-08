# brainstorm — snip 文本片段插件

> 本文是 `/autopilot:autopilot-brainstorm` 的产物。
> 生成时间：2026-07-03。基于 Alfred Snippets 官方文档调研 + buddy launcher 插件系统源码调研 + 4 轮用户澄清。
> 0 假设原则：涉及 buddy 能力/契约的结论均来自源码（`PluginManifest.swift` / `PluginManifest+AgentTool.swift` / CLAUDE.md / `20260629-社区插件作-llm-tool/brainstorm.md`），非命名推断。

## 探索的目的与约束

**用户目标**：参考 Alfred Snippets，为 buddy 设计一个 snip 文本片段插件——存常用文本（签名、地址、模板等），需要时快速取出，告别重复输入。用户原话："深入调研下 alfred 的 snip 功能设计，然后和当前 buddy 支持的社区插件能力，设计下这个 snip 插件"。

### Alfred Snippets 设计（官方文档调研）
两种形态：
1. **全局自动展开**：输入 `;sig` → 自动替换为完整片段。依赖 Alfred **常驻监听全局键盘**。
2. **`snip` keyword 查询**：输入 `snip <name>` → 取出片段。

其他可借鉴设计：Collections（集合分组）、动态占位符 `{date}/{time}/{datetime}/{clipboard}/{cursor}`、集合级 affix（统一前缀如 `\`）、Snippets Viewer 浏览、导出集合分享、Snippet Triggers（keyword 触发脚本/列表动作）。

### buddy 插件系统能力边界（源码调研，含 file:line）

| 能力 | 可用性 | 说明 |
|---|---|---|
| command mode 零 LLM 秒回 | ✅ | `PluginManifest.swift:46` CommandConfig；mode=command，keyword 命中直出 |
| 候选通道 + selection 回调 | ✅ | `$BUDDY_OUTPUT_CANDIDATES` + `submitWithCandidate` 重入（CLAUDE.md「通用候选输出通道」） |
| stdin mode agent loop（真执行） | ✅ | LLM tool_use 真执行 + 结果回灌 + 多轮（CLAUDE.md「社区插件作 LLM tool」） |
| 插件 opt-in `parameters`（JSON Schema） | ✅ | `PluginManifest.swift:16`；dry-run 实测结构化 enum 参数正确率 90% |
| 维护自己的 snippets.json | ✅ | 插件目录 / `~/.buddy/` 可读写 |
| autoCopy 到剪贴板 | ✅ | prompt mode `autoCopyToClipboard`；command 经 CopyService |
| `{date}/{time}/{datetime}` 动态变量 | ✅ | shell 脚本本地生成 |
| `{clipboard}` 当前剪贴板 | ✅ | 可读 NSPasteboard |
| `{cursor}` 光标定位 | ❌ | 粘贴后无法控制光标（macOS 限制），明确放弃 |
| 全局 auto-expansion | ❌ | launcher 按需召唤、非常驻，架构硬缺口 |
| **一插件多 mode** | ❌ | `PluginManifest.swift:123` mode 是顶层单字段（stdin/prompt/command 三选一） |
| **一插件多 tool** | ❌ | `PluginManifest+AgentTool.swift:13` `toAgentTool()` 返回单个 `AgentTool` |
| prompt mode meta tool 真执行 | ❌ | `attach_action` 是 render-only（声明按钮、点击才执行），**不能写文件**——故 add/del 等真写操作不能走 prompt mode |

**明确约束**：
- snip 走「查询式」范围（对齐 Alfred 原生 `snip` keyword，不做全局 auto-expansion）。
- 读类操作（get/list/del）确定性、LLM 无收益，**必须 command 秒回**（用户硬指标）。
- 创意写操作（add/edit）涉及自然语言理解，LLM 有收益，**走 tool**。
- 架构可扩展——用户明确"一边升级架构一边做功能"。
- 社区优先：插件放 `~/workspace/buddy-official-plugins/plugins/snip/`，不编进 app（CLAUDE.md「插件开发约定」）。

## 候选方案与权衡

### 方案 A：双插件协同（零架构改动）
- `snip`（command mode）：get/list/del 秒回 + 候选浏览
- `snip-mgr`（stdin mode agent loop）：add/edit 走 LLM，单 tool + action enum
- 共享 `~/.buddy/snippets.json`
- 优势：零架构改动，立即可做；读类秒回；写类走 LLM
- 劣势：两个 keyword 入口（`snip` 取 / `snipm` 管），认知割裂；add/edit 是 enum 退化、非独立 tool

### 方案 B：单插件全 LLM（stdin mode）
- `snip`（stdin mode）：get/list/del/add/edit 全走 LLM agent loop
- 优势：单插件统一
- 劣势：读类也吃 LLM 延迟，违反"秒回"硬指标 → **用户否决**

### 方案 C：扩展架构，1 插件 N tools
- 改 manifest/dispatcher/agent 支持「插件声明 N 个独立 tool，每个 tool 标执行模型」
- snip 暴露 `snip_get`/`snip_list`/`snip_del`（command 快速通道）+ `snip_add`/`snip_edit`（agent LLM 通道）
- 优势：统一 `snip` 入口；读类秒回 + 写类 LLM；LLM scoped tools 最稳；最贴用户"只有这些 tool 工具"原话
- 劣势：架构改动面大（manifest schema + `toAgentTool` + dispatcher + agent + trust + 测试）

## 选择与理由

**选定方案：A 与 C 的融合——「读类 command 秒回 + add/edit LLM tool」混合架构**（用户第 4 轮精准决策）

用户决策原文："get/list/del 这些非常明确的操作仍然用 command mode 秒回，用 llm 没收益，只有 add 和 edit 适合用 tool，架构可以改，我们就是一边升级架构一边做具体功能的"。

落地为：
- **读类（get/list/del）**：command mode 秒回。`snip <keyword>` → 命中 autoCopy；`snip` / `snip <词>` → 候选列表浏览；del 经候选 selection 回调二次确认。
- **创意写类（add/edit）**：LLM tool（stdin agent loop）。自然语言"加个 sig 内容 xxx" / "把 sig 改成 yyy" → tool_use → CRUD → 回灌确认。
- **架构**：允许扩展以支撑该混合形态，与功能并行演进。

**实现形态两子选项（待设计文档定）**：
- **形态 1（零架构改动，先落地）**：双插件 `snip`（command）+ `snip-mgr`（stdin agent，add/edit 用 action enum 退化）。
- **形态 2（扩展架构，目标态）**：单插件 `snip` 声明多 tool——读类标 command 快速通道、写类标 agent LLM 通道；统一 `snip` 入口，路由层智能分发。

**排除方案 B**：读类走 LLM 违反"秒回"硬指标，用户明确否决。

**推荐节奏**：形态 1 先落地（读类秒回立即可用 + add/edit enum 退化可用）→ 形态 2 架构扩展跟进（统一入口 + add/edit 升级为独立 tool）。契合"一边升级架构一边做功能"。

## 待主 SKILL 接力的设计决策

### 已确认（用户拍板）
1. 走查询式，不做全局 auto-expansion（对齐 Alfred `snip` keyword）。
2. 读类（get/list/del）command mode 秒回，零 LLM。
3. 创意写类（add/edit）走 LLM tool。
4. 架构允许扩展，与功能并行。

### 需在设计文档深化
1. **架构扩展形态选择**：形态 1（双插件 enum 退化，零改动）vs 形态 2（单插件多 tool，扩展架构）。推荐形态 2 为目标、形态 1 为先落地；须结合 `docs/agent-harness-design.md` 的 P2「plugin tool 同权化」演进路线评估改动面与回归风险。
2. **路由分发策略**（形态 2 核心）：`snip <已知 keyword>` → command 取；`snip` + 动词（加/新增/编辑/改）→ LLM；`snip` 空 → list。须明确前缀/动词匹配规则，**避免与"片段 keyword 恰好叫 add/edit"冲突**（参考 CLAUDE.md「commandPrefixMatched」严格前缀 + 分隔符逻辑）。
3. **snippets.json 数据模型**：`{keyword, content, collection?, created_at, updated_at}`。集合（Collections）首版是否需要（YAGNI 倾向首版平铺、集合留演进）。
4. **动态占位符范围**：`{date}/{time}/{datetime}` shell 生成（✅）；`{clipboard}` 读当前剪贴板（✅）；`{cursor}` 不支持（❌，文档明示放弃）。须定占位符语法（对齐 Alfred `{date}` 风格还是自定）。
5. **Alfred 片段导入**：是否支持 `.alfredsnippets` 导入（降低迁移成本）。倾向首版不做、手动迁移（YAGNI）。
6. **存储位置**：`~/.buddy/snippets.json`（与 `clipboard-history.json` 同级，约定一致）。
7. **autoCopy 语义**：get 命中后 stdout + autoCopy 到剪贴板，用户 Cmd+V 粘贴。
8. **del 确认交互**：del 经候选 selection 回调（`snip` → 列候选 → 选中 del → 二次确认 → 删），防误删；或 `snip del <keyword>` command 直删（须防误）。设计文档须定。
9. **TOFU / trust**：snip 脚本走 TOFU 首次确认（CLAUDE.md「TOFU 安全模型」）；架构扩展（形态 2）后多 tool 的 trustKey 设计——每个 tool 独立 trust 还是插件级。
10. **可观测**：复用 BuddyLogger（subsystem=`plugin`），记录 get/add/edit/del 命中与失败，便于成功率回归。

### 关键约束（设计文档须遵守）
- 读类零 LLM（command mode），不可退化走 LLM。
- 写类 LLM tool 必须走 stdin agent loop（**不可走 prompt mode**——其 meta tool 是 render-only、不能真写文件）。
- 遵循 `docs/agent-harness-design.md` 5 元原则（架构正交性、判决与执行分离、安全不依赖 model 自觉、runtime 强契约、cross-cutting 单入口）。
- 社区优先：插件放 `~/workspace/buddy-official-plugins/plugins/snip/`，build-time fetch 分发，不编进 app。
- 架构扩展须向后兼容（旧插件不受影响，`decodeIfPresent` 兜底，参考现有 parameters 字段做法）。
- 弱模型友好：tool description 用枚举式锚点（参考 `20260629-社区插件作-llm-tool/brainstorm.md` dry-run 验证的模板）；tool-use 路径强制 `enable_thinking=false`。
