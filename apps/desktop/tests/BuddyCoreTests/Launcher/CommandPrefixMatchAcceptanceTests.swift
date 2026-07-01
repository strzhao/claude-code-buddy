import XCTest
@testable import BuddyCore

// MARK: - CommandPrefixMatchAcceptanceTests
//
// 红队验收测试（det-machine 频道）— commandPrefixMatched 纯函数
//
// 设计文档契约引用（state.md ## 契约规约 / ## 验收场景）：
//   C-PREFIX-MATCH：command 命中判断 = `commandPrefixMatched`（query 开头完整匹配某 keyword
//                   + 严格分隔符空白/标点/行尾），禁用 contains 反向匹配。
//   C-REUSE-STRIP ：命中与参数剥离均复用 stripKeywordPrefix 的分隔规则，单一真相源。
//   C-BACKCOMPAT-MANIFEST：不改 plugin.json schema；qr 的 keywords（含「码」）不动。
//
// 符号映射（QA 绑定，state.md:150）：
//   commandMatcherHits(input) = LauncherRouter.commandPrefixMatched(query:input, plugins:).map(\.name)
//
// TDD 红灯：LauncherRouter.commandPrefixMatched 由蓝队 T1 实现。此刻方法不存在 → 编译 fail 是预期的，
// 绝不放宽断言或注释掉让它过。
//
// command mode mock 必须用 JSON 解码 mode:"command"（契约 T7 / C9）：
//   便利 init PluginManifest(name:...) 硬编码 .stdin mode，会被 commandPrefixMatched 的
//   `if case .command = $0.modeConfig` 过滤掉，导致假阴性。

@MainActor
final class CommandPrefixMatchAcceptanceTests: XCTestCase {

    // MARK: - 场景1（P0·Happy·误触消除）：含「码」但非前缀不触发 command

    /// 场景1.P1 [det-machine]：输入「密码」→ 命中器返回空集
    /// assert: count == 0 && lockedCommand == nil
    ///   - commandPrefixMatched 是纯函数，不碰 LauncherManager.lockedCommand；
    ///     「lockedCommand == nil」由状态机测试（LockedCommandStateMachineAcceptanceTests）守护，
    ///     本测试断言纯函数不命中（count == 0）这一前置不变式。
    func test_scenario1_P1_密码_notMatched_count0() {
        let qr = makeQrCommandManifest()
        let plugins = [qr]

        let matched = LauncherRouter.commandPrefixMatched(query: "密码", plugins: plugins)

        XCTAssertEqual(matched.count, 0,
            "场景1.P1: 输入「密码」commandPrefixMatched 必须返回空集（count==0），实际 count=\(matched.count)")
    }

    /// 场景1.P2 [det-machine]：「代码」「验证码」不命中 qr
    /// assert: commandPrefixMatched("代码").contains("qr")==false && commandPrefixMatched("验证码").contains("qr")==false
    func test_scenario1_P2_代码验证码_notContainsQr() {
        let qr = makeQrCommandManifest()
        let plugins = [qr]

        let byName1 = LauncherRouter.commandPrefixMatched(query: "代码", plugins: plugins).map(\.name)
        let byName2 = LauncherRouter.commandPrefixMatched(query: "验证码", plugins: plugins).map(\.name)

        XCTAssertFalse(byName1.contains("qr"),
            "场景1.P2: 输入「代码」命中列表不得包含 qr（前缀「码」未在开头，C-PREFIX-MATCH）")
        XCTAssertFalse(byName2.contains("qr"),
            "场景1.P2: 输入「验证码」命中列表不得包含 qr")
    }

    // MARK: - 场景2（P0·Edge·前缀严格分隔）：「qrcode」不被「qr」切

    /// 场景2.P1 [det-machine]：「qrcode」qr 后紧跟 'c'，不命中
    /// assert: commandPrefixMatched("qrcode").contains("qr")==false
    /// Mutation 5 问：若分隔符逻辑被改成「只要 hasPrefix 就命中」，此断言会失败（qrcode 含 qr 前缀但无分隔）。
    func test_scenario2_P1_qrcode_notMatchedQr() {
        let qr = makeQrCommandManifest()
        let plugins = [qr]

        let byName = LauncherRouter.commandPrefixMatched(query: "qrcode", plugins: plugins).map(\.name)

        XCTAssertFalse(byName.contains("qr"),
            "场景2.P1: 「qrcode」中 qr 后紧跟 'c'（非分隔符）必须不命中 qr，实际 contains(qr)=\(byName.contains("qr"))")
    }

