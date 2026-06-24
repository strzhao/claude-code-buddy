# brainstorm.md — 插件展示直观化与开发文档

## 探索的目的与约束

**用户目标**：完善 Launcher 插件系统的可发现性与可开发性，三件事：① 内置插件也要进设置-插件页并支持开关；② 插件描述当前不直观，优化并建立机制保证后续插件也直观；③ 设置页加「插件开发文档」入口，跳转 web 页面，核心提供「复制给 AI 使用」按钮——AI 拿到复制内容就能完整指导社区插件的开发、调试、安装、合入。

**项目上下文探索关键发现**（2 个 Explore agent + 源码定位）：

- **插件系统是双层架构**，两套数据源、两套生命周期：
  - **内置插件（BuiltinPlugin）**：in-process 原生 Swift 对象，编译时注册到 `BuiltinPluginRegistry.shared`（`apps/desktop/Sources/ClaudeCodeBuddy/Launcher/Builtin/BuiltinPluginRegistry.swift`）。当前约 4 个（AppLauncher / Calculator / Paste / SystemCommand，设计阶段以 Registry 实际注册为准）。`BuiltinPlugin` 协议（`Launcher/Builtin/BuiltinPlugin.swift:5-19`）**只有 `sectionTitle`，没有 `description`，也没有 `enabled` 概念**——既无文案、也无开关、也不出现在设置页。
  - **外部插件**：子进程 + `plugin.json`。清单 model `PluginManifest`（`Launcher/Plugin/PluginManifest.swift:3-10`，字段 name/version/description/keywords/timeout/modeConfig）。又分两种来源：Marketplace 内置（hello/qr/qzh，`source: ./plugins/xxx` local-subdir，`MarketplaceManager.seedFromBundle()` 从 Bundle 拷到 `~/.buddy/launcher-plugins/`）；社区 sideloaded（`buddy launcher add <user>/<repo>` 从 GitHub clone 到同目录）。
- **设置-插件页现状**（`Settings/PluginGalleryViewController.swift:15-279`）：数据源只调 `marketplace.inspect()`，返回的 `MarketplaceInspection` 只含外部插件（plugins + sideloadedPlugins），**内置插件完全不在此数据流里**。视图模型 `PluginEntry`（:157-186）只有 `name/version/isSideloaded/enabled`——**连 description 字段都没带进来**，副标题只渲染 `isSideloaded ? "侧载" : "v\(version)"`。所以"描述不直观"有两层根因：① 设置页根本没渲染 description；② plugin.json 里 description 文案本身晦涩（见下）。
- **当前描述文案原文**（plugin.json `description` 字段，晦涩根因）：
  - hello：`"内置示例插件，演示 stdin/stdout markdown 协议"`
  - qr：`"二维码生成器：输入文本/URL 生成可扫码 PNG，点击复制到剪贴板"`
  - qzh：`"QzhddrSrv 监控服务控制：查询运行状态、一键关闭/打开（可逆，重启自愈）"`
  - → hello/qzh 对普通用户完全不可理解（"stdin/stdout markdown 协议""QzhddrSrv"是内部黑话）。
- **三种 mode 语义**（`PluginManifest.swift:12-41`）：stdin（子进程 stdout 回灌 agent loop，工具调用语义）/ prompt（bypass agent 单轮 LLM，render-only 按钮）/ command（零 LLM，子进程直出，如二维码）。这是开发文档的核心内容。
- **web 端现状**（`apps/web/src/app/`）：纯皮肤包商店，路由 = `/`、`/upload`、`/admin`、`/colors` + `api/`。**无任何插件相关页面**。现有可复用：`components/landing/InstallSection.tsx` 有命令块样式（`/plugin marketplace add ...`）；纯 JSX + Tailwind，无 MDX。
- **既有分发链路可复用**：`buddy launcher add/remove/list/inspect`（main.swift）+ TOFU 安全模型（`launcher-trust.json`）+ `requiredPath` 依赖检查 + 禁绝对路径/`..` 的 source 校验（`PluginSourceResolver`）。这些是开发文档"安装使用 + 合入社区"章节的现成素材。
- **既有先例约束**（memory）：`feedback_builtin-feature-prefer-plugin-protocol`——Launcher 内置功能的交互层倾向走标准插件协议（plugin.json + local-subdir），不造特殊候选源，仅常驻监听下沉 app。本次"内置插件进设置页"需与此一致：内置插件虽是 in-process Swift 对象，但在设置页的**展示与开关**应与外部插件统一体验，不另造一套管理 UI。

**明确约束（用户已通过 3 轮 AskUserQuestion 确认）**：

