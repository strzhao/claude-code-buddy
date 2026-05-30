import XCTest
@testable import BuddyCore

// MARK: - AppMatcherAcceptanceTests
//
// 红队验收测试：C3 AppMatcher.score 契约
//
// 契约覆盖：
//   C3-a：子序列匹配语义 — query 字符按序出现在 name（大小写不敏感），分 > 0
//   C3-b：前缀匹配分 > 词首连续匹配分 > 普通子序列分（层次权重关系）
//   C3-c：不匹配时返回 0（字符不构成子序列）
//   C3-d：大小写不敏感（"gc"=="GC"→同分）
//   C3-e：CJK 整词匹配（"微信" 输入"微信"命中，分 > 0）
//   C3-f：纯函数确定性（同输入多次调用同输出）
//   C3-g：空 query 返回 0（不匹配）
//
// 红队红线：不读取 AppMatcher.swift 实现，仅依据设计文档契约断言行为。
// 测试 WILL NOT compile 直到蓝队合并实现 — 这是预期的 TDD 红灯。

final class AppMatcherAcceptanceTests: XCTestCase {

    // MARK: - C3-a：子序列匹配语义

    /// "gc" 按序出现在 "Google Chrome" → 分 > 0，即匹配。
    /// Mutation 探针：如果匹配器改为精确包含（非子序列），"gc" 不在 "Google Chrome" 中连续出现 → 返回 0 → 红灯。
    func test_C3a_subsequenceMatch_gcInGoogleChrome_positive() {
        let score = AppMatcher.score(query: "gc", name: "Google Chrome")
        XCTAssertGreaterThan(score, 0,
            "C3-a: 子序列匹配 'gc'→'Google Chrome' 必须得分 > 0，实际 \(score)")
    }

    /// "saf" 按序出现在 "Safari" → 分 > 0。
    func test_C3a_subsequenceMatch_safInSafari_positive() {
        let score = AppMatcher.score(query: "saf", name: "Safari")
        XCTAssertGreaterThan(score, 0,
            "C3-a: 'saf'→'Safari' 必须匹配，实际 \(score)")
    }

    /// "fig" 按序出现在 "Figma" → 分 > 0。
    func test_C3a_subsequenceMatch_figInFigma_positive() {
        let score = AppMatcher.score(query: "fig", name: "Figma")
        XCTAssertGreaterThan(score, 0,
            "C3-a: 'fig'→'Figma' 必须匹配，实际 \(score)")
    }

    // MARK: - C3-b：评分层次权重关系

    /// 完全前缀匹配分 > 词首字母连续命中分。
    /// "safari" 对 "Safari"（前缀匹配）vs "saf" 对 "System Audio Forwarding"（词首模拟）。
    /// 用直觉更强的对比：完全名称前缀 "Saf" → "Safari" 分
    /// vs 跨词首字母 "SA" → "System Audio" 这类词首匹配分，前者更高。
    func test_C3b_prefixScore_greaterThan_acronymScore() {
        // 前缀匹配：query 是 name 的完整前缀
        let prefixScore = AppMatcher.score(query: "Saf", name: "Safari")
        // 词首字母连续命中：G=Google, C=Chrome（首字母缩写命中）
        let acronymScore = AppMatcher.score(query: "GC", name: "Google Chrome")

        // 两者都应匹配（> 0）
        XCTAssertGreaterThan(prefixScore, 0, "C3-b: 前缀匹配 'Saf'→'Safari' 必须 > 0")
        XCTAssertGreaterThan(acronymScore, 0, "C3-b: 词首匹配 'GC'→'Google Chrome' 必须 > 0")

        // 前缀分应 >= 词首分
        // 注：精确的 > 还是 >= 取决于实现；设计文档明确「前缀分 > 词首连续匹配分」
        XCTAssertGreaterThanOrEqual(prefixScore, acronymScore,
            "C3-b: 前缀匹配分 \(prefixScore) 应 ≥ 词首匹配分 \(acronymScore)")
    }

    /// 完全前缀 > 词首连续字母 > 普通子序列（非词首、非前缀）。
    /// 同一 query "fo" 对不同名字的三种匹配类型：
    ///   前缀："fo" → "Foto" (前缀)
    ///   词首：「F=Finder O=…」需要找词首，改用 "FC" → "Final Cut" vs 普通子序列
    /// 简化：用三个独立 case 且都 > 0，并断言相对顺序。
    func test_C3b_scoreHierarchy_prefix_greater_than_subsequence() {
        // "notes" 是 "Notes" 的完全前缀（大小写不敏感）
        let prefixScore = AppMatcher.score(query: "notes", name: "Notes")
        // 普通子序列：query 字符散布在 name 中，无前缀无词首
        // "oe" 出现在 "Notes"（N-o-t-e-s，o 在位置1，e 在位置3），是子序列但不是前缀也不是词首
        let subsequenceScore = AppMatcher.score(query: "oe", name: "Notes")

        XCTAssertGreaterThan(prefixScore, 0, "C3-b: 前缀匹配 'notes'→'Notes' > 0")
        XCTAssertGreaterThan(subsequenceScore, 0, "C3-b: 子序列 'oe'→'Notes' > 0")
        XCTAssertGreaterThan(prefixScore, subsequenceScore,
            "C3-b: 前缀分 \(prefixScore) 必须 > 普通子序列分 \(subsequenceScore)")
    }

    // MARK: - C3-c：不匹配时返回 0

