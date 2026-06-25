import XCTest
@testable import BuddyCore

// MARK: - GitMonorepoPluginAcceptanceTests
//
// 红队验收测试（社区插件 git 化，2026-06-24）
//
// 覆盖契约：C1 / C1.1 / C3 / C6 / C7 / C10 + 跨系统数据流（source 双轨转换）
// 覆盖谓词：B1 / B3（部分）/ C6 TOFU / C7 同 codepath / C10 默认 URL / C3 双轨 source
//
// 红队红线：不读 Launcher/ 下任何实现源码（MarketplaceManager/MarketplaceManifest/
// PluginSourceResolver/TrustStore/QueryHandler），仅依据 state.md 的
// 「设计文档 + 契约规约 C1-C12 + 验收场景 P1-P13」黑盒断言。
//
// 隔离：所有 trust / marketplace 文件写 NSTemporaryDirectory，不碰真实 ~/.buddy/。

final class GitMonorepoPluginAcceptanceTests: XCTestCase {

    // MARK: - Fixtures / Helpers

    private func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    private func makeTmpDir(prefix: String = "GitMonorepoAcc") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeExecutable(in dir: URL,
                                 name: String = "run.sh",
                                 content: String = "#!/bin/sh\necho hi") throws -> URL {
        let exe = dir.appendingPathComponent(name)
        try content.write(to: exe, atomically: true, encoding: .utf8)
        return exe
    }

    private func makeStdinManifest(name: String = "gitmono-plugin",
                                   cmd: String = "./run.sh",
                                   args: [String] = []) -> PluginManifest {
        PluginManifest(
            name: name,
            version: "0.1.0",
            description: "git 化验收插件",
            keywords: ["gitmono"],
            cmd: cmd,
            args: args,
            env: nil,
            timeout: 10,
            requiredPath: nil
        )
    }

    // MARK: - C1.1 / B1: gitSubdir source 缺 sha 字段能 decode（不抛 keyNotFound）

    /// 契约 C1.1：gitSubdir 的 sha 改 String?，monorepo marketplace.json 的 gitSubdir
    /// source 不填 sha（仅 ref:"main"）。缺 sha 时 decode 必须**不抛 keyNotFound**，
    /// 得到 `sha == nil`。
    ///
    /// 对应 P#：B1 修复的核心断言（det-machine）。
    /// Mutation-Survival：若实现把 sha 改回 String（非可选），本测试 keyNotFound 即挂。
    func test_C1_1_gitSubdir_withoutSha_decodesWithoutKeyNotFound() throws {
        let json = """
        {"source":"git-subdir","url":"https://github.com/stringzhao/buddy-official-plugins","path":"plugins/hello","ref":"main"}
        """
        let decoded = try decode(PluginSourceConfig.self, from: json)

        guard case .gitSubdir(let url, let path, let ref, let sha) = decoded else {
            return XCTFail("期望 .gitSubdir，实际: \(decoded)")
        }
        XCTAssertEqual(url, "https://github.com/stringzhao/buddy-official-plugins")
        XCTAssertEqual(path, "plugins/hello")
        XCTAssertEqual(ref, "main")
        XCTAssertNil(sha, "缺 sha 字段时关联值必须为 nil（C1.1：sha 改 String?）")
    }

    // MARK: - C1.1 / B1: gitSubdir 有 sha 时仍走校验路径（镜像 gitURL 可选 sha 语义）

    /// 契约 C1.1：gitSubdir 有 sha 时 decode 拿到非 nil sha，行为与 gitURL 可选 sha 镜像。
    /// 即「sha 可选 ≠ sha 禁用」——填了仍 round-trip 保留。
    func test_C1_1_gitSubdir_withSha_keepsShaForVerification() throws {
        let json = """
        {"source":"git-subdir","url":"https://github.com/x/y.git","path":"plugins/z","ref":"v1.0.0","sha":"abc123def456"}
        """
        let decoded = try decode(PluginSourceConfig.self, from: json)

        guard case .gitSubdir(_, _, _, let sha) = decoded else {
            return XCTFail("期望 .gitSubdir，实际: \(decoded)")
        }
        XCTAssertEqual(sha, "abc123def456", "填了 sha 必须保留（可选 ≠ 禁用）")
    }

    // MARK: - C1.1: gitSubdir 无 sha → encode 不写 sha 字段（encodeIfPresent）

