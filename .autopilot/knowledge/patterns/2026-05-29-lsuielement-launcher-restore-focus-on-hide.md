---
name: lsuielement-launcher-restore-focus-on-hide
description: LSUIElement launcher 浮窗（Alfred/Spotlight 模式）在 hide() 时切回召唤前的前台 app，让用户光标继续回到原终端/编辑器位置；用 NSWorkspace.frontmostApplication 记录 + DispatchQueue.main.async 调 NSRunningApplication.activate
metadata:
  type: pattern
---

# LSUIElement launcher 隐藏时切回召唤前的前台 app

## 背景

Spotlight / Raycast / Alfred 类 launcher 的标准 UX：用户在 Terminal 输入命令时按 ⌘⇧Space 召唤 launcher 临时用一下 → Esc 退出 → 焦点**自动回到 Terminal**，光标继续在原位置可以接着输入。

朴素实现只调 NSApp.activate + makeKeyAndOrderFront 召唤 + 调 orderOut(nil) 隐藏 → 隐藏后**焦点不一定回到原 app**，用户需要手动 ⌘Tab 切回去，体验断层。

## 实现

LauncherManager 加一个 `previousFrontApp` 属性，show() 时记录，hide() 时 activate 切回：

```swift
final class LauncherManager {
    private var previousFrontApp: NSRunningApplication?

    func show() {
        // 记录召唤前的前台 app（Terminal/编辑器等），排除 buddy app 自己避免循环
        let myPID = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != myPID {
            previousFrontApp = front
        }
        // ... centerOnScreen, NSApp.activate, makeKeyAndOrderFront ...
    }

    func hide() {
        // ... orderOut, isVisible = false ...
        launcherWindow.orderOut(nil)
        // 切回召唤前的前台 app（光标自动回到原终端/编辑器）
        if let prev = previousFrontApp {
            previousFrontApp = nil
            DispatchQueue.main.async {
                prev.activate(options: [])
            }
        }
    }
}
```

## 关键技术点

1. **排除自己**：必须 `front.processIdentifier != myPID` 判断。LSUIElement app 在某些场景（如 hotkey 监听器响应）可能短暂成为 frontmostApplication，如不排除会循环激活 buddy。

2. **DispatchQueue.main.async 必要**：直接 `prev.activate()` 在 `orderOut(nil)` 同步路径上调用，macOS 会**忽略**这次 activate（因为当前 activation 转换还没完成）。必须 async 推到下个 main run loop tick。

3. **options: []**：macOS 14+ 推荐的空 options，让系统决定 raise behavior（默认 raise + 抢焦点）。**不要**用废弃的 `.activateIgnoringOtherApps`。

4. **状态清空**：activate 调用后立刻 `previousFrontApp = nil`，避免下次 show() 没拿到新前台时旧值残留导致误激活。

## 隐藏触发场景

`hide()` 在多种场景被调用，都应该触发焦点回切：
- 用户按 Esc（`cancelOperation` / `.onExitCommand`）
- 用户点击 launcher 外部（hidesOnDeactivate=true 触发 didResignKey）
- 用户再按 ⌘⇧Space（toggle）
- 程序内主动 hide

只要在 `hide()` 单一入口实现，所有路径都覆盖。

## 不需要做的

- 不需要保存焦点的 NSTextRange / cursor position：app 切回时系统自动恢复其内部焦点状态（Terminal 的光标位置由 Terminal 自己管，buddy 不需要介入）
- 不需要在 show() 前用 `NSApp.activate(ignoringOtherApps: true)` 之外做特殊准备：nonactivatingPanel + NSApp.activate 组合已经处理了不抢应用级激活

## Evidence

task 010 launcher UI 升级 retry 2 第 7 轮：用户主动询问"⌘⇧Space 召唤完，光标能继续回到之前的命令行吗？"，加上这段代码后立刻 work。

## Lesson

- LSUIElement launcher 浮窗想做"召唤完无缝回原 app"，单一 hide() 入口记录 + activate 即可
- `DispatchQueue.main.async` 调 activate 是必须，同步调会被 orderOut 路径吞掉
- 这是 Spotlight 级 UX 的基础门槛，实现成本极低（~10 行）

## Related

- [[2026-05-26 LSUIElement app 中的浮窗输入框用 NSPanel + nonactivatingPanel + NSApp.activate]]
- [[2026-05-26 NSPanel hidesOnDeactivate 与 didResignKeyNotification 双触发的 Combine 重入防御]]
