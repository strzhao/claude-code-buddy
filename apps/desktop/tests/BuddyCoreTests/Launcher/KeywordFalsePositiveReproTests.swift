import XCTest
@testable import BuddyCore

// MARK: - KeywordFalsePositiveReproTests
//
// 翻转后的回归测试（方案 B 两阶段，C-PREFIX-MATCH）：验证 commandPrefixMatched 严格前缀匹配
// 消除了 qr 单字 keyword「码」的误触根因。
//
// 翻转前（旧断言）：证明 contains 反向打分 bug ——「密码」/「代码」/「验证码」误命中 qr。
// 翻转后（新断言）：commandPrefixMatched 不误命中；qr/二维码 正确命中。
//
// 注：hello 的「写个示例」误触属于 stdin/prompt 路由（C-SCOPE-COMMAND-ONLY），
// commandPrefixMatched 不覆盖 stdin mode，hello 误触另案清理（本次范围外）。

private func makeCommandRealManifest(
    name: String,
    description: String,
    keywords: [String]
) -> PluginManifest {
    // command mode manifest：JSON 解码构造（禁用便利 init，硬编码 .stdin 会被 .command 过滤）
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

    // MARK: - 翻转 1：「密码」不再误命中 qr（C-PREFIX-MATCH）

    func test_密码_不命中qr_command() {
        let matched = LauncherRouter.commandPrefixMatched(query: "密码", plugins: [qrCommand])
        XCTAssertFalse(matched.map(\.name).contains("qr"),
                       "翻转：commandPrefixMatched 后「密码」不应命中 qr（实际: \(matched.map(\.name))）")
    }

    // MARK: - 翻转 2：「代码」「验证码」同理不再误命中

    func test_代码_不命中qr_command() {
        let matched = LauncherRouter.commandPrefixMatched(query: "代码", plugins: [qrCommand])
        XCTAssertFalse(matched.map(\.name).contains("qr"), "翻转：「代码」不应命中 qr")
    }

    func test_验证码_不命中qr_command() {
        let matched = LauncherRouter.commandPrefixMatched(query: "验证码", plugins: [qrCommand])
        XCTAssertFalse(matched.map(\.name).contains("qr"), "翻转：「验证码」不应命中 qr")
    }

    // MARK: - 翻转 3：qr/二维码 正确命中（command mode 真正可用）

    func test_qr_正确命中qr() {
        let matched = LauncherRouter.commandPrefixMatched(query: "qr https://example.com", plugins: [qrCommand])
        XCTAssertTrue(matched.map(\.name).contains("qr"), "qr 命令应正确命中 qr 插件")
    }

    func test_二维码_正确命中qr() {
        let matched = LauncherRouter.commandPrefixMatched(query: "二维码 https://x", plugins: [qrCommand])
        XCTAssertTrue(matched.map(\.name).contains("qr"), "「二维码」前缀应命中 qr 插件")
    }

    func test_码_正确命中qr() {
        let matched = LauncherRouter.commandPrefixMatched(query: "码 https://x", plugins: [qrCommand])
        XCTAssertTrue(matched.map(\.name).contains("qr"), "「码」前缀应命中 qr 插件（根因保护）")
    }
}