    /// 契约 C1.1 encode 侧：sha 为 nil 时 encode 输出**不含** "sha" 键（encodeIfPresent）。
    /// round-trip 后再 decode 仍得 nil。
    func test_C1_1_gitSubdir_nilSha_encodesWithoutShaKey() throws {
        let value = PluginSourceConfig.gitSubdir(
            url: "https://github.com/stringzhao/buddy-official-plugins",
            path: "plugins/qr",
            ref: "main",
            sha: nil
        )
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(value)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertFalse(json.contains("\"sha\""),
                       "sha 为 nil 时 encode 必须**不**输出 sha 键（encodeIfPresent），实际: \(json)")

        // round-trip
        let reDecoded = try JSONDecoder().decode(PluginSourceConfig.self, from: data)
        if case .gitSubdir(_, _, _, let sha) = reDecoded {
            XCTAssertNil(sha, "round-trip 后 sha 仍为 nil")
        } else {
            XCTFail("round-trip 后应仍是 .gitSubdir")
        }
    }

    // MARK: - C3: marketplace.json 双轨 source（localSubdir bundle / gitSubdir 远程）

    /// 契约 C3：bundle 内（fetch-plugins.sh 生成）source 为 localSubdir（`./plugins/<name>`）；
    /// 远程 monorepo source 为 gitSubdir（不填 sha）。
    /// 这是「source 在两形态间正确转换」的契约级断言。
    func test_C3_bundleSourceIsLocalSubdir_remoteSourceIsGitSubdir() throws {
        // bundle 形态（localSubdir，`./` 开头）
        let bundleJSON = """
        {"name":"hello","version":"0.1.0","description":"演示插件","author":{"name":"stringzhao"},"source":"./plugins/hello"}
        """
        let bundlePlugin = try decode(MarketplacePlugin.self, from: bundleJSON)
        XCTAssertEqual(bundlePlugin.source, .localSubdir(path: "./plugins/hello"),
                       "bundle 内 source 必须为 localSubdir 且以 ./ 开头（C3）")

        // 远程形态（gitSubdir，不填 sha）
        let remoteJSON = """
        {"name":"hello","version":"0.1.0","description":"演示插件","author":{"name":"stringzhao"},"source":{"source":"git-subdir","url":"https://github.com/stringzhao/buddy-official-plugins","path":"plugins/hello","ref":"main"}}
        """
        let remotePlugin = try decode(MarketplacePlugin.self, from: remoteJSON)
        guard case .gitSubdir(let url, let path, let ref, let sha) = remotePlugin.source else {
            return XCTFail("远程 source 必须为 gitSubdir（C3），实际: \(remotePlugin.source)")
        }
        XCTAssertEqual(url, "https://github.com/stringzhao/buddy-official-plugins")
        XCTAssertEqual(path, "plugins/hello")
        XCTAssertEqual(ref, "main")
        XCTAssertNil(sha, "远程 gitSubdir source 不填 sha（C1/C1.1）")
    }

    // MARK: - 跨系统数据流：gitSubdir → fetch 改写 → localSubdir 完整字段一致性

    /// 跨系统数据流谓词：marketplace.json source（gitSubdir）→ fetch 改写 → bundle（localSubdir）
    /// → seed → ~/.buddy/ 的字段一致性。本测试验证 source 在两形态间**无损**转换：
    /// 远程 gitSubdir(url, path=plugins/X, ref, sha=nil) → bundle localSubdir(./plugins/X)
    /// 关键不变量：path 的 `<name>` 段与 localSubdir 的 `<name>` 段必须一致（fetch 改写的核心）。
    func test_crossFlow_gitSubdirToLocalSubdir_nameSegmentPreserved() throws {
        // 远程 monorepo 三个官方插件 source（对齐设计文档 marketplace.json 样例）
        let names = ["hello", "qr", "qzh"]
        for name in names {
            let remoteJSON = """
            {"name":"\(name)","version":"0.1.0","description":"d","author":{"name":"stringzhao"},"source":{"source":"git-subdir","url":"https://github.com/stringzhao/buddy-official-plugins","path":"plugins/\(name)","ref":"main"}}
            """
            let remote = try decode(MarketplacePlugin.self, from: remoteJSON)
            guard case .gitSubdir(_, let path, _, _) = remote.source else {
                return XCTFail("\(name) 远程 source 应为 gitSubdir")
            }

            // fetch 改写规则（fetch-plugins.sh 设计）：path=plugins/<name> → ./plugins/<name>
            let rewrittenPath = "./" + path
            let bundleJSON = """
            {"name":"\(name)","version":"0.1.0","description":"d","author":{"name":"stringzhao"},"source":"\(rewrittenPath)"}
            """
            let bundle = try decode(MarketplacePlugin.self, from: bundleJSON)
            XCTAssertEqual(bundle.source, .localSubdir(path: rewrittenPath),
                           "\(name) bundle source 改写后必须为 ./plugins/\(name)")

            // 关键不变量：name 段一致
            XCTAssertTrue(rewrittenPath.hasSuffix("/\(name)"),
                          "改写后 path 必须以 /\(name) 结尾")
            XCTAssertEqual(bundle.name, name, "plugin name 不变")
        }
    }

