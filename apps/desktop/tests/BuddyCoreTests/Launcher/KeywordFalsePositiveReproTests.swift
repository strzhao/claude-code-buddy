import XCTest
@testable import BuddyCore

// MARK: - KeywordFalsePositiveReproTests
//
// 回归保护（统一混排 D2/C-UNIFIED-SCORE，场景8.P3 / 场景14）：验证 UnifiedPluginScorer 的
// 单字 keyword 档位排除消除了 qr 单字 keyword「码」的误触根因（UI 档位通道 + AI 流
// narrowCandidatesScored 内核通道，双通道一致）。
//
// 历史对照：
//   翻转前（最初断言）：contains 反向打分 bug ——「密码」/「代码」/「验证码」误命中 qr。
//   方案 B 期（旧断言）：commandPrefixMatched 严格前缀消除误触。
//   本次（新断言）：UnifiedPluginScorer 单字 keyword 仅参与完全档——「密码」类 score==0
//   不进任何候选列表；「qr」「二维码」「码」完全档正确命中。

private func makeCommandRealManifest(
    name: String,
    description: String,
    keywords: [String]
) -> PluginManifest {
    let json: [String: Any] = [
        "name": name,
        "version": "1.0.0",
        "description": description,
        "keywords": keywords,
        "mode": "command",
        "cmd": "./run.sh",
        "args": [] as [String]
    ]
    return try! JSONDecoder().decode(PluginManifest.self, from: try JSONSerialization.data(withJSONObject: json))
}

final class KeywordFalsePositiveReproTests: XCTestCase {

    /// 真实 qr manifest（keywords + description 逐字照搬社区仓库 plugin.json，含单字「码」根因）
    private var qrCommand: PluginManifest {
        makeCommandRealManifest(
            name: "qr",
            description: "把输入的文本或网址变成一张二维码图片，点击可复制到剪贴板。适合把链接快速转移到手机扫描。",
            keywords: ["qr", "qrcode", "二维码", "码"]
        )
    }

    // MARK: - 场景8.P3 / 14.P1：「密码」类 contains 弱命中被排除

    func test_密码_score0_notInCandidates() {
        let score = UnifiedPluginScorer.score(query: "密码", manifest: qrCommand)
        XCTAssertEqual(score, 0, "「密码」不得命中 qr（单字「码」排除 contains 档）")
        let scored = LauncherRouter.narrowCandidatesScored(query: "密码", plugins: [qrCommand])
        XCTAssertFalse(scored.contains { $0.manifest.name == "qr" },
                       "场景8.P3: narrowCandidatesScored(密码) 不含 qr（AI 流通道）")
    }

    func test_代码_score0() {
        XCTAssertEqual(UnifiedPluginScorer.score(query: "代码", manifest: qrCommand), 0,
                       "「代码」不得命中 qr")
    }

    func test_验证码_score0() {
        XCTAssertEqual(UnifiedPluginScorer.score(query: "验证码", manifest: qrCommand), 0,
                       "「验证码」不得命中 qr")
    }

    // MARK: - 完全档正确命中（qr/二维码/码）

    func test_qr_完全命中() {
        XCTAssertEqual(UnifiedPluginScorer.score(query: "qr", manifest: qrCommand), 1030,
                       "query==name → 完全档 1000 + name 30")
    }

    func test_二维码_完全命中() {
        XCTAssertEqual(UnifiedPluginScorer.score(query: "二维码", manifest: qrCommand), 1000,
                       "query==keyword「二维码」→ 完全档 1000")
    }

    func test_码_完全命中() {
        XCTAssertEqual(UnifiedPluginScorer.score(query: "码", manifest: qrCommand), 1000,
                       "场景14.P2: query 恰为单字 keyword「码」→ 完全档仍有效")
    }

    // MARK: - 触发词开头 + 参数（用户高频路径，contains 档进候选）

    func test_qr带参数_命中() {
        let scored = LauncherRouter.narrowCandidatesScored(query: "qr https://example.com", plugins: [qrCommand])
        XCTAssertTrue(scored.contains { $0.manifest.name == "qr" },
                      "「qr https://...」query contains keyword → qr 进候选（Enter 分流 strip 参数）")
    }

    func test_二维码带参数_命中() {
        let scored = LauncherRouter.narrowCandidatesScored(query: "二维码 https://x", plugins: [qrCommand])
        XCTAssertTrue(scored.contains { $0.manifest.name == "qr" },
                      "「二维码 https://x」→ qr 进候选")
    }

    // MARK: - AI 流触发词锚点（场景8.P1 数据层）

    func test_toolDescription_单字keyword被过滤() throws {
        let desc = qrCommand.synthesizeToolDescription()
        let triggerSection = try XCTUnwrap(
            desc.split(separator: "。").first { $0.hasPrefix("触发：") },
            "description 应含触发词段"
        )
        let tokens = triggerSection.dropFirst("触发：".count).split(separator: "、").map(String.init)
        XCTAssertFalse(tokens.contains("码"),
                       "场景8.P1: tool description 触发词不含单字「码」")
        XCTAssertTrue(tokens.contains("二维码"),
                      "场景8.P1: 多字 keyword「二维码」保留")
    }

    func test_effectiveTriggerKeywords_过滤单字() {
        XCTAssertEqual(qrCommand.effectiveTriggerKeywords, ["qr", "qrcode", "二维码"],
                       "D8.2: effectiveTriggerKeywords 过滤长度 <2 的 keyword")
    }
}