1. **描述机制 = 双字段 summary + description**：plugin.json 新增 `summary`（一句话，设置页/Launcher 首屏展示）+ 保留 `description`（详细，点开看）。内置插件也补 summary/description。后续插件 summary 必填且可校验，从机制上保证直观。
2. **「复制给 AI」= 单按钮复制完整指南**：web 文档页一个按钮一键复制 agent-ready 完整开发指南（schema + 三 mode + 示例 + 调试 + 安装 + 合入社区）。自包含、维护一份、AI 拿到上下文完整。
3. **设置页结构 = 统一列表 + 来源徽标**：内置与外部插件适配成同一视图模型、一个列表展示，靠「内置/社区/侧载」徽标区分来源。不分区。
4. 技术栈：需求 ①② 在 desktop（Swift/AppKit，已有 SwiftUI↔AppKit 桥接）；需求 ③ 在 web（Next.js App Router + Tailwind，纯 JSX）。
5. 应用面向中文用户，所有面向用户的文案（summary/description/文档页/复制内容）默认中文。

## 候选方案与权衡

### 决策点 1：描述/展示机制（需求 ② 核心）

**方案 A：双字段 summary + description（✅ 选定）**
- plugin.json 加 `summary`（≤一句话，UI 首屏）+ 保留 `description`（详细，展开看）。内置插件协议也加这两个字段。
- 优势：首屏一句话直观、详情可深入；后续 summary 必填可强制校验，从机制保证直观；一套字段同时服务设置页和 Launcher 候选展示。
- 劣势：要改 plugin.json schema + Swift `PluginManifest` model + `BuiltinPlugin` 协议 + 现有插件迁移 + 渲染逻辑。

**方案 B：单字段 + 文案规范**
- 不改 schema，只重写现有 description 写得直观，配一份写作规范文档约束后续。
- 优势：改动最小最快。
- 劣势：一个字段既要首屏简短又要详情深入，难兼顾；无强制校验，后续插件容易写跑偏——不满足"保证后续也直观"。

**方案 C：分类标签 + summary**
- 在 A 基础上加 `category` 分组展示。
- 优势：最直观可扩展。
- 劣势：当前插件数量少（个位数），分组价值有限，过度设计（YAGNI）。

### 决策点 2：「复制给 AI」内容组织（需求 ③ 灵魂）

**方案 A：单按钮复制完整指南（✅ 选定）**
- 页面是人类可读完整文档；一个按钮复制对应 agent-ready 完整指南。
- 优势：AI 上下文完整、用户零选择成本、维护一份不同步。
- 劣势：内容较长，但对 coding agent 长内容不是问题。

**方案 B：按 mode 多按钮**
- 多个按钮分别复制 stdin/command/prompt 指南。
- 劣势：用户要选 mode；多份文本维护；AI 缺跨 mode 上下文。

**方案 C：文档 + 复制精炼版**
- 按钮只复制精炼约定，不含页面散文。
- 劣势：人看版与 AI 版两份、易不同步。

### 决策点 3：设置页结构（需求 ① 展示形态）

**方案 A：统一列表 + 来源徽标（✅ 选定）**
- 内置与外部插件适配成同一视图模型，一个列表，徽标区分来源。
- 优势：体验一致；summary 双字段机制一套适用；后续加插件天然统一。
- 劣势：需写适配层；内置插件要加 enabled 状态与持久化。

**方案 B：内置/外部分区**
- 设置页分两个 section 各自渲染。
- 优势：官方/第三方性质区分清晰，改动局部。
- 劣势：两套展示逻辑、summary 分别接入、体验分裂。

## 选择与理由

三个决策点均选定方案 A，理由：

- **决策 1 选 A**：用户明确要求"保证后续插件也直观"，唯有结构化字段（summary 必填 + 可校验）能从机制上强制；单字段靠规范无约束力，分类对当前规模过度。
- **决策 2 选 A**：用户的核心诉求是"AI 拿到就知道怎么做"——自包含完整指南最匹配；coding agent 处理长上下文无碍，碎片化反而损上下文完整性。
- **决策 3 选 A**：与 memory `feedback_builtin-feature-prefer-plugin-protocol` 一致（内置功能走标准协议、不造特殊管理 UI）；统一列表让用户对"我装了哪些插件、哪些开着"有一致心智；徽标已足够区分来源，分区反而分裂体验。

被排除：决策 1 的 B（无强制力）/ C（YAGNI）；决策 2 的 B（碎片化）/ C（双份不同步）；决策 3 的 B（体验分裂、两套逻辑）。

**决策点 4：需求 ③ 范围（✅ 选定 = 文档页 + dry-run CLI）**

