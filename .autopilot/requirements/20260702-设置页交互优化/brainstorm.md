# brainstorm.md — 设置页交互优化（2026-07-02）

## 探索的目的与约束

**用户目标**：对设置页做一轮交互优化，覆盖窗口形态、sidebar 顺序、AI 配置页布局、关于页按钮排版四个面。

**项目上下文关键发现**（已读源码 + 实测 build + 用户真机截图确认）：

- 设置页架构：标准 `NSWindow`（`SettingsWindowController.swift:30-38`，初始 760×540，min 600×420，styleMask `[.titled, .closable, .miniaturizable, .resizable]`，**无 `.fullSizeContentView`**）+ `NSSplitViewController`（左 sidebar `NSTableView` sourceList + 右 detail 容器 containment 切换 child VC）。
- sidebar 顺序由 `SettingsSection` 枚举 `CaseIterable` 驱动（`SettingsSection.swift`），当前顺序：`skins → plugins → hotkey → ai → general → about`。改顺序 = 改 case 顺序（+ 改钉顺序的测试 `SettingsSectionAIRedesignTests` 等）。
- AI 配置页 `ProviderSettingsViewController`：`NSScrollView` 包裹，documentView 是普通 `NSView`（`isFlipped=false`），内容 top-anchor 到 container.top+20pt。表单行顺序：激活提供者→类型→模型→API地址→API密钥→测试连接；`noThinking` toggle 在表单分组**外**（分组下方独立行）；「AI 工具」是只读 `NSTableView`，文案是技术黑话（`attach_action — speak（朗读 TTS）`、`<插件名> — command 直接产出` / `prompt LLM 单轮`）。
- 关于页 `AboutSettingsViewController`：图标→名称→版本→更新区（检查更新/立即升级/进度/状态）→反馈问题→开源地址，全部垂直堆叠居中。
- 插件 manifest 已有**人话 `summary`** 字段（CLAUDE.md 契约 C1/C2 强制填写，`PluginManifest.displaySummary` 为展示真相源），AI 工具列表当前却展示 `mode` 黑话而非 summary。
- 继承两个强相关历史需求：`20260622-设置页产品与交互优化`（建 sidebar 骨架）、`20260628-ai配置ui`（加 AI 配置 tab）。本轮是它们的交互打磨。

**⚠️ 3.1 根因实测发现（关键，需 impl 阶段真机定位）**：

- 用户真机截图确认：**大窗（撑满屏）下 AI 配置页内容跑到下半截，顶部空一大块**；**小窗下 detail 顶部右侧被遮挡，表单/JSON tab 看不见**。
- 隔离 snapshot（只渲染 `ProviderSettingsViewController.view`）却显示内容**贴顶**、下方空——与真机行为相反。
- 结论：根因在**真实窗口嵌套链**（scrollView → `SettingsDetailContainerViewController` childView 约束 → `NSSplitViewItem` → `NSSplitView` → `window.contentView`）的某一级，隔离 snapshot 无法复现。最可能嫌疑是 documentView 的 `isFlipped` / clipView 对齐在嵌套上下文下的行为差异，但**未最终证实**。
- 这两条症状很可能是**同一根因**（documentView 贴底对齐）：大窗内容短→顶部大留白；小窗内容超可视高→顶部（表单/JSON tab）被滚到不可见。

**明确约束**：
- 表单仍用既有组件（`SettingsFormRow` / `SettingsGroupView` / `SettingsTheme` token），不重写组件体系。
- `noThinking` toggle 仍受契约 C5 约束（仅 openai-compatible 可见）。
- AI 工具列表本轮仍**只读**（不增编辑/开关能力），只改文案与分组。
- 测试需同步：`SettingsSection*` 顺序测试、`SettingsPageSnapshotTests`（AI 配置页目前**无** snapshot 基线，本轮应补）。

## 决策清单（逐项已与用户确认）

### #1 设置页改成"全屏" → 大号默认窗口
**选定 A**：打开即接近屏幕 70-80% 的大窗（~1200×800 上下），仍是普通可缩放 `NSWindow`，**不**进 macOS 原生全屏独立空间。
- 改 `SettingsWindowController.swift:31` 初始 `contentRect` 760×540 → ~1200×800（minSize 600×420 可保留或同步上调）。
- 排除 B（原生全屏，设置页极少这么做、切换成本高）、C（仅铺满内容区，与 3.1 重叠）。

### #2 皮肤位置 → 紧贴通用上方
**选定 B**：新 sidebar 顺序 = **插件 → 热键 → AI 配置 → 皮肤 → 通用 → 关于**（皮肤从 #1 移到 #4，紧贴通用）。
- 改 `SettingsSection` 枚举 case 顺序。
- ⚠️ 待确认：默认选中项现为 `.skins`（`SettingsSplitViewController.swift:51`），皮肤移到 #4 后是否改默认（如默认第一项"插件"）—— 留设计阶段定。
- 排除 A（维持现状，皮肤本就在最上，用户确认要挪）、C（其他顺序）。

