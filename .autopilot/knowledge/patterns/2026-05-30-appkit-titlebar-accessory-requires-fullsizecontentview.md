# macOS NSTitlebarAccessoryViewController 强制要求 `.fullSizeContentView` styleMask

<!-- tags: appkit, nswindow, stylemask, fullsizecontentview, nstitlebaraccessoryviewcontroller, titlebar, segmentedcontrol, macos14, red-team-finding, blue-team-fix, settings, buddy-store -->

**Scenario**: task 005 实现 Buddy Store UI 重构。SettingsWindowController 顶部要嵌入 NSSegmentedControl 切 [皮肤/插件] tabs。设计选 `NSTitlebarAccessoryViewController` 嵌入 titlebar（macOS 11+ 原生支持，比自绘 toolbar 优雅）。

第一版蓝队实现：

```swift
let panel = SettingsPanel(
    contentRect: NSRect(x: 0, y: 0, width: 600, height: 540),
    styleMask: [.titled, .closable, .resizable],  // ❌ 缺 .fullSizeContentView
    backing: .buffered,
    defer: true
)
// ...
let accessoryVC = NSTitlebarAccessoryViewController()
accessoryVC.view = segmentedControl
accessoryVC.layoutAttribute = .top  // ⚠️ 关键：.top 触发隐藏约束
panel.addTitlebarAccessoryViewController(accessoryVC)
```

红队 AT01-AT04 跑测试时抛**所有红队 UI 测试都崩**：

```
NSInternalInconsistencyException: NSLayoutAttributeTop requires
NSWindowStyleMaskFullSizeContentView to be set on the window
```

**Lesson**: macOS 14+ AppKit 加严：`NSTitlebarAccessoryViewController` 的 `layoutAttribute = .top` 强制要求 **`NSWindow.styleMask` 含 `.fullSizeContentView`**。AppKit 文档对此**隐藏说明**（仅在错误提示里暴露），开发者写惯 `.titled | .closable | .resizable` 三件套就会踩坑。

修复极简：

```swift
let panel = SettingsPanel(
    contentRect: NSRect(x: 0, y: 0, width: 600, height: 540),
    styleMask: [.titled, .closable, .resizable, .fullSizeContentView],  // ✅
    backing: .buffered,
    defer: true
)
```

**为什么 `.fullSizeContentView` 是必需的**：

- `.fullSizeContentView` 让 window 的 `contentView` 延伸到 titlebar 区域之下（视觉上 titlebar 与内容融合，常见于现代 macOS app 如 Safari/Xcode）
- 这是 `NSTitlebarAccessoryViewController.layoutAttribute = .top` 渲染的前提：accessory view 需要"漂浮"在 contentView 之上
- 缺失时 AppKit 无法计算 accessory 的 layout 锚点，遂抛异常

**关联陷阱**：

- 加了 `.fullSizeContentView` 后 contentView 顶部会被 titlebar 遮挡 ~28pt（macOS 默认 titlebar 高度）。若用 autolayout 把 contentView 的子视图 `.top` 锚到 contentView，子视图会被遮 → 需要：
  - 留 titlebar safe-area inset
  - 或 子视图改锚 `safeAreaLayoutGuide.topAnchor`（macOS 11+）
  - 或 NSTitlebarAccessoryViewController 自带的 safe area 调整

```swift
// 子视图避免被 titlebar 遮的正确锚法
mySubview.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor).isActive = true
```

**Evidence**: task 005 红队 AT01-AT04 抓到此异常 → 蓝队据此修复 SettingsWindowController.swift line 25 styleMask → 重跑 24 tests 全过。**这是红蓝对抗设计的最佳案例**——红队独立测试发现蓝队真 bug，无需 plan-reviewer 介入。

**侦察清单**（写 macOS app + titlebar accessory 时立即检查）：

1. ✅ NSWindow.styleMask 含 `.fullSizeContentView`
2. ✅ NSTitlebarAccessoryViewController.layoutAttribute 是 `.top` / `.bottom` / `.leading` / `.trailing` 之一
3. ✅ 子视图 autolayout 用 `safeAreaLayoutGuide` 避免被 titlebar 遮
4. ✅ 测试覆盖 init 路径（确保 styleMask 异常被立即捕获，不留到运行时）

**关联**：
- 与 SettingsWindowController 重构通用模式：rename + segmentedControl + content VC 切换
- 与 `.copy("Plugins")` task 001 SwiftPM 资源声明陷阱（同样属于 AppKit/SwiftPM 文档隐藏要求）
- 类似教训：AppKit error 提示通常很准确（包含具体的 styleMask flag 名字），开发者**遇到 AppKit 异常应优先 grep error message 全文**而非凭直觉
