---
id: "003-agent-loop"
depends_on: ["002-provider-abstraction"]
complexity: M
milestone: M2
acceptance_scenarios: [SC-03, SC-08]
contract_required: true
---

# 003 — Agent Loop（永远 loop 早停）+ Markdown 流式渲染

## 目标

把 `~/workspace/learn-everything/topics/agent-harness-engineering/artifacts/01-minimal-agent-loop/agent.ts`（76 行）翻译成 Swift 的 LauncherAgent，挂在 LauncherManager.submit 后面。Markdown 渲染用 `AttributedString(markdown:)`。本任务**不**做插件接入（留给 005），但内置 `echo` 桩 tool 验证 tool_use 分支。

## 架构上下文

- 文件：`Launcher/Agent/`
- 数据结构与 task 002 共享（AgentMessage / AgentContent / AgentResponse 已定义）
- 替换 task 001 的 `LauncherManager.submit` 占位实现

## 输入

- learn-everything v1 完整源码（76 行）
- Task 002 handoff（LauncherProvider 接口）
- Anthropic stop_reason 枚举值：`end_turn` / `tool_use` / `max_tokens` / `stop_sequence`

## 输出契约

### 接口签名（invariant）

```swift
struct AgentLoopConfig {
    let maxIterations: Int           // 缺省 10
    let systemPrompt: String?
}

enum AgentEvent {
    case text(String)                // 增量片段
    case toolCall(name: String, input: [String: AnyCodable])
    case toolResult(name: String, output: String, isError: Bool)
    case done(reason: String)        // "end_turn" / "max_tokens" / "max_iterations"
    case error(LauncherError)
}

final class LauncherAgent {
    init(provider: LauncherProvider, tools: [AgentTool], toolExecutor: (String, [String: AnyCodable]) async throws -> String)
    
    func run(prompt: String, config: AgentLoopConfig) -> AsyncStream<AgentEvent>
}

// LauncherManager.submit 重写
extension LauncherManager {
    func submit(_ query: String) -> AsyncStream<AgentEvent> {
        // 1. 加载 config 获取 active provider
        // 2. 构造 LauncherAgent（task 005 会传插件 tools，本任务先传 echo）
        // 3. agent.run(prompt: query)
    }
}

// Markdown 渲染辅助
enum MarkdownRenderer {
    static func render(_ markdown: String) -> AttributedString
    // 使用 AttributedString(markdown:options:) macOS 12+
    // options: .init(allowsExtendedAttributes: true, interpretedSyntax: .inlineOnlyPreservingWhitespace)
}
```

### 核心算法（伪代码）

```swift
func run(prompt: String, config: AgentLoopConfig) -> AsyncStream<AgentEvent> {
    AsyncStream { continuation in
        Task {
            var messages: [AgentMessage] = [AgentMessage(role: "user", content: [.text(prompt)])]
            
            for round in 1...config.maxIterations {
                let resp: AgentResponse
                do {
                    resp = try await provider.send(messages: messages, tools: tools, model: model)
                } catch {
                    continuation.yield(.error(.networkFailure(error)))
                    continuation.finish(); return
                }
                
                // 增量 yield text content
                for item in resp.content {
                    if case .text(let s) = item { continuation.yield(.text(s)) }
                }
                
                // append assistant message
                messages.append(AgentMessage(role: "assistant", content: resp.content))
                
                if resp.stopReason != "tool_use" {
                    continuation.yield(.done(reason: resp.stopReason))
                    continuation.finish(); return
                }
                
                // 执行所有 tool_use
                var toolResults: [AgentContent] = []
                for item in resp.content {
                    if case .toolUse(let id, let name, let input) = item {
                        continuation.yield(.toolCall(name: name, input: input))
                        let output: String; let isError: Bool
                        do {
                            output = try await toolExecutor(name, input)
                            isError = false
                        } catch {
                            output = "Tool failed: \(error)"
                            isError = true
                        }
                        continuation.yield(.toolResult(name: name, output: output, isError: isError))
                        toolResults.append(.toolResult(toolUseId: id, content: output, isError: isError))
                    }
                }
                messages.append(AgentMessage(role: "user", content: toolResults))
            }
            
            // 达到 max iterations
            continuation.yield(.error(.maxIterations))
            continuation.finish()
        }
    }
}
```

