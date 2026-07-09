# 设置 / 插件 / Snip 面板布局重构设计

- **日期**：2026-07-10
- **范围**：desktop app 设置窗口（设置主体 / 插件面板 / snip 面板）的**布局**重构
- **方案**：C — 规范收口 + master-detail 范式统一 + 技术栈收口（snip 从 SwiftUI 迁 AppKit）
- **状态**：待审阅

---

## 1. 背景与问题诊断

用户反馈三个面板「太简陋，完全没有设计」。经代码 + 渲染快照 + 通用设置/插件/snip 实际渲染对照，先纠正一个认知：代码层面**已有设计骨架**——`SettingsTheme.swift` 有统一的颜色/字体/间距 token，`BuddyPalette` 有 sage 绿品牌色 + 明暗动态，`Settings/Components/` 有复用的 `SettingsGroupView`/`SettingsToggleRow`/`SageSwitch`/`SettingsFormRow`，空态/错误态也做了。所以不是「从零没设计」，而是**骨架在、布局观感简陋**。

用户明确：**核心不是 UI（配色/阴影/图标），是布局（信息架构 / 空间组织）**。布局是骨架，骨架正了哪怕用系统默认控件也显专业（macOS 系统设置 / Linear / Raycast），反过来布局烂加多少视觉装饰都救不回来。

行号级诊断，"简陋"的真实根因（按"痛"排序）：

1. **内容区无 max-width 居中 — 头号元凶**。窗口默认占屏 75%（`SettingsWindowController:24`），但右栏所有内容贴左右页边距拉满（`GeneralSettingsVC:73-93`、`PluginGalleryVC:341-343` 全是 `±contentPadding` 贴边约束）。宽屏上一行开关被拉成横线、卡片稀疏松散，立刻显业余。macOS 系统设置 / Linear / Raycast 全部对内容区限宽居中（~720-820pt）。
2. **间距硬编码混用**。`SettingsTheme` 有 token（24/20/16/8），但实际满地魔法数字：`GeneralSettingsVC:80` 写死 6、`PluginGalleryVC` 混用 6/20/8/12、`SettingsToggleRow` 用 10/8/2/12/4、`EmptyPluginStateVC` 用 96/32/48 + 固定 frame 480×360。节奏乱，肉眼"不齐"。
3. **分栏比例写死且自相矛盾**。sidebar 卡 180-240（`SettingsSplitVC:55-56`）、插件左栏卡 200-260（`PluginGalleryVC:207-208`），但分隔条位置又按 `min(220,width/3)`（`PluginGalleryVC:352`）算——和约束对不上，拖动会跳。
4. **三面板范式不齐 + 技术栈混杂**。设置/插件是 AppKit master-detail，snip 是 SwiftUI `HSplitView`（还挂 `sizingOptions=[]` hack 修窗口塌缩）。三套分栏逻辑、三套留白节奏；snip 自己的 createForm/editForm/previewPane 三态也各干各的。

---

## 2. 方案选择

三个递进方案（A 轻规范收口 / B 范式统一 / C 含技术栈收口），**用户选定 C**：规范收口 + 三面板统一 master-detail 范式 + snip 从 SwiftUI 迁 AppKit。

选 C 的理由：A 留"三面板不齐 + snip 三态乱"的尾巴；B 把 snip 留 SwiftUI 只对齐栅格，仍背 `sizingOptions` hack 和两套布局心智；C 把用户能看见的布局骨架 + 看不见的技术栈心智一次性理顺。用户接受 snip GUI acceptance 测试重写的成本。

---

## 3. 设计

### 3.1 统一布局地基（三面板共享）

**① 内容区限宽居中**
- 引入「内容列」：detail 内容限宽 **780pt 居中**，左右留白随窗口变宽弹性增长；窗口窄到放不下时退化为贴边（小屏不浪费）。
- 统一接入：在 `SettingsDetailContainerViewController.transition(to:)`（`SettingsSplitVC:148`）把 child view 包进 `ContentColumnView` 再贴满容器，所有 detail VC **自动**获得限宽居中 + 滚动，无需各 VC 改。详见 4.2。

**② 间距栅格收口**
- `SettingsTheme` 新增 4 倍数 scale：`spacingXs=4 / sm=8 / md=12 / lg=16 / xl=24 / xxl=32 / section=48`。
- 现有语义 token 值收口到 scale：`contentPadding=24(=xl)`、`groupSpacing=20→24(xl)`、`groupTopInset=20→24(xl)`、`cardContentPadding=16(=lg)`、`rowSpacing=8(=sm)`。语义名保留，值对齐 scale。
- 组件内硬编码统一指向 scale：`2/4→xs`、`6/8→sm`、`10/12→md`、`16→lg`、`24→xl`、`32→xxl`、`48→section`。逐行映射见 4.1。

