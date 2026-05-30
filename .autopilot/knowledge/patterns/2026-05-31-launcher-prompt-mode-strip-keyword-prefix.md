<!-- tags: launcher, prompt-mode, keyword-routing, llm, query-preprocessing, edge-case, plugin, translate, word-boundary, strict-matching -->
# [2026-05-31] launcher prompt-mode 必须剥离 keyword 前缀再传 LLM（带严格边界检查）

## 现象
用户输入 `tr buddy` 命中 translate plugin（keyword 含 `tr`），但 LLM 收到的 query 也是 `tr buddy`，于是输出 `tr (训练员/旅行) 伙伴` —— 把 `tr` 当成英文缩写解释。

## 根因
LauncherManager 的 keyword 路由命中 plugin 后，把**原始 query**（含命中的 keyword 前缀）直接塞给 LLM。LLM 没有"keyword 是路由信号"这层认知，会把 `tr` 当成用户真实输入的一部分。

## 修复
prompt mode 触发 LLM 前，调 `stripKeywordPrefix(query, manifest)`：
```swift
nonisolated static func stripKeywordPrefix(_ query: String, manifest: PluginManifest) -> String {
    // 长前缀优先（"translate" 在 "tr" 前）
    let candidates = ([manifest.name] + manifest.keywords)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
        .sorted { $0.count > $1.count }
    let queryLower = query.lowercased()
    for prefix in candidates {
        let prefixLower = prefix.lowercased()
        guard queryLower.hasPrefix(prefixLower) else { continue }
        let after = query.index(query.startIndex, offsetBy: prefix.count)
        if after == query.endIndex { return "" }
        let nextChar = query[after]
        // 严格边界：前缀后必须是空白/标点，否则属于词内匹配，不剥离
        if nextChar.isWhitespace || nextChar.isPunctuation {
            return String(query[after...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    return query
}
```

## 两个关键边界条件
1. **长前缀优先**：keywords `["tr", "translate"]` + query `"translate buddy"` → 先匹 `translate` 剥成 `buddy`，否则会被 `tr` 切成 `anslate buddy`。
2. **严格边界检查**：query `"trace bug"` 不能被 keyword `tr` 切成 `ace bug`。前缀后必须是空白或标点（`isWhitespace || isPunctuation`），否则视为词内匹配，原样保留。

## Why
- LLM router 已经把"路由决策"做完了，keyword 完成使命就该退出 query，不该污染 LLM 的语义输入空间。
- 严格边界检查避免误剥离：keyword 是短前缀（`tr`/`fy`）时很容易撞到无关单词的开头。

## How to apply
- 任何 launcher prompt-mode plugin（mode: prompt），都必须在调 LLM 前 strip 命中的 keyword 前缀。
- agent-mode plugin 同理适用（user query 进 agent loop 也别带 keyword 噪声）。
- 关联 [[2026-05-27-ai-router-system-prompt-prefix]]：路由用 system prompt，user message 用纯净 query — 二者形成"路由层 / 语义层"的清晰分离。

## 代码锚点
- `apps/desktop/Sources/ClaudeCodeBuddy/Launcher/LauncherManager.swift` (`stripKeywordPrefix`)
- 调用点：`LauncherManager.submit` → prompt mode 分支 → `PluginInput(query: strippedQuery, ...)`
