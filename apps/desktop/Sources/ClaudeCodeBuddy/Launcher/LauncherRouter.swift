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
        // D8.3：短路条件对齐统一量纲（C-UNIFIED-SCORE）——词首档及以上（>=500）才可跳过 AI。
        // contains 档 150 不短路（「密码」类 contains 弱命中不再直接路由到插件）。
        let isStrong = top.score >= LauncherConstants.unifiedRouteSkipScore
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
    /// 静态化：不用 self，供其他模块（LauncherManager.submit AI 流）直接调
    static func narrowCandidates(query: String, plugins: [PluginManifest]) -> [PluginManifest] {
        return narrowCandidatesScored(query: query, plugins: plugins).map(\.manifest)
    }

    /// 带得分的候选列表（保留排序），供路由短路判断使用。
    ///
    /// D8.3：打分内核替换为 `UnifiedPluginScorer`（C-UNIFIED-SCORE 统一量纲：
    /// 完全 1000 / 前缀 800 / 词首 500 / contains 150，name +30），
    /// 使 debug route 输出的 candidates 分数与 typing 期 unifiedCandidates 一致。
    /// score >= LauncherConstants.unifiedRouteSkipScore（500）时直接命中，无需 AI 路由。
    static func narrowCandidatesScored(
        query: String,
        plugins: [PluginManifest]
    ) -> [(manifest: PluginManifest, score: Int)] {
        return plugins.map { plugin in
            (manifest: plugin, score: UnifiedPluginScorer.score(query: query, manifest: plugin))
        }
        .filter { $0.score > 0 }
        .sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.manifest.name < rhs.manifest.name   // 同分 title 字典序稳定排序
        }
        .prefix(LauncherConstants.routerMaxCandidates)
        .map { $0 }
    }

    /// 第 2 阶段（公开接口）：AI 选 1（C3 契约）
    func pickWithAI(query: String, from candidates: [PluginManifest]) async throws -> RouteDecision {
        try await aiSelect(query: query, candidates: candidates)
    }

    /// 第 2 阶段（tool 路由）：把所有开启插件作 LLM tool，provider 返回 tool_calls → 匹配 plugin name。
    ///
    /// 设计（Part 2）：
    /// - tools = 所有 plugins 的 toAgentTool()（prompt mode 排除已在 LauncherManager 候选筛选完成）
    /// - provider.send(tools, system) → 解析 .toolUse → 匹配 plugin name → (RouteDecision, extractedQuery)
    /// - extractedQuery：tool_call.input["query"] 优先（固定 {query} 契约）；非 query 键 → nil（让执行层 stripKeywordPrefix 兜底）
    /// - 无 tool_use → 文本兜底（回退 aiSelect name 匹配）
    /// - hallucinate 名（不在 plugins）→ .directChat（C-HALLUCINATE）
    /// - 空 plugins → send tools==[]，无 tool_call → .directChat（C-NO-TOOL-NO-FORGE）
    ///
    /// 返回元组：(decision, extractedQuery)。extractedQuery==nil 表示未提取（文本兜底/hallucinate/directChat）。
    func selectWithTools(
        query: String,
        plugins: [PluginManifest]
    ) async throws -> (decision: RouteDecision, extractedQuery: String?) {
        // 构造 tools：所有 plugins 作 tool（select pass 不执行，仅声明）
        let tools = plugins.map { $0.toAgentTool() }

        // system prompt：路由指令 + 原始 query（user message）。
        // D8.2：keywords 用 effectiveTriggerKeywords（过滤单字）——「码」类单字锚点不进 LLM 上下文。
        let candidateLines = plugins.map { p in
            "- \(p.name): \(p.description) (keywords: \(p.effectiveTriggerKeywords.joined(separator: ", ")))"
        }.joined(separator: "\n")
        let systemPrompt = """
        You are a router. Given a user query, decide which plugin to use (or none for direct chat).
        Available plugins:
        \(candidateLines)

        Call the matching plugin tool with the user's request as arguments, or reply with text for direct chat.
        """
        let messages: [AgentMessage] = [.init(role: "user", content: [.text(query)])]

        let resp = try await provider.send(
            messages: messages,
            tools: tools,
            model: routerModel,
            system: systemPrompt
        )

        // 找第一个 .toolUse（与 stdin agent loop 一致：首个 tool_call 即路由决策）
        let toolUse = resp.content.first { c in
            if case .toolUse = c { return true }
            return false
        }

        guard case .toolUse(_, let toolName, let input)? = toolUse else {
            // 无 tool_use → .directChat（C-NO-TOOL-NO-FORGE：LLM 选择不调 tool 即直接对话）
            // 不二次路由（避免浪费 LLM 调用 + 防文本兜底误命中）
            BuddyLogger.shared.debug("selectWithTools: no tool_use → directChat", subsystem: "launcher", meta: ["query": query])
            return (.directChat, nil)
        }

        // 匹配 plugin name（精确匹配，大小写敏感 — C-HALLUCINATE）
        guard let matched = plugins.first(where: { $0.name == toolName }) else {
            BuddyLogger.shared.warn("selectWithTools: hallucinated plugin name", subsystem: "launcher", meta: ["query": query, "toolName": toolName])
            return (.directChat, nil)
        }

        // extractedQuery：input["query"] 优先（固定 {query} 契约）；结构化 parameters 非 query 键 → nil
        let extractedQuery: String? = {
            if let q = input["query"]?.value as? String, !q.isEmpty {
                return q
            }
            return nil
        }()

        BuddyLogger.shared.info("selectWithTools: routed to plugin", subsystem: "launcher", meta: [
            "query": query, "plugin": matched.name, "hasExtractedQuery": extractedQuery != nil
        ])
        return (.withPlugin(matched), extractedQuery)
    }

    /// 第 2 阶段（debug route 入口）：镜像 `LauncherManager.submit` 的路由分支决策。
    ///
    /// 把 debug CLI 的路由选择下沉到此（router 层有 mock provider 设施可单测），handler 只调它。
    /// 分支（与 submit 完全一致）：
    /// - candidates 空 → `(.directChat, nil, "directChat")`，不调 provider（不浪费 LLM 调用）
    /// - 全 prompt mode（filter `promptConfig == nil` 后空）→ `pickWithAI` 文本路由，routeMethod `"pickWithAI"`
    /// - 含 tool 候选 → `selectWithTools`，routeMethod `"selectWithTools"`，回传 extractedQuery
    ///
    /// 返回 `(decision, extractedQuery, routeMethod)`。routeMethod 供 debug CLI 透传给用户，
    /// 让「自然语言→选插件」的 tool-use 路径在 cli 下可观测、可验证（修 e2a65ca 后 debug route
    /// 仍走旧 pickWithAI 的缺口）。
    /// debugRoute 返回类型（debug CLI 透传 routeMethod 让 tool-use 路径可观测；拆 struct 避 large_tuple）。
    struct DebugRouteResult {
        let decision: RouteDecision
        let extractedQuery: String?
        let routeMethod: String
    }

    func debugRoute(
        query: String,
        candidates: [PluginManifest]
    ) async throws -> DebugRouteResult {
        if candidates.isEmpty {
            return DebugRouteResult(decision: .directChat, extractedQuery: nil, routeMethod: "directChat")
        }
        // 与 submit 一致：tool 候选 = 非 prompt mode（stdin/command）
        let toolCandidates = candidates.filter { $0.promptConfig == nil }
        if toolCandidates.isEmpty {
            // 全 prompt mode → 退回文本路由（prompt mode 暂不作 tool，设计文档约定）
            let decision = try await pickWithAI(query: query, from: candidates)
            return DebugRouteResult(decision: decision, extractedQuery: nil, routeMethod: "pickWithAI")
        }
        let result = try await selectWithTools(query: query, plugins: toolCandidates)
        return DebugRouteResult(decision: result.decision, extractedQuery: result.extractedQuery, routeMethod: "selectWithTools")
    }

    /// 第 2 阶段：AI 选 1（异步，调一次 provider.send，无 tools）
    ///
    /// system prompt 通过 send 的 system 参数传递，user message 仅包含原始 query。
    func aiSelect(query: String, candidates: [PluginManifest]) async throws -> RouteDecision {
        guard !candidates.isEmpty else { return .directChat }
        // D8.2：keywords 用 effectiveTriggerKeywords（过滤单字，与 selectWithTools 同构）
        let candidateLines = candidates.map { p in
            "- \(p.name): \(p.description) (keywords: \(p.effectiveTriggerKeywords.joined(separator: ", ")))"
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
