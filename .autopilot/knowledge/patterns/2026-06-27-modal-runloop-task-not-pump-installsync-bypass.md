# NSApp.runModal modal runloop 不 pump Swift Concurrency main queue → installAllSync 同步绕过（弹框内装依赖 + 进度刷新）

<!-- tags: modal-runloop, nspanelrunloopmode, swift-concurrency, task-mainactor, gcd-main-queue, pump, runloop-run, installallsync, process-run, while-pump, timer-modal-mode, objectwillchange, nshostingview, setneedsdisplay, swiftui-observedobject, modal-refresh, brew-install, plugin-deps, trust-prompt, launcher, debug-logs-driven, 51s-delay -->

**Scenario**: 插件首次权限弹框（NSApp.runModal 自定义 NSWindow）内「允许并运行」点击 → `Task { @MainActor in installAll(missing) }` 触发 brew install 装依赖。用户反馈"点击后一直等待安装"无进度。诊断日志铁证：`onInstallAll triggered`（点击）→ `onInstallAll Task started` **51 秒后**（= 用户关弹框后 modal 结束才 pump）。即 `Task @MainActor` 在 `NSApp.runModal` 的 modal runloop（NSModalPanelRunLoopMode）内**完全不执行**（弹框关闭后才 pump main queue）。

**Lesson**（多轮调试得出，铁证日志驱动，非理论推测）:
- **modal runloop 不 pump GCD main queue**：`NSApp.runModal(for:)` / `NSAlert.runModal` 的 modal runloop 用 `NSModalPanelRunLoopMode`，**不在 common modes 默认集合**（common modes 默认只含 NSDefaultRunLoopMode + NSEventTrackingRunLoopMode）。故 `Task @MainActor`、`DispatchQueue.main.async`、`MainActor.run` 的 block（注册在 main queue source，common/default mode）在 modal 期间**不 pump**。Task 延迟到 modal 结束（用户关闭弹框）才执行。手动 modal session（beginModalSession/runModalSession + `RunLoop.current.run(until:)`）更糟——`run(until:)` 默认用当前 mode（NSModalPanelRunLoopMode），Task 完全不执行；显式 `RunLoop.current.run(mode: .default, before:)` 也不 pump（modal session 占用）。
- **SwiftUI @ObservedObject 在 modal 不自动刷新**：即使 @Published 值更新了（日志 + 二次进入看残留状态证实），`objectWillChange.send()` → NSHostingView body re-evaluate → display 在 modal runloop 不 pump（SwiftUI 渲染引擎靠 runloop source，modal 阻断）。用户看到"状态不变"。
- **installAllSync 同步绕过（解法）**：不用 `Task @MainActor`（async 靠 main queue），改**同步** `installAllSync`：
  - `Process.run()`（非阻塞启动 brew 子进程，不阻塞 main thread）
  - `while process.isRunning { RunLoop.current.run(until: Date(+0.05)) }`（pump 当前 modal runloop，处理 Timer + NSEvent + UI display）
  - Timer（`.common` + `RunLoop.Mode(rawValue: "NSModalPanelRunLoopMode")` 双模式）定期 `objectWillChange.send()` 强制 SwiftUI 刷新
  - `readabilityHandler` 后台线程累积 brew stdout → `DispatchQueue.main.sync`（或 Timer 内同步）更新 @Published（installingLabel/progressPhase）
  - sink `hosting.view.needsDisplay = true` + `layoutSubtreeIfNeeded()` 强制 NSHostingView 重绘读最新 @Published
- **installAll async 保留**：红队 lock（`await installAll`）+ checkAndPrompt 兜底（弹框关闭后 main pump 正常）仍用 async；installAllSync 仅弹框内 onApprove/onInstallAll 用。
- **诊断方法**：`onInstallAll triggered` + `Task started` + `Task done` 三个 `BuddyLogger.info(subsystem: "plugin")` 时间戳，对比 `installAll success` 时间，直接判定 Task 是否在弹框内执行（51s 延迟 = 弹框外 pump）。

**How to apply**:
- **modal 弹框内执行长时操作（brew/network/编译）+ 进度刷新**：禁用 `Task @MainActor` / `DispatchQueue.main`（modal 不 pump）。用**同步 Process.run + while RunLoop.run pump + Timer(.modal+.common) objectWillChange + sink hosting.setNeedsDisplay**。
- **modal 内 SwiftUI 刷新**：`@ObservedObject` 自动响应不可靠，加 `sink objectWillChange → hosting.view.needsDisplay = true + layoutSubtreeIfNeeded()` 强制 NSHostingView 重绘。
- **调试 modal 内异步不执行**：加 triggered/started/done 时间戳日志，对比 modal 关闭时间，判定 pump 时序（铁证优于理论）。
- **非 modal 场景**（普通 runloop / 非模态窗口）：main queue 正常 pump，`Task @MainActor` + `@Published` 自动刷新可用，不需同步绕过。

**关联**: [[2026-05-29-swift-process-async-bridge-terminationhandler]]（Process async 桥，非 modal 用）、[[2026-05-26-process-sigkill-orphan-pipe-readtoend-deadlock]]（Process 子进程 pipe 死锁，installAllSync 复用 readabilityHandler 异步读避免）、[[2026-05-29-nshostingcontroller-sizingoptions-preferredcontentsize]]（NSHostingController sizing）、[[2026-06-23-lsuielement-standard-nswindow-key-window-sendevent-fallback]]（LSUIElement key window sendEvent 兜底，TrustPromptWindow 复用）、[[2026-05-29-swiftui-material-vs-nsvisualeffectview-injection]]（NSVisualEffectView 毛玻璃，弹框复用）。
