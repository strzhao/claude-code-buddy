# AsyncStream + Task.detached + onTermination cancel 双层取消传播链

<!-- tags: async-stream, task-detached, on-termination, cancel, swift-concurrency, streaming, asyncsequence, structured-concurrency, leak-prevention -->
**Scenario**: LauncherManager.submit 返回 `AsyncStream<AgentEvent>` 流式接口，内部 LauncherAgent.run 也返回 AsyncStream（agent loop 多轮 yield）。消费者放弃外层 stream（如关闭浮窗）时，需要级联取消内部 stream，否则后台 Task 继续跑完整 HTTP 请求 + agent 多轮调用，浪费资源 + 并发 race。
**Lesson**: 双层 onTermination cancel 链模式：
- **外层 stream**（LauncherManager.submit）的 `AsyncStream { continuation in ... }` 闭包内：`let task = Task.detached { ... for await event in agent.run(...) { continuation.yield(event) } continuation.finish() }`；末尾 `continuation.onTermination = { _ in task.cancel() }`
- **内层 stream**（LauncherAgent.run）同样模式：`let task = Task { ... }`；`continuation.onTermination = { _ in task.cancel() }`；agent loop 内显式 `if Task.isCancelled { return }` 提前终止
- 取消传播链：消费方 break → 外 stream finish → 外 onTermination → cancel 外 Task → 外 Task 内 for await 中断 → 内 stream 也 finish → 内 onTermination → cancel 内 Task → agent loop Task.isCancelled 提前 return
- 这是 Swift 结构化并发的正确链路。注意：`task.cancel()` 是幂等操作，重复调用无副作用；continuation.yield 在 stream 已 finished 状态下被静默丢弃，不 crash
**Evidence**: task 003 LauncherManager.submit + LauncherAgent.run 双 AsyncStream 链；测试 `test_scenario4_networkFailure_immediatelyYieldsErrorWithoutRetry` 验证 cancel 后不再 yield 新事件；qa-reviewer Section B Strengths 评"双层 onTermination cancel 链是教科书级修复"。
