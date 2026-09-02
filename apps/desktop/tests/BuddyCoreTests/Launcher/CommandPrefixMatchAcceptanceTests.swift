import XCTest
@testable import BuddyCore

// MARK: - CommandPrefixMatchAcceptanceTests
//
// 蓝队验收测试（det-machine 频道）— lockedPrefixStillMatched 纯判定
//（统一混排 D3.6：原 LauncherRouter.commandPrefixMatched 集合函数退役，
//  其单 manifest 语义收敛为 LauncherManager.lockedPrefixStillMatched，服务 Tab 锁定粘性）
//
// 设计文档契约引用（state.md ## 契约规约 / ## 设计决策 D3.6）：
//   C-TAB-LOCK ：锁定仅来自 Tab/点击显式操作；「唯一命中自动锁定」「keyword+空格自动锁定」不存在
//   C-LOCK-STICKY（D3.6）：lockedCommand 非空且 query 仍以 locked 的 name/keyword 前缀开头
//                （严格分隔：空白/标点/行尾）→ 保持锁定
//   C-BACKCOMPAT-MANIFEST：不改 plugin.json schema；qr 的 keywords（含「码」）不动。
//
// 符号映射（QA 绑定）：
//   commandMatcherHits(input) = qr manifest 的 lockedPrefixStillMatched(query:input) == true
//
// mock 必须用 JSON 解码 mode:"command"（契约 C9）：
//   便利 init PluginManifest(name:...) 硬编码 .stdin mode。

@MainActor
final class CommandPrefixMatchAcceptanceTests: XCTestCase {

    // MARK: - 场景1（P0·Happy·误触消除）：含「码」但非前缀不维持 qr 锁定

    /// 场景1.P1 [det-machine]：输入「密码」→ 不满足 qr 前缀粘性
    /// assert: lockedPrefixStillMatched("密码", qr) == false
    func test_scenario1_P1_密码_notMatched() {
        let qr = makeQrCommandManifest()

        XCTAssertFalse(LauncherManager.shared.lockedPrefixStillMatched(query: "密码", manifest: qr),
            "场景1.P1: 「密码」不得满足 qr 的前缀粘性（「码」未在开头，严格分隔）")
    }

    /// 场景1.P2 [det-machine]：「代码」「验证码」不满足 qr 前缀粘性
    func test_scenario1_P2_代码验证码_notMatched() {
        let qr = makeQrCommandManifest()

        XCTAssertFalse(LauncherManager.shared.lockedPrefixStillMatched(query: "代码", manifest: qr),
            "场景1.P2: 「代码」不满足 qr 前缀粘性")
        XCTAssertFalse(LauncherManager.shared.lockedPrefixStillMatched(query: "验证码", manifest: qr),
            "场景1.P2: 「验证码」不满足 qr 前缀粘性")
    }

    // MARK: - 场景2（P0·Edge·前缀严格分隔）：「qrcode」不被「qr」粘住

    /// 场景2.P1 [det-machine]：「qrcode」不以「qr」+分隔符开头 → false（严格分隔语义）
    func test_scenario2_P1_qrcode_strictBoundary_false() {
        let qr = makeQrCommandManifest()

        XCTAssertFalse(LauncherManager.shared.lockedPrefixStillMatched(query: "qrcode", manifest: qr),
            "场景2.P1: 「qrcode」的 qr 后无分隔符 → 不满足粘性（严格分隔）")
    }

    /// 场景2.P2 [det-machine]：「qr https://example.com」（qr+空格）→ true
    func test_scenario2_P2_qrWithArg_matched() {
        let qr = makeQrCommandManifest()

        XCTAssertTrue(LauncherManager.shared.lockedPrefixStillMatched(query: "qr https://example.com", manifest: qr),
            "场景2.P2: 「qr 」+参数 → 满足粘性（C-LOCK-STICKY）")
    }

    // MARK: - 场景3（P0·Happy·keyword 命中）

