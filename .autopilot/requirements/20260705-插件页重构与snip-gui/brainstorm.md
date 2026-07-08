# Brainstorm：插件页双层目录重构 + snip GUI 化

## 探索的目的与约束

**用户目标**：当前 snip 的 launcher CLI/LLM 交互（增删改查）体验不合理（product-ux-scorer 评分 45.5/100，问题：autoCopy 零反馈、删除流程繁琐、候选混删除项、双入口认知负担、LLM 延迟），改为传统 GUI 管理；同时把设置→插件页从单列卡片流改成双层目录（左=插件列表，右=选中插件操作面板/空态）。

**项目上下文探索关键发现**：
- 设置页已是 `NSSplitViewController` 双栏（`SettingsSplitViewController.swift:16`：左 sidebar plugins/hotkey/ai/skins/general/about + 右 detail 容器）；插件子页 = `PluginGalleryViewController.swift:15`（**纯 AppKit**），当前是单列卡片流（NSScrollView + 三组 SettingsGroupView：自动更新/依赖安装/插件列表），每行=标题+summary+来源徽标+开关，点击仅展开 description，**无 CRUD 操作面板**
- snip 数据层 `plugins/snip/lib/snippets.sh` 已有完整 CRUD（load/get/search/list/add/edit/del），路径 `~/.buddy/snippets.json`，schema=`[{keyword, content, created_at, updated_at}]`；当前入口：snip.sh（GET/LIST/DEL，command mode）+ snip-mgr.sh（ADD/EDIT，stdin+LLM）
- **Swift 侧无直读 snippets.json**，但有完美范式 `ClipboardHistoryService`（Swift 单例 + Codable + 直读 `~/.buddy/clipboard-history.json` + 文件锁）可照抄
- 设置页 CRUD 先例：`SkinGalleryViewController`（NSCollectionView 卡片 + 下载/删除）
- 内置插件：SystemCommand/Calculator/Paste/AppLauncher；社区：hello/qr/qzh
- 双栏改造接入点：`PluginGalleryViewController.swift:112-116`（loadView）

**明确约束**：
- 纯 AppKit（与现有设置子页一致，不混搭 SwiftUI 架构）
- snip 取用（launcher command mode）保留（高频核心不动）
- 数据一致性：GUI（Swift 直读）和 launcher 取用（shell 只读）读同一文件

## 候选方案与权衡

### 方案 A（推荐）：Swift SnippetsService + 内嵌 NSSplitView + 面板协议
- **数据层**：新建 `SnippetsService` Swift 单例（参考 `ClipboardHistoryService`），Codable 直读 `~/.buddy/snippets.json`，内置文件锁；launcher snip.sh 取用（只读）继续工作，无锁冲突（写只在 GUI）
- **插件页**：`PluginGalleryViewController` 内嵌二级 `NSSplitView`（左=NSTableView 插件列表，项=标题+summary+开关不变；右=detail 容器按选中插件路由）
- **右栏路由**：定义 `PluginSettingsPanelProvider` 协议（`makePanelVC() -> NSViewController`），内置插件可注册面板；snip 第一个实现 `SnipPanelVC`（SwiftUI List+Form 嵌 NSHostingController：列表+新增+编辑+删除+占位符语法提示）。无面板插件走默认空态 VC（图标+「此插件无设置项」+使用说明+启用状态）
- **全局区**：「自动更新/依赖安装」移到右栏顶部全局条（选中任意插件时常驻），与插件操作面板分离
- **取用增强**：launcher snip 命令保留，framework 层加 autoCopy 成功 toast（P0-2 修复）
- 优势：UI 响应即时（无 Process 开销）·协议可扩展·复用 ClipboardHistoryService 成熟模式·不破坏 AppKit 一致性
- 劣势：Swift/shell 两套读写代码需对齐约束（白名单/长度/锁）——但 shell 取用只读，冲突面小

