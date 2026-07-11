---
id: stage-4-snip-appkit
depends_on: [stage-3-plugin-panel]
plan_tasks: [10, 11, 12, 13]
---

# stage-4 snip 迁 AppKit

## 目标
SnipPanelVC 从 `NSHostingController<SnipPanelView>` 重写为纯 AppKit `NSViewController`（master-detail），删 `SnipPanelView.swift` + sizingOptions hack，保留 delete test seam，四态统一。

## 架构上下文
架构 ⑤。左栏固定 240（搜索框 + 新增按钮 + NSTableView keyword/content 双行 cell）+ 右栏 ContentColumnView 包四态（空/create/edit/preview，统一「标题区 / 字段卡 SettingsGroupView / 操作栏」）。`objectWillChange.sink { tableView.reloadData() }` 桥接刷新。`presentDeleteAlert`/`handleDeleteResponse` static test seam 保留。

## 输入/输出契约
- 输入：ContentColumnView + spacing token + `pluginListWidth` + SnippetsService（**不动**）
- 输出：纯 AppKit SnipPanelVC（类名保留 + `PluginSettingsPanelProvider.makePanelVC()->self` + delete seam + PluginPanelRegistry 注册不变）

## 验收标准（det-machine 谓词）
- AC-CRUD-01..07（snip CRUD 端到端 in-process：新增落盘 / 编辑时间戳 / 删除 NSAlert seam / 搜索过滤 / 占位符预览 / 非法 keyword 拒写 / 长度边界）
- AC-WIN-01（grep sizingOptions SnipPanelVC.swift == 0）/ AC-WIN-02..05（窗口不塌缩 / fittingSize≥200 / 无漂移 / osascript 真机）
- AC-AX-03（snip 8 类元素 AX id）/ AC-AX-04（AX 行可 press 选中）
- AC-SNAP-01/02/03（快照重录 + RenderDiagnostic 三态尺寸合理）
- 真机：进 snip 窗口高度不塌缩

## 实现引用
plan **Task 10**（master-detail 左栏 + 右栏骨架）/ **Task 11**（四态 detail）/ **Task 12**（数据流 + 删 SnipPanelView + sizingOptions hack）/ **Task 13**（测试适配 + 重录快照 + 真机验收）。

## ⚠️ 阶段 4 必做
1. **testHook 经真实 action**（patterns/2026-07-09）：`testHook_fillAndSaveCreate` 用 `createSaveButton?.target?.perform(action)`（performClick），禁直接调私有 saveCreate；`testHook_startCreate`/`testHook_selectRow` 调真实 API 合规。
2. **NSTextView width=0**（patterns/2026-07-02）：snip content editor 作 scrollView documentView 须 autoresizingMask=.width + widthTracksTextView。
3. **自定义 NSView size**（patterns/2026-07-09）：SnipListCellView 须宿主显式 width/height 或 intrinsicContentSize。
4. **数据层零改动**：SnippetsService 签名/schema/校验/seam 全程不变（C1-C3）。
