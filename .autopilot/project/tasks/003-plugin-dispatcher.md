---
id: "003-plugin-dispatcher"
depends_on: ["002-manifest-discriminated-union"]
complexity: M
acceptance_scenarios: [SC-4]
---

# Task 003: PluginExecutor 重构为 PluginDispatcher + StdinExecutor

## 目标

把现有 `PluginExecutor`（直接跑 subprocess）重构为 `PluginDispatcher`（按 mode 分发到对应 executor）+ `StdinExecutor`（封装原 subprocess 逻辑）。LauncherManager 持有的对象类型从 `PluginExecutor` 改为 `PluginDispatcher`。stdin path 端到端行为不变。

## 架构上下文

来自 [`../design.md`](../design.md)：

- 现状：`PluginExecutor.execute(manifest:)` 直接做 subprocess fork + stdin/stdout 流
- 升级动机：002 引入 mode 后必须分流到不同 executor；003 是承接 002 schema + 准备 004 PromptExecutor 的桥梁
- 复用：现有 subprocess 逻辑（readBounded / orphan child guard / SIGTERM-then-SIGKILL）100% 平移到 StdinExecutor，行为零变化

## 契约规约

### 上游依赖（已完成）

来自 [task 002 handoff](002-manifest-discriminated-union.handoff.md)：
- `PluginManifest.modeConfig: PluginModeConfig` enum 已可用
- `PluginModeConfig.stdin(StdinConfig)` / `.prompt(PromptConfig)` case 已可用
- `StdinConfig` 含 cmd/args/env/requiredPath

### 新引入 contract

#### 1. PluginDispatcher

```swift
final class PluginDispatcher {
    let stdinExecutor: StdinExecutor
    let promptExecutor: PromptExecutor?  // 004 任务实现，本 task 可为 nil
    
    init(
        stdinExecutor: StdinExecutor,
        promptExecutor: PromptExecutor? = nil
    ) {
        self.stdinExecutor = stdinExecutor
        self.promptExecutor = promptExecutor
    }
    
    func execute(
        manifest: PluginManifest,
        pluginDir: URL,
        query: String,
        sessionId: String,
        cwd: String
    ) async throws -> PluginResult {
        switch manifest.modeConfig {
        case .stdin(let cfg):
            return try await stdinExecutor.execute(
                manifest: manifest,
                config: cfg,
                pluginDir: pluginDir,
                query: query,
                sessionId: sessionId,
                cwd: cwd
            )
        case .prompt(let cfg):
            guard let executor = promptExecutor else {
                throw LauncherError.promptExecutorNotAvailable  // 003 单独跑时 prompt 走不通
            }
            return try await executor.execute(
                manifest: manifest,
                config: cfg,
                query: query
            )
        }
    }
}
```

#### 2. StdinExecutor

```swift
final class StdinExecutor {
    // 内部逻辑：把现有 PluginExecutor.execute() 主体逻辑搬过来
    //   - subprocess fork + stdin JSON 写入 + stdout/stderr 读取
    //   - readBounded（1 MiB stdout 上限）
    //   - SIGTERM/grace 5s/SIGKILL 超时
    //   - orphan child guard（patterns.md `[2026-05-26]` SIGKILL 死锁陷阱）
    
    func execute(
        manifest: PluginManifest,
        config: StdinConfig,
        pluginDir: URL,
        query: String,
        sessionId: String,
        cwd: String
    ) async throws -> PluginResult { ... }
}
```

### 修改但兼容的 contract

#### 3. LauncherManager 持有对象

```swift
// Before
final class LauncherManager {
    let executor: PluginExecutor
    init(executor: PluginExecutor, ...) { ... }
}

// After
final class LauncherManager {
    let dispatcher: PluginDispatcher
    init(dispatcher: PluginDispatcher, ...) { ... }
}
```

调用点（`LauncherManager.swift:178-203` 附近）：

```swift
// Before
let result = try await executor.execute(manifest: manifest, ...)

// After
let result = try await dispatcher.execute(manifest: manifest, ...)
```

### 不变 contract

