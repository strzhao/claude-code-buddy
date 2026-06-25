import XCTest
@testable import BuddyCore

// MARK: - OfficialPluginGitRealScenarioTests
//
// 红队验收测试（社区插件 git 化，2026-06-24）
//
// 本文件覆盖「真实集成场景谓词」——这些依赖真实 make bundle / 网络 / NSAlert / sync debounce，
// 单测无法覆盖，以测试骨架 + REAL_SCENARIO 注释形式留给 QA Tier 1.5 真机验证。
//
// 每个测试方法包含：
//   1. 契约级硬断言（能单测的部分，守护契约不被破坏）
//   2. REAL_SCENARIO 注释（QA 驱动方式 + 期望，真机验证）
//
// 覆盖谓词：P1 / P2 / P3 / P5 / P6 / P7 / P8 / P9 / P10 / P11 / P12 / P13

final class OfficialPluginGitRealScenarioTests: XCTestCase {

    private func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    // MARK: - P1 [det] bundle 内含官方插件完整产物

    /// 谓词 P1：`make bundle` 后 `.app/.../Marketplace/plugins/{hello,qr,qzh}/` 下
    /// plugin.json 可解析 + 每目录至少 1 个 `-x` 可执行文件。
    ///
    /// 单测可验证：bundle 内 marketplace.json 的 source 为 localSubdir（C3 bundle 形态）。
    /// 真机验证：make bundle 产物完整性 + 可执行文件权限。
    func test_P1_bundleContainsOfficialPlugins_withExecutable() throws {
        // 契约级：bundle marketplace.json 的 source 必须是 localSubdir（C3）
        // REAL_SCENARIO: 留 QA Tier 1.5 真机验证，驱动方式：
        //   1. make -C apps/desktop bundle
        //   2. 检查 .app/Contents/Resources/ClaudeCodeBuddy_BuddyCore.bundle/Marketplace/plugins/{hello,qr,qzh}/
        //      每目录下 plugin.json 可 JSON 解析
        //   3. 每目录至少 1 个 -x 可执行文件（hello/hello.sh 或 run.sh；qr/qr-gen；qzh/qzh-exec）
        //      命令：find <bundle>/Marketplace/plugins -name 'plugin.json' | wc -l == 3
        //      命令：find <bundle>/Marketplace/plugins -type f -perm +111 | wc -l >= 3
        //   期望：3 个 plugin.json + 每目录 ≥1 可执行

        // 单测守护：bundle 形态 source 必须是 localSubdir
        let bundleSourceJSON = "\"./plugins/hello\""
        let decoded = try decode(PluginSourceConfig.self, from: bundleSourceJSON)
        XCTAssertEqual(decoded, .localSubdir(path: "./plugins/hello"),
                       "bundle 内 source 必须为 localSubdir（C3，P1 前提）")
    }

    // MARK: - P2 [det] app 仓库插件源目录 gitignore

    /// 谓词 P2：`git check-ignore` 对 `plugins/hello/plugin.json` 退出 0；
    /// `git ls-files plugins/` 仅 `.gitkeep`。
    ///
    /// 单测无法验证 git 状态（需 repo 上下文），REAL_SCENARIO 留 QA。
    func test_P2_appRepoPluginsDir_isGitignored_singleSourceOfTruth() {
        // REAL_SCENARIO: 留 QA Tier 1.5 真机验证，驱动方式：
        //   1. cd apps/desktop
        //   2. git check-ignore Sources/ClaudeCodeBuddy/Marketplace/plugins/hello/plugin.json
        //      期望：退出码 0（被 ignore），stdout 输出该路径
        //   3. git ls-files Sources/ClaudeCodeBuddy/Marketplace/plugins/
        //      期望：仅输出 .gitkeep（单一真源，源码在 monorepo）
        //   4. git status --porcelain Sources/ClaudeCodeBuddy/Marketplace/plugins/
        //      期望：CLEAN（无未跟踪的插件源码）
        //
        // 契约 C2：plugins/ 整目录 gitignored（保留 .gitkeep），插件源只在 monorepo。
        // 此处无单测断言（git 状态依赖 repo），留 QA 真机验证。
    }

    // MARK: - P3 [det] 断网首启官方插件可加载