经可行性调研（见下节），外部用户开发基本可行、调试薄弱。用户确认范围：
1. 本次做 **web 文档页 + AI 指南**（单按钮复制完整指南）。
2. 本次补 **`buddy launcher run <name> --input "xxx"` dry-run 命令**（desktop CLI 新增）——外部开发者最大痛点，让 AI 指南调试章节的"独立测试"真正可用，不依赖完整 Launcher 候选路由触发。
3. 本次**修复 hello 残缺示例**（补最小可运行 `hello.sh`）。
4. **日志调试能力假设已具备**——`buddy log` CLI 正在 main 分支并行开发（autopilot 任务 `20260624-帮我给-app-设计一个本`，已 `phase: implement`，契约 C4 定义 `buddy log {path|tail|show|grep|clear}` + C6 含 `plugin`/`launcher` 子系统埋点）。AI 指南调试章节可直接引用 `buddy log show --subsystem plugin`，**不必等日志任务合并**。
5. 热重载（`buddy launcher reload`）、扫描错误反馈到设置页——留后续。

**实现协同提示**：dry-run（`buddy launcher run`）与日志任务都改 `Sources/BuddyCLI/main.swift`，实现阶段注意两者命令注册的合并/冲突。

## 待主 SKILL 接力的设计决策

以下方向已对齐，具体实现值留待设计文档深化（主 skill 接力时读源码确认，遵循 0 假设原则）：

### desktop（Swift）侧

1. **plugin.json schema 扩展**：加 `summary` 字段。需定：是否必填（倾向必填，缺省时回退用 description 首句或 name）；`PluginManifest` Swift model 同步加字段；向后兼容（旧插件无 summary 的降级策略）；是否同步更新 `MarketplacePlugin`/`MarketplaceManifest` 的展示字段。
2. **内置插件协议扩展**：`BuiltinPlugin` 协议加 `summary` + `description`（或 `displayInfo` 结构）。需读 `BuiltinPlugin.swift` 确认加字段对 4 个实现类的影响面；sectionTitle 与 summary 的关系（sectionTitle 是分组标题，summary 是插件自身一句话，二者并存）。
3. **内置插件开关机制**：内置插件当前无 enabled。需定：① 状态存哪——复用 `PluginManager` 的 `.disabled` 目录标记机制不适用（内置无目录），倾向 UserDefaults（如 `builtinPlugin.<id>.enabled`）；② 关闭语义——**关闭 = 该插件不参与 Launcher 路由/不产生候选/不响应**（含 Paste 等常驻监听型，关闭应停止响应；设计文档需逐插件确认有无后台监听需一并停）；③ 路由层在哪检查 enabled（`BuiltinPluginRegistry` 取候选处）。
4. **设置页适配层**：`PluginGalleryViewController` 当前数据源只有 `marketplace.inspect()`。需新增一个统一视图模型（扩展现有 `PluginEntry` 或新建 `UnifiedPluginEntry`），把内置插件（来自 `BuiltinPluginRegistry`）与外部插件（来自 marketplace inspect）适配到同一模型，字段 = name / summary / description / source(内置/社区/侧载) / version / enabled / 可展开详情。开关分派：内置走 ③ 的持久化，外部走现有 `PluginManager.disable/enable`。
5. **描述文案重写**（需求 ② 直接产出，设计文档定稿）。草稿方向：
   - 外部插件：hello → summary「插件开发入门示例（Hello World）」/ description「最小可运行的 Launcher 插件，演示 stdin/stdout markdown 协议如何与 agent loop 交互，适合作为新插件起点模板」；qr → summary「输入文本或链接，生成可扫码的二维码图片」/ description「支持任意文本和 URL，生成 PNG 后点击即可复制到剪贴板（command 模式示例）」；qzh → summary「查询和控制 QzhddrSrv 后台服务的运行状态」/ description「查看服务是否在运行，一键关闭或打开（操作可逆，重启自愈）；仅对安装了该服务的环境有效」。
   - 内置插件（设计阶段以 Registry 为准）：AppLauncher →「快速启动 App 或打开文件/链接」；Calculator →「输入算式，即时算出结果」；Paste →「搜索并粘贴剪贴板历史记录」；SystemCommand →「执行锁屏、休眠、清空废纸篓等系统操作」。
6. **summary 强制校验**：如何保证后续插件也直观。候选：plugin.json 加载时 summary 为空告警/拒绝；开发文档里写明写作规范；可选 lint。设计文档定力度（告警 vs 拒绝）。
7. **设置页入口按钮**：插件分区右上角加「插件开发文档 →」按钮，点击用系统浏览器打开 web 文档页 URL。需定 URL（见 web 侧 ⑧）。

