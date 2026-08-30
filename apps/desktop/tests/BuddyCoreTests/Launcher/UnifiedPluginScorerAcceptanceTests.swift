import XCTest
@testable import BuddyCore

// MARK: - UnifiedPluginScorerAcceptanceTests
//
// 红队验收测试（TDD 红灯）：统一打分档位 C-UNIFIED-SCORE
//
// 设计文档契约引用（设计文档 ## 设计决策 D2 / ## 契约规约 C-UNIFIED-SCORE）：
//   完全 1000（query==name 或 ==keyword，lowercased）
//   前缀 800（query 是 name/keyword 前缀）
//   词首 500（camelCase/空格/中英边界词首连续）
//   contains 150（双向互 contains）
//   0 不进列表
//   name 命中 +30；多 keyword 取最高（非叠加）
//   长度 <2 的 keyword 仅参与完全档（前缀/词首/contains 排除）
//
// 被测 API（设计文档 Context 声明）：
//   `UnifiedPluginScorer.score(query:manifest:) -> Int` static 纯函数（LauncherRouter 内）
//
// CONTRACT_AMBIGUOUS: 设计写「UnifiedPluginScorer…（LauncherRouter 内）」——若蓝队把类型
//   嵌套为 LauncherRouter.UnifiedPluginScorer，请只调整引用路径，**不得改动任何断言值**
//   （档位字面量 1000/800/500/150/30 是 C-UNIFIED-SCORE 冻结契约）。
//
// TDD 红灯：UnifiedPluginScorer 蓝队未实现时本文件编译失败，属预期；绝不放宽断言让它过。

@MainActor
final class UnifiedPluginScorerAcceptanceTests: XCTestCase {

    // MARK: - manifest 构造（JSON 解码，与 LockedCommandStateMachineAcceptanceTests 同构）

    private func makeManifest(name: String, keywords: [String], icon: String? = nil) throws -> PluginManifest {
        var dict: [String: Any] = [
            "name": name,
            "version": "0.1.0-test",
            "description": "test \(name) plugin",
            "keywords": keywords,
            "mode": "command",
            "cmd": "echo",
            "args": [String]()
        ]
        if let icon = icon {
            dict["icon"] = icon
        }
        let data = try JSONSerialization.data(withJSONObject: dict)
        return try JSONDecoder().decode(PluginManifest.self, from: data)
    }

    private func score(_ query: String, manifest: PluginManifest) -> Int {
        UnifiedPluginScorer.score(query: query, manifest: manifest)
    }

    // MARK: - 完全档 1000

    /// C-UNIFIED-SCORE [det-machine]：query==keyword（lowercased）→ 恰好 1000
    /// assert: score("二维码", qr(keywords:[qr,二维码,码])) == 1000
    /// Mutation kill：档位值漂移（如 999/1001/加 name+30）→ 精确相等断言挂。
    func test_C_UNIFIED_SCORE_completeKeyword_exact1000() throws {
        let qr = try makeManifest(name: "qr", keywords: ["qr", "二维码", "码"])
        XCTAssertEqual(score("二维码", manifest: qr), 1000,
            "C-UNIFIED-SCORE: query==keyword 完全档必须恰好 1000")
    }

    /// C-UNIFIED-SCORE [det-machine]：query==name 完全档 + name 命中 +30 → 恰好 1030
    /// assert: score("qzh", qzh(keywords:[qzh])) == 1030
    func test_C_UNIFIED_SCORE_completeName_plus30_exact1030() throws {
        let qzh = try makeManifest(name: "qzh", keywords: ["qzh", "圈住"])
        XCTAssertEqual(score("qzh", manifest: qzh), 1030,
            "C-UNIFIED-SCORE: query==name 完全档 1000 + name 命中 +30 = 1030（+30 不可缺不可叠加）")
    }