**③ 分栏比例规范**
- 设置 sidebar 固定 **200pt**（删 `SettingsSplitVC:55-56` 的 180-240 区间）。
- 插件 / snip 左列表栏统一固定 **240pt**（删 `PluginGalleryVC:207-208` 的 200-260 区间 + `:352` 的 `min(220,width/3)` 比例算法）。
- 分隔条位置 = 固定宽度，彻底消除拖动跳动。

**④ 统一行高 + 列表项对齐范式**
- 所有交互行（toggle/form/plugin cell/snip cell）最小行高 **44pt**（HIG 标准）。两行内容 cell 自然更高（插件 cell ~56pt）。
- 列表项统一栅格：`[图标16pt] [主标题 + 副标题列 左对齐成列] [右锚: badge/开关 右对齐 baseline 对齐]`。

**⑤ master-detail 范式定义**
- 统一骨架：**左 = 固定宽栏 ｜ 右 = 限宽居中内容列（标题区 + 字段卡组 + 底部操作栏）**。左栏语义按面板不同（设置 sidebar=分类导航 200pt；插件/snip=条目列表 240pt，含搜索 + 新增），但"左固定宽 + 右统一限宽居中"这套骨架三面板一致。三面板的"右内容列"共用同一套 `ContentColumnView` + 同一套留白节奏。

**⑥ snip 迁 AppKit 顶层架构**
- `SnipPanelVC` 类名保留（`PluginPanelRegistry` 注册 / 测试 / `PluginSettingsPanelProvider` 都引用），父类 `NSHostingController<SnipPanelView>` → `NSViewController`。删除 `SnipPanelView.swift`。详见 3.2。

### 3.2 snip 面板 AppKit 重写

**① 新 VC 结构（套 3.1 范式）**
- `SnipPanelVC: NSViewController, PluginSettingsPanelProvider`。
- **左栏固定 240pt**（不用 `NSSplitView`——snip 不需用户调列宽，两个并列 `NSView` 更简单无跳动）：搜索框 + 「新增片段」按钮 + `NSTableView`（keyword 主标题 + content 预览副标题双行 cell）。
- **右栏经 `ContentColumnView` 限宽 780 居中**：detail 容器 containment 切四态。

**② 四态统一成「标题区 / 字段卡组 / 操作栏」**（字段卡统一用 `SettingsGroupView`，消除当前 SwiftUI 三态各自为政的 `VStack+Divider` 手摆）
- 空态：图标 + 提示居中。
- create：标题「新增片段」+ `keyword` 字段卡 + `content` 字段卡 + 占位符提示卡 + `[取消 | 保存]`。
- edit：标题「编辑片段」+ `keyword`(只读) + `content` 字段卡 + 占位符提示卡 + 时间戳 + `[删除 | 取消 | 保存]`。
- preview：标题「预览」+ `keyword`(只读) + `content` 原文卡 + 展开后卡 + `[编辑 | 删除]`。

**③ 数据流（SnippetsService 不变）**
- `SnippetsService` 已是 `@MainActor ObservableObject`。VC 持引用 + `service.objectWillChange.sink { tableView.reloadData() }` 桥接刷新（替代 SwiftUI `@ObservedObject` 自动刷新）。
- CRUD 调 `service.add/edit/delete`（签名不变）；preview 展开调 `SnippetsService.expandPlaceholders`（手动设 `stringValue`）。

**④ sizingOptions hack 消除**
- 纯 AppKit 不经 `NSHostingController`，无 fittingSize 塌缩 → 删 `sizingOptions=[]`（`SnipPanelVC.swift:37-39`）。
- VC view 用固定初始 frame + autoresize（对齐 `GeneralSettingsVC:33` patterns/2026-06-16 防 fittingSize 缩 0），`pluginPanelContainer` equality 约束接管撑满。

**⑤ 契约保留映射**（AC-SNIPGUI-* 见 4.4）
- 数据/持久化类（08/09/11/14/15/16/17/18/19/24）：`SnippetsService` 不动，自动满足。
- AC-01 双栏：固定宽度并列双 `NSView`（语义等价 `NSSplitView`，无跳动）。
- AC-10 删除确认：`presentDeleteAlert` / `handleDeleteResponse` static test seam 原样保留（`SnipPanelVC.swift:54-74`）。
- AC-13 占位符提示 / AC-23 展开预览：AppKit `NSTextField` 可遍历，比 SwiftUI 更好测。
- AC-28 焦点保持：外层 `SettingsWindow.sendEvent` 兜底已存在，VC 内部不破坏。

