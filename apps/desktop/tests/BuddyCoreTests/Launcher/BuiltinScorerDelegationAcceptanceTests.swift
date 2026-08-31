import XCTest
@testable import BuddyCore

// MARK: - BuiltinScorerDelegationAcceptanceTests
//
// 红队验收测试（仅基于设计文档编写，黑盒视角）：统一打分器入口扩展的委托等价契约。
//
// 设计文档引用（state.md ## 设计文档 D2 / ## 契约规约）：
//   C-SCORER-DELEGATION：score(query:manifest:) ≡ score(query:name:manifest.name,
//     keywords:manifest.keywords)（逐字委托，任意输入等价；既有 manifest 版测试全数通过）。
//   C-BUILTIN-FUZZY-ROW score 闭集 {150,180,500,530,800,830,1000,1030} 的来源锚点：
//     D2 新入口对 paste 配置（name=paste，keywords=cb/clipboard/剪贴板/paste）的档位算术。
//
// 注：`score(query:name:keywords:)` 是 D2 声明的新入口——蓝队合流前本文件编译红（预期 TDD 红灯），
// 合流后与 manifest 版全矩阵等价断言共同守住「一处定义多处消费」。

@MainActor
final class BuiltinScorerDelegationAcceptanceTests: XCTestCase {

    // MARK: - 构造辅助

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

    /// 覆盖四档位 × name/keyword 侧 × 单字 keyword 防线 × 大小写归一 × 空输入的代表性矩阵
    private var matrix: [(name: String, keywords: [String], queries: [String])] {
        [
            ("paste", ["cb", "clipboard", "剪贴板", "paste"],
             ["pas", "p", "paste", "cb", "剪", "剪贴板", "clipboard", "cl", "zzqq", "PASTE", ""]),
            ("qr", ["qr", "qrcode", "二维码", "码"],
             ["qr", "二维码", "密码", "验证码", "码", "qrc", "QR", ""]),
            ("qzh", ["qzh", "qzhddr", "监控"],
             ["qz", "qzh", "监控", "关闭监控服务", "zz", ""]),
            ("SnipTool", ["snippet"],
             ["snip", "snippet", "snip abc", "snipfoo", "sniptool", "st", ""]),
        ]
    }

    // MARK: - C-SCORER-DELEGATION：manifest 版 ≡ name/keywords 版（任意输入等价）

    /// C-SCORER-DELEGATION：全矩阵逐对等价。
    /// Mutation kill：新入口与 manifest 版实现漂移（档位/加成/单字防线不一致）→ 任一对不等 → 红。
    func test_cscorerdelegation_manifestFormEquivalentToNameKeywordsForm() {
        for case_ in matrix {
            let m = manifest(name: case_.name, keywords: case_.keywords)
            for q in case_.queries {
                let viaManifest = UnifiedPluginScorer.score(query: q, manifest: m)
                let viaNameKeywords = UnifiedPluginScorer.score(
                    query: q, name: m.name, keywords: m.keywords)
                XCTAssertEqual(viaManifest, viaNameKeywords,
                    "C-SCORER-DELEGATION: name=\(case_.name) keywords=\(case_.keywords) query=\"\(q)\" "
                    + "manifest 版(\(viaManifest)) ≡ name/keywords 版(\(viaNameKeywords))")
            }
        }
    }

    // MARK: - C-BUILTIN-FUZZY-ROW score 闭集锚点：D2 新入口对 paste 配置的档位算术

    /// paste 配置（D1：name=paste，keywords=4 触发词闭集）的精确档位值 ——
    /// builtin: 行 score 闭集的算术来源。字面量取自 C-UNIFIED-SCORE 档位表 + name +30。
    func test_scoreNameKeywords_pasteConfig_tierAnchors() {
        let keywords = ["cb", "clipboard", "剪贴板", "paste"]

        // 前缀档 + name 加成：「pas」是 name「paste」前缀 → 800 + 30
        XCTAssertEqual(
            UnifiedPluginScorer.score(query: "pas", name: "paste", keywords: keywords), 830,
            "pas → name 前缀档 830（C-BUILTIN-FUZZY-ROW 闭集内）")
        // 前缀档 keyword 侧（无 name 加成）：「cl」是「clipboard」前缀 → 800
        XCTAssertEqual(
            UnifiedPluginScorer.score(query: "cl", name: "paste", keywords: keywords), 800,
            "cl → keyword 前缀档 800（场景1.P4 闭集内）")
        // 单字 query 经前缀档命中多字 keyword（单字防线只作用 keyword 侧）：「剪」→「剪贴板」800
        XCTAssertEqual(
            UnifiedPluginScorer.score(query: "剪", name: "paste", keywords: keywords), 800,
            "剪 → 「剪贴板」前缀档 800（场景1.P2 闭集内）")
        // 完全档 + name 加成：query == name → 1030
        XCTAssertEqual(
            UnifiedPluginScorer.score(query: "paste", name: "paste", keywords: keywords), 1030,
            "paste → 完全档 1030")
        // 完全档 keyword 侧：query == keyword「cb」→ 1000
        XCTAssertEqual(
            UnifiedPluginScorer.score(query: "cb", name: "paste", keywords: keywords), 1000,
            "cb → keyword 完全档 1000")
        // 无命中 → 0（不产行，场景2.P1 的分数来源）
        XCTAssertEqual(
            UnifiedPluginScorer.score(query: "zzqq", name: "paste", keywords: keywords), 0,
            "zzqq → 0（无命中不进列表）")
    }

    /// 空关键词边界：name 侧仍打分（错误边界「keywords 空 → 不产行」是 registry 层语义，
    /// scorer 本身对 name 照常工作——委托等价在空 keywords 下同样成立）。
    func test_scoreNameKeywords_emptyKeywords_nameSideStillScored() {
        XCTAssertEqual(
            UnifiedPluginScorer.score(query: "qzh", name: "qzh", keywords: []), 1030,
            "空 keywords：name 完全档 1000 + 30")
        XCTAssertEqual(
            UnifiedPluginScorer.score(query: "zz", name: "qzh", keywords: []), 0,
            "空 keywords 且 name 不命中 → 0")
        let m = manifest(name: "qzh", keywords: [])
        XCTAssertEqual(
            UnifiedPluginScorer.score(query: "qzh", manifest: m),
            UnifiedPluginScorer.score(query: "qzh", name: "qzh", keywords: []),
            "C-SCORER-DELEGATION: 空 keywords 下两形态等价")
    }
}
