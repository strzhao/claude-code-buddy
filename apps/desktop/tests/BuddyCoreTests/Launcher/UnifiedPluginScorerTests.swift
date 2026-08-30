import XCTest
@testable import BuddyCore

// MARK: - UnifiedPluginScorerTests
//
// 契约 C-UNIFIED-SCORE（state.md ## 契约规约）：
//   - 完全 1000 / 前缀 800 / 词首 500 / contains 150，name 命中 +30
//   - 长度 <2 的 keyword 仅参与完全档（前缀/词首/contains 档排除）
//   - 大小写不敏感（lowercased 归一）；纯函数；0 = 无命中
// 设计 D2 效果锚点：
//   「二维码」→ qr keyword 完全 1000+30；「密码」→ qr 单字「码」排除不进列表；
//   「qr」→ keyword 完全 1000；「qz」→ qzh 前缀 800；「QR」→ 命中。

@MainActor
final class UnifiedPluginScorerTests: XCTestCase {

    // MARK: - 辅助构造

    private func manifest(name: String, keywords: [String]) -> PluginManifest {
        let json: [String: Any] = [
            "name": name,
            "version": "0.1.0",
            "description": "test plugin \(name)",
            "keywords": keywords,
            "mode": "command",
            "cmd": "echo",
            "args": [] as [String]
        ]
        return try! JSONDecoder().decode(PluginManifest.self, from: try JSONSerialization.data(withJSONObject: json))
    }

    // MARK: - 档位分值

    /// 完全档 1000：query == name
    func test_exactQueryEqualsName_score1000PlusNameBonus() {
        let m = manifest(name: "qzh", keywords: ["监控"])
        XCTAssertEqual(UnifiedPluginScorer.score(query: "qzh", manifest: m), 1030,
            "C-UNIFIED-SCORE: query == name → 完全档 1000 + name +30 = 1030")
    }

    /// 完全档 1000：query == keyword
    func test_exactQueryEqualsKeyword_score1000() {
        let m = manifest(name: "qr", keywords: ["二维码", "码"])
        XCTAssertEqual(UnifiedPluginScorer.score(query: "二维码", manifest: m), 1000,
            "C-UNIFIED-SCORE: query == keyword → 完全档 1000（keyword 命中无 name +30）")
    }

    /// 前缀档 800：query 是 name 的前缀（qz → qzh）
    func test_prefixQueryPrefixOfName_score800PlusNameBonus() {
        let m = manifest(name: "qzh", keywords: ["监控"])
        XCTAssertEqual(UnifiedPluginScorer.score(query: "qz", manifest: m), 830,
            "C-UNIFIED-SCORE: query 是 name 前缀 → 前缀档 800 + name +30 = 830")
    }

    /// 前缀档 800：query 是 keyword 的前缀
    func test_prefixQueryPrefixOfKeyword_score800() {
        let m = manifest(name: "xyz", keywords: ["snippet"])
        XCTAssertEqual(UnifiedPluginScorer.score(query: "snip", manifest: m), 800,
            "C-UNIFIED-SCORE: query 是 keyword 前缀 → 前缀档 800")
    }

    // MARK: - 前缀档双向（D2 裁决：keyword+参数形态）

    /// 前缀档 800（反向）：query 以 keyword 开头 + 空格分隔 + 参数
    func test_reversePrefix_keywordWithArgs_score800() {
        let m = manifest(name: "xyz", keywords: ["qr"])
        XCTAssertEqual(UnifiedPluginScorer.score(query: "qr hello world", manifest: m), 800,
            "D2 双向前缀档：keyword「qr」+空格+参数 → 前缀档 800（keyword 命中无 name +30）")
    }

    /// 前缀档 800（反向）：query 以 keyword 开头 + 空格分隔 + CJK 参数
    func test_reversePrefix_keywordWithCJKArgs_score800() {
        let m = manifest(name: "xyz", keywords: ["snip"])
        XCTAssertEqual(UnifiedPluginScorer.score(query: "snip 今天的周报", manifest: m), 800,
            "D2 双向前缀档：「snip 今天的周报」→ 800（压过 app 前缀命中，防 Snippet Lab 类 app 行排前）")
    }