7b. **`buddy launcher run <name> --input "xxx"` dry-run 命令设计**（需求 ③，desktop CLI 新增）：
   - **语义**：对**已安装**（已在 `~/.buddy/launcher-plugins/`）的指定插件，**跳过 Launcher 候选筛选/路由**，直接喂 input 单次执行，返回完整结果（stdout/stderr/退出码/耗时）。**不安装插件**——安装仍是 `buddy launcher add` 或手动 sideload 的独立动作，二者不要混。
   - **用途**：开发调试——改完插件脚本立刻验证"喂这个 input 输出对不对"，不必在 Launcher 里想触发词、走候选命中、也看不到中间 stdout/stderr。
   - **三种 mode 行为**：command = 直接跑子进程；stdin = 默认**只跑子进程**取原始 stdout（验证 markdown 协议格式），是否连 LLM agent loop **待定**（倾向 `--agent` 可选、默认不连，避免强制依赖 provider 配置）；prompt = 跑单轮 LLM（需 provider）。
   - **信任**：复用 TOFU 还是 dry-run 免确认——**待定**（倾向复用，首次确认后不阻塞开发迭代）。
   - **输出**：默认人类可读（含调试细节），`--json` 输出结构化（供 AI/脚本消费）。
   - **实现**：复用现有 `StdinExecutor`/执行链，仅新增 CLI 入口 + 跳过路由层。与日志任务同改 `main.swift`，注意命令注册合并。

### web（Next.js）侧

8. **文档页路由与实现**：新增路由（候选 `/plugin/docs` 或 `/docs/plugin`，倾向 `/plugin/docs`）。实现方式需确认 web 是否有 markdown 渲染能力——agent 报告为纯 JSX 无 MDX，倾向：内容源放一份 markdown（`apps/web/src/content/plugin-dev-guide.md` 或 `docs/plugin-dev-guide.md`），页面用纯 JSX 渲染人类可读版 + 复用 `InstallSection` 命令块样式展示命令。
9. **「复制给 AI」按钮实现**：按钮点击复制 agent-ready 完整指南文本到剪贴板（`navigator.clipboard.writeText`）。复制内容 = 一份自包含 markdown（与页面同源或单独维护一份精炼 agent 版，**倾向同源单份**避免不同步）。需定复制后的反馈（toast「已复制，粘贴给 Claude Code 即可」）。
10. **AI 指南内容大纲**（复制按钮的内容骨架，设计文档填充）：
    1. 插件是什么（Launcher 插件 = `plugin.json` + 可执行子进程；三种 mode；运行在 `~/.buddy/launcher-plugins/`）
    2. `plugin.json` 完整 schema（字段表：name/version/**summary**/description/keywords/mode/cmd/args/env/timeout/requiredPath）
    3. 三种 mode 语义与选择指南（stdin 何时用 / command 何时用 / prompt 何时用）
    4. 目录结构与 local-subdir 约定（name 必须等于目录名；source 相对路径；禁绝对路径/`..`）
    5. 最小示例（step-by-step，以 hello 为模板：建目录 → 写 plugin.json → 写可执行脚本 → 本地测试）
    6. 本地开发与调试（放到 `~/.buddy/launcher-plugins/`；如何触发；日志用 `buddy log` 查看；`buddy launcher list/inspect` 验证）
    7. 安装使用（本地 sideload；`buddy launcher add <user>/<repo>` 从 GitHub 装；`buddy launcher remove`）
    8. 合入社区（提交到官方 marketplace 的流程：fork → 加插件目录 → 注册到 `marketplace.json` → PR；MarketplaceManifest 字段）
    9. 安全模型（TOFU 信任、requiredPath 依赖检查、source 路径限制）
    10. **summary/description 写作规范**（呼应需求 ②：summary 一句话说清"这插件帮我做什么"，避免内部黑话；description 补充怎么用、适用场景）。

### 跨工程

11. **范围与拆分**：三需求横跨 desktop + web，建议作为同一需求下的两个工作流（desktop 改动 + web 文档页），设计文档给出实现顺序（倾向：② schema/文案 → ① 设置页适配 → ③ web 文档页，因 ③ 的 AI 指南依赖 ② 的 schema 定型）。
12. **task_dir**：`.autopilot/requirements/20260624-插件展示与开发文档/`（本次 brainstorm 直接调用，主 skill 接力时据此建 state.md）。

## 可行性调研：外部用户开发调试闭环（需求 ③ 的前置验证）

