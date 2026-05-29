---
name: nshostingcontroller-sizingoptions-preferredcontentsize
description: NSHostingController.sizingOptions = .preferredContentSize 让 SwiftUI 内 .frame(height:) 自动同步 NSPanel.contentSize，解决 panel frame 不跟随 SwiftUI 动态高度的"内容飘到 panel 外"问题（macOS 13+）
metadata:
  type: pattern
---

# NSPanel + SwiftUI 动态高度同步：sizingOptions = .preferredContentSize

## 背景

LSUIElement launcher 浮窗（NSPanel + NSHostingController）的 SwiftUI 内容随状态展开（输入区 + 候选行 + 输出区），SwiftUI 用 `.frame(height: panelHeight(...))` 设置内容高度。但 NSPanel 本身的 `contentSize` 没动 → SwiftUI 子视图（候选行、输出文字）**画到 panel 边界外的虚空中**。

具体表现：用户截图显示 "Hello! How can I help today?" 输出在 panel 外面飘着，毛玻璃只覆盖到 panel 实际 frame（90pt 高），下面的内容暴露在桌面上。

## 为什么默认不同步

NSPanel.contentSize 由 init contentRect 决定（task 010 初始 `windowMinHeight: 90`），后续不会自动响应 NSHostingController 内 SwiftUI 视图的 frame 变化。NSHostingController 默认行为是渲染 SwiftUI body，但不向上传播 `preferredContentSize` → NSPanel 不知道要 resize。

## 正确做法

macOS 13+ 的 `NSHostingController.sizingOptions`：

```swift
final class LauncherHostingController: NSHostingController<LauncherInputView> {
    init(manager: LauncherManager) {
        super.init(rootView: LauncherInputView(manager: manager))
        // 让 SwiftUI 内 .frame(height: ...) 的 fittingSize 自动同步到 NSWindow.contentSize
        if #available(macOS 13.0, *) {
            sizingOptions = [.preferredContentSize]
        }
    }
}
```

机制：
- `.preferredContentSize` 让 NSHostingController 把 SwiftUI 视图的 fittingSize 计算结果写入自己的 `preferredContentSize`
- NSWindow / NSPanel 自动遵循 `contentViewController.preferredContentSize` 来调整 contentSize
- 每次 SwiftUI 内 `.frame(height: ...)` 的值变化（因 manager state 变化），preferredContentSize 重算 → panel.contentSize 自动 resize

可用选项（OptionSet）：
- `.minSize`：传播 minimum 但不限制最大
- `.maxSize`：传播 maximum
- `.preferredContentSize`：双向同步推荐尺寸（最常用）
- `.intrinsicContentSize`：内 SwiftUI 视图的固有尺寸

launcher 浮窗用 `.preferredContentSize` 单值即可。

## 配合 NSVisualEffectView

如果 panel 有手动注入的 NSVisualEffectView（或 contentView 圆角 mask），它们的 layout 通过 autoresizing mask 或 constraints 跟随 contentView 自动 resize → 毛玻璃 / 圆角随 panel 高度同步无需额外代码。

## 重启 panel 时的位置漂移

panel 高度因之前 sizingOptions 变成 600pt 后，下次 `show()` 时如果不重置：
- `centerOnScreen()` 基于当前 600pt frame 计算 y 坐标 → 浮窗居中位置偏高
- 解决：show() 开头先 `setContentSize(NSSize(width: ..., height: minHeight))` 把 panel 缩回初始小尺寸，再 centerOnScreen → SwiftUI sizingOptions 会立刻把 panel 重新撑到当前内容尺寸

```swift
func show() {
    let w = launcherWindow
    // 重置回初始小尺寸，避免上次大尺寸残留导致居中位置偏高
    w.setContentSize(NSSize(width: LauncherConstants.windowWidth, height: LauncherConstants.windowMinHeight))
    w.centerOnScreen()
    NSApp.activate(ignoringOtherApps: true)
    w.makeKeyAndOrderFront(nil)
}
```

## Evidence

task 010 launcher UI 升级 retry 2：
- 第 3 轮：用户截图 "Hello!" 输出文字飘在 panel 下方虚空 → 诊断为 panel.frame 不跟 SwiftUI .frame 同步
- 加 `sizingOptions = [.preferredContentSize]` 一行 → 立刻解决

## Lesson

- **NSPanel + NSHostingController 内 SwiftUI 用 `.frame(height:)` 动态高度时，必须设 `sizingOptions = .preferredContentSize`**
- 重启 panel show() 前 setContentSize 回 minHeight，避免上次大尺寸残留影响居中
- macOS 13+ 才可用；老版本需自己 @Published 一个 height + KVO 手动同步

## Related

- [[2026-05-28 SwiftUI root view 缺 .frame 让 NSHostingController 把 NSPanel 缩到内容最小尺寸]]
- [[swiftui-material-vs-nsvisualeffectview-injection]]
