# Swift 5.9 协议方法不支持默认参数值，需 concrete impl 各加默认 + 协议引用调用方显式传

<!-- tags: swift, protocol, default-parameter, swift-5.9, language-limitation, launcher-provider, api-evolution, backward-compatibility -->

**Scenario**: task 001 给 `LauncherProvider.send()` 加新参数 `system: String?` 时，设计初稿写法是：

```swift
protocol LauncherProvider {
    func send(messages: [AgentMessage], tools: [AgentTool], model: String, system: String? = nil) async throws -> AgentResponse
}
```

期望：现有调用方编译零改动（Swift 5.9 应该支持？）。实际：Swift 5.9 **不允许** protocol 方法 requirement 带默认参数值（SE-0309 仍未落地）。protocol 默认参数会编译错误：`'default arguments are not allowed in protocol requirements'`。

**Lesson**: API 演进给协议加新参数时的正确范式：

1. **协议层无默认值**：`func send(..., system: String?)`（必填）
2. **每个 concrete impl 加默认值**：`func send(..., system: String? = nil)`（concrete 类型直调可省略）
3. **协议引用调用方必须显式传参**：所有 `let provider: LauncherProvider; provider.send(...)` 调用都要补 `system: nil`（或显式值），否则编译失败

为什么？Swift 协议引用（动态分发）不知道哪个 impl 提供了默认值，必须 require 调用方显式传参。concrete 类型引用（静态分发）可以走 impl 的默认值。

**应对清单**：API 演进时一次性更新：
- 所有协议 impl（本工程：AnthropicProvider, OpenAICompatibleProvider）→ 加 `= nil`
- 所有协议 mock impl（本工程：MockProvider, RouterMockProvider 等 4 个）→ 加 `= nil`（mock 通常也走协议引用）
- 所有协议引用调用方（本工程：LauncherAgent, LauncherRouter 等）→ 显式传 `system: nil`

**Evidence**: task 001 plan-reviewer 第一时间识别此陷阱，设计文档加"修正 1"明确方案。蓝队按此实现，9 个文件全部就位，swift build 一次通过。如果按设计初稿写，至少 6 个文件编译失败，return-trip 一轮 QA。

**关联**：
- 与 Swift Evolution SE-0309（接受但未实现）相关
- 与 Anti-Overfitting：本陷阱在任何"给现有协议加可选参数"的场景都适用，非 launcher 特有
- 对比 Kotlin/Scala：默认参数在接口方法中允许，Swift 是少数派
