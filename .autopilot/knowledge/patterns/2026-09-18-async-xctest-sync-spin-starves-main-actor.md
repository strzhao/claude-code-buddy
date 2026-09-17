# async XCTest 内同步自旋等待饿死 Swift Concurrency 主 actor——须挂起式等待

<!-- tags: xctest, async, mainactor, runloop, spin-wait, task-sleep, cooperative-scheduling, false-red, red-team, autopilot -->
**Scenario**: @MainActor async XCTest 方法里等一个「回主 actor 落定」的异步结果（如后台检测链 Task 回主线程 addCat），用 `while !cond { RunLoop.current.run(mode:.default, before:+0.05s) }` 泵式自旋等待。
**Lesson**:
1. **async 测试方法内的同步自旋会饿死主 actor**：协作式调度不可抢占——自旋循环占住 main thread 的同步执行流，被等待的 `Task { @MainActor in ... }` 落定任务永远排不上（表现 = 超时假红）。sync 测试方法里同样的泵式等待反而可行（XCTest 在 main thread 裸跑 sync 方法，RunLoop泵能顺便 serviced 主队列/主 actor 任务）。
2. 正解 = async 上下文改 `Task.sleep` 挂起式等待（`while !cond { try await Task.sleep(nanoseconds: 50_000_000) }`）——await 挂起点让出主 actor，落定任务得以执行。同一套件内 sync 用泵、async 用挂起，双 helper 并存。
3. 元模式：async 改造既有 sync 测试时，「等待原语」必须同步换掉，不能只改函数签名——假红与假绿都可能出现，且形态是「单独跑也失败」（非测试次序污染），易误判为实现 bug。
**Evidence**: autopilot 20260917-开始实现红队验收：S2P2/S5P1/S5P4 在 async 方法内用泵式等待 25s 超时假红（单独跑也红），改 Task.sleep 挂起后全绿（实测 2.0-2.1s 通过）；同套件 sync 类（CHeadlessNoCat）泵式等待正常（核对锚点：RedTeamAcceptanceSupport.swift waitUntil/waitUntilAsync 双 helper）。