    /// 场景2.P2 [det-machine]：「qr 」「qr」「qr,」三者命中 qr
    /// assert: 三者 commandPrefixMatched.contains("qr")==true
    ///   - 「qr 」(后跟空白)、「qr」(行尾)、「qr,」(后跟标点逗号) 均满足严格分隔符。
    func test_scenario2_P2_qrSpace_qr_qrComma_allMatched() {
        let qr = makeQrCommandManifest()
        let plugins = [qr]

        for q in ["qr ", "qr", "qr,"] {
            let byName = LauncherRouter.commandPrefixMatched(query: q, plugins: plugins).map(\.name)
            XCTAssertTrue(byName.contains("qr"),
                "场景2.P2: 输入「\(q)」必须命中 qr（keyword 后为分隔符/行尾），实际 contains(qr)=\(byName.contains("qr"))")
        }
    }

    // MARK: - 场景3（P0·Edge·单字根因保护）：非「码」开头不命中

    /// 场景3.P1 [det-machine]：「码」命中 qr；「密码」「打码」不命中
    /// assert: commandPrefixMatched("码").contains("qr")==true && commandPrefixMatched("密码"/"打码").contains("qr")==false
    ///   - qr 的 keywords 含单字「码」（plugin.json schema 不动，C-BACKCOMPAT-MANIFEST）。
    ///     「码」本身即完整 keyword + 行尾 → 命中；「密码」「打码」前缀不是「码」→ 不命中。
    func test_scenario3_P1_码_matches_密码打码_notMatches() {
        let qr = makeQrCommandManifest()
        let plugins = [qr]

        let maHit = LauncherRouter.commandPrefixMatched(query: "码", plugins: plugins).map(\.name)
        let miMaHit = LauncherRouter.commandPrefixMatched(query: "密码", plugins: plugins).map(\.name)
        let daMaHit = LauncherRouter.commandPrefixMatched(query: "打码", plugins: plugins).map(\.name)

        XCTAssertTrue(maHit.contains("qr"),
            "场景3.P1: 输入「码」（qr keyword 之一）必须命中 qr，实际 contains(qr)=\(maHit.contains("qr"))")
        XCTAssertFalse(miMaHit.contains("qr"),
            "场景3.P1: 输入「密码」不得命中 qr（前缀非「码」），实际 contains(qr)=\(miMaHit.contains("qr"))")
        XCTAssertFalse(daMaHit.contains("qr"),
            "场景3.P1: 输入「打码」不得命中 qr，实际 contains(qr)=\(daMaHit.contains("qr"))")
    }

    // MARK: - 场景12（P3·det-machine·纯函数基线）：同输入恒等无副作用

    /// 场景12.P1 [det-machine]：同输入多次调用逐字节同结果，无 IO/子进程副作用
    /// assert: commandPrefixMatched(X) 恒等 && 无 IO/子进程
    ///   - 纯函数性：N 次调用结果相同（Equatable PluginManifest 比对）。
    ///   - 「无 IO/子进程」由 spy 在状态机测试覆盖；本测试断言返回值稳定性（pure 等价性）。
    func test_scenario12_P1_sameInput_idempotent_pure() {
        let qr = makeQrCommandManifest()
        let plugins = [qr]

        let input = "qr https://example.com"
        let first = LauncherRouter.commandPrefixMatched(query: input, plugins: plugins)
        // 多次调用，每次新建 plugins 数组引用以排除可变缓存嫌疑
        let second = LauncherRouter.commandPrefixMatched(query: input, plugins: [qr])
        let third = LauncherRouter.commandPrefixMatched(query: input, plugins: [qr])

        XCTAssertEqual(first, second,
            "场景12.P1: 同输入「\(input)」多次调用结果必须逐字节相等（first==second）")
        XCTAssertEqual(second, third,
            "场景12.P1: 同输入「\(input)」多次调用结果必须逐字节相等（second==third）")

        // 同一输入不应产生不同命中集合大小（防内部状态泄漏）
        let counts = Set([
            LauncherRouter.commandPrefixMatched(query: input, plugins: plugins).count,
            LauncherRouter.commandPrefixMatched(query: input, plugins: plugins).count,
            LauncherRouter.commandPrefixMatched(query: input, plugins: plugins).count
        ])
        XCTAssertEqual(counts.count, 1,
            "场景12.P1: 同输入连续 3 次调用的命中数集合必须仅 1 个元素（无状态泄漏），实际 counts=\(counts)")
    }

    // MARK: - 补充：多 keyword 命中 / 非命令 mode 过滤（C9 守护）