    /// 反向不满足严格分隔（无空白/标点）→ 落 contains 档 150
    func test_reversePrefix_noBoundary_fallsToContains() {
        let m = manifest(name: "xyz", keywords: ["snip"])
        XCTAssertEqual(UnifiedPluginScorer.score(query: "snipfoo", manifest: m), 150,
            "「snipfoo」无分隔边界 → 不进前缀档，contains 兜底 150")
        let m2 = manifest(name: "xyz", keywords: ["qr"])
        XCTAssertEqual(UnifiedPluginScorer.score(query: "qrhello", manifest: m2), 150,
            "「qrhello」无分隔边界 → 不命中前缀档，contains 兜底 150")
    }

    /// name 侧同样适用双向：query 以 name 开头 + 分隔 → 800 + name 30 = 830
    func test_reversePrefix_nameWithArgs_score830() {
        let m = manifest(name: "snip", keywords: [])
        XCTAssertEqual(UnifiedPluginScorer.score(query: "snip abc", manifest: m), 830,
            "D2 双向前缀档 name 侧：「snip abc」→ 800 + name +30 = 830")
        // 无分隔 → name contains 兜底 150 + 30
        XCTAssertEqual(UnifiedPluginScorer.score(query: "snipfoo", manifest: m), 180,
            "「snipfoo」对 name 无分隔 → contains 150 + name +30 = 180")
    }

    /// 单字 keyword 双向排除不变：单字 keyword 不参与前缀档（含反向）
    func test_reversePrefix_singleCharKeyword_excluded() {
        let m = manifest(name: "zzz", keywords: ["码"])
        XCTAssertEqual(UnifiedPluginScorer.score(query: "码上", manifest: m), 0,
            "单字 keyword「码」不参与前缀档双向——「码上」不命中（C-NO-REGRESS ⑥）")
    }

    /// 词首档 500：query 匹配 name 的词首连续段（camelCase / 空格边界）
    func test_wordStartMatch_score500PlusNameBonus() {
        let m = manifest(name: "QzhddrSrv", keywords: ["zzz"])
        XCTAssertEqual(UnifiedPluginScorer.score(query: "qs", manifest: m), 530,
            "C-UNIFIED-SCORE: query 匹配 camelCase 词首（Q+S）→ 词首档 500 + name +30")
    }

    /// 词首档 500：空格分词（"Google Chrome" 词首 gc）
    func test_wordStartMatch_spaceBoundary_score500() {
        let m = manifest(name: "Some Tool", keywords: ["zzz"])
        XCTAssertEqual(UnifiedPluginScorer.score(query: "st", manifest: m), 530,
            "C-UNIFIED-SCORE: 空格词首 S+T → 词首档 500 + name +30")
    }

    /// contains 档 150：name.contains(query)
    func test_containsName_score150PlusNameBonus() {
        let m = manifest(name: "qzhddr", keywords: ["zzz"])
        XCTAssertEqual(UnifiedPluginScorer.score(query: "zhdd", manifest: m), 180,
            "C-UNIFIED-SCORE: name contains query → contains 档 150 + name +30 = 180")
    }

    /// contains 档 150：query.contains(keyword)（反向，中文整词）
    func test_containsQueryContainsKeyword_score150() {
        let m = manifest(name: "abc", keywords: ["监控"])
        XCTAssertEqual(UnifiedPluginScorer.score(query: "关闭监控服务", manifest: m), 150,
            "C-UNIFIED-SCORE: query contains keyword（反向）→ contains 档 150")
    }

    // MARK: - 单字 keyword 防误命中（C-NO-REGRESS ⑥）

    /// 单字 keyword「码」：query「密码」不命中（contains 档排除）
    func test_singleCharKeyword_containsExcluded() {
        let qr = manifest(name: "qr", keywords: ["qr", "qrcode", "二维码", "码"])
        XCTAssertEqual(UnifiedPluginScorer.score(query: "密码", manifest: qr), 0,
            "C-UNIFIED-SCORE: 单字 keyword 不参与 contains 档——「密码」不得命中 qr（历史缺陷回归保护）")
    }

    /// 单字 keyword「码」：query「验证码」不命中
    func test_singleCharKeyword_verifCodeExcluded() {
        let qr = manifest(name: "qr", keywords: ["qr", "qrcode", "二维码", "码"])
        XCTAssertEqual(UnifiedPluginScorer.score(query: "验证码", manifest: qr), 0,
            "C-UNIFIED-SCORE: 单字 keyword 不参与 contains 档——「验证码」不得命中 qr")
    }

