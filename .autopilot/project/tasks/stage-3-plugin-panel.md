---
id: stage-3-plugin-panel
depends_on: [stage-2-settings-main]
plan_tasks: [7, 8, 9]
---

# stage-3 插件面板双栏改造

## 目标
插件左栏固定 240 + 删比例算法 + PluginListCellView 补图标重排 + globalHeader 间距收口 + 右栏包 ContentColumnView（只包右栏非整体）+ 重录插件快照。

## 架构上下文
架构 ③④⑤。双栏 master-detail：左栏固定 240（删 200-260 区间 + `min(220,width/3)` 比例算法，消除拖动跳动），右栏内容进 ContentColumnView（**只包右栏**，因左栏需占满高度固定宽）。列表项范式 `[icon16pt][nameLabel+summaryLabel 左对齐列][sourceBadge][toggle 右对齐 baseline]`，补 16pt SF Symbol 图标。

## 输入/输出契约
- 输入：ContentColumnView + spacing token + `pluginListWidth`（stage-0）
- 输出：插件面板左栏固定 240 + 列表项范式（含图标）+ 右栏限宽居中

## 验收标准（det-machine 谓词）
- AC-SPLIT-02（插件/snip 左栏宽恒 240）
- AC-SPLIT-03（拖分隔条松手回弹固定值）
- AC-SPLIT-04（三面板切换左栏不跳）
- AC-SPLIT-05（osascript 真机读 splitter 一致）
- AC-SNAP-01/02（插件快照重录后稳定）
- `make build && make lint` 过 + 路由测试（SnipGUIInProcessAcceptanceTests 路由层）过

## 实现引用
plan **Task 7**（左栏固定 240 + 删比例算法）/ **Task 8**（PluginListCellView 补图标重排 + globalHeader 间距收口 + 右栏包 ContentColumnView）/ **Task 9**（重录插件快照 + 真机验证）。
