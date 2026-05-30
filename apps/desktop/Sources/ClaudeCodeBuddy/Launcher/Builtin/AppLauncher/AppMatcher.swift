import Foundation

/// 纯函数 App 名称模糊匹配打分器（C3 契约）。
/// - 相同 (query, name) 输入 → 相同分数（确定性）
/// - 不匹配返回 0
/// - 前缀匹配分 > 词首连续匹配分 > 普通子序列分
enum AppMatcher {

    // MARK: - 分数基准（设计分层）

    private static let scorePrefix: Int = 1000          // 完全前缀匹配（最高）
    private static let scoreWordStart: Int = 500        // 词首字母连续匹配（如 "gc"→Google Chrome）
    private static let scoreSubsequence: Int = 100      // 普通子序列匹配（最低）
    /// 连续字符加分（每个额外连续字符 +10）
    private static let bonusConsecutive: Int = 10
    /// 起始位置越早加分（位置权重基数）
    private static let bonusPositionBase: Int = 50

    // MARK: - 主打分函数

    /// 计算 query 对 name 的匹配分数（大小写不敏感）。
    /// C3 契约：纯函数，0 = 不匹配，分数越高越相关。
    /// - Parameters:
    ///   - query: 用户输入（可能含 CJK）
    ///   - name: App 名（原始大小写，如 "Google Chrome"）
    /// - Returns: ≥0 的整数分数；0 表示不匹配
    static func score(query: String, name: String) -> Int {
        guard !query.isEmpty, !name.isEmpty else { return 0 }

        let q = query.lowercased()
        let n = name.lowercased()

        // 1) 完全前缀匹配（最高）
        if n.hasPrefix(q) {
            // 起始位置为 0，最高分
            return scorePrefix + bonusPositionBase
        }

        // 2) 词首字母连续匹配（如 "gc"→Google Chrome 首字母组合）
        if let wordScore = wordStartScore(query: q, name: n, originalName: name) {
            return wordScore
        }

        // 3) 普通子序列 fuzzy 匹配
        if let seqScore = subsequenceScore(query: q, name: n) {
            return seqScore
        }

        return 0
    }

    // MARK: - 词首字母匹配

    /// 提取 name 的词首字母组合，匹配 query 是否是其前缀。
    /// 词边界：空格、驼峰（大写字母前）、中划线、下划线。
    private static func wordStartScore(query: String, name: String, originalName: String) -> Int? {
        // 提取词首字母（保持原始大小写的首字母，用于拼接）
        var initials: [Character] = []
        var prevWasSpace = true
        for (idx, ch) in originalName.enumerated() {
            let scalar = ch.unicodeScalars.first?.value ?? 0
            // 空格/分隔符后：下一个字符是词首
            if ch == " " || ch == "-" || ch == "_" {
                prevWasSpace = true
                continue
            }
            // 驼峰：大写字母也视为词首（前一个不是空格时）
            let isUpperCase = scalar >= 65 && scalar <= 90
            if prevWasSpace || (idx > 0 && isUpperCase) {
                initials.append(ch)
                prevWasSpace = false
            } else {
                prevWasSpace = false
            }
        }

        let initialsStr = String(initials).lowercased()
        guard initialsStr.hasPrefix(query) || query.count <= initials.count else { return nil }
        // 检查 query 的每个字符是否都是词首字母的子序列
        guard initialsStr.hasPrefix(query) else { return nil }

        // 词首匹配成功：score = scoreWordStart + 连续加分
        let consecutive = query.count
        return scoreWordStart + consecutive * bonusConsecutive
    }

    // MARK: - 子序列 fuzzy 匹配

    /// query 的所有字符按序出现在 name 中（大小写不敏感）。
    /// CJK 字符整体参与子序列匹配，不做拼音转换。
    /// - Returns: 分数（含连续加分 + 起始位置加分），或 nil 表示不匹配
    private static func subsequenceScore(query: String, name: String) -> Int? {
        let queryChars = Array(query)
        let nameChars = Array(name)

        var qIdx = 0
        var firstMatchPos: Int?
        var consecutiveCount = 0
        var totalConsecutive = 0
        var prevMatchPos: Int = -2

        for (nIdx, nCh) in nameChars.enumerated() {
            guard qIdx < queryChars.count else { break }
            if nCh == queryChars[qIdx] {
                if firstMatchPos == nil { firstMatchPos = nIdx }
                // 连续检测
                if nIdx == prevMatchPos + 1 {
                    consecutiveCount += 1
                    totalConsecutive += consecutiveCount
                } else {
                    consecutiveCount = 1
                }
                prevMatchPos = nIdx
                qIdx += 1
            }
        }

        guard qIdx == queryChars.count else { return nil }

        // 起始位置越早分越高（最多 bonusPositionBase，位置 0 最高）
        let positionBonus: Int
        if let firstPos = firstMatchPos {
            positionBonus = max(0, bonusPositionBase - firstPos * 5)
        } else {
            positionBonus = 0
        }

        return scoreSubsequence + totalConsecutive * bonusConsecutive + positionBonus
    }
}
