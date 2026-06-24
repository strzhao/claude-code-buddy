# [2026-06-24] BuddyLogger 进程级单例测试隔离：setEnv 不触发重配，需 configureForTesting seam

## 问题
红队 acceptance 测试首轮 25 个全失败（"buddy.jsonl 必须存在 expected true" / "无法读取日志"），`BUDDY_LOG_LEVEL=debug` 重跑仍失败。根因：`BuddyLogger.shared` 是进程级单例（`static let`），整个测试进程**只初始化一次读 env**。测试 setUp 的 `setEnv("BUDDY_LOG_LEVEL"/"BUDDY_LOG_DIR")` 修改了进程环境变量，但**不触发已初始化单例重新读 env**——单例缓存首次配置（测试宿主默认 off，或被先跑的测试污染），`info(...)` 后日志没写到测试临时目录。

## 解法
暴露测试 seam（`@testable` 可见，不污染公开 API）：
- `BuddyLogger.shared.resetForTesting()`：清缓存配置
- `BuddyLogger.shared.configureForTesting(logsDir:level:)`：显式强制配置单例（直传临时目录路径，不走 env 驱动）
- `BuddyLogger.shared._syncFlush()`：串行队列 `.sync {}` 屏障，等异步写落盘（替代 `usleep` 探测，消除 flaky）

每个测试 setUp：`resetForTesting()` + `configureForTesting(logsDir: 临时目录, level: .debug/.info)`；写入后 `_syncFlush()` 再读文件断言；tearDown `resetForTesting()`。

## 通用教训
进程级单例（`static let shared`）缓存首次配置时，**环境变量在测试中不可靠**（setEnv 不触发重配，且测试间单例状态污染）。测试这类单例必须暴露「显式重配」seam，不能依赖 env 驱动。红队信息隔离下基于契约（C2「env 覆盖」）写测试会自然用 setEnv，**契约/文档必须明确「env 在 configure 时读取缓存，测试用 seam」**，否则红队测试必然全 fail。

## 旁证
蓝队单测用 `configureForTesting` 全过（19/19）；红队用 setEnv 全失败（25/25），SendMessage 告知 seam API 后改 `configureForTesting` 全过（80/80）。

## 同类延伸
轮转/保留测试：单例内部 size 计数不读预置文件，预置 hugeLine + 单例写一行无法触发轮转。改用公开类型 `LogWriter(logsDir:currentPath:)` 直接 `append(level:msg:)` 写超大 payload，或 `pruneArchives()` 显式触发——绕过单例缓存的内部状态。

<!-- tags: testing, singleton, test-isolation, configurefortesting, syncflush, resetfortesting, env, bu-log-level, bu-log-dir, red-team, information-isolation, swift, xctest, buddylogger, seam, logwriter, rotation, flaky, contract, c2 -->
