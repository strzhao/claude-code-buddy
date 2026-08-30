import Foundation

/// 统一插件打分器（契约 C-UNIFIED-SCORE，设计 D2）。
///
/// 全源候选统一量纲（与 AppMatcher 分层对齐），供三处共用：
/// 1. `LauncherManager.unifiedCandidates(for:)` —— typing 期插件候选混排进 instantActions
/// 2. `LauncherRouter.narrowCandidatesScored` —— AI 流缩候选内核（替换旧 contains 加分制）
/// 3. `route(query:)` 短路判断 —— score ≥ LauncherConstants.unifiedRouteSkipScore 直接命中
///
/// 档位分值：
/// | 档位 | 分值 | 条件 |
/// |---|---|---|
/// | 完全 | 1000 | query == name（lowercased）或 == 某 keyword |
/// | 前缀 | 800 | query 是 name 或某 keyword 的前缀 |
/// | 词首 | 500 | query 匹配 name/keyword 的词首连续段（camelCase/空格/中英边界分词） |
/// | contains | 150 | query 与 name/keyword 互为 contains（双向） |
/// | 无命中 | 0 | 不进列表 |
///
/// - name 命中同档 +30（name 命中 > keyword 命中）；多 keyword 命中取最高档。
/// - **单字 keyword 防误命中**：长度 <2 的 keyword（如 qr 的「码」）只参与完全档
///   （query == keyword），不参与前缀/词首/contains 档——否则「密码」「验证码」contains
///   命中「码」复活 2026-07-01 已修缺陷。
/// - 大小写不敏感（lowercased 归一）。纯函数：同输入恒等输出。
enum UnifiedPluginScorer {

    static let scoreExact: Int = 1000
    static let scorePrefix: Int = 800
    static let scoreWordStart: Int = 500
    static let scoreContains: Int = 150
    /// 同档内 name 命中 > keyword 命中的加成
    static let bonusNameHit: Int = 30

    /// 计算 query 对插件 manifest 的统一分数。0 = 无命中。
    static func score(query: String, manifest: PluginManifest) -> Int {
        let q = query.lowercased()
        guard !q.isEmpty else { return 0 }

        // name 侧（命中 +30）
        let nameScore = tierScore(query: q, target: manifest.name)
            ?? 0

        // keyword 侧（多 keyword 取最高；无 name +30）
        var kwBest = 0
        for kw in manifest.keywords {
            let trimmed = kw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let kwScore = keywordScore(query: q, keyword: trimmed) ?? 0
            if kwScore > kwBest { kwBest = kwScore }
        }

        return max(nameScore, kwBest)
    }

    // MARK: - name 侧（含 +30）

    private static func tierScore(query q: String, target: String) -> Int? {
        guard let tier = tier(query: q, target: target) else { return nil }
        return tier + bonusNameHit
    }

    // MARK: - keyword 侧（单字排除）

    /// keyword 打分：长度 <2 的 keyword 仅参与完全档（前缀/词首/contains 排除）。
    private static func keywordScore(query q: String, keyword: String) -> Int? {
        let lower = keyword.lowercased()
        // 完全档对所有 keyword 开放（含单字）
        if q == lower { return scoreExact }
        // 单字 keyword 防误命中：不参与前缀/词首/contains 档
        guard lower.count >= 2 else { return nil }
        return tier(query: q, target: keyword)
    }

    // MARK: - 档位判定（对 name 或多字 keyword 通用；返回该 target 的档位分）

    private static func tier(query q: String, target: String) -> Int? {
        let lower = target.lowercased()
        guard !lower.isEmpty else { return nil }
        // 完全档
        if q == lower { return scoreExact }
        // 前缀档（D2 裁决：双向）：
        // ① 输入中形态：query 是 target 的前缀（qz → qzh）
        if lower.hasPrefix(q) { return scorePrefix }
        // ② keyword+参数形态：query 以 target 开头且紧随严格分隔（空白/标点，与
        //    stripKeywordPrefix 分隔语义一致）。用户显式输「snip 今天的周报」意图明确是该插件，
        //    800 档须压过 app 前缀命中（否则 app 行排前、Enter 打开 app 而非执行插件）。
        //    无分隔（「snipfoo」）不进前缀档 → 落 contains 150。
        if q.hasPrefix(lower), q.count > lower.count {
            let afterIdx = q.index(q.startIndex, offsetBy: lower.count)
            let nextChar = q[afterIdx]
            if nextChar.isWhitespace || nextChar.isPunctuation { return scorePrefix }
        }
        // 词首档：query 匹配词首连续段（camelCase/空格/-/_ 边界）
        if wordStartMatches(query: q, originalTarget: target) { return scoreWordStart }
        // contains 档：双向
        if lower.contains(q) || q.contains(lower) { return scoreContains }
        return nil
    }

    /// 词首连续段匹配（D2：query 匹配 name/keyword 分词后**某个词的开头连续段**）：
    /// 边界 = 空格/`-`/`_`/驼峰大写/中英文切换；query（lowercased）是任一词的前缀 → 命中。
    /// 例："monitor" → "open monitor"（第二词）；"qr" → "genQR"（驼峰第二词）。
    private static func wordStartMatches(query q: String, originalTarget: String) -> Bool {
        guard !q.isEmpty else { return false }
        var words: [String] = []
        var current = ""
        var prev: Character?
        for ch in originalTarget {
            let isBoundaryPunct = ch == " " || ch == "-" || ch == "_"
            if isBoundaryPunct {
                if !current.isEmpty { words.append(current) }
                current = ""
                prev = ch
                continue
            }
            let isUpper = ch.isUppercase
            // 驼峰边界：非大写前字符后遇大写
            let camelBreak = isUpper && !(prev?.isUppercase ?? true) && prev != nil
            // 中英边界：上一字符与当前字符的中英文属性切换
            let scriptBreak: Bool
            if let p = prev, p.isLetter, ch.isLetter {
                scriptBreak = isCJK(p) != isCJK(ch)
            } else {
                scriptBreak = false
            }
            if camelBreak || scriptBreak {
                if !current.isEmpty { words.append(current) }
                current = String(ch)
            } else {
                current.append(ch)
            }
            prev = ch
        }
        if !current.isEmpty { words.append(current) }
        // 判定①：query 是任一词的开头连续段（"monitor" → "open monitor"；"qr" → "genQR"）
        if words.contains(where: { $0.lowercased().hasPrefix(q) }) { return true }
        // 判定②：首字母缩写串（AppMatcher 对齐："qs" → "QuickStart"，词首字母连串前缀）
        let initials = words.compactMap { $0.first }.map { String($0) }.joined().lowercased()
        return initials.count >= 2 && q.count >= 2 && q.count <= initials.count && initials.hasPrefix(q)
    }

    private static func isCJK(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first else { return false }
        return (scalar.value >= 0x4E00 && scalar.value <= 0x9FFF)
            || (scalar.value >= 0x3400 && scalar.value <= 0x4DBF)
    }
}
