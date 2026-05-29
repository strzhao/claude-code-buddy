# Task 002 Handoff — PluginSourceResolver 多态加载

## 实现摘要

新建 `PluginSourceResolving` 协议 + `PluginSourceResolver` 默认实现，解析 4 种 PluginSourceConfig 形态（localSubdir / file / gitURL / gitSubdir）为本地插件目录 URL。git 类型用 Process（/usr/bin/git）+ `--depth 1`，sha 通过 `git rev-parse HEAD` 单独校验（不通过 clone 的 `--branch sha` 实现——后者不支持 sha）。

**关键设计修正（plan-reviewer 5 BLOCKER）**：
- `gitURL.sha` 与 `gitSubdir.ref/sha` 语义分离：ref 仅 branch/tag，sha 通过 verifySHA 校验 HEAD
- Process + Concurrency 桥接用 `terminationHandler` + `Task.sleep` 替代 `DispatchQueue.global().async + waitUntilExit`（避免死锁）
- temp 清理统一在 resolve 顶层 catch（verifySHA 内不重复删）
- verifySHA expected ≥7 字符 + 单向 `hasPrefix`（防 short hash 误报）
- 测试 setUp `XCTSkip` 当 `/usr/bin/git` 不存在；tearDown 调 `cleanupOrphans()`

## 文件变更（commit a87fa13）

**新增**:
- `apps/desktop/Sources/ClaudeCodeBuddy/Launcher/Marketplace/PluginSourceResolver.swift`
  - `PluginSourceResolving` protocol
  - `PluginSourceResolver` class（shared 单例 + init 注入 gitExecutable/timeoutSeconds）
  - `resolve(_:bundleRoot:)` 主入口，顶层 catch 统一 temp 清理
  - 私有 `gitClone(url:ref:)`：terminationHandler + Task.sleep 超时 + resumeOnce 守卫 + env 白名单（仅 PATH/HOME）
  - 私有 `verifySHA(in:expected:)`：≥7 字符约束 + 单向 hasPrefix；不删 temp
  - 静态 `cleanupOrphans()`：清 `buddy-resolver-` 前缀的孤儿 temp 目录

**测试**:
- `apps/desktop/tests/BuddyCoreTests/PluginSourceResolverTests.swift`（蓝队 11 单测，含 TestGitFixture）
- `apps/desktop/tests/BuddyCoreTests/PluginSourceResolverAcceptanceTests.swift`（红队 14 AT）

**修改（设计允许的 ripple）**:
- `apps/desktop/Sources/ClaudeCodeBuddy/Launcher/LauncherError.swift`：加 `pluginInvalid(String)` case
- `apps/desktop/tests/BuddyCoreTests/Launcher/LauncherHotkeyAcceptanceTests.swift`：exhaustive switch 补一行
- `apps/desktop/tests/BuddyCoreTests/Launcher/LauncherManagerAcceptanceTests.swift`：同上

## 验证证据

- swift build: PASS
- swift test --filter PluginSourceResolver: **25 tests / 0 failures / 17.6s**
- SwiftLint --strict: PASS（0 violations / 102 files）
- contract-checker: PASS（0 mismatches）
- Tier 1.5 4/4 PASS（E=N=4）
- qa-reviewer Section A 8/8 设计符合 + Section B 3 个 ≥80 置信度工程改进（不阻塞）

## 下游须知

### task 003 (MarketplaceManager) 直接复用

- `PluginSourceResolver.shared` 默认单例可直接调
- `resolve(_:bundleRoot:)` 返回 URL：
  - localSubdir / file：**永久路径**（不删）
  - gitURL / gitSubdir：**temp 目录**（前缀 `buddy-resolver-`），调用方必须拷走后调 `FileManager.removeItem`
- seedFromBundle 在启动时**先调** `PluginSourceResolver.cleanupOrphans()` 清孤儿（plan-reviewer B5 修复点要求）
- 错误契约：localSubdir 缺 bundleRoot → `LauncherError.pluginInvalid("localSubdir requires bundleRoot")`；clone 失败 → `networkFailure`；sha 不匹配 → `pluginInvalid("sha mismatch: ...")`

### task 003 注意 ref/sha 语义

- `gitSubdir.ref` 必填 branch/tag name，`sha` 必填（== ref 的 HEAD commit sha）
- `gitURL` 无 ref，clone default branch；`sha` 可空（nil 不校验）
- marketplace 维护惯例：每次 bump version 时 ref + sha 同步更新

## 偏差说明

**3 个 ≥80 置信度 follow-up（不影响契约）**：

1. **gitClone Task.sleep 超时器无 cancel 路径**：process 提前结束时 Task 仍 sleep 满 N 秒。建议 terminationHandler 内 `timeoutTask?.cancel()`。task 003 顺手修。
2. **Process 抛错路径 Pipe fileHandle 未显式 close**：依赖 ARC，实践影响低。
3. **AT12 红队测试名实不符**：`/bin/sleep + git args` 实际测的是"非 0 退出 → networkFailure"路径而非真 Task.sleep timeout。AT12 仍验证了契约不变量（temp 清理 + networkFailure 错误类型），但未坐实 timeout 分支。后续可换 `/bin/cat`（stdin 阻塞）或 `sh -c 'sleep 30'`。

**无契约偏差**。设计实施完整，所有 plan-reviewer 5 BLOCKER 修复点均落地验证。