    // MARK: - C6 TOFU: isEverTrusted(pluginName) 有该 name 记录即 true（不看 exe hash）

    /// 契约 C6：`isEverTrusted(pluginName) -> Bool` —— trust store 中存在该 pluginName 的
    /// 任意记录即返回 true（不看 exe hash）。
    ///
    /// 对应 P#：C6 TOFU 严格首次的核心谓词。
    /// 实现方式：直接构造 TrustRecord(pluginName:) 写入 trust store，调 isEverTrusted 必须返回 true。
    /// Mutation-Survival：若 isEverTrusted 错误地复用 isTrusted（含 exe hash 比对），
    /// 因为我们写入的 trustKey 与「当前 exe hash 计算的 trustKey」不同，会返回 false → 测试挂。
    func test_C6_isEverTrusted_trueWhenNameRecordExists_regardlessOfExeHash() throws {
        let dir = try makeTmpDir(prefix: "C6-name-only")
        defer { try? FileManager.default.removeItem(at: dir) }

        let trustFile = dir.appendingPathComponent("launcher-trust.json")
        let store = TrustStore(file: trustFile)

        // 直接写一条「名字匹配、但 trustKey 是任意伪造值（不可能匹配真实 exe hash）」的记录
        let fakeKey = "stdin:" + String(repeating: "0", count: 64)
        try store.addRecord(TrustRecord(
            trustKey: fakeKey,
            pluginName: "ever-trusted-plugin",
            approvedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))

        // isEverTrusted 只看 pluginName 有无记录，不看 exe hash
        XCTAssertTrue(store.isEverTrusted("ever-trusted-plugin"),
                      "存在该 pluginName 记录时 isEverTrusted 必须返回 true（C6：不看 exe hash）")
        XCTAssertFalse(store.isEverTrusted("never-trusted-plugin"),
                       "无记录的 pluginName 必须返回 false")
    }

    // MARK: - C6 TOFU: 已信任插件 exe 变化后 checkAndPrompt 放行（不弹）

    /// 契约 C6 / 子设计 5：`checkAndPrompt` 只在 `isEverTrusted(pluginName)==false` 时弹框；
    /// true 时直接放行不校验 exe hash。
    ///
    /// 对应 P#：P8（已信任官方插件更新后不弹框）/ P9（第三方 git 源更新后同样不弹框）的单元可验证部分。
    /// 本测试用注入 trustStore seam 验证：approve 一次（任意 exe）→ 改 exe → isEverTrusted 仍 true。
    /// （真实 checkAndPrompt 弹框属 NSAlert UI，留 REAL_SCENARIO 给 QA Tier 1.5。）
    func test_C6_isEverTrusted_remainsTrue_afterExeChanges() throws {
        let dir = try makeTmpDir(prefix: "C6-exe-change")
        defer { try? FileManager.default.removeItem(at: dir) }

        let exe = try writeExecutable(in: dir, content: "#!/bin/sh\necho v1")
        let trustFile = dir.appendingPathComponent("launcher-trust.json")
        let store = TrustStore(file: trustFile)
        let manifest = makeStdinManifest(name: "updatable-plugin")

        // 首次信任
        XCTAssertFalse(store.isEverTrusted("updatable-plugin"), "approve 前 isEverTrusted 应 false")
        try store.approve(manifest, executablePath: exe)
        XCTAssertTrue(store.isEverTrusted("updatable-plugin"),
                      "approve 后 isEverTrusted 应 true")

        // exe 内容变化（模拟插件更新覆盖）
        try "#!/bin/sh\necho v2-new-version".write(to: exe, atomically: true, encoding: .utf8)

        // 关键断言：isEverTrusted 仍 true（C6：不看 exe hash）
        XCTAssertTrue(store.isEverTrusted("updatable-plugin"),
                      "exe 变化后 isEverTrusted 必须**仍**为 true（C6 TOFU 严格首次，更新免提示）")

        // 对照：旧 isTrusted（含 exe hash）此时应 false —— 证明 isEverTrusted 与 isTrusted 语义不同
        XCTAssertFalse(store.isTrusted(manifest, executablePath: exe),
                       "exe 变化后旧 isTrusted（含 exe hash）应 false —— 反衬 isEverTrusted 是新语义")
    }

    // MARK: - C7: 官方源与第三方 git 源 trust 判定走同一 isEverTrusted codepath

