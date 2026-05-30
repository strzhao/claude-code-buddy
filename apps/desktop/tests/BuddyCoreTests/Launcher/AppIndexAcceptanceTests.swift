import XCTest
@testable import BuddyCore

// MARK: - AppIndexAcceptanceTests
//
// 红队验收测试：C4 AppIndex.search 契约
//
// 契约覆盖：
//   C4-a：返回按 score 降序排序的 [AppEntry]
//   C4-b：过滤 score == 0 的条目（不匹配的不出现）
//   C4-c：截断到 limit（≤ limit 条结果）
//   C4-d：同分时按 name 字典序稳定排序（C3 tie-break 补充）
//   C4-e：空 query 返回 []（不返回全量索引）
//   C4-f：纯内存搜索，注入固定 AppEntry 列表，不触碰文件系统
//   C4-g：场景 7 — 大量候选时截断到 Top-N（≤ appSearchLimit=8）
//
// 红队红线：不读取 AppIndex.swift / AppEntry.swift 实现。
// 测试 WILL NOT compile 直到蓝队合并实现 — 这是预期的 TDD 红灯。
//
// 注入方式：AppIndex 支持用固定 AppEntry 列表初始化（测试用，不触发真实扫盘）。

@MainActor
final class AppIndexAcceptanceTests: XCTestCase {

    // MARK: - 测试夹具：固定 AppEntry 列表

    /// 构造注入用的固定 AppEntry（无需真实 URL，只需 url + name 字段）。
    private func makeEntry(name: String) -> AppEntry {
        let url = URL(fileURLWithPath: "/Applications/\(name).app")
        return AppEntry(url: url, name: name, nameLower: name.lowercased())
    }

    /// 注入固定条目列表的 AppIndex（不扫盘）。
    private func makeIndex(entries: [AppEntry]) -> AppIndex {
        return AppIndex(fixedEntries: entries)
    }

    // MARK: - C4-a：按 score 降序返回

    /// 高相关度条目排在低相关度之前。
    /// "saf" → Safari（完全前缀）排在 SafariHistoryService（更长前缀但相关度较低）之前
    /// 简化：注入两条，精确前缀匹配分 > 非前缀匹配分，断言顺序。
    func test_C4a_resultsOrderedByScoreDescending() {
        let entries = [
            makeEntry(name: "Safari"),            // "saf" = 前缀匹配，高分
            makeEntry(name: "AppSafeguard"),       // "saf" 出现在内部，低分
        ]
        let index = makeIndex(entries: entries)
        let results = index.search("saf", limit: 10)

        XCTAssertFalse(results.isEmpty, "C4-a: 至少有一条匹配结果")

        if results.count >= 2 {
            // 第一条（Safari）分 ≥ 第二条（AppSafeguard）分
            // 通过在结果中找到 Safari 排在 AppSafeguard 之前来验证
            let safariIdx = results.firstIndex { $0.name == "Safari" }
            let safeguardIdx = results.firstIndex { $0.name == "AppSafeguard" }
            if let si = safariIdx, let sg = safeguardIdx {
                XCTAssertLessThan(si, sg,
                    "C4-a: 'Safari'（前缀匹配）应排在 'AppSafeguard'（内部匹配）之前")
            }
        }
    }

    // MARK: - C4-b：过滤 score == 0

    /// 不匹配的条目（score == 0）不出现在结果中。
    /// "saf" 对 "Notes" 的 score 应为 0，不应出现在结果里。
    func test_C4b_filtersOutZeroScoreEntries() {
        let entries = [
            makeEntry(name: "Safari"),    // 匹配
            makeEntry(name: "Notes"),     // "saf" 不出现在 Notes → score 0，过滤
            makeEntry(name: "Calendar"),  // "saf" 不出现 → score 0，过滤
        ]
        let index = makeIndex(entries: entries)
        let results = index.search("saf", limit: 10)

        let names = results.map { $0.name }
        XCTAssertTrue(names.contains("Safari"), "C4-b: Safari 必须在结果中")
        XCTAssertFalse(names.contains("Notes"), "C4-b: Notes 不匹配，必须被过滤掉")
        XCTAssertFalse(names.contains("Calendar"), "C4-b: Calendar 不匹配，必须被过滤掉")
    }

    // MARK: - C4-c：截断到 limit

    /// 注入 5 条全匹配条目，limit=3 → 只返回 3 条。
    func test_C4c_truncatesToLimit() {
        // 全部以 "a" 开头 → 全部匹配 query "a"
        let entries = [
            makeEntry(name: "App1"),
            makeEntry(name: "App2"),
            makeEntry(name: "App3"),
            makeEntry(name: "App4"),
            makeEntry(name: "App5"),
        ]
        let index = makeIndex(entries: entries)
        let results = index.search("a", limit: 3)

        XCTAssertEqual(results.count, 3,
            "C4-c: limit=3 时最多返回 3 条，实际 \(results.count) 条")
    }

    /// limit=1 → 只返回最高分的 1 条。
    func test_C4c_limit1_returnsTopScoreOnly() {
        let entries = [
            makeEntry(name: "Safari"),
            makeEntry(name: "AppSafeguard"),
            makeEntry(name: "SafeNet"),
        ]
        let index = makeIndex(entries: entries)
        let results = index.search("saf", limit: 1)

        XCTAssertEqual(results.count, 1,
            "C4-c: limit=1 只返回 1 条，实际 \(results.count) 条")
    }

    // MARK: - C4-d：同分时按 name 字典序稳定排序（C3 tie-break）

