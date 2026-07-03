# async→sync 桥接用 Task.detached+semaphore.wait 在 @MainActor 调用方死锁；nonisolated mock 测不出

<!-- tags: swift, concurrency, deadlock, mainactor, semaphore, task-detached, async-sync-bridge, actor-hop, nonisolated-mock, test-blind-spot, screencapturekit, cooperative-await, event-driven, auto-fix -->

**Scenario**: 在 `@MainActor` 同步入口（如 BuiltinPlugin 的 `perform` 闭包）里需要一个 async 结果（如 `captureArea` 捕获），于是用 `Task.detached { ... } + DispatchSemaphore.wait()` 把 async 桥进同步。同时为该 async seam 写了注入式 mock 单测。

**Lesson**: 这是**双重陷阱**叠加。① **死锁**：若被等待的 async 工作本身隔离到 `@MainActor`（如 `SCScreenCapture` / 多数 AppKit + ScreenCaptureKit API），它执行时必须 hop 到 main actor；而 main actor 正被 `semaphore.wait()` 阻塞 → 死锁（典型表现：30s 超时后静默失败，无崩溃无日志）。② **测试盲区**：注入的 mock 若是 **nonisolated**（没标 `@MainActor`），它的 `async` 方法在 cooperative pool 上跑、**不需要 main hop** → 单测全绿，生产挂死。两陷阱叠加 = mock 全绿而生产死锁，极难发现。**正解**：不要在同步入口桥接 async。改成**事件驱动 cooperative 回调**——同步入口只做轻量前置（权限检查 + `present` UI），把 async 工作放到用户交互后的 `async` 回调（如 overlay `onConfirm`）里，`await` 在 main actor 的 cooperative 挂起点上完成（await 期间 main actor 释放，不死锁）；测试用 inline `await` 而非 semaphore 拿确定性。**侦察清单**（写 Swift async 桥接时必查）：① 同步入口里出现 `DispatchSemaphore` + `Task.detached` 组合 → 红灯 ② 被等待的 async 是否 `@MainActor`？是 → 红灯 ③ mock 是 nonisolated 而生产实现是 `@MainActor`？是 → 单测不可信，必须真机 / 集成路径验证。

**Evidence**: cycle 1 SC-3 关键缺陷——`ScreenshotPlugin.performCaptureSync` 用 `Task.detached + semaphore.wait` 桥接 `SCScreenCapture(@MainActor).captureArea`，生产环境 30s 挂起后静默失败；`ScreenshotPluginLogicTests.swift:14-18` 的 `CaptureSpy` 是 nonisolated，故 handleConfirm 单测全绿绕开了 actor hop；auto-fix 删除 semaphore，改 `handleConfirm(_ rect: async)` + overlay `onConfirm` 用 `Task { @MainActor in await onConfirm(rect) }` 事件驱动，死锁消除（生产 SCScreenCapture 在 main 上 cooperative 跑，main 在 await 期间释放）。（核对锚点：2026-07-04 源码版本）

**关联**: 这是 `2026-07-01-command-dual-path-ui-vs-ai-flow`、`2026-06-29-openai-send-tools-channel-asymmetry` 同类「测试盲区 / Tier0+1 全绿≠消 bug」教训的 Swift-concurrency 机制版；与 `2026-05-26-mainactor-sync-prefetch-task-detached-ui`（正向：用 Task.detached **避免**阻塞 UI）互补——本条是反例（Task.detached + semaphore 反而死锁）。
