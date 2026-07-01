import XCTest
@testable import BuddyCore

// MARK: - LauncherRouterCommandPrefixMatchedTests
//
// T1 单测：commandPrefixMatched 纯函数（C-PREFIX-MATCH）。
// 复用 stripKeywordPrefix 的「前缀 + 严格分隔符（空白/标点/行尾）」逻辑反过来做命中判断。
//
// 构造 mock 必须用 JSON 解码（mode:"command"），禁用 PluginManifest(name:...) 便利 init
// （后者硬编码 .stdin mode，会被 commandPrefixMatched 的 .command 过滤掉）。

private func makeCommandManifest(
    name: String,
    keywords: [String],
    cmd: String = "echo"
) -> PluginManifest {
    let json: [String: Any] = [
        "name": name,
        "version": "0.0.1-test",
        "description": "test command plugin \(name)",
        "keywords": keywords,
        "mode": "command",
        "cmd": cmd,
        "args": [] as [String]
    ]
    return try! JSONDecoder().decode(PluginManifest.self, from: try JSONSerialization.data(withJSONObject: json))
}

private func makeStdinManifest(
    name: String,
    keywords: [String]
) -> PluginManifest {
    let json: [String: Any] = [
        "name": name,
        "version": "0.0.1-test",
        "description": "test stdin plugin \(name)",
        "keywords": keywords,
        "mode": "stdin",
        "cmd": "echo",
        "args": [] as [String]
    ]
    return try! JSONDecoder().decode(PluginManifest.self, from: try JSONSerialization.data(withJSONObject: json))
}

final class LauncherRouterCommandPrefixMatchedTests: XCTestCase {

    /// 真实 qr manifest（keywords 含单字「码」，根因保护回归用例）
    private var qrLikePlugins: [PluginManifest] {
        [makeCommandManifest(name: "qr", keywords: ["qr", "qrcode", "二维码", "码"])]
    }

    // MARK: - 场景1：含「码」但非前缀不触发（C-PREFIX-MATCH）

    func test_密码_不命中任何command() {
        let matched = LauncherRouter.commandPrefixMatched(query: "密码", plugins: qrLikePlugins)
        XCTAssertTrue(matched.isEmpty, "「密码」不以「码」开头，不应命中 qr，实际: \(matched.map(\.name))")
    }

    func test_代码_不命中qr() {
        let matched = LauncherRouter.commandPrefixMatched(query: "代码", plugins: qrLikePlugins)
        XCTAssertFalse(matched.map(\.name).contains("qr"), "「代码」不应命中 qr")
    }

    func test_验证码_不命中qr() {
        let matched = LauncherRouter.commandPrefixMatched(query: "验证码", plugins: qrLikePlugins)
        XCTAssertFalse(matched.map(\.name).contains("qr"), "「验证码」不应命中 qr")
    }

    // MARK: - 场景2：前缀严格分隔（qrcode 不被 qr 短前缀切）
    // 注：用一个只含 "qr" keyword 的 manifest 验证短前缀严格分隔；
    // qrLikePlugins 含完整 keyword "qrcode"，qrcode 会被长前缀命中（见 test_长前缀优先）。

    func test_qrcode_不被qr短前缀切() {
        // 仅 "qr" keyword，qrcode 后跟 'c'（非分隔符）→ 不命中
        let qrShortOnly = [makeCommandManifest(name: "qr", keywords: ["qr"])]
        let matched = LauncherRouter.commandPrefixMatched(query: "qrcode", plugins: qrShortOnly)
        XCTAssertFalse(matched.map(\.name).contains("qr"), "「qrcode」不应被「qr」短前缀切中")
    }

    func test_qr_空格_命中qr() {
        let matched = LauncherRouter.commandPrefixMatched(query: "qr ", plugins: qrLikePlugins)
        XCTAssertTrue(matched.map(\.name).contains("qr"), "「qr 」（后接空格）应命中 qr")
    }

    func test_qr_纯前缀_命中qr() {
        // query 恰是 keyword 本身（行尾）→ 命中
        let matched = LauncherRouter.commandPrefixMatched(query: "qr", plugins: qrLikePlugins)
        XCTAssertTrue(matched.map(\.name).contains("qr"), "「qr」应命中 qr")
    }

    func test_qr_逗号_命中qr() {
        let matched = LauncherRouter.commandPrefixMatched(query: "qr,", plugins: qrLikePlugins)
        XCTAssertTrue(matched.map(\.name).contains("qr"), "「qr,」（后接标点）应命中 qr")
    }

    func test_qr_带参数_命中qr() {
        let matched = LauncherRouter.commandPrefixMatched(query: "qr https://example.com", plugins: qrLikePlugins)
        XCTAssertTrue(matched.map(\.name).contains("qr"), "「qr https://example.com」应命中 qr")
    }