### 3.1 AI 配置页"从上往下布局，顶部空一大块" → 内容贴顶
**意图**：内容始终从顶部往下流，窗口变大也不漂移、不留顶部大块空白；小窗下表单/JSON tab 必须可见。
**根因**：待 impl 阶段用真机 build 定位（documentView `isFlipped` / 嵌套链对齐，见上"关键发现"）。隔离 snapshot 不可复现，**必须真机验证**。
**修法方向**（impl 验证后选）：给 documentView 翻折（`isFlipped=true`）或约束内容贴 clipView 顶；并核查 detail 容器 childView 约束是否把 scrollView 拉满高导致对齐异常。
**附大窗限宽**：#1 改大窗后表单输入框会被拉得过宽（实测 ~950px），需给表单内容加 max-width（如 ~540pt），让大窗下表单保持可读宽度、右侧留白是设计意图而非失控。

### 3.2 测试连接按钮 → API 地址后一行
**选定 A**：测试连接作为独立一行，紧跟 API 地址行（中间不再隔 API 密钥）。
- 新表单顺序：**激活提供者 → 类型 → 模型 → API 地址 → 测试连接 → API 密钥**。
- 改 `ProviderSettingsViewController.setupLayout` 的 `providerGroup.addRow` 顺序（`testRow` 从第 6 行挪到 API 地址之后、API 密钥之前）。
- 排除 B（同 API 地址同一行右侧，输入框会变窄）。

### 3.3 关闭 LLM 思考 → 并入模型行
**选定**：`noThinking` toggle 从表单分组外的独立行，改为并入「模型」行右侧（小开关，仅 openai-compatible 时显示，契约 C5 不变）。
- 需要模型行容纳双控件（modelField + toggle）：要么扩展 `SettingsFormRow` 支持附属控件，要么模型行用自定义行布局。
- toggle 文案精简（如"关闭思考"），subtitle 提示保留但移到模型行说明里。

### 3.4 AI 工具列表 → 分组 + 人话文案
**选定 B**：按「内置能力」「已装插件」**两组**展示，每行 = 图标 + 功能名 + 一句话说明 + 来源标签（内置 / 插件名）。
- 内置项（attach_action speak/copy）固定人话文案：如"🔊 朗读回复 · 把 AI 回复读出声 · 内置"、"📋 复制到剪贴板 · 一键复制 AI 回复 · 内置"。
- 插件项功能名/说明优先取 `manifest.displaySummary`（人话 summary），**不再展示 mode 黑话**（stdin/command/prompt）；来源标签显示插件 name。
- 分组标题上方加引导句"AI 会根据输入自动选用"。
- 改 `loadToolItems`（`ProviderSettingsViewController.swift:393-420`）：数据结构从 `[String]` 升级为分组模型（内置/插件 + 功能名 + 说明 + 来源），`NSTableView` 改为支持分组（section header）或两个 group。
- 排除 A（不分组扁平列表）、C（最简纯文本）。

### #4 关于页 3 按钮 → 同一行
**选定 A**：[检查更新] [反馈问题] [开源地址] **三个按钮同一行**；检查更新相关的状态文案、转圈进度、发现新版本时的[立即升级] **放按钮行正下方一行**（"跟着过去"）。
- 按钮行稳定不跳动（3 按钮恒定），动态内容（status/progress/立即升级）在下方一行。
- 改 `AboutSettingsViewController.swift:120-193` 的垂直堆叠约束 → 按钮行 `NSStackView` 水平 + 状态行在下方。
- 排除 B（升级时挤进按钮行成 4 按钮，按钮数量会变）。

## 待主 SKILL 接力的设计决策（设计文档深化）

1. **3.1 根因定位（最高优先）**：impl 阶段必须真机 build 复现"大窗顶部空/小窗 tab 遮挡"，定位是 `isFlipped` 还是嵌套链约束，再定精确修法。**禁凭隔离 snapshot 下结论**（已被证明与真机不符）。
2. **大窗尺寸精确值**：#1 的 1200×800 是估值，需结合常见 MacBook 分辨率定（如按 screen visibleFrame 的 75%）；minSize 是否同步上调。
3. **大窗下其他页面的限宽一致性**：#1 改大窗后，不只是 AI 配置页，通用/热键/插件/皮肤页都会变宽。是否统一一个 detail 内容 max-width 策略（避免有的页撑满有的页不限）。本轮用户只点了 AI 配置，但需评估一致性。
4. **默认选中项**：#2 移动皮肤后，默认选中 `.skins` 是否改（现 `SettingsSplitViewController.swift:51`）。
5. **模型行双控件 API**：3.3 并入 toggle 后，`SettingsFormRow` 是否扩展支持"主控件 + 附属控件"，还是模型行单独自定义。设计文档定 API。
6. **AI 工具分组数据模型**：3.4 从 `[String]` 升级为分组结构，设计文档定模型形状 + `NSTableView` 分组实现（section header vs 两个 group view）。
7. **测试同步**：`SettingsSection` 顺序测试更新；补 AI 配置页 + 关于页 snapshot 基线（`SettingsPageSnapshotTests` 当前未覆盖 AI/About 的新布局）；关于页按钮 AX/布局断言。
8. **视觉伴侣**：本轮 brainstorm 用了浏览器视觉伴侣（`http://localhost:55430`，screen_dir 在 `.autopilot/requirements/20260702-设置页交互优化/visual/`），6 屏 mockup 已存档，设计阶段可复用。设计完成后由主 skill 决定是否 stop 服务器。

## 范围外（本轮不做）

- AI 配置的多 provider 管理 UI（新增/删除/切换列表）—— 历史需求已标后续。
- AI 工具的编辑/开关能力 —— 本轮只读改文案。
- 系统提示词覆盖编辑 —— 历史需求标后续。
- sidebar 分组/分级导航 —— YAGNI，当前 6 项扁平足够。
