# Task 003 Handoff — PluginDispatcher + StdinExecutor 重构

## 实现摘要

`PluginExecutor`（208 行 final class + singleton）重命名为 `StdinExecutor`（保持 logic 100% 不变，去掉 `final` 以支持 `MockStdinExecutor` 继承）；新增 `PluginDispatcher` 薄壳（`static let shared`，按 `plugin.modeConfig` switch 分发：stdin → 委托 StdinExecutor，prompt → 抛 `LauncherError.promptExecutorNotAvailable`）。LauncherManager 行 197 调用切换为 `PluginDispatcher.shared`。

**同时吸收 task 002 移交的 BLOCKER**：BuddyCLI 的 `CLIPluginManifestCheck` 加 `mode: String?` + cmd/args 改 Optional；`cliTrustStatus` 三分支 mode-aware（stdin 走 trustKey / prompt 返回 placeholder / default unknown_mode）。

测试：256 tests / 0 failures / 12.8s（含红队 7 测试 + 既有 mocks 同步 case + builtin-hello 端到端回归）。

## 文件变更（commit 5dcf120）

**源代码**：
- `Sources/.../Launcher/LauncherError.swift` (+2: `promptExecutorNotAvailable` case + 描述)
- `Sources/.../Launcher/Plugin/PluginExecutor.swift` → `StdinExecutor.swift`（rename 99%，class 名同步改）
- `Sources/.../Launcher/Plugin/PluginDispatcher.swift` (NEW，~20 行薄壳)
- `Sources/.../Launcher/LauncherManager.swift` (line 197 调用切换)
- `Sources/.../Launcher/Plugin/PluginManager.swift` (注释更新)
- `Sources/BuddyCLI/main.swift` (CLIPluginManifestCheck schema + cliTrustStatus mode-aware)
- `apps/desktop/CLAUDE.md` (Plugin 目录注释同步)

**测试**：
- `PluginExecutorTests.swift` → `StdinExecutorTests.swift`（rename 96%）
- `PluginRuntimeAcceptanceTests.swift`（类型引用全部 PluginExecutor → StdinExecutor）
- `LauncherManagerAcceptanceTests.swift` + `LauncherHotkeyAcceptanceTests.swift`（switch 补 promptExecutorNotAvailable case）
- `PluginDispatcherAcceptanceTests.swift` (NEW，红队 7 测试)

## 下游须知

### 给 task 004 (PromptExecutor)

`PluginDispatcher` 当前对 prompt mode 抛 `promptExecutorNotAvailable`，task 004 完成 PromptExecutor 后必须：

1. 给 `PluginDispatcher` 加 `promptExecutor: PromptExecutor?` 注入（init 默认 nil 保持向后兼容）
2. `execute()` 的 `.prompt` case 改为：

```swift
case .prompt(let cfg):
    guard let executor = promptExecutor else {
        throw LauncherError.promptExecutorNotAvailable
    }
    return try await executor.execute(plugin, pluginDir: pluginDir, input: input)
```

3. `LauncherManager` 构造 dispatcher 时同步注入 promptExecutor 实例

PromptExecutor 接口与 StdinExecutor 完全对齐：`func execute(_ plugin: PluginManifest, pluginDir: URL, input: PluginInput) async throws -> PluginResult`

### 给 task 005 (Trust mode-aware) — **关键 placeholder 移交**

⚠️ BuddyCLI 的 `cliTrustStatus` 函数（`Sources/BuddyCLI/main.swift:1163-1186`）对 prompt mode 当前返回 **占位字符串 `"trusted_pending_task_005"`**。这是 task 003 的临时方案，task 005 实现 trust mode-aware 后必须：

1. 用 task 005 定义的真正 trustKey 算法（`prompt:` 前缀 + SHA256(systemPrompt|maxIterations|model)）计算 currentKey
2. 替换 `return "trusted_pending_task_005"` 为 `return currentKey == record.trustKey ? "trusted" : "untrusted"`
3. 同时更新主 app 路径 `TrustStore.checkAndPrompt` 用同算法

grep 关键字定位：`trusted_pending_task_005`（CLI 唯一出现处）

### 给所有 task

`LauncherError.promptExecutorNotAvailable` case 已 active。任何穷举 switch（含 mock 测试）必须包含此 case，否则编译失败。

## 偏差说明

1. **StdinExecutor 去 final**（合理改进）：原 PluginExecutor 是 final class，brief 未明说要保留 final 修饰。蓝队为了让红队的 `MockStdinExecutor` 能继承，去掉了 final——qa-reviewer 标记为 low-risk 偏差。后续建议（非阻断）：引入 `PluginExecuting` 协议做 protocol-based DI，彻底解除继承耦合。

2. **额外触达 2 个测试文件**（LauncherManagerAcceptanceTests / LauncherHotkeyAcceptanceTests）：因新增 LauncherError case 触发穷举 switch 编译失败，蓝队补了对应 case。属附带 fix，不算偏差。

3. **PluginRuntimeAcceptanceTests 类名 PluginExecutorAcceptanceTests 保留**：设计允许，仅内部 type 引用更新。后续 task 可选清理。

## 验证证据

- swift build: PASS
- swift test --filter Plugin/Stdin/Dispatcher/Manager: **256 tests / 0 failures / 12.8s**
- SwiftLint --strict: PASS (0 violations / 98 files)
- contract-checker: PASS (1 low-severity 偏差: StdinExecutor 去 final 为合理改进)
- qa-reviewer: PASS（Section A 6/6 ✅，Section B 仅 2 个低优先级改进建议）

## qa-reviewer 提的 2 个改进建议（非阻断，留给后续）

1. **PluginExecuting protocol DI**：把 `StdinExecutor` 包装在 protocol 内，让 mock 实现 protocol 而非继承，消除 singleton 被子类覆写的隐患
2. **magic string 提取**：`"trusted_pending_task_005"` 提为 `private let` 常量（与 task 005 占位移除时联动）
