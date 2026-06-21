import XCTest
@testable import BuddyCore

/// 蓝队单元测试 — AppMatcher 打分（C3 契约验证）
/// 测试 AppMatcher.score 纯函数的确定性、分层分数、子序列语义
final class AppMatcherTests: XCTestCase {

    // MARK: - 基础匹配

    func test_emptyQuery_returnsZero() {
        XCTAssertEqual(AppMatcher.score(query: "", name: "Safari"), 0)
    }

    func test_emptyName_returnsZero() {
        XCTAssertEqual(AppMatcher.score(query: "saf", name: ""), 0)
    }

    func test_noMatch_returnsZero() {
        XCTAssertEqual(AppMatcher.score(query: "xyz", name: "Safari"), 0)
    }

    // MARK: - C3 前缀 > 词首 > 子序列

    func test_prefixScore_greaterThan_wordStartScore() {
        // "saf"→Safari 前缀匹配
        let prefixScore = AppMatcher.score(query: "saf", name: "Safari")
        // "gc"→Google Chrome 词首匹配
        let wordScore = AppMatcher.score(query: "gc", name: "Google Chrome")
        XCTAssertGreaterThan(prefixScore, wordScore, "前缀匹配分应大于词首匹配分")
    }

    func test_wordStartScore_greaterThan_subsequenceScore() {
        // "gc"→Google Chrome 词首匹配（G + C）
        let wordScore = AppMatcher.score(query: "gc", name: "Google Chrome")
        // "ge"→Google（子序列，g-o-o-g-l-e，e 是普通子序列）
        let seqScore = AppMatcher.score(query: "ge", name: "Google")
        XCTAssertGreaterThan(wordScore, seqScore, "词首匹配分应大于普通子序列分")
    }

    // MARK: - 确定性（相同输入相同输出）

    func test_deterministic_sameInputSameOutput() {
        let s1 = AppMatcher.score(query: "saf", name: "Safari")
        let s2 = AppMatcher.score(query: "saf", name: "Safari")
        XCTAssertEqual(s1, s2)
    }

    // MARK: - 前缀匹配

    func test_fullPrefixMatch() {
        let score = AppMatcher.score(query: "safari", name: "Safari")
        XCTAssertGreaterThan(score, 0)
    }

    func test_partialPrefixMatch() {
        let score = AppMatcher.score(query: "saf", name: "Safari")
        XCTAssertGreaterThan(score, 0)
    }

    // MARK: - 词首字母匹配

    func test_wordStart_googleChrome() {
        // gc → Google Chrome（G-oogle C-hrome 首字母）
        let score = AppMatcher.score(query: "gc", name: "Google Chrome")
        XCTAssertGreaterThan(score, 0, "gc 应匹配 Google Chrome 词首字母")
    }

    func test_wordStart_singleWordNoMatch() {
        // "gc" 对单词 "Safari" 无词首两字母匹配
        let score = AppMatcher.score(query: "gc", name: "Safari")
        XCTAssertEqual(score, 0)
    }

    // MARK: - 子序列 fuzzy 匹配

    func test_subsequence_matchInOrder() {
        // "sfi" 在 Safari 中按序出现
        let score = AppMatcher.score(query: "sfi", name: "Safari")
        XCTAssertGreaterThan(score, 0)
    }

    func test_subsequence_charOutOfOrder_noMatch() {
        // "ifs" 在 Safari 中不按序（i 在 f 前）
        let score = AppMatcher.score(query: "ifs", name: "Safari")
        XCTAssertEqual(score, 0)
    }

    func test_caseInsensitive() {
        let lower = AppMatcher.score(query: "safari", name: "Safari")
        let upper = AppMatcher.score(query: "SAFARI", name: "Safari")
        XCTAssertGreaterThan(lower, 0)
        XCTAssertGreaterThan(upper, 0)
    }

    // MARK: - CJK 兼容

    func test_cjk_exactMatch() {
        // 中文 app 名精确匹配
        let score = AppMatcher.score(query: "微信", name: "微信")
        XCTAssertGreaterThan(score, 0, "中文精确前缀应匹配")
    }

    func test_cjk_partialSubsequence() {
        // 中文子序列
        let score = AppMatcher.score(query: "信", name: "微信")
        XCTAssertGreaterThan(score, 0, "中文子序列应匹配")
    }

    // MARK: - 拼音别名匹配（CJK name → pinyin alias）

    func test_pinyin_alias_fullPinyin() {
        // 别名已含拼音 "weixin"，应匹配用户输入 "weixin"
        let score = AppMatcher.score(query: "weixin", name: "weixin")
        XCTAssertGreaterThan(score, 0, "拼音别名 weixin 应前缀匹配")
    }

    func test_pinyin_alias_initials() {
        // 别名已含首字母 "wx"，应匹配用户输入 "wx"
        let score = AppMatcher.score(query: "wx", name: "wx")
        XCTAssertGreaterThan(score, 0, "拼音首字母 wx 应前缀匹配")
    }

    func test_pinyin_alias_partialPinyin() {
        // 别名已含拼音 "weixin"，用户输入部分拼音 "wei"
        let score = AppMatcher.score(query: "wei", name: "weixin")
        XCTAssertGreaterThan(score, 0, "拼音部分前缀 wei 应匹配 weixin")
    }

    // MARK: - 分数层级关系

    func test_prefixScore_isAtLeast1000() {
        let score = AppMatcher.score(query: "saf", name: "Safari")
        XCTAssertGreaterThanOrEqual(score, 1000, "前缀匹配应 ≥ 1000 分")
    }

    func test_nonMatch_isExactlyZero() {
        let score = AppMatcher.score(query: "zzz", name: "Safari")
        XCTAssertEqual(score, 0)
    }
}