    /// C-UNIFIED-SCORE / 场景10.P2 [det-machine]：大小写不敏感——「QR」命中 keyword "qr" 完全档
    /// assert: score("QR", qr(keywords:[qr])) == 1030（完全 1000 + name "qr" 命中 +30）
    func test_scenario10_P2_uppercaseQuery_caseInsensitiveComplete() throws {
        let qr = try makeManifest(name: "qr", keywords: ["qr", "二维码", "码"])
        XCTAssertEqual(score("QR", manifest: qr), 1030,
            "场景10.P2: 大小写不敏感，query \"QR\" == name/keyword \"qr\"（lowercased）→ 1000+30=1030")
    }

    // MARK: - 前缀档 800（场景10.P1）

    /// C-UNIFIED-SCORE / 场景10.P1 [det-machine]：query 是 keyword 前缀 → 恰好 800
    /// assert: score("qz", qzh) == 800
    func test_scenario10_P1_prefixTier_exact800() throws {
        let qzh = try makeManifest(name: "qzh", keywords: ["qzh", "圈住"])
        // 830 = 前缀档 800 + name 命中加成 30（fixture name 也是 "qzh"，"qz" 同时是其前缀 → D2 name+30）
        XCTAssertEqual(score("qz", manifest: qzh), 830,
            "场景10.P1: query \"qz\" 是 keyword/name \"qzh\" 的前缀 → 前缀档 800 + name 命中 30 = 830")
    }

    // MARK: - 词首档 500

    /// C-UNIFIED-SCORE [det-machine]：camelCase 词首连续命中（非前缀）→ 恰好 500
    /// assert: score("QR", camtool(keywords:[genQR])) == 500
    ///   - "QR" 在 "genQR" 的 camel 边界（Q）词首连续；"genqr".hasPrefix("qr")==false 非前缀；
    ///     name "camtool" 不命中（无 +30）。
    func test_C_UNIFIED_SCORE_camelCaseWordStart_exact500() throws {
        let cam = try makeManifest(name: "camtool", keywords: ["genQR"])
        XCTAssertEqual(score("QR", manifest: cam), 500,
            "C-UNIFIED-SCORE: camelCase 词首连续命中 → 词首档恰好 500（name 无命中不加 30）")
    }

    /// C-UNIFIED-SCORE [det-machine]：空格词首连续命中（非前缀）→ 恰好 500
    /// assert: score("monitor", sp(keywords:[open monitor])) == 500
    func test_C_UNIFIED_SCORE_spaceWordStart_exact500() throws {
        let sp = try makeManifest(name: "spacer", keywords: ["open monitor"])
        XCTAssertEqual(score("monitor", manifest: sp), 500,
            "C-UNIFIED-SCORE: 空格边界词首连续命中 → 词首档恰好 500")
    }

    // MARK: - contains 档 150

    /// C-UNIFIED-SCORE [det-machine]：双向互 contains（非前缀/词首）→ 恰好 150
    /// assert: score("维码", ctr(keywords:[生成二维码])) == 150
    ///   - "生成二维码" contains "维码" 但 "维码" 不是前缀也非词首 → contains 档。
    func test_C_UNIFIED_SCORE_containsTier_exact150() throws {
        let ctr = try makeManifest(name: "ctr", keywords: ["生成二维码"])
        XCTAssertEqual(score("维码", manifest: ctr), 150,
            "C-UNIFIED-SCORE: 双向互 contains → contains 档恰好 150")
    }

    // MARK: - 单字 keyword（<2）仅参与完全档

    /// C-UNIFIED-SCORE / 场景14.P1 [det-machine]：单字 keyword「码」不参与 contains/前缀/词首
    /// assert: score("密码", qr'(keywords:[码])) == 0（防误命中根因）
    /// Mutation kill：若「码」仍参与 contains（旧 narrowCandidatesScored contains 语义残留），
    ///   "密码" contains "码" → score>0 → 红灯。这是本次改造的核心防误触断言。
    func test_scenario14_P1_singleCharKeyword_negativeQuery_excluded() throws {
        let m = try makeManifest(name: "qr", keywords: ["码"])
        XCTAssertEqual(score("密码", manifest: m), 0,
            "场景14.P1: 单字 keyword「码」仅参与完全档；「密码」contains「码」不得得分（必须 ==0）")
    }

