---
id: stage-1-content-column
depends_on: [stage-0-grid-token]
plan_tasks: [2]
---

# stage-1 ContentColumnView 内容容器

## 目标
新建 ContentColumnView（限宽 780 居中 + 内嵌滚动），作为各面板主内容区容器。

## 架构上下文
架构 ①。`NSScrollView → documentView（宽度跟随 clip 只竖滚 + height≥contentView 防贴底盲区）→ contentColumn（width≤780 + centerX）`。AX：透明容器不挂 id，调用方 child view 持 AX 锚点（契约 7）。

## 输入/输出契约
- 输入：`SettingsTheme.spacing*` + `contentMaxWidth`（stage-0）
- 输出：`ContentColumnView`（NSView）+ `.contentColumn`（调用方加内容）+ `.scrollView`（let，可访问）+ `.maxWidth`（test seam）

## 验收标准
- `ContentColumnViewTests` 5 测试（scrollView/contentColumn 存在 / 限宽 ≤780 / maxWidth seam / 加内容 / **documentView height≥contentView 防贴底**）全绿

## 实现引用
plan **Task 2**。⚠️ **必含** `documentView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor)`（patterns/2026-07-03 防 NSScrollView 贴底空顶，plan 已落地）。
