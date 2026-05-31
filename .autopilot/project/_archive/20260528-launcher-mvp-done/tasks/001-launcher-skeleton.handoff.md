# 001-launcher-skeleton handoff

## 实现摘要

Launcher 骨架子系统已在 `apps/desktop/Sources/ClaudeCodeBuddy/Launcher/` 落地，与现有像素猫互不干扰。⌘⇧Space 召唤 NSPanel 浮窗 + SwiftUI 输入框 + echo 占位 + 失焦/Esc 隐藏。所有 7 个 TDD Step 完成，QA 85/100 通过。

## 关键文件路径

```
apps/desktop/Sources/ClaudeCodeBuddy/Launcher/
├── LauncherManager.swift        # 顶层控制器（@MainActor singleton shared）
├── LauncherWindow.swift         # NSPanel 子类（canBecomeKey=true，level=.floating）
├── LauncherInputView.swift      # SwiftUI 输入视图（TextField + 字数指示器）
├── LauncherHostingController.swift  # NSHostingController 桥接
├── LauncherHotkey.swift         # KeyboardShortcuts 注册 + probeIfNeeded
├── LauncherConstants.swift      # 路径/尺寸/字符串常量
└── LauncherError.swift          # 项目级 LauncherError enum（task 001 含 hotkeyConflict）
```

修改：
- `apps/desktop/Package.swift` — KeyboardShortcuts 2.4.0 SPM 依赖 + BuddyCore target deps
- `apps/desktop/Sources/ClaudeCodeBuddy/App/AppDelegate.swift:30` — 追加 `setupLauncher()` 单行接入
- `apps/desktop/CLAUDE.md` — Sources 树新增 Launcher 目录条目（最小化更新，完整修订留 task 007）

## 下游须知

### Task 002 (Provider 抽象) 接入

```swift
// 在 LauncherManager.submit 中调 ProviderFactory（task 002 实现）
func submit(_ query: String) async -> AttributedString {
    // 当前占位：return AttributedString("echo: \(query)")
    // task 002 替换：let provider = try ProviderFactory.shared.create(...)
    //                let resp = try await provider.send(messages: ...)
    //                return MarkdownRenderer.render(resp.text)
}
```

### Task 003 (Agent Loop) 接入

`LauncherManager.submit` 在 task 003 重写为 `AsyncStream<AgentEvent>`（流式）。`LauncherInputView.body` 的 `output: AttributedString?` 状态变量需相应改造为流式累积（增量 yield 累加进 buffer）。

### LauncherError 扩展

`LauncherError.swift` 是项目级共享 enum。下游任务追加 case **在同一文件**：
- task 002: `providerNotConfigured`, `invalidAPIKey`, `networkFailure(Error)`, `providerHTTPError(Int, String)`, `secretStoreUnavailable`
- task 003: `maxIterations`
- task 004: `pluginNotFound(String)`, `pluginNotTrusted(String)`, `pluginTimeout(Int)`, `pluginCrash(Int32, String)`, `pluginMissingDependency(String)`

## 设计偏差

3 项已确认合理（QA Section A 通过）：
1. **`setup()` 用 isSetup 标志 + lazy var**：比草图"window != nil 判断"更幂等；下游可放心多次调 setup
2. **`hide()` 先设 isVisible=false 再 orderOut**：比草图顺序更严格防 Combine 重入双发布（避免 didResignKeyNotification 同步回调时再触发 hide 导致 3 次而非 2 次 @Published 事件）
3. **`toggle()` 改 if-else**：避免 SwiftLint `void_function_in_ternary` 违规，行为等价

## 已知限制（task 005/006 顺手修复）

1. `KeyboardShortcuts.probeIfNeeded()` 仅判断 `getShortcut(for:) != nil`，不做合成 keyDown 测试（避免辅助功能权限）。Xcode 占用 ⌘⇧Space 时不会自动引导改键，仅 `NSLog`。task 005 可加 KeyboardShortcuts.Recorder UI。
2. 红队测试 backlog：
   - `test_SC01_hotkeyRegistration_succeeds` 用 `XCTAssertNotNil(combo)`，应升级为 `combo?.key == .space && combo?.modifiers == [.command, .shift]`
   - `test_launcherError_conformsToError` 是 tautological，可移除
   - `test_centerOnScreen_positionsAtGoldenRatio` 有 XCTSkip，主屏环境下未验证实际 y 坐标
3. `NSApp.activate(ignoringOtherApps:)` 在 macOS 14 有 deprecation warning，等 macOS 15 强制再迁移

## 验证证据

- `swift test --filter Launcher` → 49 passed / 0 failed
- `swift test` 全量 → 494 passed / 0 failed（未破坏现有像素猫/skin/session 测试）
- `make lint` → 0 violations
- `make build && make bundle` → 通过
- `buddy ping` + `buddy session start/inspect/emit thinking` → cat 系统正常（SC-10 间接验证）

## 下游接入点示例（最小 3 行）

```swift
// task 002 在 LauncherManager.submit 内替换占位：
let provider = try await ProviderFactory.shared.activeProvider()
let resp = try await provider.send(messages: [.init(role: "user", content: [.text(query)])], tools: [], model: config.model)
return MarkdownRenderer.render(resp.content.first?.text ?? "")
```
