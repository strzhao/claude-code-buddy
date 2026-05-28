---
id: "001-provider-system-field"
depends_on: []
complexity: S
acceptance_scenarios: [SC-1, SC-2, SC-7]
---

# Task 001: LauncherProvider 协议扩展 system 字段 + Router hack 迁移

## 目标

给 `LauncherProvider.send()` 加 `system: String?` 可选参数，两个 impl（Anthropic / OpenAI-compatible）正确处理，同时把 `LauncherRouter.swift:75-91` 的 user-message 前缀 hack 迁移到 system 参数。

## 架构上下文

来自 [`../design.md`](../design.md)：

- 现状：`LauncherProvider.send(messages, tools, model)` 没有 system 字段，router 把 system 指令拼到 user message 前缀（patterns.md `[2026-05-27]` AI 路由器条目）
- 升级动机：prompt mode plugin（task 004 引入）的 systemPrompt 必须以 system 字段送给 LLM，user-prefix 方案语义不准（LLM 把 system 当 user 输入）+ token 计数偏
- 此 task 同时清理 router 的历史 hack，避免 003/004 上线后 router 与 PromptExecutor 各做一半

## 契约规约

### 修改的 contract

#### 1. LauncherProvider 协议

```swift
// Before
protocol LauncherProvider {
    func send(messages: [AgentMessage], tools: [AgentTool], model: String) 
        async throws -> AgentResponse
}

// After
protocol LauncherProvider {
    func send(
        messages: [AgentMessage],
        tools: [AgentTool],
        model: String,
        system: String? = nil               // NEW
    ) async throws -> AgentResponse
}
```

- 默认参数 nil 保证现有调用方编译零改动
- nil 行为 = 现有行为（不传 system 字段）
- 非 nil 行为 = 各 impl 按下方约定处理

#### 2. AnthropicProvider 适配

```swift
final class AnthropicProvider: LauncherProvider {
    func send(..., system: String? = nil) async throws -> AgentResponse {
        var body = MessagesRequest(model: model, messages: ..., tools: ...)
        if let system = system, !system.isEmpty {
            body.system = system               // 原生 Messages API top-level system 字段
        }
        // ... 其余不变
    }
}
```

#### 3. OpenAICompatibleProvider 适配

```swift
final class OpenAICompatibleProvider: LauncherProvider {
    func send(..., system: String? = nil) async throws -> AgentResponse {
        var allMessages = messages
        if let system = system, !system.isEmpty {
            allMessages.insert(
                AgentMessage(role: "system", content: [.text(system)]),
                at: 0
            )
        }
        // ... 其余不变（包括将 allMessages 编码为 OAIMessage[]）
    }
}
```

#### 4. LauncherRouter 迁移

`LauncherRouter.swift:75-91` 当前：

```swift
let systemInstruction = "You are a router. ..."
let userMessage = "\(systemInstruction)\n\nUser query: \(query)"
let response = try await provider.send(
    messages: [AgentMessage(role: "user", content: [.text(userMessage)])],
    tools: [],
    model: routerModel
)
```

迁移为：

```swift
let systemInstruction = "You are a router. ..."
let response = try await provider.send(
    messages: [AgentMessage(role: "user", content: [.text(query)])],
    tools: [],
    model: routerModel,
    system: systemInstruction
)
```

### 不变 contract

- `AgentResponse` 结构不变
- `AgentMessage` / `AgentTool` 结构不变
- Provider 异常类型不变（`LauncherError.providerHTTPError` 等）

## 实现要点

1. **先实测 Qwen 本地服务对 prepend role=system 的兼容性**：
   - 用 curl 直接验证：`POST http://127.0.0.1:8001/v1/chat/completions` 含 `{"role":"system","content":"..."}` 首条 message
   - 验证返回 200 且响应符合预期（不返回 4xx schema 错误）
   - 失败 → 在 patterns.md 记录陷阱并调整方案（如改用 OpenAI 的 instructions 字段，或退回 user-prefix）
   - 此步骤是 **task 第一个红队验收测试** 的依据

2. **修改顺序建议**：
   - Step 1: 改 LauncherProvider 协议签名（加默认参数 nil）
   - Step 2: 改 AnthropicProvider impl（编译应该不破）
   - Step 3: 改 OpenAICompatibleProvider impl
   - Step 4: 改 LauncherRouter 调用方
   - Step 5: 跑红队测试验证两个 impl + router

3. **不动**：现有 LauncherAgent.swift / LauncherManager.swift / 任何 plugin 相关代码

## 输入

- 现有 `Sources/.../Launcher/Provider/LauncherProvider.swift`
- 现有 `Sources/.../Launcher/Provider/AnthropicProvider.swift`
- 现有 `Sources/.../Launcher/Provider/OpenAICompatibleProvider.swift`
- 现有 `Sources/.../Launcher/LauncherRouter.swift`

## 输出

- 修改上述 4 个文件，新 send() 签名 + 两个 impl + router 迁移
- 红队验收测试（详见下方）
- handoff 文档 `001-provider-system-field.handoff.md` 含：
  - send 新签名 + 三个调用方式（不传 / 传 nil / 传非空）
  - 实测 Qwen 兼容性结论（成功 / 退回方案）
  - 下游须知：004 PromptExecutor 调用方式样例

## 验收标准（红队测试候选清单）

红队（执行者：subagent，仅读设计 + brief，不读实现代码）独立编写以下测试：

### Tier 1 单元测试

1. **send 不传 system**：调 `send(messages: [user("hi")], tools: [], model: "x")` 行为与现有完全一致
2. **send 传 nil system**：调 `send(..., system: nil)` 等价于不传
3. **AnthropicProvider 传 system**：mock URLSession 验证请求 body 含 `"system": "..."` top-level 字段
4. **OpenAICompatibleProvider 传 system**：mock URLSession 验证请求 messages[0] 为 `{role: "system", content: "..."}`
5. **空 system 字符串**：传 system="" 等价于不传（不污染 message 流）
6. **LauncherRouter 用 system 参数**：mock provider 验证 router 不再前缀拼接，systemInstruction 走 system 通道

### Tier 1.5 真实场景

7. **Qwen 本地实测**：调用真实 `http://127.0.0.1:8001/v1/chat/completions`，prepend role=system 验证返回 200 + 内容符合 prompt 引导
8. **Router 路由行为不变**：迁移前后给定相同 query + 候选列表，router 选择结果一致（行为等价性）

## 已识别风险

- **Qwen 服务对首条 role=system 的 schema 严格性未知**：实测优先
- **Router 行为不变**：迁移前后必须等价（红队 Test 8 保障）

## 时间预估

1-2 小时 autopilot 自动跑（含 design + implement + qa + auto-fix）
