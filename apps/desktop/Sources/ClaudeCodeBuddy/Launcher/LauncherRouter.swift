import Foundation

/// 路由决策：直接对话 vs 绑定 plugin tool
/// 用 Swift 自动合成 Equatable（PluginManifest 已 Codable+Equatable），不自定义 ==
enum RouteDecision: Equatable {
    case directChat
    case withPlugin(PluginManifest)
}

final class LauncherRouter {
    private let pluginManager: PluginManager
    private let provider: LauncherProvider
    /// 复用 chatModel（LauncherProvider 不暴露 system 字段，routerModel = chatModel）
    private let routerModel: String

    init(pluginManager: PluginManager, provider: LauncherProvider, routerModel: String) {
        self.pluginManager = pluginManager
        self.provider = provider
        self.routerModel = routerModel
    }

    /// 主入口：keyword 缩候选 → AI 选 1
    func route(query: String) async throws -> (decision: RouteDecision, candidates: [PluginManifest]) {
        let plugins = (try? pluginManager.list()) ?? []
        let candidates = narrowCandidates(query: query, plugins: plugins)
        if candidates.isEmpty { return (.directChat, []) }
        let decision = try await aiSelect(query: query, candidates: candidates)
        return (decision, candidates)
    }

    /// 第 1 阶段：keyword 缩候选（同步、本地，几 ms）
    /// 中文兼容：unicode > 127 字符不作为分隔符（整段保留，走 contains 整词匹配）
    func narrowCandidates(query: String, plugins: [PluginManifest]) -> [PluginManifest] {
        // 按 ASCII 标点分割；unicode > 127（中文/CJK 等）不作分隔符，整段保留
        let queryTokens = query.lowercased()
            .split(whereSeparator: { c in
                let isAsciiPunct = !c.isLetter && !c.isNumber
                let isHighUnicode = c.unicodeScalars.first.map { $0.value > 127 } ?? false
                return isAsciiPunct && !isHighUnicode
            })
            .map(String.init).filter { !$0.isEmpty }
        guard !queryTokens.isEmpty else { return [] }

        let queryLower = query.lowercased()

        let scored: [(PluginManifest, Int)] = plugins.map { plugin in
            var score = 0
            let nameLower = plugin.name.lowercased()
            let descLower = plugin.description.lowercased()
            let kwsLower = plugin.keywords.map { $0.lowercased() }

            // 1. token（query 分词）在 name/desc/kw 中的命中
            for token in queryTokens {
                let haystack = ([nameLower, descLower] + kwsLower).joined(separator: " ")
                if haystack.contains(token) { score += 1 }
                if nameLower.contains(token) { score += 5 }
                if kwsLower.contains(where: { $0.contains(token) }) { score += 3 }
            }

            // 2. 反向检查：plugin 的 keywords 是否被 query 包含（中文整词匹配）
            //    例：query="请翻译这段"，keyword="翻译" → query.contains(kw) 命中
            for kw in kwsLower where queryLower.contains(kw) { score += 3 }
            if queryLower.contains(nameLower) { score += 5 }

            return (plugin, score)
        }
        return scored.filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(LauncherConstants.routerMaxCandidates)
            .map { $0.0 }
    }

    /// 第 2 阶段：AI 选 1（异步，调一次 provider.send，无 tools）
    ///
    /// **system prompt 通过 user message 前缀传递**：
    /// LauncherProvider.send 协议不暴露独立 system 字段（task 002 设计），
    /// 故将 system prompt 嵌入 user message 首段，再追加 "User query: ..."。
    /// Trade-off：claude-haiku/sonnet 对此差异不显著；用"Reply ONLY with..."强约束输出。
    func aiSelect(query: String, candidates: [PluginManifest]) async throws -> RouteDecision {
        guard !candidates.isEmpty else { return .directChat }
        let candidateLines = candidates.map { p in
            "- \(p.name): \(p.description) (keywords: \(p.keywords.joined(separator: ", ")))"
        }.joined(separator: "\n")
        let systemPrompt = """
        You are a router. Given a user query, decide which plugin to use (or none for direct chat).
        Available plugins:
        \(candidateLines)

        Reply ONLY with the plugin name (e.g. "translate"), or "NONE" for direct chat. No other text.
        """
        let combinedPrompt = systemPrompt + "\n\nUser query: " + query
        let messages: [AgentMessage] = [.init(role: "user", content: [.text(combinedPrompt)])]
        let resp = try await provider.send(messages: messages, tools: [], model: routerModel)

        let answer = resp.content.compactMap { c -> String? in
            if case .text(let s) = c { return s }
            return nil
        }.joined().trimmingCharacters(in: .whitespacesAndNewlines)

        if answer == "NONE" || answer.isEmpty { return .directChat }
        if let matched = candidates.first(where: { $0.name == answer }) {
            return .withPlugin(matched)
        }
        // AI hallucinate 非候选名 → 兜底 directChat
        return .directChat
    }
}
