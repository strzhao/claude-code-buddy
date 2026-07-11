# Settings / Plugins / Snip 面板布局重构 — 架构设计

> 权威 spec / plan：
> - `docs/superpowers/specs/2026-07-10-settings-plugins-snip-layout-redesign-design.md`
> - `docs/superpowers/plans/2026-07-10-settings-plugins-snip-layout-redesign.md`（13 task TDD）
> Plan 审查：✅ 2 轮通过（初审修 2 blocker + 4 important，重审 PASS）。

## Context
设置窗口三面板（设置主体/插件/snip）布局简陋根因：①内容贴边拉满无限宽居中（头号元凶）②间距硬编码混用 ③分栏比例写死且自相矛盾（拖动跳）④三面板范式不齐 + AppKit/SwiftUI 技术栈混杂（snip SwiftUI 挂 sizingOptions hack）。核心是**布局非视觉装饰**。代码层已有设计骨架（SettingsTheme token / 复用组件 / 空态），属"骨架在、观感简陋"，补齐打磨而非推翻。

## 整体架构设计
1. **ContentColumnView 内容容器**（新建）：`NSScrollView → documentView（宽度跟随 clip 只竖滚 + height≥contentView 防贴底盲区 patterns/2026-07-03）→ contentColumn（width≤780 + centerX 居中）`。各面板按需用（单栏整体包 / 双栏只包右栏 / SkinGallery 不用）。
2. **间距栅格收口**：SettingsTheme 加 4 倍数 scale（xs4/sm8/md12/lg16/xl24/xxl32/section48）+ 布局常量（contentMaxWidth780/sidebarWidth200/pluginListWidth240/minRowHeight44）；硬编码→scale。
3. **分栏固定**：sidebar 200 / 列表栏 240，删区间 + 比例算法。
4. **master-detail 范式统一**：左固定宽栏 + 右限宽居中内容列。
5. **snip 迁 AppKit**：SnipPanelVC 从 NSHostingController<SnipPanelView> 重写为 NSViewController（master-detail），删 SnipPanelView.swift + sizingOptions hack；保留 presentDeleteAlert/handleDeleteResponse test seam；objectWillChange sink 刷新列表。

## 任务 DAG（5 阶段线性）
stage-0 栅格 token → stage-1 ContentColumnView → stage-2 设置主体套地基 → stage-3 插件面板 → stage-4 snip 迁 AppKit。对应 plan Task 1 / 2 / 3-6 / 7-9 / 10-13。

## 跨任务设计约束（所有阶段硬约束）
- **数据层零改动**：SnippetsService / SnippetItem / SnippetsError / snippets.json schema / PluginSettingsPanelProvider / PluginPanelRegistry 注册——全程不动。
- **AX 契约**（AC-AX-01 唯一性）：settings.detail **只在活动 child root view**；阶段 2 修订 3 处（SettingsSplitVC:170→settings.detail.container / EmptyPluginStateVC:121→settings.plugin.empty / :160 child 保持 settings.detail），全窗 ==settings.detail 命中唯一。sidebar row id settings.sidebar.{section}；窗口 title 设置。
- **栅格单一来源**：阶段 0 后所有间距引用 SettingsTheme.spacing*，禁硬编码。
- **自定义 NSView 盲区**（patterns/2026-07-09）：新建自定义 NSView 须覆盖 intrinsicContentSize 或宿主显式 width/height 约束，否则 0×0 点不动；禁绕过真实 mouseDown 的 test hook。
- **NSScrollView 盲区**（patterns/2026-07-03）：documentView 须 height ≥ contentView.height（防贴底空顶），headless 复现不了须真机/osascript。
- **NSTextView width=0**（patterns/2026-07-02）：作 documentView/子控件须 autoresizingMask=.width + widthTracksTextView。
- **CALayer 外观**（patterns/2026-06-28）：用 layer 须 viewDidChangeEffectiveAppearance 刷新 cgColor。
- **日志**：BuddyLogger（subsystem settings/snippets），禁 print/NSLog。
- **真机 QA（AI 自测，不依赖用户手动 GUI）**：每阶段 SKIP_FETCH_PLUGINS=1 make bundle → pkill+open → AI 用 osascript 读 frame + in-process XCTest 驱动。纯视觉 fallback 用户目视。
- **testHook 原则**（patterns/2026-07-09）：经真实 action（performClick/selectRowIndexes），禁直接调私有方法。
- **阶段间快照中间态**：各阶段末只重录该阶段涉及面板快照，阶段间允许半新半旧。

## 契约规约（C1-C7）
- C1 数据层不变：SnippetsService API（add/edit/delete/search/list/expandPlaceholders）/ @MainActor ObservableObject / init(snippetsFile:) seam。
- C2 schema 不变：SnippetItem Codable（keyword/content/created_at/updated_at，ISO8601，顶级数组）。
- C3 校验不变：keyword [A-Za-z0-9_-] 1-64 / content ≤10000 / SnippetsError 四 case。
- C4 AX 不变：settings.detail / settings.sidebar.{section} / 窗口 title。
- C5 栅格单一来源 + NSView size。
- C6 SnipPanelVC：类名保留 / makePanelVC()->self / presentDeleteAlert+handleDeleteResponse seam / PluginPanelRegistry 注册不变。
- C7 ScrollView 稳定：documentView height ≥ contentView height / 限宽 780 居中只竖滚。

## 验收场景
29 条预注册谓词（28 det-machine / 1 det-human），见 state.md `## 验收场景`：限宽居中 4 / 分栏固定 5 / snip CRUD 7 / 窗口稳定 5 / AX 可达 4 / 快照回归 4。红队/qa SSOT。
