## 探索的目的与约束

**用户目标**：在设置页新增一个独立 tab 来支持 LLM 提供者配置，包括 URL / token / prompt 覆盖 / 内置 tools 开关等相关能力。

**项目上下文关键发现**：
- `LauncherConfig`（`~/.buddy/launcher.json`）已有 `activeProvider` + `providers: [String: ProviderConfig]` 数据模型，支持 `kind`/`baseURL`/`model`/`keyRef`/`noThinking` 字段
- API key 走 `SecretStore` 双后端（Keychain 生产 / ChaChaPoly 加密文件 开发），真值不落盘
- CLI（`BuddyCLI/main.swift:1470-1561`）已有完整 `config set/get/use` 命令，是当前唯一配置入口
- 设置 UI 有 5 个 tab（skins/plugins/hotkey/general/about），无 provider 配置页
- `DefaultAgentPrompt.system` 硬编码系统提示词，无覆盖入口
- `MetaTools.all` 当前仅 `attach_action`（speak/copy），prompt 模式全量注入，无开关
- 设置页有成熟组件：`SettingsGroupView`（卡片容器）、`SettingsGroupLabel`（分组标题）、`SettingsToggleRow`（toggle 行，但右控件硬编码 SageSwitch）、`SettingsTheme`（全部视觉 token）
- **缺少**表单输入组件（text field / secure field / dropdown）

**明确约束**：
- prompt 覆盖和 tools 开关本轮只做展示（只读），后续迭代加编辑
- 模型字段用文本输入（非下拉），因为模型 ID 枚举不完
- 需要配置调试/连接测试能力，带具体错误提示

## 候选方案与权衡

### 方案 A：最小切入 + 1 个通用 SettingsFormRow

- 新增 `SettingsSection.ai`，新建 `ProviderSettingsViewController`
- 建 1 个通用 `SettingsFormRow`（仿 `SettingsToggleRow` 的左 label + 右任意 NSView 模式），传入 `NSTextField`/`NSSecureTextField`/`NSPopUpButton` 作为右控件
- 布局复现 `SettingsGroupView` + `SettingsGroupLabel`
- 连接测试：`ProviderFactory.create()` → 轻量 chat completion（单条 "ping"）→ 解析 HTTP 状态码映射中文错误提示
- 优势：改动面小、快速交付、1 个组件即可覆盖所有表单需求
- 劣势：`SettingsFormRow` 是唯一新增组件（但遵循现有 Settings/Components/ 目录约定）

### 方案 B：完全手写不加组件

- 直接在 VC 中 NSStackView + 裸 AppKit 控件手写布局
- 优势：零新组件
- 劣势：布局代码散落 VC，与现有 Settings 组件化风格不一致，复用性为零

## 选择与理由

选定方案：**方案 A（轻量封装 — 1 个通用 SettingsFormRow）**

选择理由：
- `SettingsGroupView` + `SettingsGroupLabel` + `SettingsTheme` 已有现成复用
- 只缺表单输入行的封装，`SettingsFormRow` 改动最小（1 个新组件），但复用价值高
- 与现有 `SettingsToggleRow` 风格一致（左 label + 右控件）
- 连接测试、只读展示等逻辑都在 VC 层，不污染组件

被排除方案及原因：
- 方案 B：与现有 Settings 组件化风格不一致，后续第二个表单页会有大量重复布局代码

## 待主 SKILL 接力的设计决策

### 已确认决策

1. **新 tab**：`SettingsSection.ai`（独立 tab，中文名「AI 配置」），sidebar 用 SF Symbol 图标
2. **布局顺序**：提供者（可编辑）→ 系统提示词（只读）→ AI 工具（只读）
3. **提供者区**（可编辑）：
   - 激活提供者：`NSPopUpButton`（从 `providers` dict keys 读取选项）
   - 类型：`NSPopUpButton`（anthropic / openai-compatible）
   - 模型：`NSTextField`（自由输入，非下拉）
   - API 地址：`NSTextField`（openai-compatible 必填校验）
   - API 密钥：`NSSecureTextField`（写入 SecretStore，读时显示掩码）
   - 连接测试：按钮 → 异步 `ProviderFactory.create()` → 轻量 chat completion → 结果区展示成功（延迟 + 模型）或错误（HTTP 状态码 + 中文原因 + 修复建议）
4. **系统提示词区**（只读）：
   - 展示 `DefaultAgentPrompt.system` 全文
   - 虚线边框卡片 +「只读」标签区分
   - 底部文案「当前使用默认系统提示词 · 后续支持自定义覆盖」
5. **AI 工具区**（只读）：
   - 展示 `MetaTools.all`（当前仅 `attach_action`）
   - 每个 tool 展示：名称、描述、input schema 子字段（speak/copy）
   - 注入策略说明行
   - 实线卡片 +「只读」标签
6. **新组件**：`SettingsFormRow`（左 title + subtitle + 右任意 NSView），置于 `Settings/Components/`
7. **色彩体系**：全部使用 `SettingsTheme` token（sage accent、labelColor 层级、间距栅格）

### 待设计文档深化

- `SettingsFormRow` 的完整 API 设计（init 参数、回调、校验态）
- 连接测试的具体实现（`ConnectionTester` 独立类 vs VC 内联？测试 endpoint：models list vs 轻量 completion？超时策略？）
- 提供者管理：仅编辑当前激活提供者 vs 支持新增/删除/切换（LauncherConfig.providers 是 dict 天然支持多提供者）
- `LauncherConfig` 是否需要新增字段（如 `systemPromptOverride`、`disabledTools`），还是本轮仅 UI 展示、后续再加
- hotkey 配置的后端 bindings（`ProviderFactory.create()` 只在 App 端可用，CLI 测试需评估可行性）