**⑥ 删除桥接不变**
- `onDeleteRequest` 闭包 → `SnipPanelVC.confirmDelete(item:)` → `presentDeleteAlert` + `runModal` + `handleDeleteResponse`。只是触发源从 SwiftUI Button 改为 AppKit `NSButton` action。

### 3.3 插件面板 + 设置主体套地基

**① ContentColumnView 统一接入**
- 结构：`NSScrollView`（撑满 detail 区）→ `documentView`（宽度跟随 clipView，只竖滚）→ `contentColumn`（`width ≤ 780` + `centerX` 居中）。约束细节见 4.2。
- 接入：改 `SettingsDetailContainerViewController.transition(to:)`，child view 塞进 `ContentColumnView` 再贴满。
- **特例 SkinGallery 不套**：皮肤市场是 CollectionView 网格，限宽 780 反而挤；保持自带 `ScrollView` + 网格（但收口卡片间距/样式走栅格）。
- **ProviderSettings**：去掉自带 ScrollView，改用 ContentColumnView 统一 scroll（AI 配置表单 + JSON 限宽 780 合理）。

**② 插件面板改造**
- 左栏固定 240pt（删区间 + 比例算法）。
- 右栏 globalHeader 三组（autoUpdate/depInstall/docs）+ `pluginPanelContainer` 都进 ContentColumnView。
- **`PluginListCellView` 列表项重排**（套 3.1 ④ 范式）：`[图标16pt SF Symbol] [nameLabel + summaryLabel 左对齐成列] [sourceBadge] [toggle 右对齐 baseline]`。当前无图标——补 16pt SF Symbol（按 source/类型给默认 icon，如 `puzzlepiece`/`command`/`terminal`）。

**③ 设置 sidebar 固定 200pt**（删 180-240 区间，不可拖）。

**④ 间距收口**：组件内硬编码逐行替换到 scale（4.1）。覆盖 `SettingsToggleRow` / `SettingsFormRow` / `PluginListCellView` / 插件右栏 globalHeader / `GeneralSettingsVC` / `AboutSettingsVC`。

**⑤ EmptyPluginStateVC 响应式**
- 删固定 frame `480×360`（`EmptyPluginStateVC:42`），改撑满 ContentColumnView + 内容居中；硬编码 `96/32/48` 收口到 `contentTopInset=48 / spacingXxl=32 / spacingSection=48`。

### 3.4 测试与回归策略

**① 测试四类处置**（详见 4.5）
- **保留不动**：`SnippetsServiceTests`(21)、`SnipGUIInProcessAcceptanceTests` 路由层（AC-01/02/03/04/05/10/27/28）、契约编译测试、`expandPlaceholders` 逻辑测试。
- **适配**：AC-13（`NSTextField` 可遍历）、AX 契约（`ContentColumnView` 接入后确认 `settings.detail` AX id 挂正确层，守契约 7）、`SnipWindowSizingTests`（删 hack 后）。
- **重录基线**：`SettingsPageSnapshotTests`（general/plugin/about/hotkey × light/dark）、`SnipPanelRenderDiagnosticTests`（SwiftUI→AppKit）、检查 `SkinGallerySnapshotTests`。
- **新增（红利）**：snip AppKit 端到端 in-process（AC-08/09/12/17/18 GUI 路径，SwiftUI 时代测不了）。

**② 必须真机验证（headless 盲区）**
本次全是 GUI/布局/sizing/NSHostingController 变更，headless `swift test` 对窗口几何 / preferredContentSize 传播 / ScrollView 贴底 / 限宽居中观感有盲区。单测只守"根因属性"（sizingOptions 值、约束常量、栅格 token），**端到端必须真机**（`SKIP_FETCH_PLUGINS=1 make bundle` → `pkill + open` → osascript 读 frame 验高度稳定 + 用户点 GUI 验四态/CRUD/观感）。

**③ 迁移顺序（5 阶段，低风险先行，每阶段独立验证 + 提交）**
- **阶段 0 · 栅格 token 扩展**：`SettingsTheme` 加 scale + 布局常量。纯加法零风险。
- **阶段 1 · ContentColumnView + 统一接入**：新建组件，改 `transition(to:)`，SkinGallery 特例。
- **阶段 2 · 设置主体收口**：sidebar 固定 200、detail VC 硬编码收口、`EmptyPluginStateVC` 响应式。重录设置快照。
- **阶段 3 · 插件面板改造**：左栏固定 240、右栏套地基、`PluginListCellView` 补图标重排、globalHeader 收口。重录插件快照。
- **阶段 4 · snip 迁 AppKit**：新建 `SnipPanelVC(NSViewController)`、删 `SnipPanelView.swift` + hack、保留 delete seam、`objectWillChange` 桥接。适配/新增测试、重录 snip 快照。

