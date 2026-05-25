---
id: "005-routing"
depends_on: ["003-agent-loop", "004-plugin-runtime"]
complexity: M
milestone: M4
acceptance_scenarios: [SC-03, SC-04, SC-05]
contract_required: true
---

# 005 — 智能路由（keyword 缩候选 + AI 选 plugin + 候选列表 UI）

## 目标

实现 LauncherRouter：先用 keyword 模糊匹配把所有 plugin 缩到 ≤5 个候选，再把候选的 manifest + README.md 喂 system prompt 让 AI 选 1 个 plugin（或直接对话）。候选 UI 列表展示 top 候选，上下箭头切换。

## 架构上下文

- 文件：`Launcher/LauncherRouter.swift` + `Launcher/LauncherCandidateView.swift`
- 接入点：LauncherManager.submit → Router.route → 决定 Agent 是直接对话（无 tools）还是带 plugin tools
- Router 不直接执行 plugin，而是把"是否绑定 plugin tools"决策提前到 AI 调用前

## 输入

- Task 003 handoff（LauncherAgent 接口）
- Task 004 handoff（PluginManager.list + PluginExecutor.execute）

## 输出契约

### 接口签名（invariant）

```swift
enum RouteDecision {
    case directChat                          // 无 plugin，纯对话
    case withPlugin(PluginManifest)         // AI 把 plugin 作为 tool 调用
}

final class LauncherRouter {
    init(pluginManager: PluginManager, provider: LauncherProvider)
    
    // 主入口
    func route(query: String) async throws -> (decision: RouteDecision, candidates: [PluginManifest])
    
    // 第 1 阶段：keyword 缩候选（同步、本地，几 ms）
    func narrowCandidates(query: String, plugins: [PluginManifest]) -> [PluginManifest]
    
    // 第 2 阶段：AI 选 1（异步，调一次 provider.send，无 tools）
    func aiSelect(query: String, candidates: [PluginManifest]) async throws -> RouteDecision
}

// Plugin → AgentTool 转换
extension PluginManifest {
    func toAgentTool() -> AgentTool {
        // name: self.name
        // description: self.description
        // inputSchema: { "query": {type:"string"} }
    }
}

// LauncherManager.submit 重写（最终版本）
extension LauncherManager {
    func submit(_ query: String) -> AsyncStream<AgentEvent> {
        AsyncStream { continuation in
            Task {
                // 1. Router 决策
                let (decision, _) = try await router.route(query: query)
                
                // 2. 构造 LauncherAgent 的 tools 和 toolExecutor
                let tools: [AgentTool]
                let toolExecutor: (String, [String: AnyCodable]) async throws -> String
                switch decision {
                case .directChat:
                    tools = []
                    toolExecutor = { _, _ in throw LauncherError.providerNotConfigured }
                case .withPlugin(let manifest):
                    tools = [manifest.toAgentTool()]
                    toolExecutor = { name, input in
                        guard name == manifest.name else { throw LauncherError.pluginNotFound(name) }
                        guard trustStore.isTrusted(manifest) else {
                            // task 006 接 NSAlert 弹框；本任务仅占位抛错
                            throw LauncherError.pluginNotTrusted(manifest.name)
                        }
                        let pluginInput = PluginInput(
                            query: input["query"]?.value as? String ?? "",
                            sessionId: currentSessionId,
                            cwd: NSHomeDirectory()
                        )
                        let result = try await executor.execute(manifest, pluginDir: ..., input: pluginInput)
                        return result.stdout
                    }
                }
                
                // 3. 启动 agent
                let agent = LauncherAgent(provider: provider, tools: tools, toolExecutor: toolExecutor)
                for await event in agent.run(prompt: query, config: .init(maxIterations: 10, systemPrompt: nil)) {
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }
    }
}

// 候选列表 UI
struct LauncherCandidateView: View {
    let candidates: [PluginManifest]
    @Binding var selectedIndex: Int
    // 显示 candidates[i].name + .description
    // 上下箭头键切换 selectedIndex
}
```

### keyword 缩候选算法（伪代码）

```swift
func narrowCandidates(query: String, plugins: [PluginManifest]) -> [PluginManifest] {
    let queryTokens = query.lowercased().split(separator: " ").map(String.init)
    
    let scored = plugins.map { plugin -> (PluginManifest, Int) in
        var score = 0
        let haystack = ([plugin.name, plugin.description] + plugin.keywords).joined(separator: " ").lowercased()
        for token in queryTokens {
            if haystack.contains(token) { score += 1 }
            if plugin.name.lowercased().contains(token) { score += 5 }     // name 命中加权
            if plugin.keywords.contains { $0.lowercased() == token } { score += 3 } // 关键词精确加权
        }
        return (plugin, score)
    }
    
    return scored
        .filter { $0.1 > 0 }
        .sorted { $0.1 > $1.1 }
        .prefix(5)
        .map { $0.0 }
}
```