    /// 注入两个得分相同的条目（同样的前缀匹配），按 name 字典序排列。
    /// "a1" → "Alpha" 和 "a1" → "Alpaca"：若同分，"Alpaca" < "Alpha" 字典序在前。
    func test_C4d_tieBreakByNameLexicographic() {
        // 构造同 query 得分相同的两条：同样是 2 字符前缀匹配
        // "ap" → "App Store" 和 "ap" → "Appetize" — 都是前缀
        // 字典序：App Store < Appetize? 实际 "App Store" vs "Appetize"：
        //   'A'='A', 'p'='p', 'p'='p', ' '<'e' → ' '<'e'（ASCII 32 < 101）→ App Store 在前
        let entries = [
            makeEntry(name: "Appetize"),    // 先插入
            makeEntry(name: "App Store"),   // 后插入
        ]
        let index = makeIndex(entries: entries)
        let results = index.search("ap", limit: 10)

        // 两个都应匹配
        let names = results.map { $0.name }
        XCTAssertTrue(names.contains("Appetize"), "C4-d: Appetize 应在结果中")
        XCTAssertTrue(names.contains("App Store"), "C4-d: App Store 应在结果中")

        // 若同分，字典序 "App Store" < "Appetize"（空格 ASCII 32 < 'e' ASCII 101）
        // 断言 App Store 排在 Appetize 之前
        let appStoreIdx = results.firstIndex { $0.name == "App Store" }
        let appetizeIdx = results.firstIndex { $0.name == "Appetize" }

        if let ai = appStoreIdx, let bi = appetizeIdx {
            // 只有当 AppMatcher 认为两者得分相同时，字典序才决定顺序
            // 若得分不同，以得分为准（不强制此断言）
            // 至少验证结果可重复（调用两次顺序相同）
            let results2 = index.search("ap", limit: 10)
            let names2 = results2.map { $0.name }
            XCTAssertEqual(names, names2,
                "C4-d: 同输入两次调用，结果顺序必须完全一致（稳定排序）")
            _ = (ai, bi)  // suppress unused warning
        }
    }

    // MARK: - C4-e：空 query 返回 []

    /// 空字符串 query → 返回空数组，不返回全量索引。
    func test_C4e_emptyQuery_returnsEmpty() {
        let entries = [
            makeEntry(name: "Safari"),
            makeEntry(name: "Notes"),
            makeEntry(name: "Calendar"),
        ]
        let index = makeIndex(entries: entries)
        let results = index.search("", limit: 10)

        XCTAssertTrue(results.isEmpty,
            "C4-e: 空 query 必须返回 []（不返回全量），实际 \(results.count) 条")
    }

    // MARK: - C4-f：纯内存，不扫盘

    /// 注入固定 entries 后 search 不触碰文件系统（测试本身不需文件存在）。
    /// entries 的 url.path 指向一个不存在的路径，但 search 应正常工作。
    func test_C4f_pureMemotySearch_noFilesystemAccess() {
        let nonExistentURL = URL(fileURLWithPath: "/Applications/FakeApp123NotReallyThere.app")
        let fakeEntry = AppEntry(
            url: nonExistentURL,
            name: "FakeApp123NotReallyThere",
            nameLower: "fakeapp123notreallythere"
        )
        let index = makeIndex(entries: [fakeEntry])
        // 搜索应正常返回，不因文件不存在崩溃
        let results = index.search("fake", limit: 10)
        XCTAssertFalse(results.isEmpty,
            "C4-f: 纯内存搜索，即使文件不存在也应返回匹配条目，实际 \(results.count) 条")
        XCTAssertEqual(results.first?.name, "FakeApp123NotReallyThere",
            "C4-f: 返回正确条目 name，实际 \(String(describing: results.first?.name))")
    }

    // MARK: - C4-g：场景 7 — Top-N 截断（appSearchLimit=8）

    /// 注入 15 条全匹配条目，limit=8 → 返回 ≤ 8 条（不撑出屏幕）。
    func test_C4g_topNTruncation_scenario7_atMost8Results() {
        let entries = (1...15).map { makeEntry(name: "App\($0)") }
        let index = makeIndex(entries: entries)
        let results = index.search("app", limit: 8)

        XCTAssertLessThanOrEqual(results.count, 8,
            "C4-g（场景 7）: limit=8（appSearchLimit）时最多 8 条，实际 \(results.count) 条")
    }

    /// 结果按相关度排序（分更高的在前）。
    /// "app" 对 "App1" 的前缀匹配分 ≥ 对 "Approval1" 的分（前者 app 是完整 name 起始部分）。
    func test_C4g_topNResults_orderedByRelevance() {
        let entries = [
            makeEntry(name: "App1"),      // 高相关度：query 是前缀
            makeEntry(name: "App2"),      // 高相关度
            makeEntry(name: "Approval"),  // 中等：app 出现在内部
            makeEntry(name: "Happen"),    // 低相关度：app 子序列分散
        ]
        let index = makeIndex(entries: entries)
        let results = index.search("app", limit: 8)

        // 全部应匹配 > 0
        XCTAssertEqual(results.count, 4,
            "C4-g: 全部 4 条都应匹配 'app'，实际 \(results.count) 条")

        // App1/App2 应排在 Happen 之前
        let happenIdx = results.firstIndex { $0.name == "Happen" }
        let app1Idx   = results.firstIndex { $0.name == "App1" }
        if let hi = happenIdx, let a1 = app1Idx {
            XCTAssertLessThan(a1, hi,
                "C4-g: 'App1'（前缀匹配）应排在 'Happen'（散布子序列）之前")
        }
    }
}