- `PluginResult` 结构不变（stdout/stderr/exitCode/durationMs/stdoutTruncated）
- subprocess 行为完全一致（输入输出、超时、错误码）
- 现有 PluginExecutor 测试（如有）作为 StdinExecutor 行为的回归基线

## 实现要点

1. **重构步骤**：
   - Step 1: 创建 `StdinExecutor.swift`，把 `PluginExecutor.swift` 主体 90% 平移
   - Step 2: 创建 `PluginDispatcher.swift`，含 mode switch
   - Step 3: 把 LauncherManager 改为持有 dispatcher
   - Step 4: 删除原 `PluginExecutor.swift`（或保留兼容 alias）
   - Step 5: 跑现有 stdin plugin（builtin-hello）端到端测试（SC-4 子项）

2. **PromptExecutor 占位**：本 task 不实现 PromptExecutor，dispatcher init 接受 nil。004 task 完成后改为非 nil 注入。

3. **错误处理**：dispatcher 对 prompt mode + nil executor 抛明确错误 `promptExecutorNotAvailable`（避免静默死循环）

## 输入

- 现有 `Sources/.../Launcher/Plugin/PluginExecutor.swift`（重构源）
- 现有 `Sources/.../Launcher/LauncherManager.swift`（调用方）
- task 002 输出的新 PluginManifest schema

## 输出

- 新 `Sources/.../Launcher/Plugin/PluginDispatcher.swift`
- 新 `Sources/.../Launcher/Plugin/StdinExecutor.swift`
- 删除 `Sources/.../Launcher/Plugin/PluginExecutor.swift`（或保留向后兼容 alias）
- 修改 LauncherManager.swift 持有对象类型
- 红队验收测试
- handoff `003-plugin-dispatcher.handoff.md` 含：
  - dispatcher / executor 类图
  - 现有 PluginExecutor 测试如何迁移
  - 下游须知：004 PromptExecutor 注入方式 + 006 集成测试场景

## 验收标准（红队测试候选）

### Tier 1 单元测试

1. **stdin path 回归**：dispatcher.execute(stdin manifest) → stdinExecutor.execute() 行为 100% 等价（subprocess fork + stdout 读取 + 退出码）
2. **prompt path nil executor**：dispatcher.execute(prompt manifest) + promptExecutor=nil → 抛 promptExecutorNotAvailable
3. **mode switch 正确性**：mock stdinExecutor + mock promptExecutor，验证 dispatcher 按 manifest.modeConfig 分发到对应 executor，传入参数一致
4. **PluginResult 不变性**：dispatcher 返回的 result 字段与 executor 返回的相同（不污染）
5. **LauncherManager 集成**：mock dispatcher，verify LauncherManager 调用 dispatcher 而不是任何旧接口

### Tier 1.5 真实场景

6. **builtin-hello 端到端**（SC-4 基础）：app 启动 → 召唤 launcher → 输入 "hi" → 走 dispatcher → stdinExecutor → 子进程 → 返回 "## Hello, hi!"，与重构前行为字节级一致
7. **错误传播**：subprocess 退出码 1 → PluginResult.exitCode=1 + stderr 含原 stderr 内容（不被 dispatcher 包装）

## 已识别风险

- **PluginExecutor 测试迁移**：原 PluginExecutor 的所有 XCTest case 需平移到 StdinExecutor + 加 dispatcher 集成测试。原 case 0 改动
- **orphan child 死锁**（patterns.md `[2026-05-26]`）：StdinExecutor 必须保留 readabilityHandler 而非 readDataToEndOfFile，否则 SIGKILL 后死锁
- **LauncherManager 测试**：mock 类型从 PluginExecutor → PluginDispatcher，需同步更新 mock

## 时间预估

1-2 小时（主体是搬代码 + dispatch 层很薄）

## QA scope（避免 SpriteKit 卡顿）

```bash
swift test --filter Plugin --filter Dispatcher --filter Stdin
# 或反向：swift test --skip Snapshot --skip CatSprite
```

需要 stdin path 回归：用 filtered 跑包括 builtin-hello 集成测试。