    // MARK: - 场景3：单字根因保护（码 / 二维码 命中）

    func test_码_命中qr() {
        let matched = LauncherRouter.commandPrefixMatched(query: "码", plugins: qrLikePlugins)
        XCTAssertTrue(matched.map(\.name).contains("qr"), "「码」以「码」开头应命中 qr")
    }

    func test_二维码_命中qr() {
        let matched = LauncherRouter.commandPrefixMatched(query: "二维码", plugins: qrLikePlugins)
        XCTAssertTrue(matched.map(\.name).contains("qr"), "「二维码」以「二维码」开头应命中 qr")
    }

    func test_打码_不命中qr() {
        let matched = LauncherRouter.commandPrefixMatched(query: "打码", plugins: qrLikePlugins)
        XCTAssertFalse(matched.map(\.name).contains("qr"), "「打码」不以「码」开头不应命中 qr")
    }

    // MARK: - 场景12：纯函数基线（无副作用 / 大小写不敏感 / 保持原序）

    func test_大小写不敏感() {
        let matched = LauncherRouter.commandPrefixMatched(query: "QR https://x", plugins: qrLikePlugins)
        XCTAssertTrue(matched.map(\.name).contains("qr"), "「QR ...」大小写不敏感应命中 qr")
    }

    func test_多次调用同结果() {
        let r1 = LauncherRouter.commandPrefixMatched(query: "qr a", plugins: qrLikePlugins).map(\.name)
        let r2 = LauncherRouter.commandPrefixMatched(query: "qr a", plugins: qrLikePlugins).map(\.name)
        XCTAssertEqual(r1, r2, "纯函数：同输入多次调用结果恒等")
    }

    func test_保持plugins原序() {
        let plugins = [
            makeCommandManifest(name: "zeta", keywords: ["z"]),
            makeCommandManifest(name: "alpha", keywords: ["a"]),
            makeCommandManifest(name: "mid", keywords: ["m"])
        ]
        // 三个都不会同时被同一 query 命中；构造一个共享前缀 query
        let shared = [
            makeCommandManifest(name: "first", keywords: ["qq"]),
            makeCommandManifest(name: "second", keywords: ["qq"])
        ]
        let matched = LauncherRouter.commandPrefixMatched(query: "qq x", plugins: shared)
        XCTAssertEqual(matched.map(\.name), ["first", "second"], "应保持 plugins 原序（非打分排序）")
        _ = plugins  // unused guard
    }

    // MARK: - mode 过滤：仅 .command mode 命中

    func test_stdin_mode_不被命中() {
        let plugins: [PluginManifest] = [
            makeStdinManifest(name: "stdinQr", keywords: ["qr"])
        ]
        let matched = LauncherRouter.commandPrefixMatched(query: "qr x", plugins: plugins)
        XCTAssertTrue(matched.isEmpty, "stdin mode 插件不应被 commandPrefixMatched 命中")
    }

    // MARK: - 长前缀优先（避免短前缀误报）

    func test_长前缀优先_不因短前缀重复命中() {
        // qr keywords 含 "qr" 与 "qrcode"；query "qrcode" 应被 "qrcode" 切中（长前缀优先）→ 命中 qr
        // （命中结果只看 plugin，不看具体 kw；这里验证长前缀场景下不会因 "qr" 短前缀判定失败而漏命中）
        let matched = LauncherRouter.commandPrefixMatched(query: "qrcode", plugins: qrLikePlugins)
        // 注意：stripKeywordPrefix 长前缀优先，"qrcode" 完整匹配 keyword "qrcode"（行尾）→ 命中
        XCTAssertTrue(matched.map(\.name).contains("qr"), "「qrcode」应被长 keyword 「qrcode」命中")
    }

    // MARK: - 空输入 / 空 plugins 边界

    func test_空query_不命中() {
        let matched = LauncherRouter.commandPrefixMatched(query: "", plugins: qrLikePlugins)
        XCTAssertTrue(matched.isEmpty, "空 query 不应命中")
    }

    func test_空plugins_返回空() {
        let matched = LauncherRouter.commandPrefixMatched(query: "qr x", plugins: [])
        XCTAssertTrue(matched.isEmpty, "空 plugins 应返回空")
    }

    // MARK: - 多 plugin 命中（场景5 基线）

    func test_多plugin共享keyword_都命中() {
        let plugins = [
            makeCommandManifest(name: "qr", keywords: ["q"]),
            makeCommandManifest(name: "qzh", keywords: ["q"])
        ]
        let matched = LauncherRouter.commandPrefixMatched(query: "q xxx", plugins: plugins)
        XCTAssertEqual(Set(matched.map(\.name)), Set(["qr", "qzh"]), "共享 keyword 「q」的多 plugin 应都命中")
    }
}