    /// 谓词 P3：断网 + 空 launcher-plugins 首启 → `buddy launcher list` 见 hello/qr/qzh，
    /// version 非空；`launcher-plugins/hello/` 有 plugin.json + 可执行文件。
    ///
    /// 单测守护：bundle marketplace.json 含 3 个官方插件（seed 来源）。
    /// 真机验证：断网首启 + buddy launcher list。
    func test_P3_offlineFirstLaunch_loadsBundledPlugins() throws {
        // 契约级：bundle marketplace.json 含 hello/qr/qzh（seed 来源，断网首启依赖）
        // REAL_SCENARIO: 留 QA Tier 1.5 真机验证，驱动方式：
        //   1. 关闭网络（Wi-Fi off / 拔网线）
        //   2. rm -rf ~/.buddy/launcher-plugins（清空运行时副本）
        //   3. 启动 app（open ClaudeCodeBuddy.app）
        //   4. buddy launcher list
        //      期望：输出含 hello/qr/qzh，version 非空
        //   5. ls ~/.buddy/launcher-plugins/hello/
        //      期望：plugin.json + 可执行文件（hello.sh / run.sh）

        // 单测守护：bundle 形态的 3 个插件 source 都是 localSubdir（首启 seed 依赖 bundle 就位）
        for name in ["hello", "qr", "qzh"] {
            let json = "\"./plugins/\(name)\""
            let decoded = try decode(PluginSourceConfig.self, from: json)
            XCTAssertEqual(decoded, .localSubdir(path: "./plugins/\(name)"),
                           "bundle 内 \(name) source 必须为 localSubdir（P3 首启 seed 前提）")
        }
    }

    // MARK: - P5 [det] 检测新版 + 开关 ON → 自动覆盖

    /// 谓词 P5：monorepo bump hello version + sync → inspect hello version 变化；
    /// sync 窗口内 log stream 无 trust/alert 关键字。
    func test_P5_autoUpdateON_detectsAndOverwrites_noTrustPrompt() {
        // REAL_SCENARIO: 留 QA Tier 1.5 真机验证，驱动方式：
        //   1. rm ~/.buddy/marketplace-meta.json（重置 sync debounce，I2）
        //   2. 默认 autoUpdate ON（C4 默认 true）
        //   3. cd <monorepo> && 改 plugins/hello/plugin.json version 0.1.0 → 0.2.0 && git push
        //   4. 触发 sync（等 1h 窗口 或 buddy launcher marketplace sync 手动触发）
        //   5. buddy launcher inspect hello → version == "0.2.0"（自动覆盖）
        //   6. sync 窗口内 log stream --predicate 'processImagePath CONTAINS "ClaudeCodeBuddy"'
        //      grep -i 'trust\|alert\|NSAlert' → 期望**无输出**（C5：绕过 checkAndPrompt）
        //
        // 单测守护在 MarketplaceAutoUpdateAcceptanceTests.test_C5_autoUpdateON_syncOverwritesUpdatedPlugin
        // （autoUpdate store ON 是覆盖前提）。
    }

    // MARK: - P6 [det] 开关 OFF → 不覆盖

    /// 谓词 P6：autoUpdate OFF + monorepo bump qr + sync → inspect qr version 不变。
    func test_P6_autoUpdateOFF_doesNotOverwrite() {
        // REAL_SCENARIO: 留 QA Tier 1.5 真机验证，驱动方式：
        //   1. rm ~/.buddy/marketplace-meta.json（重置 sync debounce，I2）
        //   2. 关闭 autoUpdate（设置页 switch OFF 或 defaults write buddy.launcher.marketplace.autoUpdate false）
        //   3. cd <monorepo> && 改 plugins/qr/plugin.json version 0.1.0 → 0.2.0 && git push
        //   4. 触发 sync
        //   5. buddy launcher inspect qr → version **仍为 0.1.0**（C5：OFF 不覆盖）
        //      marketplace cache（~/.buddy/marketplace.json）可能更新 version，但
        //      运行时副本（~/.buddy/launcher-plugins/qr/）不变
        //
        // 单测守护在 MarketplaceAutoUpdateAcceptanceTests.test_C5_autoUpdateOFF_syncDoesNotOverwrite。
    }

    // MARK: - P7 [human+det] 首次执行弹信任框 + 落记录