    /// 单字 keyword：query 恰为该字 → 完全档仍有效（1000）
    func test_singleCharKeyword_exactStillWorks() {
        let qr = manifest(name: "qr", keywords: ["qr", "qrcode", "二维码", "码"])
        XCTAssertEqual(UnifiedPluginScorer.score(query: "码", manifest: qr), 1000,
            "C-UNIFIED-SCORE: 单字 keyword 参与完全档——query「码」→ 1000")
    }

    /// 单字 keyword：query「m」是 keyword「码」……单字 keyword 也不参与前缀档（如 keyword「a」，query「a1」不前缀命中）
    func test_singleCharKeyword_prefixExcluded() {
        let m = manifest(name: "zzz", keywords: ["码"])
        XCTAssertEqual(UnifiedPluginScorer.score(query: "码上", manifest: m), 0,
            "C-UNIFIED-SCORE: 单字 keyword 不参与前缀档（query「码上」不命中）")
    }

    // MARK: - name 加成与多 keyword 取最高

    /// 同档 name 命中 > keyword 命中（+30）
    func test_nameBonusBeatsKeywordAtSameTier() {
        let nameHit = manifest(name: "monitor", keywords: ["other"])
        let kwHit = manifest(name: "other", keywords: ["monitor"])
        let nameScore = UnifiedPluginScorer.score(query: "moni", manifest: nameHit)
        let kwScore = UnifiedPluginScorer.score(query: "moni", manifest: kwHit)
        XCTAssertEqual(nameScore, 830, "name 前缀命中 → 800 + 30")
        XCTAssertEqual(kwScore, 800, "keyword 前缀命中 → 800")
        XCTAssertGreaterThan(nameScore, kwScore, "同档 name 命中 > keyword 命中")
    }

    /// 多 keyword 命中取最高档
    func test_multipleKeywords_takeHighest() {
        let m = manifest(name: "xyz", keywords: ["翻译", "translate", "转换"])
        // "trans" 是 keyword "translate" 的前缀（800）；"翻译"/"转换" 不命中
        XCTAssertEqual(UnifiedPluginScorer.score(query: "trans", manifest: m), 800)
    }

    // MARK: - 大小写不敏感

    func test_caseInsensitive_keyword() {
        // name "qr" 与 keyword "qr" 双完全命中 → 取 name 侧 1030
        let m = manifest(name: "qr", keywords: ["qr", "二维码"])
        XCTAssertEqual(UnifiedPluginScorer.score(query: "QR", manifest: m), 1030,
            "C-UNIFIED-SCORE: 大小写不敏感（「QR」命中 name+keyword 完全档 → 1030）")
        // keyword 完全命中（name 不命中）→ 1000
        let kwOnly = manifest(name: "xyz", keywords: ["QR"])
        XCTAssertEqual(UnifiedPluginScorer.score(query: "qr", manifest: kwOnly), 1000)
    }

    func test_caseInsensitive_name() {
        let m = manifest(name: "SnipTool", keywords: ["snip"])
        XCTAssertEqual(UnifiedPluginScorer.score(query: "sniptool", manifest: m), 1030,
            "C-UNIFIED-SCORE: 大小写不敏感（name lowercased 归一）")
    }

    // MARK: - 无命中

    func test_noMatch_returnsZero() {
        let m = manifest(name: "qr", keywords: ["qr", "二维码", "码"])
        XCTAssertEqual(UnifiedPluginScorer.score(query: "wechat", manifest: m), 0,
            "C-UNIFIED-SCORE: 无命中 → 0（不进列表）")
    }

    func test_emptyQuery_returnsZero() {
        let m = manifest(name: "qr", keywords: ["qr"])
        XCTAssertEqual(UnifiedPluginScorer.score(query: "", manifest: m), 0)
    }

    /// 档位优先于 name 加成：keyword 前缀 800 > name contains 180
    func test_tierBeatsNameBonus() {
        let m = manifest(name: "snip", keywords: ["snippet"])
        // query "snip" == name → 完全档 1030（本例验证完全档压制 keyword 前缀档）
        XCTAssertEqual(UnifiedPluginScorer.score(query: "snip", manifest: m), 1030)
    }
}
