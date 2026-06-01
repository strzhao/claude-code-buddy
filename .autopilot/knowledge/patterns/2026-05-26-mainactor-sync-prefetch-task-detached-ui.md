# @MainActor 类内异步方法用同步前置读 + Task.detached 离开 actor 隔离避免阻塞 UI

<!-- tags: mainactor, task-detached, actor-isolation, ui-blocking, async-await, sendable, capture-list, swift-concurrency -->
**Scenario**: `@MainActor final class LauncherManager` 内的 `submit(_ query: String) -> AsyncStream<AgentEvent>` 默认隔离到 MainActor。如果直接写 `Task { await provider.send(...) }`，Task 闭包继承调用方的 actor 隔离 → 整个 agent loop（含 120s HTTP 超时窗口）在主线程跑，UI 卡顿。
**Lesson**: 模式：① 在 `@MainActor` 函数体**同步**读出所有需要的依赖到本地 let 常量（config / providerConfig / secretStore / factoryOverride）—— 此时还在 MainActor，安全读 self 的属性 ② 用 **`Task.detached`**（不是 `Task { }`）执行 agent loop，捕获列表中**只**带入前面读出的本地常量，不带 self ③ `nonisolated private static func errorStream(_:)` 用于配置错误等同步快速路径（不需要 detach）④ 对错误前置场景（providerNotConfigured / secretStoreUnavailable）走 errorStream 同步返回，对正常路径走 detach。这样 MainActor 在 submit 调用瞬间释放，UI 不阻塞，detach Task 在后台执行 HTTP+agent。
**Evidence**: task 003 LauncherManager.swift submit 实现；plan-reviewer 第 1 轮 BLOCKER-2 即此问题（默认 Task { } 阻塞 UI），第 2 轮通过此修复 PASS；706 个测试 + Tier 1.5 5 场景全过。