每阶段后：相关 `make test-only FILTER=…` + 真机 bundle 验证。

---

## 4. 详细附录

### 4.1 栅格 token 收口映射表

`SettingsTheme` 新增：
```swift
// 4 倍数 scale
static let spacingXs: CGFloat = 4
static let spacingSm: CGFloat = 8
static let spacingMd: CGFloat = 12
static let spacingLg: CGFloat = 16
static let spacingXl: CGFloat = 24
static let spacingXxl: CGFloat = 32
static let spacingSection: CGFloat = 48
// 布局常量
static let contentMaxWidth: CGFloat = 780
static let sidebarWidth: CGFloat = 200
static let pluginListWidth: CGFloat = 240
static let minRowHeight: CGFloat = 44
static let contentTopInset: CGFloat = 48
```

现有语义 token 值收口：`contentPadding=24`、`groupSpacing` 20→24、`groupTopInset` 20→24、`cardContentPadding=16`、`rowSpacing=8`（语义名保留）。

硬编码 → scale 逐行替换（实现时以源码为准核对行号）：

| 文件 | 当前值 | → token |
|---|---|---|
| `SettingsToggleRow.swift` | 10(title/etail top/bottom) | `spacingMd` |
| `SettingsToggleRow.swift` | 8/12(右锚间距) | `spacingSm` / `spacingMd` |
| `SettingsToggleRow.swift` | 2(title↔subtitle) | `spacingXs` |
| `SettingsToggleRow.swift` | 4(行间) | `spacingXs` |
| `SettingsFormRow.swift` | 10/12/2/8 | `spacingMd` / `spacingMd` / `spacingXs` / `spacingSm` |
| `PluginListCellView.swift` | 8(top/bottom/right) | `spacingSm` |
| `PluginListCellView.swift` | 12(leading/trailing) | `spacingMd` |
| `PluginListCellView.swift` | 4(badge) / 2(name↔summary) | `spacingXs` |
| `PluginGalleryVC.swift` globalHeader | 6(label→group) | `spacingSm` |
| `PluginGalleryVC.swift` | 24/12(placeholder/reseed) | `spacingXl` / `spacingMd` |
| `GeneralSettingsVC.swift` | 6(label→group) | `spacingSm` |
| `AboutSettingsVC.swift` | 4 | `spacingXs` |
| `EmptyPluginStateVC.swift` | 96(icon top) | `spacingSection × 2`（响应式后内容居中，此值仅映射参考） |
| `EmptyPluginStateVC.swift` | 32/48(left-right) | `spacingXxl` / `spacingSection` |
| `EmptyPluginStateVC.swift` | 16/8/12(其余) | `spacingLg` / `spacingSm` / `spacingMd` |

### 4.2 ContentColumnView 约束

```
ContentColumnView: NSView  (撑满 detail 区)
├── scrollView: NSScrollView  (top/leading/trailing/bottom = 四边 0)
│   ├── hasVerticalScroller = true, hasVerticalScroller=true
│   ├── drawBackground = false, scrollerStyle 跟随系统
│   └── documentView: NSView  (FitClipView 让 width 跟随 clipView)
│       └── contentColumn: NSView  (实际内容竖排进这里)
│           ├── width ≤ contentMaxWidth(780)
│           ├── centerX = documentView.centerX
│           ├── top/bottom ≥ spacingSection(48)
│           └── leading/trailing ≥ spacingXl(24)
```

- documentView 宽度跟随 clipView（只竖滚，横向不滚：限宽 780 + 居中永远放得下或退化为贴边）。
- `settings.detail` AX id 仍挂在 child VC 的 root view（塞进 contentColumn 的最上层 view），保持契约 7（AX 锚点设在 AX 可见层）；ContentColumnView / scrollView 是透明布局容器，不挂 id。
- SkinGallery 不经 ContentColumnView（`transition` 特判，或 SkinGallery 自声明"自带滚动"跳过）；ProviderSettings 去掉自带 ScrollView 复用 ContentColumnView scroll。

### 4.3 snip 四态 AppKit 结构

master-detail 并列双 `NSView`（不用 NSSplitView）：
```
SnipPanelVC.view
├── leftPane: NSView  (width = pluginListWidth=240, 固定)
│   ├── searchField (top, spacingSm 间距)
│   ├── addButton "新增片段" (spacingSm)
│   └── tableView (撑满, keyword+content 双行 cell, minRowHeight 44)
└── rightPane: NSView  (撑满剩余)
    └── detailContainer (ContentColumnView 包裹, 切四态)
```

