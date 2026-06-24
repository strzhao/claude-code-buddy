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
    /// 复用 chatModel（routerModel = chatModel，system 走 send 参数）
    private let routerModel: String

    /// 测试用：覆盖 pluginManager.list() 的返回值（SC-13/SC-14 注入固定候选列表）
    var pluginsOverride: [PluginManifest]?

    init(pluginManager: PluginManager, provider: LauncherProvider, routerModel: String) {
        self.pluginManager = pluginManager
        self.provider = provider
        self.routerModel = routerModel
    }

    /// 主入口 wrapper：keyword 缩候选 → 短路判断 → 必要时 AI 选 1
    func route(query: String) async throws -> (decision: RouteDecision, candidates: [PluginManifest]) {
        let plugins = pluginsOverride ?? (try? pluginManager.list()) ?? []
        let scored = Self.narrowCandidatesScored(query: query, plugins: plugins)
        if scored.isEmpty {
            BuddyLogger.shared.debug("router → directChat (no candidates)", subsystem: "launcher", meta: ["query": query])
            return (.directChat, [])
        }
        let top = scored[0]
        let isUnique = scored.count == 1
        let isStrong = top.score >= LauncherConstants.routerSkipScore
        if isUnique || isStrong {
            BuddyLogger.shared.info("router short-circuit", subsystem: "launcher", meta: [
                "query": query, "plugin": top.manifest.name, "score": top.score,
                "reason": isUnique ? "unique" : "strong"
            ])
            return (.withPlugin(top.manifest), scored.map(\.manifest))
        }
        BuddyLogger.shared.debug("router → aiSelect", subsystem: "launcher", meta: [
            "query": query, "candidateCount": scored.count, "topScore": top.score
        ])
        let decision = try await pickWithAI(query: query, from: scored.map(\.manifest))
        BuddyLogger.shared.info("router aiSelect decision", subsystem: "launcher", meta: [
            "query": query, "decision": "\(decision)"
        ])
        return (decision, scored.map(\.manifest))
    }

    /// 第 1 阶段：keyword 缩候选（同步纯函数，几 ms）
    /// 中文兼容：unicode > 127 字符不作为分隔符（整段保留，走 contains 整词匹配）
    /// pluginsOverride 非 nil 时跳过 pluginManager（用于测试注入固定候选列表）
    func narrowCandidates(_ query: String) -> [PluginManifest] {
        let plugins = pluginsOverride ?? (try? pluginManager.list()) ?? []
        return Self.narrowCandidates(query: query, plugins: plugins)
    }

    /// 第 1 阶段（实例重载）：接受外部 plugins 列表，供测试注入（通过实例调用）
    /// 转发到静态版本，保持向后兼容（旧测试使用 router.narrowCandidates(query:plugins:)）
    func narrowCandidates(query: String, plugins: [PluginManifest]) -> [PluginManifest] {
        return Self.narrowCandidates(query: query, plugins: plugins)
    }

    /// 第 1 阶段（内部重载）：接受外部 plugins 列表，供测试注入
    /// 静态化：不用 self，供其他模块（LauncherManager.updateQuery）直接调
    static func narrowCandidates(query: String, plugins: [PluginManifest]) -> [PluginManifest] {
        return narrowCandidatesScored(query: query, plugins: plugins).map(\.manifest)
    }

    /// 带得分的候选列表（保留排序），供路由短路判断使用
    /// score >= LauncherConstants.routerSkipScore 时直接命中，无需 AI 路由
    static func narrowCandidatesScored(
        query: String,
        plugins: [PluginManifest]
    ) -> [(manifest: PluginManifest, score: Int)] {
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
            .map { (manifest: $0.0, score: $0.1) }
    }

    /// 第 2 阶段（公开接口）：AI 选 1（C3 契约）
    func pickWithAI(query: String, from candidates: [PluginManifest]) async throws -> RouteDecision {
        try await aiSelect(query: query, candidates: candidates)
    }

    /// 第 2 阶段：AI 选 1（异步，调一次 provider.send，无 tools）
    ///
    /// system prompt 通过 send 的 system 参数传递，user message 仅包含原始 query。
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
        let messages: [AgentMessage] = [.init(role: "user", content: [.text(query)])]
        let resp = try await provider.send(messages: messages, tools: [], model: routerModel, system: systemPrompt)

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