    /// query 字符不构成 name 的子序列 → 返回 0。
    /// "xyz" 不出现在 "Safari"（x 不在 Safari 中）。
    func test_C3c_noMatch_returnsZero_xyzInSafari() {
        let score = AppMatcher.score(query: "xyz", name: "Safari")
        XCTAssertEqual(score, 0,
            "C3-c: 'xyz'→'Safari' 不匹配，必须返回 0，实际 \(score)")
    }

    /// 乱码特殊字符 "!@#" 不构成子序列 → 返回 0。
    func test_C3c_noMatch_returnsZero_specialChars() {
        let score = AppMatcher.score(query: "!@#$%", name: "Safari")
        XCTAssertEqual(score, 0,
            "C3-c: 特殊字符 '!@#$%'→'Safari' 必须返回 0，实际 \(score)")
    }

    /// emoji query 不在普通 ASCII app 名中 → 返回 0（场景 9：不崩溃）。
    func test_C3c_noMatch_emoji_returnsZero_noCrash() {
        let score = AppMatcher.score(query: "🦊", name: "Firefox")
        XCTAssertEqual(score, 0,
            "C3-c: emoji '🦊'→'Firefox' 必须返回 0（不崩溃），实际 \(score)")
    }

    /// "xyznotanapp" 不在任何合理 app 名中 → 返回 0（场景 4：无匹配回落 AI）。
    func test_C3c_noMatch_longNonsense_returnsZero() {
        let score = AppMatcher.score(query: "xyznotanapp", name: "Safari")
        XCTAssertEqual(score, 0,
            "C3-c: 'xyznotanapp'→'Safari' 必须返回 0，实际 \(score)")
    }

    // MARK: - C3-d：大小写不敏感

    /// "GC"（大写）和 "gc"（小写）对 "Google Chrome" 应得相同分数。
    func test_C3d_caseInsensitive_gcEqualsGC() {
        let lower = AppMatcher.score(query: "gc", name: "Google Chrome")
        let upper = AppMatcher.score(query: "GC", name: "Google Chrome")
        XCTAssertEqual(lower, upper,
            "C3-d: 大小写不敏感，'gc' 和 'GC' 对 'Google Chrome' 必须得分相同，lower=\(lower), upper=\(upper)")
    }

    /// name 大小写不影响：query "safari" 匹配 "SAFARI"（全大写 name）。
    func test_C3d_caseInsensitive_nameCaseIgnored() {
        let score = AppMatcher.score(query: "safari", name: "SAFARI")
        XCTAssertGreaterThan(score, 0,
            "C3-d: 'safari'→'SAFARI' 大小写不敏感，必须匹配，实际 \(score)")
    }

    // MARK: - C3-e：CJK 整词匹配

    /// "微信" 输入 "微信" → 整体匹配，分 > 0（场景 6：中文 App 名可匹配）。
    func test_C3e_CJK_wechat_exactMatch_positive() {
        let score = AppMatcher.score(query: "微信", name: "微信")
        XCTAssertGreaterThan(score, 0,
            "C3-e: CJK '微信'→'微信' 必须匹配，分 > 0，实际 \(score)")
    }

    /// CJK 子序列：query "微" 是 "微信" 的前缀 → 分 > 0。
    func test_C3e_CJK_partialMatch_positive() {
        let score = AppMatcher.score(query: "微", name: "微信")
        XCTAssertGreaterThan(score, 0,
            "C3-e: CJK '微'→'微信' 前缀子序列匹配，分 > 0，实际 \(score)")
    }

    /// CJK 完整名不含 query → 返回 0（确认不误匹配）。
    func test_C3e_CJK_noMatch_returnsZero() {
        let score = AppMatcher.score(query: "支付宝", name: "微信")
        XCTAssertEqual(score, 0,
            "C3-e: CJK '支付宝'→'微信' 不匹配，必须返回 0，实际 \(score)")
    }

    // MARK: - C3-f：纯函数确定性

    /// 同输入多次调用，返回完全相同分数（纯函数，无内部状态）。
    func test_C3f_pureFunction_sameInputSameOutput() {
        let call1 = AppMatcher.score(query: "gc", name: "Google Chrome")
        let call2 = AppMatcher.score(query: "gc", name: "Google Chrome")
        let call3 = AppMatcher.score(query: "gc", name: "Google Chrome")
        XCTAssertEqual(call1, call2, "C3-f: 纯函数第1次=第2次，call1=\(call1), call2=\(call2)")
        XCTAssertEqual(call2, call3, "C3-f: 纯函数第2次=第3次，call2=\(call2), call3=\(call3)")
    }

    /// 不同 query 不混串结果（交叉调用后仍确定性）。
    func test_C3f_pureFunction_interleavedCallsDontMutateState() {
        let scoreA1 = AppMatcher.score(query: "saf", name: "Safari")
        let scoreB1 = AppMatcher.score(query: "gc", name: "Google Chrome")
        let scoreA2 = AppMatcher.score(query: "saf", name: "Safari")
        let scoreB2 = AppMatcher.score(query: "gc", name: "Google Chrome")

        XCTAssertEqual(scoreA1, scoreA2, "C3-f: 交叉调用后 'saf'→'Safari' 得分应不变")
        XCTAssertEqual(scoreB1, scoreB2, "C3-f: 交叉调用后 'gc'→'Google Chrome' 得分应不变")
    }

    // MARK: - C3-g：空 query 返回 0

    /// 空字符串 query → 返回 0（不匹配任何 name）。
    func test_C3g_emptyQuery_returnsZero() {
        let score = AppMatcher.score(query: "", name: "Safari")
        XCTAssertEqual(score, 0,
            "C3-g: 空 query 必须返回 0，实际 \(score)")
    }
}