    /// 「二维码」命中 qr（qr 的 keywords 含「二维码」）— 与场景3「码」命中互补，验证多 keyword 模型。
    func test_scenario2_supplement_二维码_matchesQr() {
        let qr = makeQrCommandManifest()
        let plugins = [qr]

        let byName = LauncherRouter.commandPrefixMatched(query: "二维码 https://x", plugins: plugins).map(\.name)
        XCTAssertTrue(byName.contains("qr"),
            "「二维码」是 qr 的 keyword 之一，命中列表必须含 qr")
    }

    /// stdin/prompt mode 插件不进 commandPrefixMatched（C-SCOPE-COMMAND-ONLY / C9）。
    /// 用 keyword 相同的 stdin + prompt mock 验证 mode 过滤（禁便利 init）。
    func test_supplement_stdinPromptMode_filteredOut() {
        let stdin = makeStdinManifest(name: "stdin-plug", keywords: ["qr"])
        let prompt = makePromptManifest(name: "prompt-plug", keywords: ["qr"])
        let plugins = [stdin, prompt]

        let byName = LauncherRouter.commandPrefixMatched(query: "qr arg", plugins: plugins).map(\.name)

        XCTAssertFalse(byName.contains("stdin-plug"),
            "C-SCOPE-COMMAND-ONLY: stdin mode 插件不得进 commandPrefixMatched 命中集")
        XCTAssertFalse(byName.contains("prompt-plug"),
            "C-SCOPE-COMMAND-ONLY: prompt mode 插件不得进 commandPrefixMatched 命中集")
        XCTAssertTrue(byName.isEmpty,
            "仅 stdin/prompt 候选时命中集必须为空（command 子集为空）")
    }

    /// 多 command 命中保持 plugins 原序（C-PREFIX-MATCH：返回 [PluginManifest]，保持原序）。
    func test_supplement_multipleCommands_preserveOrder() {
        // 两 command 插件共享 keyword "q"，构造多命中
        let qa = makeCommandManifest(name: "qa", keywords: ["q"])
        let qb = makeCommandManifest(name: "qb", keywords: ["q"])
        let plugins = [qa, qb]

        let matched = LauncherRouter.commandPrefixMatched(query: "q arg", plugins: plugins)

        XCTAssertEqual(matched.count, 2,
            "两 command 插件共享 keyword「q」时命中数必须为 2（多命中场景5 前置）")
        XCTAssertEqual(matched.map(\.name), ["qa", "qb"],
            "C-PREFIX-MATCH: 命中结果必须保持 plugins 原序 [qa,qb]，实际=\(matched.map(\.name))")
    }

    // MARK: - 辅助：构造 manifest（command mode 必须用 JSON 解码，禁便利 init）

    /// qr 插件 mock：keywords 含 ["qr", "二维码", "码"]（镜像 buddy-official-plugins/plugins/qr/plugin.json:6 schema）
    private func makeQrCommandManifest() -> PluginManifest {
        decodeManifest(name: "qr", keywords: ["qr", "二维码", "码"], mode: "command", cmd: "echo")
    }

    private func makeCommandManifest(name: String, keywords: [String]) -> PluginManifest {
        decodeManifest(name: name, keywords: keywords, mode: "command", cmd: "echo")
    }

    private func makeStdinManifest(name: String, keywords: [String]) -> PluginManifest {
        decodeManifest(name: name, keywords: keywords, mode: "stdin", cmd: "echo")
    }

    private func makePromptManifest(name: String, keywords: [String]) -> PluginManifest {
        var json: [String: Any] = [
            "name": name,
            "version": "0.0.1-test",
            "description": "test prompt plugin",
            "keywords": keywords,
            "mode": "prompt",
            "systemPrompt": "x",
            "maxIterations": 1,
            "autoCopyToClipboard": false
        ]
        if let manifest = try? JSONDecoder().decode(PluginManifest.self, from: try JSONSerialization.data(withJSONObject: json)) {
            return manifest
        }
        json["mode"] = "stdin"
        json["cmd"] = "echo"
        return try! JSONDecoder().decode(PluginManifest.self, from: try JSONSerialization.data(withJSONObject: json))
    }

    private func decodeManifest(name: String, keywords: [String], mode: String, cmd: String) -> PluginManifest {
        let json: [String: Any] = [
            "name": name,
            "version": "0.0.1-test",
            "description": "test \(mode) plugin",
            "keywords": keywords,
            "mode": mode,
            "cmd": cmd,
            "args": [] as [String]
        ]
        return try! JSONDecoder().decode(PluginManifest.self, from: try JSONSerialization.data(withJSONObject: json))
    }
}