> 调研问题：外部用户只拿 release app（无源码），能否独立开发 + 调试社区插件？结论直接影响需求 ③ 的 AI 指南能承诺什么、是否需要配套补能力。

### 开发能力：✅ 基本可行

- ✅ 目录约定清晰：`~/.buddy/launcher-plugins/<name>/`，name=目录名（`PluginManager.swift:13-64`，`.disabled` 标记禁用）。
- ✅ sideload 双路径：手动放目录 或 `buddy launcher add <user>/<repo>` git clone（`main.swift:cmdLauncherAdd`）。
- ✅ TOFU 不阻塞开发：首次弹窗确认后写 `launcher-trust.json`，同二进制/cmd/args 不重复弹（`TrustStore.swift:33-96`）。
- ✅ 可执行文件类型广泛：bash/python/二进制，`requiredPath` 依赖检查，PATH 扩展含 homebrew（`StdinExecutor.swift:10-23,241-254`）。
- ✅ command mode 零 LLM 依赖，开发门槛最低；stdin/prompt mode 需先 `buddy launcher config set` 配 provider。
- ❌ **缺口 1：无面向外部的 schema 文档**——这正是需求 ③ 要补的核心。
- ❌ **缺口 2：hello 入门示例残缺**——`hello/plugin.json` 的 `cmd=./hello.sh`，但目录只有 plugin.json、**没有 hello.sh**，跑不起来。外部用户复制当模板会被误导。对比 qr（qr-gen 二进制 + qr-gen.swift 源码）、qzh（qzh-exec + README + setup.sh）是完整的。

### 调试能力：⚠️ 当前薄弱，强依赖并行日志系统

- ✅ `buddy launcher list/inspect` 随 release 分发（bundle.sh 打包 + cask symlink 到 `/usr/local/bin/buddy`），可验证插件被识别 + 看 manifest 解析结果。
- ✅ 执行错误 UI 可见：崩溃（退出码+stderr 前 200 字）、依赖缺失、超时、manifest 无效均有中文提示（`LauncherError.swift:47-60`）。
- ❌ **缺口 3：无 `buddy log`**（当前代码 grep 全空）——**但有并行需求 `20260624-帮我给-app-设计一个本` 已在 `phase: implement`**，其契约 C4/C6 明确会埋点 `plugin`/`launcher` 子系统 + 提供 `buddy log {path|tail|show|grep|clear}`。**日志落地后 `buddy log show --subsystem plugin` 即插件调试核心手段**——需求 ③ 的"调试"章节应建立在日志系统之后。
- ❌ **缺口 4：无 dry-run**——无 `buddy launcher run <name> --input`，外部开发者只能走完整 Launcher 候选路由触发，无法单独跑一次插件看输出。**外部开发体验最大痛点**。
- ❌ **缺口 5：无热重载**——改完插件需重启 app（虽有重扫，但 trust key 变需重新确认）。
- ⚠️ **缺口 6：扫描错误静默**——plugin.json 解析失败只 NSLog，用户不可见（日志系统落地后会进 buddy log，但设置页仍不显示）。

### 对需求 ③ 的直接影响（已定，见决策点 4）

1. AI 指南"开发"章节：**可写**——schema + 目录 + sideload + 三 mode + 安全模型均有源码依据。
2. AI 指南"调试"章节：**buddy log 假设已可用**（main 分支并行开发中，决策点 4），直接写 `buddy log show --subsystem plugin`；**本次补 dry-run**（`buddy launcher run`）让独立测试可用。
3. **本次修复 hello 示例**（补最小可运行 `hello.sh`）——否则文档教人"复制 hello 当模板"会误导。
4. **本次补 `buddy launcher run`（dry-run）**——已定（决策点 4）。
5. 热重载、扫描错误反馈到设置页——留后续范围。

## 后续范围（本次不做，记录待办）

- 插件市场（marketplace）在 web 端的可视化浏览/搜索/一键安装（当前 marketplace 只随 app Bundle 分发，web 无商店）。
- 插件开发的脚手架 CLI（类似 skin-cli 的 `buddy plugin init/create`，自动生成插件骨架）——本次 AI 指南里用文字说明手动建目录即可，脚手架后续单独做。
- 插件的版本更新通知/自动更新。
- **插件热重载**（`buddy launcher reload`）——本次靠"改后重启 app"（PluginManager 每次查询重扫，但 trust key 变需重确认）；热重载后续补。
- **扫描错误反馈到设置页**——plugin.json 解析失败当前只 NSLog 静默跳过；日志系统落地后会进 `buddy log`，但设置页 UI 反馈（让用户知道"插件为什么没出现"）留后续。