    /// 谓词 P7：无 trust 记录的插件首次 run → 弹 NSAlert（人工确认）；
    /// trust.json records +1，新记录 pluginName 匹配、trustKey 为 64 字符 hex。
    func test_P7_firstRun_promptsTrust_andWritesRecord() throws {
        // REAL_SCENARIO: 留 QA Tier 1.5 真机验证（含人工确认 NSAlert），驱动方式：
        //   1. rm ~/.buddy/launcher-trust.json（清空信任记录）
        //   2. buddy launcher run hello --input "test" [--json]
        //   3. 人工确认：弹出 NSAlert（首次执行信任框）
        //   4. 点击「信任」
        //   5. cat ~/.buddy/launcher-trust.json
        //      期望：records 数组 +1，新记录 pluginName == "hello"，
        //           trustKey 为 "<mode>:" + 64 字符 lowercase hex（stdin: 前缀 + sha256）
        //   6. buddy launcher run hello --input "test" 再次执行
        //      期望：**不弹框**（C6：isEverTrusted 已 true）

        // 单测守护（det 部分）：trustKey 格式（mode 前缀 + 64 hex）—— 已在
        // TrustStoreAcceptanceTests.test_SC02 覆盖。此处补 isEverTrusted 首次 false 的契约级断言。
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("P7-first-run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let trustFile = dir.appendingPathComponent("launcher-trust.json")
        let store = TrustStore(file: trustFile)

        // 首次：无记录 → isEverTrusted false（P7 首次弹框的前提）
        XCTAssertFalse(store.isEverTrusted("brand-new-plugin"),
                       "无记录的插件 isEverTrusted 必须 false（P7 首次弹框前提，C6）")
    }

    // MARK: - P8 [det] 已信任官方插件更新后不弹框

    /// 谓词 P8：hello 更新后 run → log stream 无 trust/alert；trust.json records 数不变；run 退出码 0。
    func test_P8_trustedOfficialPlugin_update_noRePrompt() throws {
        // REAL_SCENARIO: 留 QA Tier 1.5 真机验证，驱动方式：
        //   1. 确保 hello 已被信任（先 run 一次并确认 NSAlert）
        //   2. 触发 hello 更新（monorepo bump version + autoUpdate ON + sync，或手动重装）
        //   3. buddy launcher run hello --input "test"
        //      期望：退出码 0，**不弹框**
        //   4. log stream --predicate 'processImagePath CONTAINS "ClaudeCodeBuddy"' --level debug
        //      grep -i 'trust\|alert' → 期望**无输出**（C6：isEverTrusted 放行）
        //   5. cat ~/.buddy/launcher-trust.json | jq '.records | length'
        //      期望：与更新前相同（records 数不变，C6：不新增记录）

        // 单测守护在 GitMonorepoPluginAcceptanceTests.test_C6_isEverTrusted_remainsTrue_afterExeChanges
        // （exe 变化后 isEverTrusted 仍 true）。
    }

    // MARK: - P9 [det] 第三方 git 源更新后同样不弹框

    /// 谓词 P9：第三方插件首次信任后更新 run → 与 P8 行为一致（同 codepath）。
    func test_P9_thirdPartyGitSource_update_noRePrompt_sameAsOfficial() throws {
        // REAL_SCENARIO: 留 QA Tier 1.5 真机验证，驱动方式：
        //   1. buddy launcher add <user>/<repo>（第三方 git 源插件）
        //   2. buddy launcher run <third-party-plugin> --input "test" → 确认 NSAlert（首次）
        //   3. 触发第三方插件更新（远程仓库 push 新 version + sync）
        //   4. buddy launcher run <third-party-plugin> --input "test"
        //      期望：退出码 0，**不弹框**（与 P8 行为一致，C7：同 codepath）
        //   5. trust.json records 数不变

        // 单测守护在 GitMonorepoPluginAcceptanceTests.test_C7_isEverTrusted_signatureTakesOnlyName_noSourceTypeParam
        // （isEverTrusted 不区分 source 类型）。
    }

    // MARK: - P10 [det] 单一真源

    /// 谓词 P10：app 仓库 `git ls-files plugins/` 对源码输出空；monorepo 含 hello/qr/qzh。
    func test_P10_singleSourceOfTruth_monorepoOnly() {
        // REAL_SCENARIO: 留 QA Tier 1.5 真机验证，驱动方式：
        //   1. cd apps/desktop
        //   2. git ls-files Sources/ClaudeCodeBuddy/Marketplace/plugins/
        //      期望：仅输出 .gitkeep（或空），无任何 plugin.json / .sh / .swift 源码
        //   3. git log --oneline -- Sources/ClaudeCodeBuddy/Marketplace/plugins/ | head -1
        //      期望：最新提交语义为「移除/迁移」（如 "remove plugins, migrate to monorepo"）
        //   4. cd <monorepo> && ls plugins/
        //      期望：含 hello/qr/qzh 三个目录
        //
        // 契约 C2：plugins/ 整目录 gitignored，单一真源在 monorepo。
        // 无单测断言（git 状态），留 QA。
    }

    // MARK: - P11 [det] CLI 一致性

    /// 谓词 P11：`buddy launcher list/inspect` 的 name/version/summary 与 bundle 内 plugin.json 严格一致。
    func test_P11_cliListInspect_matchesBundlePluginJSON() {
        // REAL_SCENARIO: 留 QA Tier 1.5 真机验证，驱动方式：
        //   1. make bundle && open ClaudeCodeBuddy.app
        //   2. buddy launcher list --json
        //      期望：输出含 hello/qr/qzh，name/version 与 bundle 内 plugin.json 一致
        //   3. buddy launcher inspect hello --json
        //      期望：name/version/summary 字段与 bundle Marketplace/plugins/hello/plugin.json 严格一致
        //   4. diff <(buddy launcher inspect hello --json | jq '.name,.version,.summary') \
        //          <(jq '.name,.version,.summary' <bundle>/Marketplace/plugins/hello/plugin.json)
        //      期望：无 diff
        //
        // 无单测断言（依赖 CLI + bundle 产物），留 QA。
    }

    // MARK: - P12 [det] marketplace.json 双轨

    /// 谓词 P12：bundle 内 source 以 `./` 开头（localSubdir）；sync cache source 含 git URL（gitSubdir）；
    /// sourceLabel 两 case 不同。
    func test_P12_marketplaceDualTrack_sourceLabelDiffers() throws {
        // 契约级：bundle（localSubdir）与 sync cache（gitSubdir）source 形态不同
        // REAL_SCENARIO: 留 QA Tier 1.5 真机验证，驱动方式：
        //   1. make bundle
        //   2. cat <bundle>/Marketplace/marketplace.json | jq '.plugins[].source'
        //      期望：所有 source 以 "./" 开头（localSubdir，bundle 形态）
        //   3. 触发一次 sync（buddy launcher marketplace sync）
        //   4. cat ~/.buddy/marketplace.json | jq '.plugins[].source'
        //      期望：所有 source 含 git URL（gitSubdir，sync cache 形态）
        //   5. buddy launcher inspect hello → sourceLabel 应为 "git-subdir: ..."（与 bundle 的 "local-subdir: ..." 不同）

        // 单测守护：两种 source 形态可正确 decode 且不相等
        let bundleSource = try decode(PluginSourceConfig.self, from: "\"./plugins/hello\"")
        let remoteSource = try decode(PluginSourceConfig.self, from: """
        {"source":"git-subdir","url":"https://github.com/stringzhao/buddy-official-plugins","path":"plugins/hello","ref":"main"}
        """)

        XCTAssertNotEqual(bundleSource, remoteSource,
                          "bundle（localSubdir）与 sync cache（gitSubdir）source 必须不相等（P12 双轨）")

        if case .localSubdir(let path) = bundleSource {
            XCTAssertTrue(path.hasPrefix("./"),
                          "bundle source 必须以 ./ 开头（P12，C3）")
        } else {
            XCTFail("bundle source 应为 localSubdir")
        }

        if case .gitSubdir(let url, _, _, _) = remoteSource {
            XCTAssertTrue(url.contains("github.com"),
                          "sync cache source 必须含 git URL（P12，C3）")
        } else {
            XCTFail("sync cache source 应为 gitSubdir")
        }
    }

    // MARK: - P13 [det] fetch 失败兜底

    /// 谓词 P13：断网 `make bundle` → 有缓存退出 0 + stderr 含 fallback 警告 + bundle 完整；
    /// 无缓存无网络退出非 0 + 清晰错误 + 无半成品 bundle。
    func test_P13_fetchFailureFallback_cacheOrCleanError() {
        // REAL_SCENARIO: 留 QA Tier 1.5 真机验证，驱动方式：
        //
        // 场景 A（有缓存兜底）：
        //   1. 先联网 make bundle 一次（生成 .cache/buddy-plugins/）
        //   2. 关闭网络
        //   3. rm -rf Sources/ClaudeCodeBuddy/Marketplace/plugins/（清产物，强制重新 fetch）
        //   4. make bundle 2>&1 | tee /tmp/fetch.log
        //      期望：退出码 0，stderr 含 "fetch failed, using cache"（或类似 fallback 警告）
        //   5. 检查 bundle 完整：plugins/{hello,qr,qzh}/ 齐全（用缓存填充）
        //
        // 场景 B（无缓存无网络，清晰错误）：
        //   1. 关闭网络
        //   2. rm -rf .cache/buddy-plugins/ Sources/ClaudeCodeBuddy/Marketplace/plugins/
        //   3. make bundle 2>&1 | tee /tmp/fetch.log; echo "exit=$?"
        //      期望：退出码**非 0**，stderr 含清晰错误（如 "fetch failed: no network, no cache"）
        //   4. 检查无半成品：Sources/ClaudeCodeBuddy/Marketplace/plugins/ 不应存在或仅 .gitkeep
        //      （不产半成品 bundle，C8）
        //
        // 契约 C8：fetch 失败时，有缓存 → 用缓存 + stderr 警告、退出 0；
        //         无缓存无网络 → 清晰错误退出非 0、不产半成品 bundle。
        // 无单测断言（依赖网络 + 文件系统 + shell），留 QA。
    }
}
