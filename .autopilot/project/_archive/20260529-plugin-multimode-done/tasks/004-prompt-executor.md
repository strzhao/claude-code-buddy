---
id: "004-prompt-executor"
depends_on: ["001-provider-system-field", "002-manifest-discriminated-union", "003-plugin-dispatcher"]
complexity: M
acceptance_scenarios: [SC-5, SC-6, SC-7]
---

# Task 004: PromptExecutor 实现 — 单轮 provider.send + 空输入兜底 + Task cancel 超时

## 目标

实现 `PromptExecutor`：接收 prompt manifest + query，调 `provider.send()` 单轮拿到响应，包装为 PluginResult 返给 dispatcher。覆盖空输入短路、超时 cancel 真传播、provider 错误转 exitCode=1 三个关键行为。

## 架构上下文

来自 [`../design.md`](../design.md)：

- 现状：003 task 留了 PromptExecutor 注入点（dispatcher 接受 nil）
- 升级动机：本 task 让 prompt mode plugin 真正能跑
- 简洁原则：单轮调用（maxIterations=1），不复用 LauncherAgent loop（避免引入不必要复杂度；agent loop 是未来 v2 的事）

## 契约规约

### 上游依赖（已完成）

- **task 001**：`provider.send(..., system: String?)` 签名 + 两个 impl 已就绪
- **task 002**：`PluginManifest.modeConfig` enum + `PromptConfig` 已可用
- **task 003**：`PluginDispatcher` 已支持注入 PromptExecutor

### 新引入 contract

#### 1. PromptExecutor

```swift
final class PromptExecutor {
    let provider: LauncherProvider
    let activeProviderModel: String  // 来自 LauncherConfig 当前激活的 provider
    
    init(provider: LauncherProvider, activeProviderModel: String) {
        self.provider = provider
        self.activeProviderModel = activeProviderModel
    }
    
    func execute(
        manifest: PluginManifest,
        config: PromptConfig,
        query: String
    ) async throws -> PluginResult {
        let started = Date()
        
        // 空输入短路（验收 SC-5）
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return PluginResult(
                stdout: "请输入需要翻译的文字",
                stderr: "",
                exitCode: 0,
                durationMs: Int(Date().timeIntervalSince(started) * 1000),
                stdoutTruncated: false
            )
        }
        
        let model = config.model ?? activeProviderModel
        let messages = [AgentMessage(role: "user", content: [.text(query)])]
        let timeout = TimeInterval(manifest.timeout ?? LauncherConstants.defaultTimeoutSec)
        
        // 超时用 Task + cancel 模式（确保 URLSession 真正释放）
        let task = Task { () -> AgentResponse in
            try await provider.send(
                messages: messages,
                tools: [],
                model: model,
                system: config.systemPrompt
            )
        }
        let cancelTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            task.cancel()
        }
        
        do {
            let response = try await task.value
            cancelTask.cancel()
            
            let text = response.content.compactMap { content -> String? in
                if case .text(let s) = content { return s }
                return nil
            }.joined()
            
            return PluginResult(
                stdout: text,
                stderr: "",
                exitCode: 0,
                durationMs: Int(Date().timeIntervalSince(started) * 1000),
                stdoutTruncated: false
            )
        } catch is CancellationError {
            cancelTask.cancel()
            return PluginResult(
                stdout: "",
                stderr: "翻译超时（\(Int(timeout))s）",
                exitCode: 1,
                durationMs: Int(timeout * 1000),
                stdoutTruncated: false
            )
        } catch {
            cancelTask.cancel()
            return PluginResult(
                stdout: "",
                stderr: "翻译失败: \(error.localizedDescription)",
                exitCode: 1,
                durationMs: Int(Date().timeIntervalSince(started) * 1000),
                stdoutTruncated: false
            )
        }
    }
}
```

#### 2. LauncherError 新增 case

```swift
enum LauncherError: Error {
    // ... 现有 case
    case promptExecutorNotAvailable  // task 003 引入
    // 本 task 不新增 case，所有 provider 错误用现有的
}
```

#### 3. PluginDispatcher 升级注入

dispatcher 构造时不再接受 nil：

```swift
init(stdinExecutor: StdinExecutor, promptExecutor: PromptExecutor) { ... }
```

LauncherManager 构造 dispatcher 时同时注入：

```swift
let promptExecutor = PromptExecutor(
    provider: activeProvider,
    activeProviderModel: activeConfig.model
)
let dispatcher = PluginDispatcher(
    stdinExecutor: stdinExecutor,
    promptExecutor: promptExecutor
)
```

