# Task 001 Handoff — LauncherProvider system 字段

## 实现摘要

LauncherProvider 协议从 3 参数扩展为 4 参数（加 `system: String?`），AnthropicProvider 用 Messages API 原生 system 顶层字段，OpenAICompatibleProvider prepend role=system message 到 messages[0]。同时清理 LauncherRouter 历史 user-message 前缀 hack，systemInstruction 直接走 send 参数。**Swift 5.9 协议方法不支持默认值**，因此协议层无默认值，concrete impl 加 `= nil`，所有协议引用调用方（LauncherAgent + 4 个测试 mock）必须显式传 `system: nil`。

测试：红队 11 测试全 PASS（含 Qwen 真实端点 system message → 200 + 中文响应 4.72s）。QA Wave 1/1.5/2 全绿，仅 1 个预存 D1 测试隔离 bug（与本 task 无关）。

## 文件变更（commit 25c6630）

**源代码**：
- `apps/desktop/Sources/.../Provider/LauncherProvider.swift`（+1：协议加 system 参数）
- `apps/desktop/Sources/.../Provider/AnthropicProvider.swift`（+6：impl + AnthropicRequestBody 加 system 字段 + CodingKey）
- `apps/desktop/Sources/.../Provider/OpenAICompatibleProvider.swift`（+5：impl + var oaiMessages + insert index 0）
- `apps/desktop/Sources/.../LauncherRouter.swift`（±4：迁移 + 注释更新两处）
- `apps/desktop/Sources/.../Agent/LauncherAgent.swift`（+1：显式 system: nil）

**测试**：
- 4 个测试 mock 同步签名：LauncherAgentTests / LauncherAgentAcceptanceTests / LauncherRouterTests / LauncherRouterAcceptanceTests
- 新增红队验收测试：`LauncherProviderSystemFieldAcceptanceTests.swift`（11 测试 + Qwen 真实端点）

## 下游须知

### 给 task 003 (PluginDispatcher) / task 004 (PromptExecutor) / task 006 (builtin-translate)

调用 `provider.send()` 时**必须**显式传 system 参数（协议引用调用）：

```swift
// ✅ 正确
let response = try await provider.send(
    messages: messages,
    tools: [],
    model: model,
    system: config.systemPrompt    // 或 nil
)

// ❌ 错误（Swift 协议无默认值，会编译失败）
let response = try await provider.send(messages: messages, tools: [], model: model)
```

### 给所有未来写 LauncherProvider mock 的测试代码

Mock 类必须实现 4 参数签名：

```swift
final class MockProvider: LauncherProvider {
    var capturedSystem: String?  // 推荐保留，便于断言
    
    func send(messages: [AgentMessage], tools: [AgentTool], model: String, system: String? = nil) async throws -> AgentResponse {
        self.capturedSystem = system
        // ...
    }
}
```

### Provider 行为约定

- `system: nil` 或 `system: ""` → 不发送 system 字段（业务侧 guard 已统一）
- AnthropicProvider：通过 AnthropicRequestBody.system 顶层字段
- OpenAICompatibleProvider：insert `OAIMessage(role: "system", content: system)` 到 oaiMessages[0]

## 偏差说明

无偏差。设计 + brief 100% 落地，contract-checker 0 mismatch，qa-reviewer Section A 6/6 ✅。

唯一遗留：qa-reviewer 提了 1 个低优先级 style 建议 —— 两个 Provider 对 system 空值守卫风格不统一（`AnthropicProvider.swift:33` 三元 vs `OpenAICompatibleProvider.swift:38` if-let）。不阻塞，可后续 cleanup task 处理。

## 验证证据

- swift build：PASS (3.58s)
- swift test --filter Provider --filter Router --filter Agent：131 tests, 1 pre-existing failure（D1 isolation bug）
- SwiftLint --strict：PASS (0 violations / 97 files)
- 红队 11/11 PASS（含 Qwen 真实端点 system → 中文响应）
- contract-checker：PASS (0 mismatch)
- qa-reviewer：PASS（Section A 6/6 + Section B 仅 1 style 建议）
