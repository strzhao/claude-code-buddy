---
id: stage-0-grid-token
depends_on: []
plan_tasks: [1]
---

# stage-0 栅格 token 扩展

## 目标
SettingsTheme 加 4 倍数间距 scale + 布局常量，作为后续所有阶段间距的唯一来源。

## 架构上下文（摘自 design.md）
间距栅格收口是地基（架构 ②）。新增 `spacingXs4/sm8/md12/lg16/xl24/xxl32/section48` + `contentMaxWidth780/sidebarWidth200/pluginListWidth240/minRowHeight44/contentTopInset48`；现有语义 token（contentPadding/groupSpacing/groupTopInset/cardContentPadding/rowSpacing）值收口到 scale，语义名保留（调用方零改动）。

## 输入/输出契约
- 输入：无（第一阶段）
- 输出：`SettingsTheme.spacing*` + 布局常量（后续阶段消费）

## 验收标准
- `SettingsThemeTests` 3 测试（scale 值 / 布局常量 / 语义 token 对齐 scale）全绿
- `make build && make lint` 过（语义 token 名不变，调用方零改动）

## 实现引用
plan `docs/superpowers/plans/2026-07-10-settings-plugins-snip-layout-redesign.md` **Task 1**（完整 TDD 步骤 + 代码 + commit message）。蓝队按 Task 1 的 6 个 Step 执行。
