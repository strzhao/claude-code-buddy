# AppKit 布局 headless 几何验证：真实 NSWindow in-process + plain NSSplitView setPosition + 快照 host NSWindow

设置/插件/snip 面板布局重构（5 阶段 project）沉淀：headless `swift test` 验证 frame 级布局谓词（限宽 ≤780 / sidebar 200 / 列表栏 240 / AX 唯一 / 窗口不塌缩）的方法。NSScrollView/NSSplitView/窗口几何在 headless 无 window server 时塌缩或两栏坍缩，patterns/2026-07-03 已记 NSScrollView 须真机——本模式给出 in-process 替代（更可靠，不依赖 osascript AX 路由 patterns/2026-06-23）。

## 模式 1：frame 谓词 in-process（真实 NSWindow 驱动，替代 osascript 外部）

```swift
let wc = SettingsWindowController()
let splitVC = wc.window?.contentViewController as? SettingsSplitViewController  // @testable
splitVC?.testHook_selectSection(.plugins)
splitVC?.view.layoutSubtreeIfNeeded()
// sidebar 宽（NSSplitViewController）：
let w = splitVC?.splitViewItems[0].viewController.view.bounds.width  // == 200
// AX 唯一（递归）：
let matches = splitVC?.view.findAllSubviews(where: { $0.accessibilityIdentifier() == "settings.detail" })
// 限宽（递归找 ContentColumnView）：
let col = splitVC?.view.findAllSubviews(of: ContentColumnView.self).first
// col?.contentColumn.bounds.width <= 780
// 改窗口宽（defensive optional，contentView 是 NSView?）：
let h = wc.window?.contentView?.bounds.height ?? 600
wc.window?.setContentSize(NSSize(width: 1400, height: h))
wc.window?.layoutIfNeeded()
```

- 用真实 NSWindow（非 show，仅提供 window 上下文让 viewDidLayout 触发），不依赖 osascript 外部 AX（LSUIElement osascript click 不路由 patterns/2026-06-23）。
- `splitViewItems[0]`（NSSplitViewController）vs `splitView.arrangedSubviews[0]`（plain NSSplitView）—— 插件面板内部是 plain NSSplitView（addSubview，非 NSSplitViewController），须用 arrangedSubviews。
- AX id 定位插件面板 splitView：`settings.plugins.splitview` 精确定位（避免误中顶层 splitView）。

## 模式 2：plain NSSplitView（非 NSSplitViewController）headless 盲区

plain NSSplitView（addSubview 两栏，无 NSSplitViewItem 抽象）headless 下：
- **setPosition 显式驱动 divider**：删 viewDidLayout 的 setPosition 整段会两栏坍缩（约束不够，右栏 detailContainer 宽度→0）。必须保留 `setPosition(fixedWidth, ofDividerAt: 0)`（固定宽，删比例算法 `min(220, width/3)`）。
- **快照 helper 改 host NSWindow**：裸 `vc.view` + `layoutSubtreeIfNeeded()` 在 headless 下两栏坍缩，快照捕获**错误单栏布局**（light/dark 文件大小完全相同，明显异常）。改 helper host 进临时 `NSWindow`（不 show，仅 window 上下文让 viewDidLayout 触发 → setPosition → 两栏正确），新基线 light/dark 大小不同。

## 证据
- stage-2 `SettingsFrameAcceptanceTests` + `SettingsLayoutAcceptanceTests`（AC-AX-01 全窗递归唯一 / AC-SPLIT-01 sidebar 200 三宽度 / AC-WIDTH-01 限宽 ≤780）
- stage-3 `PluginGalleryLayoutAcceptanceTests`（AC-SPLIT-02 左栏 240 / AC-SPLIT-04 切换不跳，arrangedSubviews[0] + AX id 定位）
- stage-3 蓝队修正 plain NSSplitView setPosition（删整段塌缩，group 宽 311→80）+ 快照 helper NSWindow（旧 helper 错误单栏，light/dark 同大小）
- stage-4 `SnipAppKitAcceptanceTests`（AC-WIN-01 sizingOptions==0 / AC-WIN-02 非 NSHostingController / preferredContentSize 不塌缩）

## 关联
patterns/2026-07-03（NSScrollView documentView 贴底须真机）—— 本模式演进：in-process 真实 NSWindow 替代 osascript 真机，覆盖 NSScrollView/NSSplitView/窗口几何 headless 盲区。patterns/2026-07-09（自定义 NSView test hook 盲区）—— frame 谓词读外部可观测 bounds，不依赖 test hook 内部。

<!-- tags: appkit, nswindow, nssplitview, nsscrollview, layout, frame-assertion, in-process, xctest, headless, blind-spot, settings, contentcolumnview, ax, real-window, snapshot, setposition, plain-nssplitview, autoresizing, testhook, splitviewitems, arrangedsubviews, ac-width, ac-split, ac-ax, ac-win, 5-stage-project -->