    /// C-UNIFIED-SCORE / 场景14.P2 [det-machine]：单字 keyword 完全档仍有效
    /// assert: score("码", qr'(keywords:[码])) == 1000
    func test_scenario14_P2_singleCharKeyword_completeTierStillWorks() throws {
        let m = try makeManifest(name: "qr", keywords: ["码"])
        XCTAssertEqual(score("码", manifest: m), 1000,
            "场景14.P2: 输「码」单字 keyword 完全档必须仍得 1000（完全档不被 <2 过滤误伤）")
    }

    /// C-UNIFIED-SCORE [det-machine]：单字 keyword 不参与前缀档
    /// assert: score("密码", m'(keywords:[码,qr])) — 「密码」非任何 keyword 前缀、
    ///   「码」不参与 contains → 恰好 0；同时前缀排除断言：query "密" 是「密码」…
    ///   （前缀方向是 query⊆keyword，单字 keyword 「码」 只拦 contains/词首，前缀方向
    ///   query 必须以 keyword 开头，"密码" 不以 "码" 开头 → 无影响）。
    /// 本用例锁定：多 keyword 下取最高且单字 keyword 不抬分。
    func test_singleCharKeyword_doesNotLiftScore_multiKeyword() throws {
        let m = try makeManifest(name: "qr", keywords: ["码", "qr"])
        XCTAssertEqual(score("密码", manifest: m), 0,
            "C-UNIFIED-SCORE: 单字 keyword「码」在多 keyword 下也不得经 contains/词首/前缀抬分")
    }

    // MARK: - 多 keyword 取最高（非叠加）

    /// C-UNIFIED-SCORE [det-machine]：多 keyword 命中取最高档，不叠加
    /// assert: score("banana", multi(keywords:[apple,banana])) == 1000（非 2000）
    ///         score("ban",     multi(keywords:[apple,banana])) == 800（非 1600）
    func test_C_UNIFIED_SCORE_multiKeyword_takesMax_notAdditive() throws {
        let multi = try makeManifest(name: "multi", keywords: ["apple", "banana"])
        XCTAssertEqual(score("banana", manifest: multi), 1000,
            "C-UNIFIED-SCORE: 多 keyword 取最高（完全 1000），不得叠加")
        XCTAssertEqual(score("ban", manifest: multi), 800,
            "C-UNIFIED-SCORE: 多 keyword 取最高（前缀 800），不得叠加")
    }

    // MARK: - 0 分不进列表

    /// C-UNIFIED-SCORE [det-machine]：无任何档位命中 → 0（0 分不进列表）
    /// assert: score("zzz", qr) == 0
    func test_C_UNIFIED_SCORE_noMatch_zero() throws {
        let qr = try makeManifest(name: "qr", keywords: ["qr", "二维码", "码"])
        XCTAssertEqual(score("zzz", manifest: qr), 0,
            "C-UNIFIED-SCORE: 无命中必须恰好 0 分（0 分不进列表）")
    }

    // MARK: - 档位优先级（同一 query 命中多档取高档）

    /// C-UNIFIED-SCORE [det-machine]：前缀优先于 contains（"维码" 也 contains 于
    ///  "二维码"…构造：query "二维" 是 keyword "二维码" 前缀 → 800，而非 contains 150）
    /// assert: score("二维", qr(keywords:[二维码])) == 800
    func test_C_UNIFIED_SCORE_tierPrecedence_prefixBeatsContains() throws {
        let qr = try makeManifest(name: "qr", keywords: ["二维码"])
        XCTAssertEqual(score("二维", manifest: qr), 800,
            "C-UNIFIED-SCORE: 同 query 命中多档时取最高档（前缀 800 > contains 150）")
    }
}
