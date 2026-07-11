# stage-3 Handoff

## 实现摘要
插件面板双栏改造（plan Task 7-9）：左栏固定 240 + 删 `min(220,width/3)` 比例算法（消除拖动跳动）+ PluginListCellView 补 16pt SF Symbol 图标重排（`[icon][name+summary][badge][toggle]`）+ globalHeader 间距收口 + 右栏包 ContentColumnView（只包右栏）+ cell AX id + 重录快照。

## 文件变更（3 commits + merge）
- `8e30326` 左栏固定 240（plain NSSplitView setPosition 显式驱动）
- `93cfe88` cell 补图标重排 + globalHeader 收口 + 右栏包 ContentColumnView + cell AX id
- `1f740c0` 重录插件快照（helper host NSWindow 真实几何）
- merge commit（红队 PluginGalleryLayoutAcceptanceTests + sidebar.ai 注释同步）

## 下游须知（stage-4 snip 迁 AppKit）
- **snip master-detail 范式**：左栏固定 240 + 右栏 ContentColumnView，但 snip 用**并列 NSView**（非 NSSplitView，plan Task 10）——更简单，**无 plain NSSplitView 的 setPosition headless 盲区**。
- **cell 范式已建立**（stage-3 PluginListCellView `[icon][name+summary][badge][toggle]`）：stage-4 SnipListCellView（双行 cell keyword+content）复用同范式。
- **frame 谓词 in-process 模式成熟**（stage-2/3）：SettingsWindowController + 真实 window + 递归找 NSSplitView/AX id/ContentColumnView。stage-4 验证 AC-CRUD（snip CRUD）用 in-process + NSAlert seam（presentDeleteAlert/handleDeleteResponse），AC-WIN（窗口稳定）用真实 window frame。
- **AX**：cell AX id（`settings.plugins.cell.{name}`）已建立；snip 加 AX id（`settings.snip.*`）不冲突 settings.detail 唯一性（stage-2 已修订）。

## 偏差说明
- 蓝队修正 plain NSSplitView headless 盲区：① `setPosition` 显式驱动 divider（删整段会塌缩，plain NSSplitView 无 NSSplitViewItem 抽象）② 快照 helper 改 host NSWindow（旧裸 vc.view helper headless 下两栏坍缩，捕获错误单栏布局）。这是 NSScrollView 盲区（patterns/2026-07-03）的同类（AppKit 分栏/滚动控件 headless 几何盲区）。
- 工作区注释 M（SettingsAXContractTests/SettingsSidebarAcceptanceTests 补 `settings.sidebar.ai`）是 SettingsSection.ai 注释同步（非功能性），merge 顺带 commit。无功能偏差。