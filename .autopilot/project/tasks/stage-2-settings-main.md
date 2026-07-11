---
id: stage-2-settings-main
depends_on: [stage-1-content-column]
plan_tasks: [3, 4, 5, 6]
---

# stage-2 设置主体套地基 + 间距收口

## 目标
复用组件间距收口（GroupView/ToggleRow/FormRow）+ 单栏设置页（General/About/Hotkey/Provider）包 ContentColumnView + EmptyPluginStateVC 响应式 + sidebar 固定 200 + **AX 唯一性修订** + 重录设置快照。

## 架构上下文
架构 ①②③④。ContentColumnView 作为内容容器：单栏面板（General/About/Hotkey/Provider）整体包；双栏（PluginGallery/snip）在后续阶段只包右栏。SkinGallery 不套（网格全宽）。Provider 去 自建 ScrollView 改 ContentColumnView。

## 输入/输出契约
- 输入：ContentColumnView（stage-1）+ spacing token（stage-0）
- 输出：单栏设置页限宽居中 + 组件间距统一栅格 + AX id 唯一 + sidebar 固定 200

## 验收标准（det-machine 谓词）
- AC-WIDTH-01/02/03/04（限宽居中：宽屏 ≤780 / 窄屏贴边 / margin 对称 / 可滚）
- AC-SPLIT-01（sidebar 宽恒 200）
- AC-AX-01（settings.detail 全窗 ==命中唯一）
- AC-SNAP-01/02（设置快照重录后自稳定 + 非像素断言全绿）
- `make build && make lint` 过

## 实现引用
plan **Task 3**（组件收口）/ **Task 4**（单栏 VC 包 ContentColumnView）/ **Task 5**（Provider 去 scroll + Empty 响应式）/ **Task 6**（sidebar 固定 + 重录快照）。

## ⚠️ 阶段 2 必做（blocker 级）
1. **AX 唯一性 3 处修订**（Global Constraints）：①`SettingsSplitViewController:170` 容器 view AX id `settings.detail`→`settings.detail.container`；②`EmptyPluginStateVC:121` container AX id `settings.detail`→`settings.plugin.empty`；③`:160` child root view 保持 `settings.detail`。
2. **ProviderSettings JSON tab NSTextView 三件套**（patterns/2026-07-02）：jsonTextView 作子控件须 `autoresizingMask=.width` + `widthTracksTextView=true` + containerSize。
3. **自定义 NSView size**（patterns/2026-07-09）：ContentColumnView/新组件须 intrinsicContentSize 或宿主显式 width/height。