    /// 场景3.P1 [det-machine]：「二维码 xxx」（keyword+空格+参数）→ true
    func test_scenario3_P1_keywordWithArg_matched() {
        let qr = makeQrCommandManifest()

        XCTAssertTrue(LauncherManager.shared.lockedPrefixStillMatched(query: "二维码 https://a.b", manifest: qr),
            "场景3.P1: keyword「二维码」+参数 → 满足粘性")
    }

    /// 场景3.P2 [det-machine]：query 恰为 keyword（行尾）→ true
    func test_scenario3_P2_queryIsKeyword_exactMatched() {
        let qr = makeQrCommandManifest()

        XCTAssertTrue(LauncherManager.shared.lockedPrefixStillMatched(query: "qr", manifest: qr),
            "场景3.P2: query 恰是 keyword「qr」（行尾）→ 满足粘性")
    }

    // MARK: - 场景4（P1·Edge·长前缀优先）：name 与 keyword 有共同前缀

    /// 场景4.P1 [det-machine]：长前缀优先——keyword「qrcode」时「qrcode xxx」true（不因短前缀「qr」分隔失败而误判）
    func test_scenario4_P1_longPrefixPriority() {
        let m = makeCommandManifest(name: "longprefix", keywords: ["qrcode"])

        XCTAssertTrue(LauncherManager.shared.lockedPrefixStillMatched(query: "qrcode abc", manifest: m),
            "场景4.P1: 「qrcode abc」经长前缀「qrcode」命中 → true")
        XCTAssertFalse(LauncherManager.shared.lockedPrefixStillMatched(query: "qrcodeabc", manifest: m),
            "场景4.P1: 「qrcodeabc」无分隔边界 → false")
    }

    // MARK: - 场景5（P1·Edge·大小写）

    /// 场景5.P1 [det-machine]：大小写不敏感——「QR https://x」→ true
    func test_scenario5_P1_caseInsensitive() {
        let qr = makeQrCommandManifest()

        XCTAssertTrue(LauncherManager.shared.lockedPrefixStillMatched(query: "QR https://x", manifest: qr),
            "场景5.P1: 大小写不敏感（lowercased 归一）")
    }

    // MARK: - 场景6（P0·回归·stdin/prompt 无关性）

    /// 场景6.P1 [det-machine]：粘性判定只看 prefix 集合（mode 无关——判定语义与 mode 解耦，
    /// 锁定入口已由 Tab 只对插件行生效保证）
    func test_scenario6_P1_promptManifest_prefixLogicUnchanged() {
        let json: [String: Any] = [
            "name": "hello", "version": "0.1.0", "description": "d",
            "keywords": ["hello", "hi"], "mode": "prompt",
            "systemPrompt": "x", "maxIterations": 1, "autoCopyToClipboard": false
        ]
        let m = try! JSONDecoder().decode(PluginManifest.self, from: try JSONSerialization.data(withJSONObject: json))

        XCTAssertTrue(LauncherManager.shared.lockedPrefixStillMatched(query: "hi there", manifest: m),
            "场景6.P1: keyword「hi」+空格 → 满足粘性（判定与 mode 解耦）")
        XCTAssertFalse(LauncherManager.shared.lockedPrefixStillMatched(query: "hellox", manifest: m),
            "场景6.P1: 「hellox」无分隔边界 → false")
    }

    // MARK: - 辅助

    private func makeQrCommandManifest() -> PluginManifest {
        decodeManifest(name: "qr", keywords: ["qr", "二维码", "码"])
    }

    private func makeCommandManifest(name: String, keywords: [String]) -> PluginManifest {
        decodeManifest(name: name, keywords: keywords)
    }

    private func decodeManifest(name: String, keywords: [String]) -> PluginManifest {
        let json: [String: Any] = [
            "name": name,
            "version": "0.0.1-test",
            "description": "test command plugin",
            "keywords": keywords,
            "mode": "command",
            "cmd": "echo",
            "args": [] as [String]
        ]
        return try! JSONDecoder().decode(PluginManifest.self, from: try JSONSerialization.data(withJSONObject: json))
    }
}
