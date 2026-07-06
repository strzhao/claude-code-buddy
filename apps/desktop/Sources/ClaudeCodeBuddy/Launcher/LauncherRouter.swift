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

    /// command mode 命中判断（C-PREFIX-MATCH / C-REUSE-STRIP）。
    ///
    /// 复用 `LauncherManager.stripKeywordPrefix`（LauncherManager.swift）已验证的
    /// 「query 前缀完整匹配某 keyword + 严格分隔符（空白/标点/行尾）」逻辑，
    /// **方向反过来用于命中判断**：遍历 plugins，仅 `.command` mode；该 plugin 的
    /// `[name] + keywords` 中任一 `kw` 满足 query 以 kw 开头且 kw 后紧跟分隔符/行尾 → 命中。
    ///
    /// 与 `narrowCandidatesScored`（contains 反向打分，服务 stdin/prompt 路由）并存：
    /// command 命中改走本函数（严格前缀，禁 contains）。
    ///
    /// - 返回 `[PluginManifest]`（保持 plugins 原序；非打分，是精确前缀匹配集合）。
    /// - 行为示例：`qr`/`二维码`/`qr https://x` → 命中 qr；`密码`/`qrcode`/`q` → 不命中任何 command。
    /// - 纯函数：无 IO / 无副作用，同输入恒等输出（场景12 基线）。
    static func commandPrefixMatched(
        query: String,
        plugins: [PluginManifest]
    ) -> [PluginManifest] {
        guard !query.isEmpty else { return [] }
        let queryLower = query.lowercased()
        return plugins.filter { manifest in
            // C-SCOPE-COMMAND-ONLY：仅 .command mode
            guard case .command = manifest.modeConfig else { return false }
            // C-REUSE-STRIP：候选前缀集合 = [name] + keywords，trim + 去空，长前缀优先
            let prefixes = ([manifest.name] + manifest.keywords)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .sorted { $0.count > $1.count }
            for prefix in prefixes {
                let prefixLower = prefix.lowercased()
                guard queryLower.hasPrefix(prefixLower) else { continue }
                // 严格分隔：prefix 后必须紧跟空白 / 标点 / 行尾（与 stripKeywordPrefix 同语义）
                let after = query.index(query.startIndex, offsetBy: prefix.count)
                if after == query.endIndex {
                    return true  // query 恰是 keyword 本身（行尾）
                }
                let nextChar = query[after]
                if nextChar.isWhitespace || nextChar.isPunctuation {
                    return true
                }
                // 当前 prefix 不是分隔边界，继续试下一个（长前缀优先已排序）
            }
            return false
        }
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

        // system prompt：路由指令 + 原始 query（user message）
        let candidateLines = plugins.map { p in
            "- \(p.name): \(p.description) (keywords: \(p.keywords.joined(separator: ", ")))"
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