### AI 选 1 算法（伪代码）

```swift
func aiSelect(query: String, candidates: [PluginManifest]) async throws -> RouteDecision {
    if candidates.isEmpty { return .directChat }
    
    // 构造 system prompt
    let candidateDescriptions = candidates.map { p in
        "- \(p.name): \(p.description) (keywords: \(p.keywords.joined(separator: ", ")))"
    }.joined(separator: "\n")
    
    let systemPrompt = """
    You are a router. Given a user query, decide which plugin to use (or none for direct chat).
    Available plugins:
    \(candidateDescriptions)
    
    Reply ONLY with the plugin name, or "NONE" for direct chat.
    """
    
    let messages: [AgentMessage] = [.init(role: "user", content: [.text(query)])]
    let resp = try await provider.send(messages: messages, tools: [], model: routerModel)
    
    let answer = resp.content.compactMap { c -> String? in
        if case .text(let s) = c { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        return nil
    }.joined()
    
    if answer == "NONE" || answer.isEmpty { return .directChat }
    
    if let matched = candidates.first(where: { $0.name == answer }) {
        return .withPlugin(matched)
    }
    
    // AI 返回了非候选名 → 兜底直接对话
    return .directChat
}
```

### 接口签名（example）

```
# 无插件场景
Given: PluginManager.list() == []
When:  router.route("hi")
Then:  (.directChat, [])

# 有插件但 keyword 不匹配
Given: plugins=[translate(keywords:["翻译","translate"])]
When:  router.route("讲个笑话")
Then:  (.directChat, [])  // 缩候选阶段 score=0，跳过 AI 选

# Keyword 匹配 + AI 选中
Given: plugins=[translate(keywords:["翻译"])]
When:  router.route("翻译这段：Hello")
Then:  (.withPlugin(translate), [translate])  // keyword 命中 → AI 选中

# AI 兜底
Given: plugins=[translate], AI 返回 "NONE"
When:  router.route("翻译这段")  // keyword 仍命中
Then:  (.directChat, [translate])  // AI 决定不用
```

### 数据结构

- `RouteDecision` 枚举只有 2 个 case（不要扩展到 3+，YAGNI）
- candidates 数组顺序按 score 降序
- AI 选 1 用专门的 routerModel（可与 chatModel 不同，可在 config 配 cheaper/faster 模型如 haiku）

### 边界值（DbC）

- 候选数量：≤ 5（缩候选输出）
- AI 选 1 调用：== 1 次 provider.send（不允许多轮）
- AI 选 1 超时：≤ 30s
- keyword 缩候选时间：≤ 100ms（本地，无 IO）

### 错误契约

| 错误码 | 触发 |
|---|---|
| `pluginNotFound(String)` | toolExecutor 收到非候选 plugin 名 |
| `pluginNotTrusted(String)` | trustStore 未通过（task 006 实现） |
| 其他来自 task 002/003/004 的错误透传 |

### 副作用清单

- 一次额外的 provider.send（路由用，不算 agent loop 的 iteration）
- 不写文件、不启子进程（这些由下游处理）

## 验收标准

- ✅ SC-03（增强）：输入"什么是量子纠缠"无 plugin 走 directChat，markdown 流式渲染
- ✅ SC-04（增强）：装了 translate plugin 后输入"翻译 hello" → AI 选中 translate plugin
- ✅ SC-05（增强）：plugin 执行后 stdout 通过 toolResult 注入到 agent loop 继续对话

## 测试要求

- `LauncherRouterTests.swift`：
  - 空 plugin → directChat
  - keyword 不匹配 → directChat 不调 AI
  - keyword 匹配但 AI 返回 NONE → directChat
  - keyword 匹配 + AI 选中 → withPlugin
  - AI 返回非候选名 → directChat 兜底
- `LauncherCandidateViewSnapshotTests.swift`：候选列表渲染快照
- `LauncherRouter.acceptance.test.swift`（红队）：mock plugin manager + mock provider 跑完整路径

## 风险与缓解

- **AI 选 1 hallucinate 一个不存在的 plugin 名**：兜底返回 directChat（已设计）；测试 fixture 覆盖
- **路由 prompt 太长拖慢响应**：限制 candidates ≤ 5，README 不喂（只喂 manifest description + keywords）；如必须喂 README，截断到 500 字以内
- **routerModel 配置缺失**：fallback 用 activeProvider 的 model（同模型多次调用）

## 接出

handoff 写：LauncherRouter.route 接入 LauncherManager.submit 的具体 line:N；toolExecutor 闭包形态；task 006 需要在哪里加 trustStore.check + NSAlert（指明 toolExecutor 闭包内的具体行）。