### 接口签名（example）

```
# 直接对话正例
Given: prompt="Hi", tools=[]
When:  agent.run(prompt:)
Then:  events 流：.text("Hello!") → .done("end_turn")

# 单轮 tool_use 正例
Given: prompt="echo hello", tools=[echo_tool]，echo_tool 接 input.text 返回 input.text
When:  agent.run(prompt:)
Then:  events: .toolCall("echo", {text:"hello"}) → .toolResult("echo", "hello", false)
        → .text("Done.") → .done("end_turn")

# Max iterations 边界
Given: tool 永远返回需要再调用的 prompt，每轮都 tool_use
When:  agent.run(prompt:, config:.init(maxIterations:10))
Then:  10 轮后 yield .error(.maxIterations) → finish

# Network failure
Given: provider 抛 URLError.timedOut
When:  send(...)
Then:  yield .error(.networkFailure(error)) → finish（不重试）
```

### 数据结构

- `AgentMessage.role: "user" | "assistant"`
- tool_result 在 Anthropic 协议里走 **user** 消息的 content 数组（不是 assistant）
- `AnyCodable` 包装 input（动态 JSON）

### 边界值（DbC）

- maxIterations：== 10（缺省）/ 用户可配 ≤ 20
- HTTP 单次超时：≤ 120s
- 单次 yield .text 片段最小：无下限（可以是 1 char）
- Markdown 累积 buffer 大小：≤ 1 MiB（超过截断 + 警告）

### 错误契约

| 错误码 | 触发 |
|---|---|
| `maxIterations` | loop 跑到第 maxIterations 仍 tool_use |
| `networkFailure(Error)` | 任何一轮 send 抛错 |
| `providerHTTPError(Int, String)` | 4xx/5xx |

### 副作用清单

- 调 provider.send（task 002 实现，HTTP 网络出）
- 调 toolExecutor（task 004 才有真实插件；本任务用 echo 闭包桩）

## 验收标准

- ✅ SC-03：浮窗输入"什么是量子纠缠"按回车，输出区域流式 markdown 渲染 AI 回答（标题/列表/代码块正确）
- ✅ SC-08：关闭浮窗再召唤，新 session（新 messages 数组，无历史）

## 测试要求

- `LauncherAgentTests.swift`：
  - mock provider 返回 end_turn → 期望 .text + .done
  - mock provider 返回 tool_use → 期望 .toolCall + .toolResult + 第二轮 send + .done
  - mock provider 永远 tool_use → 期望第 10 轮后 .error(.maxIterations)
  - mock provider 抛错 → 期望 .error(.networkFailure)
- `MarkdownRendererTests.swift`：标题/列表/代码块/链接 各一个 fixture
- `LauncherAgent.acceptance.test.swift`（红队）：用 mock provider 跑完整 5 轮 tool_use 场景

## 风险与缓解

- **流式 markdown 代码块未闭合**：增量 yield 用 buffer 累积，到 .done 才最终 render 完整 AttributedString
- **Codable 解码 AgentContent.type 字段**：单元测试覆盖 type="text" 和 "tool_use" 两种 fixture，确保 Swift Codable 正确判别
- **AnyCodable 实现选择**：自己写一个最小 AnyCodable（不引入第三方库），仅支持 String/Int/Double/Bool/Array/Dictionary 即可

## 接出

handoff 写：LauncherAgent.run 接入 LauncherInputView 的具体 line:N；toolExecutor 闭包签名（task 004/005 会传真实 plugin executor）；MarkdownRenderer.render 在 SwiftUI 中的使用方式。
