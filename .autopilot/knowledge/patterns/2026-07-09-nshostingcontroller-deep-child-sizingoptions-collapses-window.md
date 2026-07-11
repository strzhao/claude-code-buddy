---
name: nshostingcontroller-deep-child-sizingoptions-collapses-window
description: NSHostingController 作深层 child VC（非直接 contentViewController），其 sizingOptions 默认 [.minSize,.maxSize,.preferredContentSize] 把 SwiftUI root（无 explicit frame）塌缩的 fittingSize 经 preferredContentSize 向上传播，压缩顶层 NSWindow；修复 = sizingOptions=[] 切断（detail pane 有 equality 约束撑满，不需 window 跟随）
metadata:
  type: pattern
---

# NSHostingController 深层 child 的 sizingOptions 默认传播塌缩 fittingSize 压顶层 window

## 现象

设置 → 插件 → snip 面板后，整个设置窗口高度突然变得非常矮（被压到 window minSize 兜底值），切到别的分类也不恢复，用户无法拖回。

## 根因

`SnipPanelVC` 是 `NSHostingController<SnipPanelView>`，作为**4 层深的 child VC**挂在设置窗口上：

```
NSWindow.contentViewController
  └─ SettingsSplitViewController（外层 NSSplitView）
       └─ SettingsDetailContainerViewController（detail 容器，containment 切 child）
            └─ PluginGalleryViewController（内层 NSSplitView：插件列表 + detail）
                 └─ pluginPanelContainer（4 边 equality 约束）
                      └─ SnipPanelVC（NSHostingController）← 此处
```

两个叠加因素：

1. **SwiftUI root 缺 height frame → fittingSize 塌缩**：`SnipPanelView.body` 的 root `HSplitView` 只给了 `listPane.frame(minWidth: 220)` + `detailPane.frame(minWidth: 320)`，**没有 height**。空态内容只有一个小 Image + Text，SwiftUI ideal size 塌缩到 **32×32**（实测 `SnipPanelVC.view.fittingSize = (32, 32)`）。

2. **NSHostingController 默认 sizingOptions 全传播**：macOS 14 实测 `sizingOptions.rawValue = 7` = `[.minSize, .maxSize, .preferredContentSize]`。hosting controller 把塌缩的 fittingSize（32×32）写入自己的 `preferredContentSize`，经 VC containment 链向上传播，最终顶层 `NSWindow` 遵循 contentViewController 的 preferredContentSize 把 contentSize 压到该值（window `minSize 800×560` 兜底，故用户见「非常矮」）。

对照：其他 detail VC（`GeneralSettingsViewController` / `SkinGalleryViewController` / `PluginGalleryViewController`）`loadView` 都用**固定 frame NSView**（防 fittingSize 缩 0，[[appkit-contentviewcontroller-root-view-frame-fitting-size]]），且不是 NSHostingController、不主动传播 preferredContentSize → 不触发。

## 机制证据（直接 contentVC 复现）

把 `NSHostingController(rootView: Text("x").frame(width:50,height:40))` 直接设为 `NSWindow.contentViewController`：默认 sizingOptions 下 window contentSize 被压到 **(50, 40)**（= fittingSize）。这证明 `sizingOptions` 是「hosting fittingSize → window」的传播开关。swift test headless 环境复现不了**深层 child** 的端到端传播（preferredContentSize 经 VC 链到 window 需完整 window server session），但用**直接 contentVC** 场景（[[swiftui-frame-nshosting-controller-resize]] 同款）能确证 sizingOptions 的传播行为，配合 fittingSize 塌缩（32×32 可单元测试捕获）两条独立证据锁定根因。

## 修复

`SnipPanelVC.init` 显式切断传播：

```swift
super.init(rootView: view)
// 切断 hosting controller → 父级/window 的 sizing 传播
if #available(macOS 13.0, *) {
    sizingOptions = []
}
```

snip 是**固定 detail pane**（`pluginPanelContainer` 四边 equality 约束撑满），不需要 window 跟随 SwiftUI fittingSize。`sizingOptions = []` 后 hosting controller 不再向父级报告任何 sizing，equality 约束接管让 view 撑满容器，window 高度稳定。

## Lesson

- **NSHostingController 的 sizingOptions 是双向开关**：浮窗需要 window 跟随 SwiftUI 动态高度 → `[.preferredContentSize]`（[[nshostingcontroller-sizingoptions-preferredcontentsize]]）；固定容器里的 detail pane 不需要跟随 → `[]` 切断。选错方向就压缩窗口或内容飘出。
- **两种「SwiftUI 缺 frame 压窗口」场景区分**：
  - 直接 contentViewController（[[swiftui-frame-nshosting-controller-resize]]）→ 给 SwiftUI root 加 explicit `.frame(width:,height:)`。
  - 深层 child detail pane（本 pattern）→ `sizingOptions = []` 切断传播（equality 约束接管，加 root frame 反而可能与窄容器 equality 约束冲突）。
- **swift test headless 复现不了 hosting→window 端到端**：深层 child preferredContentSize 经 VC 链传到顶层 window 需完整 window server session；单元测试只能捕获根因属性（fittingSize 塌缩值 + sizingOptions 值）+ 直接 contentVC 机制证据，端到端须真机验证（与 [[nsscrollview-documentview-bottom-align-snapshot-blindspot]] 同款「隔离 snapshot 复现不了，须真机」教训）。

## Related

- [[swiftui-frame-nshosting-controller-resize]]（直接 contentVC + root frame）
- [[nshostingcontroller-sizingoptions-preferredcontentsize]]（浮窗正向用 [.preferredContentSize]）
- [[appkit-contentviewcontroller-root-view-frame-fitting-size]]（AppKit VC 固定 frame 防缩，对照）