四态 child VC containment 切换（对齐 `pluginPanelContainer` 现有机制）：
- 空态 / create / edit / preview 各为独立构建的 NSView，塞进 rightPane 的 ContentColumnView contentColumn。
- 字段卡用 `SettingsGroupView`（keyword / content / 占位符提示各一组），操作栏 `HStack` 等价的 AppKit `NSStackView`。

### 4.4 AC-SNIPGUI 契约映射

| AC | 含义 | 迁移后 |
|---|---|---|
| 01 双栏渲染 | 固定宽度并列双 NSView（等价） | ✅ |
| 02 默认选 row 0 | tableView 逻辑保留 | ✅ |
| 03 无面板→空态 | 路由层不变 | ✅ |
| 04 A→B→A 复现 | containment 缓存不变 | ✅ |
| 05 选中持久化 | UserDefaults key 不变 | ✅ |
| 08 新增写 snippets.json | service 不变 | ✅ |
| 09 编辑 updated_at 变 | service 不变 | ✅ |
| 10 删除二次确认 | presentDeleteAlert/handleDeleteResponse seam 保留 | ✅ |
| 11 确认删除移除 | service 不变 | ✅ |
| 12 搜索过滤 ≤300ms | NSTableView + searchField 即时过滤 | ✅ |
| 13 占位符提示 | NSTextField 可遍历（更好测） | ✅ |
| 14/15 空态/损坏容错 | service 不变 | ✅ |
| 17/18 字段/长度校验 | service 不变 + GUI 字段级错误 | ✅ |
| 23 占位符展开预览 | expandPlaceholders 不变 | ✅ |
| 28 焦点保持 | 外层 sendEvent 兜底 | ✅ |

数据层契约 C1-C6（接口 / schema / 校验 / 路径原子写 / 一致性）全部不变。

### 4.5 测试处置清单

| 测试 | 处置 |
|---|---|
| `SnippetsServiceTests`(21) | 保留不动 |
| `SnipGUIInProcessAcceptanceTests` 路由层（AC-01/02/03/04/05/10/27/28） | 保留 |
| 契约编译测试（C1-C4） | 保留 |
| `SnipPanelVCSnapshotTests` expandPlaceholders/serviceCRUD | 保留 |
| `SnipPanelVCSnapshotTests.test_snipPanelVC_*` | 适配（父类变 NSViewController，makePanelVC 仍 self） |
| AC-13 占位符提示 | 适配（NSTextField 遍历） |
| `SnipWindowSizingTests` | 适配（删 hack 后） |
| `SettingsPageSnapshotTests`(general/plugin/about/hotkey × light/dark) | 重录基线 |
| `SnipPanelRenderDiagnosticTests`(create/edit/empty) | 重录基线（SwiftUI→AppKit） |
| `SkinGallerySnapshotTests` | 检查（若动网格间距） |
| snip AppKit 端到端（AC-08/09/12/17/18 GUI 路径） | 新增 |

---

## 5. 风险与开放问题

- **ContentColumnView 接入破坏现有 AX 测试**：`settings.detail` AX id 当前挂在 child root view + 容器 view（`SettingsSplitVC:160,170`）。接入后需重新确认挂在 ContentColumnView 且不被遮蔽，红队 SC-01..16 守护。
- **objectWillChange 桥接刷新时机**：AppKit 无 SwiftUI 自动刷新，`service.objectWillChange.sink { reloadData }` 需确保 CRUD 后立即触发（@MainActor 同步，预期无延迟）。
- **SkinGallery 不套 ContentColumnView 的一致性**：皮肤市场与其他面板视觉语言可能略有不齐（网格 vs 列）。可接受——网格市场本就该用全宽。
- **行号准确性**：4.1 映射表的行号来自摸底，实现时遵循 0 假设原则以源码为准核对。

## 6. 非目标（YAGNI）

- **不改皮肤市场架构**：SkinGallery 仅收口间距/卡片样式，不重做 CollectionView。
- **不重做信息架构**：保留三面板现有内容组织（哪些设置项、哪些插件信息），只改布局/排版/范式。
- **不引入新功能**：不加新设置项、新插件能力。
- **不换品牌色**：保留 sage 绿，不做配色重设计（用户明确核心是布局非 UI）。
- **不碰 Launcher 浮窗 / 猫咪 / 菜单栏**：仅设置窗口三个面板。
- **不做视觉装饰重设计**（阴影/玻璃/动效）：留待布局骨架稳后另开。