    /// 契约 C7：官方与第三方插件 trust 判定均不区分 source 类型，走同一 isEverTrusted。
    /// 本测试验证 isEverTrusted 是「按 pluginName 查」的纯函数，**签名不含 source 参数**——
    /// 即调用方无法、也不需要传 source 类型，从 API 层面保证同 codepath。
    ///
    /// 对应 P#：P9（第三方 git 源更新后同样不弹框，与 P8 行为一致）。
    func test_C7_isEverTrusted_signatureTakesOnlyName_noSourceTypeParam() throws {
        // isEverTrusted 签名契约：只接受 pluginName，不区分 source。
        // 用两个不同 source 的「同名」插件验证：只要 pluginName 一致，trust 判定一致。
        let dir = try makeTmpDir(prefix: "C7-same-codepath")
        defer { try? FileManager.default.removeItem(at: dir) }

        let trustFile = dir.appendingPathComponent("launcher-trust.json")
        let store = TrustStore(file: trustFile)

        // 写入一条 third-party-git-plugin 的信任记录（模拟第三方插件首次信任）
        try store.addRecord(TrustRecord(
            trustKey: "stdin:" + String(repeating: "a", count: 64),
            pluginName: "shared-name",
            approvedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))

        // 同一 pluginName，无论是官方还是第三方来源，isEverTrusted 返回值一致
        let officialResult = store.isEverTrusted("shared-name")
        let thirdPartyResult = store.isEverTrusted("shared-name")
        XCTAssertEqual(officialResult, thirdPartyResult,
                       "同一 pluginName 的 isEverTrusted 必须一致（C7：不区分 source 类型）")
        XCTAssertTrue(officialResult, "有记录即 true，无论来源")
    }

    // MARK: - C10: MarketplaceManager 默认 remoteURL 指向 monorepo（非旧 claude-code-buddy 仓库）

    /// 契约 C10：`MarketplaceManager.productionRemoteURLString` 改指 monorepo raw URL
    /// `https://raw.githubusercontent.com/stringzhao/buddy-official-plugins/main/marketplace.json`。
    ///
    /// 对应 P#：C10 B2 修复的核心断言（det-machine）。
    /// Mutation-Survival：若实现忘改 productionRemoteURLString（仍指旧仓库），本测试挂。
    ///
    /// CONTRACT_AMBIGUOUS: productionRemoteURLString 当前是 private static（见现有源）。
    /// 契约 C10 要求改其**值**但未明确改**可见性**。本测试假设蓝队将其改为 internal
    /// （或提供 internal getter）以支持测试验证。若蓝队保持 private，此测试编译失败——
    /// 此时蓝队需将 productionRemoteURLString 改 internal（@testable import 可访问），
    /// 或提供一个 internal static computed property 暴露默认 URL。
    func test_C10_defaultRemoteURL_pointsToMonorepo_notLegacyRepo() {
        let defaultURL = MarketplaceManager.productionRemoteURLString

        XCTAssertTrue(defaultURL.contains("buddy-official-plugins"),
                      "默认 remoteURL 必须指向 buddy-official-plugins monorepo（C10），实际: \(defaultURL)")
        XCTAssertTrue(defaultURL.contains("raw.githubusercontent.com"),
                      "默认 remoteURL 必须是 GitHub Raw URL（C10），实际: \(defaultURL)")
        XCTAssertTrue(defaultURL.hasSuffix("/marketplace.json"),
                      "默认 remoteURL 必须指向 marketplace.json（C10），实际: \(defaultURL)")

        // 反向断言：不得含旧仓库路径
        XCTAssertFalse(defaultURL.contains("/claude-code-buddy/"),
                       "默认 remoteURL 不得指向旧 claude-code-buddy 仓库（C10 B2 迁移），实际: \(defaultURL)")
    }

    // MARK: - C1: officialPluginsRepoURL 常量含 monorepo 标识

    /// 契约 C1：`LauncherConstants.officialPluginsRepoURL` + `officialMarketplaceRawURL`
    /// 为硬编码常量，指向 buddy-official-plugins monorepo。
    /// 本测试验证两个常量都存在且指向正确仓库。
    func test_C1_officialRepoConstants_pointToMonorepo() {
        let repoURL = LauncherConstants.officialPluginsRepoURL
        let rawURL = LauncherConstants.officialMarketplaceRawURL

        XCTAssertTrue(repoURL.contains("buddy-official-plugins"),
                      "officialPluginsRepoURL 必须含 buddy-official-plugins（C1），实际: \(repoURL)")
        XCTAssertTrue(rawURL.contains("buddy-official-plugins"),
                      "officialMarketplaceRawURL 必须含 buddy-official-plugins（C1），实际: \(rawURL)")
        XCTAssertTrue(rawURL.contains("raw.githubusercontent.com"),
                      "officialMarketplaceRawURL 必须是 raw URL（C1），实际: \(rawURL)")
    }
}
