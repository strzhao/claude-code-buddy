<!-- tags: launcher, router, ai-router, llm-call, perf, score, narrow-candidates, plugin-selection, architecture, yagni -->
# [2026-05-31] launcher router 短路：唯一/strong 命中跳过 aiSelect LLM call

## 反模式
LauncherRouter 当前实现：
```swift
func route(query: String) async throws -> ... {
    let candidates = narrowCandidates(query)            // keyword 评分
    if candidates.isEmpty { return (.directChat, []) }
    let decision = try await pickWithAI(query: query, ...) // ★ 无条件调 LLM
    return (decision, candidates)
}
```
即使 keyword 评分只命中**唯一** plugin（无歧义），仍调一次 LLM 让它确认"这唯一候选就是 translate 吗" → **字面意义上的废话调用**。`tr buddy` 这类场景白白浪费 1.4s（thinking on）或 65ms（thinking off）。

## 修复
返回 scored 元组，唯一/strong 命中时短路：
```swift
func route(query: String) async throws -> ... {
    let scored = narrowCandidatesScored(query)         // [(manifest, score)]
    if scored.isEmpty { return (.directChat, []) }
    let top = scored[0]
    let isUnique = scored.count == 1
    let isStrong = top.score >= LauncherConstants.routerSkipScore  // 10
    if isUnique || isStrong {
        return (.withPlugin(top.manifest), [top.manifest])  // ★ 跳过 aiSelect
    }
    let decision = try await pickWithAI(query: query, from: scored.map(\.manifest))
    return (decision, scored.map(\.manifest))
}
```

## 阈值选择（routerSkipScore = 10）
narrowCandidates 评分（见 `LauncherRouter.swift:56`）：
- token 命中 plugin name 内含: +5
- token 出现在 haystack（name+desc+kw 拼接）: +1
- token 命中 keyword 内含: +3
- 反向 query 含 keyword 全文: +3
- 反向 query 含 plugin name 全文: +5

**score ≥ 10 → 仅当 plugin name 完全匹配（5+5=10）或类似强信号**。keyword 精确命中只到 6（3+3），保留走 aiSelect 让 AI 矫正可能的 false positive。

## Why
- router 的设计本意是「**多候选歧义裁决**」——唯一候选 → 数学上不存在歧义，调 AI 无信息增益
- 哪怕 AI 调用极快（65ms），干脆**不调**仍更优：省网络 + provider 构造 + LLM 上下文污染风险（"NONE" 误判）
- 99% 流量是用户明确 keyword 命中场景（`tr xxx` / `翻译 xxx`），全受益

## 风险与对策
| 风险 | 对策 |
|---|---|
| 阈值定低 → 误短路（让 AI 没机会矫正 narrow 的 false positive）| 阈值取保守 10，仅 plugin name 完全匹配才超过 |
| 唯一候选其实是用户不想要的（如装了个不常用 plugin 关键词撞了）| 唯一候选短路是合理 trade-off；用户可在 launcher.json 移除噪音 keyword |

## How to apply
- 任何"keyword 缩候选 + AI 选 1" 两阶段路由架构都应加这层短路
- AI 调用作为"歧义裁决器"，不是"无脑确认器"
- 对 LauncherProvider mock 测试用 sendCallCount=0 断言短路生效

## 关联
- 由 [[2026-05-27-ai-router-system-prompt-prefix]] 描述的 AI 路由架构 + 本短路 = 完整 router 设计
- 用户反问"唯一命中时 Call #1 价值是什么"触发的架构反思
