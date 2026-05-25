---
id: "001-launcher-skeleton"
depends_on: []
complexity: M
milestone: M1
acceptance_scenarios: [SC-01, SC-08, SC-10]
contract_required: true
---

# 001 — Launcher 骨架（窗口 + 快捷键 + 输入框 + echo 占位）

## 目标

在 buddy app 内新增独立的 Launcher 子系统骨架：用户按 ⌘⇧Space 召唤一个浮窗，输入框获焦后回车显示 echo 输出，失焦/Esc 隐藏。**本任务不接 AI**，纯 UI 框架打通。

## 架构上下文

- 新建目录 `apps/desktop/Sources/ClaudeCodeBuddy/Launcher/`
- 不动现有像素猫代码（BuddyWindow / BuddyScene / CatSprite / SessionManager 不修改）
- AppDelegate.applicationDidFinishLaunching 末尾追加 `setupLauncher()` 单行接入
- 新增 SPM 依赖 `sindresorhus/KeyboardShortcuts >= 2.0.0`
- 窗口选 NSPanel（**不要**复用 BuddyWindow，BuddyWindow.swift:30 虽有 canBecomeKey=true 但 ignoresMouseEvents=true + styleMask=.borderless 用于点击穿透，不适合输入框）

## 输入

- `~/Downloads/prd.txt` 中 PRD 决策 1/2/8/11（智能输入框 / macOS / 仅快捷键浮窗 / 每次新 session）
- 上一节"架构上下文"
- KeyboardShortcuts SPM 文档：https://github.com/sindresorhus/KeyboardShortcuts

## 输出契约

### 接口签名（invariant）

```swift
// LauncherManager（顶层控制器）
final class LauncherManager {
    static let shared: LauncherManager
    func setup()                            // AppDelegate 调用
    func show()
    func hide()
    func toggle()
}

// LauncherWindow（NSPanel 子类）
final class LauncherWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    init()  // styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel]
            // level: .floating
            // collectionBehavior: [.canJoinAllSpaces, .stationary]
            // titlebarAppearsTransparent = true
            // backgroundColor = .clear
}

// LauncherInputView（SwiftUI）
struct LauncherInputView: View {
    @ObservedObject var manager: LauncherManager
    // body: TextField 居中 + 占位文本 "Ask anything..."
    // 回车回调 manager.submit(query)
}

// 本任务的 submit 占位实现（task 003 替换）
extension LauncherManager {
    func submit(_ query: String) async -> AttributedString {
        return AttributedString("echo: \(query)")
    }
}

// LauncherHotkey
enum LauncherHotkey {
    static let toggle = KeyboardShortcuts.Name("launcher-toggle",
                                                default: .init(.space, modifiers: [.command, .shift]))
    static func register()    // 注册 + 探针
    static func probe() -> Bool  // 合成 keyDown 看回调
}
```

### 接口签名（example）

```
# show / hide 正例
Given: app 启动完成、快捷键已注册
When:  LauncherManager.shared.show()
Then:  LauncherWindow 居中显示在主屏幕、becomes key window、TextField 获焦

# Esc 关闭正例
Given: 浮窗显示中、TextField 有焦点
When:  用户按 Esc
Then:  LauncherWindow.orderOut(nil)、NSApp.hide(nil) 不调用（不影响其他 app）

# 失焦关闭正例
Given: 浮窗显示中
When:  用户点击桌面或其他 app
Then:  LauncherWindow 收到 windowDidResignKey → orderOut(nil)
```

### 数据结构

- `LauncherManager.isVisible: Bool`（@Published）
- `LauncherInputView.query: String`（@State，回车后清空 + 显示输出）
- `LauncherInputView.output: AttributedString?`（@State）

### 边界值（DbC）

- 浮窗宽度：== 600pt（固定）
- 浮窗高度：≥ 80pt（初始）≤ 600pt（含输出展开后）
- 浮窗 y 位置：屏幕高度 × 0.3（视觉黄金分割位置，参考 Spotlight）
- TextField 最大输入长度：≤ 8000 字符
- 快捷键探针超时：≤ 1000ms

### 边界值（example）

- 正例：show() 后 TextField.becomeFirstResponder() 在 50ms 内完成 → ✅
- 边界：用户粘贴恰好 8000 字符 → 接受
- 反例：用户粘贴 8001 字符 → 截断到 8000 + UI 显示警告

### 错误契约

| 错误码 | 触发 | UI 表现 |
|---|---|---|
| `LauncherError.hotkeyConflict(String)` | KeyboardShortcuts 注册失败或探针无响应 | 弹 KeyboardShortcuts 录制 UI 让用户改键 |

### 副作用清单

- 写 `UserDefaults`: `launcher.hotkeyProbeCompleted = true`（避免每次启动都探针）
- 注册全局快捷键（KeyboardShortcuts SPM）
- `NSApp.activate(ignoringOtherApps: true)` 仅在 show() 时调用
- 监听 `NSWindow.didResignKeyNotification` 关联 LauncherWindow

## 验收标准

- ✅ SC-01：⌘⇧Space 召唤浮窗，输入框获焦；点击外部或 Esc 关闭；再次召唤输入框清空（新 session）
- ✅ SC-08：每次召唤 output 区域为空（不保留上次输入/输出）
- ✅ SC-10：召唤期间 BuddyScene/CatSprite 状态不变（红队测试用 `cat.state == .idle` 类型断言）

## 测试要求

- `LauncherManagerTests.swift`：show/hide/toggle 单元测试（mock NSPanel）
- `LauncherHotkey.acceptance.test.swift`：注册 + 探针验证（红队验收）
- `LauncherWindowSnapshotTests.swift`：浮窗渲染快照（SwiftUI 默认精度）
- `LauncherIsolationTests.swift`（task 007 也会覆盖）：召唤 launcher 时 BuddyScene 状态机不变

## 风险与缓解

- **NSPanel canBecomeKey 在 LSUIElement app 中**：先在 main 函数里写最小验证 demo（10 行 demo + ⌘N 召唤），跑通再写正式代码
- **⌘⇧Space 与 Xcode "Show Documentation" 冲突**：首次启动注册后立即 dispatch 一个合成 keyDown 探针；探针失败/超时 → 弹 KeyboardShortcuts.Recorder UI 让用户改键
- **KeyboardShortcuts SPM resolve 冲突**：执行 `swift package resolve` 单独验证；如有冲突 fallback DIY CGEventTap

## 接出

完成后写 `tasks/001-launcher-skeleton.handoff.md`：
- LauncherManager.shared 单例如何被 task 002 ProviderFactory 注入
- LauncherInputView.submitHandler 替换点的具体 line:N
- Package.swift 新增的 KeyboardShortcuts 版本号