### 方案 B（最小改动）：硬编码 snip 面板 + Process 桥接 shell
- 不写 Swift 数据层，GUI 通过 `PluginDispatcher`/`Process` 调 `snippets.sh`
- 右栏硬编码 switch（`if name == "snip" → SnipPanelVC else → 空态`），无协议
- 优势：改动最小·复用 shell 全部校验/锁·单一数据层
- 劣势：每次操作 fork Process ~50-100ms（列表/搜索卡顿）·shell JSON→Swift 解析链路长·硬编码不可扩展·GUI 写后要重新 load 实时性差

### 方案 C（原生重写）：SwiftUI NavigationSplitView
- 弃 `PluginGalleryViewController`，SwiftUI `NavigationSplitView` 重写
- 优势：最现代·List+Form 最简洁
- 劣势：与其他设置子页（AppKit）架构混搭·重写风险大（开关/来源徽标/展开详情/空态都要移植）·NavigationSplitView 在 AppKit NSWindow containment 有 quirks

## 选择与理由

**选定方案：A**

**选择理由**：
- 性能：Swift 直读 JSON，UI 响应即时（B 每次 fork Process 卡顿）
- 可扩展性：协议机制让未来内置插件（lock 配置/clipboardhistory 浏览）可加面板（B 硬编码不可扩展）
- 低风险：复用现有 NSSplitViewController 模式 + ClipboardHistoryService 范式，不破坏 AppKit 一致性（C 重写+混搭）
- 数据一致性可控：shell 取用只读，GUI 独占写，锁冲突面小

**被排除方案及原因**：
- B：进程开销影响 UX（列表/搜索卡顿），硬编码路由不可扩展，违背「每个插件面板不一样」的可扩展诉求
- C：与全 AppKit 设置页架构混搭，重写风险大，NavigationSplitView 在 AppKit containment 有已知 quirks

## 待主 SKILL 接力的设计决策

**已确认决策（用户已选）**：
1. snip GUI 化范围：管理（增删改查片段库）搬进设置页 GUI；取用（`snip <kw>` 精确取→复制）保留在 launcher 并增强
2. snip-mgr（stdin+LLM 自然语言增改）**废弃**，删除 snip-mgr 插件
3. 左栏列表项：保留「标题+summary+开关」单行（启用/禁用不动地方），右栏纯操作面板/空态
4. 取用增强：**仅** autoCopy 成功反馈（toast/角标「已复制」，修复 P0-2 零反馈）；不做自动粘贴/摘要化输出/模糊唯一自动取

**关键设计点（需在设计文档深化）**：
- **SnippetsService 数据层**：Codable 模型（keyword/content/created_at/updated_at）、文件锁策略（NSFileCoordinator vs 复用 mkdir 锁语义）、约束对齐（keyword 白名单 [A-Za-z0-9_-] 长度 1-64、content ≤10000、空/损坏文件容错——对齐 snippets.sh 契约 C8/C9/C11）
- **PluginSettingsPanelProvider 协议**：方法签名、注册机制（内置插件如何声明面板）、默认空态 VC 设计
- **SnipPanelVC UI**：SwiftUI List（片段列表，搜索过滤）+ Form（新增/编辑表单：keyword 输入+content 多行文本框+占位符语法提示 {date}/{time}/{clipboard}）+ 删除二次确认（友好弹窗，非候选回选）
- **双栏布局**：左栏宽度（~240px 固定/可调）、右栏 detail 容器 containment 切换、全局区（自动更新/依赖安装）放右栏顶部全局条
- **autoCopy 反馈**：framework toast 组件（位置/时长/样式），复用现有 toast 机制（如有）
- **snip-mgr 废弃**：删除 `plugins/snip-mgr/`、清理 marketplace.json 注册、相关测试归档
- **测试**：SnippetsService 单测（CRUD + 并发 + 容错）、SnipPanelVC 快照、PluginSettingsPanelProvider 路由测试、autoCopy 反馈集成测试

**待澄清/深化**：
- 全局区（自动更新/依赖安装）具体放右栏顶部还是 sidebar 独立项（推荐右栏顶部全局条，设计文档定）
- 空态 VC 的「使用说明」内容来源（manifest.description？专属文案？）
- 搜索过滤是否需要（片段多了之后）——推荐 MVP 先不做，YAGNI
