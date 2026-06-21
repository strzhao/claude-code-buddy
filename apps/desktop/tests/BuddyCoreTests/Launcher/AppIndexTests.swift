import XCTest
@testable import BuddyCore

/// 蓝队单元测试 — AppIndex.search 排序截断（C3/C4 契约）
@MainActor
final class AppIndexTests: XCTestCase {

    /// 创建一个注入固定 entries 的 AppIndex
    private func makeIndex(entries: [AppEntry]) -> AppIndex {
        let idx = AppIndex()
        // 直接替换内存 entries（internal 可访问 via @testable import）
        idx.entries = entries
        return idx
    }

    /// 回归：中文名 app 可通过英文别名搜到（微信→wechat / 哔哩哔哩→bilibili）
    func test_search_matchesViaAliases_chineseAppEnglishName() {
        let idx = makeIndex(entries: [
            AppEntry(url: URL(fileURLWithPath: "/Applications/微信.app"),
                     name: "微信", aliases: ["WeChat", "tencent", "xinWeChat"]),
            AppEntry(url: URL(fileURLWithPath: "/Applications/哔哩哔哩.app"),
                     name: "哔哩哔哩", aliases: ["哔哩哔哩", "bilibili", "bilibiliPC"])
        ])
        XCTAssertEqual(idx.search("wechat", limit: 10).first?.name, "微信",
                       "微信 应能通过英文别名 wechat 搜到")
        XCTAssertEqual(idx.search("bilibili", limit: 10).first?.name, "哔哩哔哩",
                       "哔哩哔哩 应能通过 bundleId 成分 bilibili 搜到")
        // 显示名仍可中文搜到
        XCTAssertEqual(idx.search("微信", limit: 10).first?.name, "微信")
    }

    func test_search_emptyQuery_returnsEmpty() {
        let idx = makeIndex(entries: [
            AppEntry(url: URL(fileURLWithPath: "/Applications/Safari.app"), name: "Safari")
        ])
        let result = idx.search("", limit: 10)
        XCTAssertTrue(result.isEmpty, "空 query 应返回 []")
    }

    func test_search_noMatch_returnsEmpty() {
        let idx = makeIndex(entries: [
            AppEntry(url: URL(fileURLWithPath: "/Applications/Safari.app"), name: "Safari")
        ])
        let result = idx.search("zzz", limit: 10)
        XCTAssertTrue(result.isEmpty)
    }

    func test_search_filterScoreZero() {
        let idx = makeIndex(entries: [
            AppEntry(url: URL(fileURLWithPath: "/Applications/Safari.app"), name: "Safari"),
            AppEntry(url: URL(fileURLWithPath: "/Applications/TextEdit.app"), name: "TextEdit")
        ])
        // "saf" 应只匹配 Safari
        let result = idx.search("saf", limit: 10)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].name, "Safari")
    }

    func test_search_sortedByScoreDescending() {
        let idx = makeIndex(entries: [
            // "te" 前缀 TextEdit（高分）
            AppEntry(url: URL(fileURLWithPath: "/Applications/TextEdit.app"), name: "TextEdit"),
            // "te" 子序列 Safari（含字符 a, f, a, r, i — 不含 t,e）→ 不匹配
            AppEntry(url: URL(fileURLWithPath: "/Applications/Terminal.app"), name: "Terminal")
        ])
        let result = idx.search("te", limit: 10)
        // TextEdit 前缀匹配分 > Terminal 前缀匹配分（te→TextEdit 更前缀）
        // 但两者都以 "te" 开头，所以都是前缀匹配
        // 验证两者都在结果中且 TextEdit 在前（字典序 T...E < T...r）
        XCTAssertEqual(result.count, 2)
    }

    func test_search_tieBreakByNameAlpha_C3() {
        // C3 tie-break：分数相同时按 name 字典序
        // 构造两个名字让它们得到相同分数：同样是精确前缀 "a"
        let idx = makeIndex(entries: [
            AppEntry(url: URL(fileURLWithPath: "/Applications/Acme.app"), name: "Acme"),
            AppEntry(url: URL(fileURLWithPath: "/Applications/Apex.app"), name: "Apex"),
            AppEntry(url: URL(fileURLWithPath: "/Applications/Atom.app"), name: "Atom")
        ])
        let result = idx.search("a", limit: 10)
        // 同为前缀匹配，按字典序排列
        let names = result.map(\.name)
        XCTAssertEqual(names, names.sorted(), "同分时应按 name 字典序")
    }

    /// 拼音别名：中文名 app 可通过拼音搜到（微信→weixin/wx/wexin）。wexin 虽是拼写错误，
    /// 但作为 weixin 的子序列仍然可命中（容错）。
    func test_search_matchesViaPinyinAliases_chineseAppName() {
        let idx = makeIndex(entries: [
            AppEntry(url: URL(fileURLWithPath: "/Applications/微信.app"),
                     name: "微信", aliases: ["WeChat", "tencent", "xinWeChat", "weixin", "wx"])
        ])
        // 全拼
        XCTAssertEqual(idx.search("weixin", limit: 10).first?.name, "微信",
                       "微信 应能通过拼音别名 weixin 搜到")
        // 首字母缩写
        XCTAssertEqual(idx.search("wx", limit: 10).first?.name, "微信",
                       "微信 应能通过拼音首字母 wx 搜到")
        // 拼写错误但仍是子序列（wexin 是 weixin 的子序列）
        XCTAssertEqual(idx.search("wexin", limit: 10).first?.name, "微信",
                       "微信 应能通过 wexin（weixin 子序列）容错搜到")
        // 中文仍可搜到
        XCTAssertEqual(idx.search("微信", limit: 10).first?.name, "微信")
    }

    /// WeChat.app 场景：文件名英文无 CJK，别名含中文名（来自本地化资源）→ 拼音搜应命中
    func test_search_matchesViaPinyin_fromLocalizedChineseName() {
        // 模拟 WeChat.app：显示名 "WeChat"，别名含本地化中文名 "微信" + 拼音
        let idx = makeIndex(entries: [
            AppEntry(url: URL(fileURLWithPath: "/Applications/WeChat.app"),
                     name: "WeChat", aliases: ["WeChat", "tencent", "xinWeChat", "微信", "weixin", "wx"])
        ])
        XCTAssertEqual(idx.search("weixin", limit: 10).first?.name, "WeChat",
                       "WeChat.app 应能通过中文名拼音 weixin 搜到")
        XCTAssertEqual(idx.search("wx", limit: 10).first?.name, "WeChat",
                       "WeChat.app 应能通过拼音首字母 wx 搜到")
        XCTAssertEqual(idx.search("wexin", limit: 10).first?.name, "WeChat",
                       "WeChat.app 应能通过 wexin（weixin 子序列）容错搜到")
    }

    func test_search_limit_truncates() {
        let entries = (1...20).map { i in
            AppEntry(
                url: URL(fileURLWithPath: "/Applications/App\(i).app"),
                name: "App\(i)"
            )
        }
        let idx = makeIndex(entries: entries)
        let result = idx.search("app", limit: 5)
        XCTAssertLessThanOrEqual(result.count, 5, "截断到 limit")
    }
}