### 不变 contract

- PluginResult 结构不变
- PluginDispatcher.execute 签名不变
- provider.send 调用方式与 task 001 一致

## 实现要点

1. **空输入短路**（SC-5）：trim 后空字符串直接返回提示，**不发 HTTP 请求**（省 token + 防 Qwen 收到空 user message 报 schema 错）

2. **超时 cancel 必须真传播**：
   - 不用 `withTaskGroup` 的 `addTask` + `cancelAll`（Swift 5.9 行为不一致）
   - 用上面示例的 dual-Task 模式：work task + sleep-then-cancel task
   - **URLSession 在 task.cancel() 时会调 `URLSessionTask.cancel()` 释放连接**（Swift 内置行为，但需测试验证）

3. **错误统一映射**：所有 provider 异常 → exitCode=1 + stderr 含本地化描述（不暴露内部类型给 UI）

4. **超大输入处理**（SC-6）：本 task 不做截断（LLM 自己处理上下文 + 超时兜底）。design.md 验证矩阵已注明 SC-6 "由 provider 超时或截断"

## 输入

- task 001 输出的新 provider.send 签名
- task 002 输出的 PromptConfig schema
- task 003 输出的 PluginDispatcher 注入点
- 现有 `Sources/.../Launcher/Provider/LauncherProvider.swift`

## 输出

- 新 `Sources/.../Launcher/Plugin/PromptExecutor.swift`
- 修改 `Sources/.../Launcher/Plugin/PluginDispatcher.swift`（构造非 nil）
- 修改 `Sources/.../Launcher/LauncherManager.swift`（注入 promptExecutor）
- 红队验收测试
- handoff `004-prompt-executor.handoff.md` 含：
  - PromptExecutor 类签名 + 三种返回路径（成功 / 超时 / 错误）
  - cancel 传播实测验证
  - 下游须知：006 builtin-translate 调用方式 + UI 渲染对 exitCode=1 的处理

## 验收标准（红队测试候选）

### Tier 1 单元测试

1. **空 query 短路**（SC-5）：query="" → 返回 stdout="请输入需要翻译的文字" + exitCode=0，**provider.callCount=0**
2. **空白 query 短路**：query="   \n  " → 同上行为
3. **正常成功路径**：mock provider 返回 `.text("你好")` → PromptExecutor 返回 stdout="你好" + exitCode=0
4. **多 content 合并**：mock provider 返回 [.text("你"), .text("好")] → stdout="你好"
5. **provider 抛 LauncherError.providerHTTPError(500, ...)** → exitCode=1 + stderr 含 "翻译失败:" + 错误描述
6. **超时 cancel 传播**：mock provider sleep 60s，manifest.timeout=2s → 2s 后返回 exitCode=1 + stderr "翻译超时（2s）"，**且** mock provider 收到 CancellationError（不是 wall-clock 等死）
7. **model 字段回退**：config.model=nil → 实际传给 provider.send 的 model 是 activeProviderModel
8. **system 字段传递**：mock provider 验证 send() 的 system 参数 == config.systemPrompt

### Tier 1.5 真实场景

9. **真实 Qwen 翻译**（SC-7 反面）：本地 Qwen 服务关闭 → exitCode=1 + stderr 含 "连接被拒绝" 类信息（用户可读）
10. **真实 Qwen 翻译成功**：本地 Qwen 启动 → query="hello" + systemPrompt=翻译指令 → stdout="你好" 或语义等价（用 contains 容差）

## 已识别风险

- **URLSession cancel 传播实测**：Swift 5.9 / macOS 14 上 task.cancel() 是否真的让 URLSession 关闭 socket → 红队 Test 6 必须有 mock 验证 + Test 9 真实场景验证
- **空响应处理**：mock provider 返回 content=[] → stdout="" + exitCode=0（不算错误，让 UI 显示空译文）
- **dispatcher 注入时机**：LauncherManager 构造顺序——provider 初始化 → promptExecutor 构造 → dispatcher 构造，单元测试覆盖此顺序

## 时间预估

1-2 小时

## QA scope（避免 SpriteKit 卡顿）

```bash
swift test --filter Prompt --filter Provider --filter Dispatcher
# 或反向：swift test --skip Snapshot --skip CatSprite
```

Tier 1.5 真实场景 SC-7 LLM 不可达：mock 端口验证；SC-10 Qwen 真实端点 reachable 时跑。
