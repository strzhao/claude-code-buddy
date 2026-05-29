# Swift Process + async 桥接用 terminationHandler，不要 DispatchQueue + waitUntilExit

<!-- tags: swift, process, concurrency, async, continuation, terminationhandler, deadlock, timeout, git-clone, resource-leak, plugin-source-resolver -->

**Scenario**: task 002 PluginSourceResolver 实现 git clone 异步 helper（gitClone: async throws -> URL）。第一版设计：

```swift
return try await withCheckedThrowingContinuation { continuation in
    let process = Process()
    process.executableURL = gitExecutable
    process.arguments = args
    
    let timeoutWork = DispatchWorkItem {
        if process.isRunning { process.terminate() }
    }
    
    try process.run()
    
    DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: timeoutWork)
    
    DispatchQueue.global().async {       // ❌ 隐患
        process.waitUntilExit()          // 阻塞调用，必须 off-main
        timeoutWork.cancel()
        if process.terminationStatus == 0 {
            continuation.resume(returning: tempDir)
        } else {
            continuation.resume(throwing: ...)
        }
    }
}
```

plan-reviewer 抓出问题：
1. **双 resume 风险**：timeout 触发 terminate 后 process 退出 → waitUntilExit 返回 → resume；但 timeoutWork **本身**也可能再次拼装错误路径（虽然此实现没有，但模式脆弱，容易在迭代中误加）
2. **DispatchQueue 长尾**：timeoutWork 即使 cancel，asyncAfter 不保证立即停止；timeoutWork 内执行的 process.isRunning 检查是 race
3. **资源泄漏**：异常路径（process.run() throw）下 timeoutWork 仍在 queue 中等待 60s 触发，无意义浪费

**Lesson**: Swift Process 桥接 async 应用 `terminationHandler` + `Task.sleep` 替代 `DispatchQueue.global().async + waitUntilExit`：

```swift
return try await withCheckedThrowingContinuation { continuation in
    let resumeLock = NSLock()
    var resumed = false
    let resumeOnce: (Result<URL, Error>) -> Void = { result in
        resumeLock.lock()
        defer { resumeLock.unlock() }
        guard !resumed else { return }     // 双 resume 守卫
        resumed = true
        continuation.resume(with: result)
    }
    
    let process = Process()
    process.executableURL = gitExecutable
    process.arguments = args
    process.terminationHandler = { proc in
        if proc.terminationStatus == 0 {
            resumeOnce(.success(tempDir))
        } else {
            try? FileManager.default.removeItem(at: tempDir)
            resumeOnce(.failure(LauncherError.networkFailure(...)))
        }
    }
    
    do {
        try process.run()
    } catch {
        resumeOnce(.failure(LauncherError.networkFailure(error)))
        return
    }
    
    // timeout 用 Task.sleep，触发后 terminate process；terminationHandler 会接管
    Task {
        try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
        if process.isRunning {
            process.terminate()
            // process 退出后 terminationHandler 自动触发非 0 退出路径
        }
    }
}
```

**关键优势**：
- ✅ **terminationHandler 是 Process 的唯一退出通道**：无论正常完成 / 被 terminate / 异常退出，都走同一路径，无并发判断
- ✅ **resumeOnce + NSLock**：守卫双 resume 崩溃（Swift continuation 双 resume 会 trap）
- ✅ **Task.sleep 是协程级**：不占用 thread，比 DispatchWorkItem 轻量，且 Task 可被父 Task 取消传播
- ✅ **process.run() 抛错路径**：直接 resumeOnce(.failure)，Task.sleep 仍会跑但跑完啥事不做（process 早已不在）

**进一步优化**（task 002 未做，但建议）：保存 Task 引用 + terminationHandler 内 cancel，避免短任务下 sleep 长尾浪费：

```swift
let timeoutTask = Task { try? await Task.sleep(...); if process.isRunning { process.terminate() } }
process.terminationHandler = { proc in
    timeoutTask.cancel()    // 早退时清理
    // ...
}
```

**陷阱清单**：
- ❌ `DispatchQueue.global().async { process.waitUntilExit() }`：thread 浪费 + cancel 不可靠 + 错误路径混乱
- ❌ continuation 双 resume：直接 trap；必须用 resumeOnce 模式（NSLock 或 atomic flag）
- ❌ Process.environment 默认 = ProcessInfo.processInfo.environment：会传 GIT_* 等用户配置污染。**白名单 PATH + HOME** 是安全实践

**Evidence**: task 002 plan-reviewer 第 1 轮 B4 抓出此问题；第 2 轮验收新实现 PASS；红队 14 AT 全过（含 temp 无泄漏 + timeout → networkFailure），qa-reviewer Section A 8/8 设计符合。

**关联**：
- 与 Swift Concurrency `withCheckedThrowingContinuation` 模式
- 类似场景：CLLocationManager / AVAudioRecorder / 任何 callback-based API 桥接到 async — 都需要 resumeOnce 守卫
- 类似教训："waitUntilExit 必须 off-main" → 用 terminationHandler 直接异步，不要自己换线程
