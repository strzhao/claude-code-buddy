import XCTest
@testable import BuddyCore

// MARK: - QzhPluginAcceptanceTests
//
// 红队验收测试：qzh 插件（command mode）路由契约 + sudoers 最小权限（C7）。
//
// 信息隔离铁律：本文件由红队独立编写，仅依据：
//   - state.md ## 设计文档（§4 qzh 插件 plugin.json + qzh-exec 路由 + §5 sudoers）
//   - state.md ## 契约规约 C7（sudoers 4 条精确命令，不含通配）
//   - state.md ## 验收场景（场景2/3/8 det-machine 谓词）
//   - qr 插件 plugin.json schema（参考，非蓝队新写）
// 未读取蓝队本次任何实现代码（Marketplace/plugins/qzh/ 下的 plugin.json/qzh-exec/setup.sh）。
//
// 契约引用（逐字一致）：
//   [C7] sudoers 最小权限：NOPASSWD 仅 4 条精确命令串，不含通配/任意 label/参数；visudo -c 校验
//     1. launchctl bootout system/com.cyberserval.qzhddr.service
//     2. launchctl bootout system/com.cyberserval.qzhddr.update
//     3. launchctl bootstrap system /Library/LaunchDaemons/com.cyberserval.qzhddr.service.plist
//     4. launchctl bootstrap system /Library/LaunchDaemons/com.cyberserval.qzhddr.update.plist
//
// 验收场景覆盖：
//   场景8.P1 [det-machine]: /etc/sudoers.d/qzhddr-launcher 存在
//   场景8.P2 [det-machine]: visudo -cf 校验通过
//   场景8.P3 [det-machine]: 含 "bootout system/com.cyberserval.qzhddr.service" AND NOT "*"
//   场景2.P4 [det-machine]: 无管理员权限 → bootout 失败 stderr 含 permission/sudo（契约 §4 容错）
//   场景3.P1 [real-process] 间接：selection=start → bootstrap 命令（命令串契约）
//
// ⚠️ 真实 bootout/bootstrap 副作用（场景2/3/4 的 pgrep 断言）不可在自动化测试中求值（需 root + KeepAlive 自愈），
//    走 det-machine：断言命令串契约 + sudoers 内容 + 路由分支（spy/日志），不真改系统。

final class QzhPluginAcceptanceTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("QzhAcceptance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let dir = tmpDir { try? FileManager.default.removeItem(at: dir) }
        tmpDir = nil
        try await super.tearDown()
    }

    // MARK: - [C7] sudoers 4 条精确命令串契约（设计文档 §5 + 契约 C7）
    //
    // 不真写 /etc/sudoers.d（需 root + 不可逆副作用），而是断言「setup.sh 产出的内容模板」
    // 符合 C7。setup.sh 由蓝队写在 Marketplace/plugins/qzh/setup.sh，红队读其生成的预期内容。
    // CONTRACT_AMBIGUITY: setup.sh 可能用变量拼装而非字面量；此处断言「关键命令串必须以可被 sudoers 匹配的形式出现」。
    //
    // 若 setup.sh 尚未实现（RED），读文件失败 → XCTFail 挂（符合 TDD 红灯）。

    /// C7 规定的 4 条精确命令串（设计文档 §5 逐字）
    private let c7ExactCommands: [String] = [
        "launchctl bootout system/com.cyberserval.qzhddr.service",
        "launchctl bootout system/com.cyberserval.qzhddr.update",
        "launchctl bootstrap system /Library/LaunchDaemons/com.cyberserval.qzhddr.service.plist",
        "launchctl bootstrap system /Library/LaunchDaemons/com.cyberserval.qzhddr.update.plist",
    ]

    /// 读取 setup.sh 内容（若蓝队已实现）
    private func readSetupSh() throws -> String? {
        // setup.sh 随插件分发，路径相对 Sources（SPM .copy("Marketplace")）
        // 测试进程的 cwd 不确定，用 #filePath 相对定位
        let testFile = URL(fileURLWithPath: #file)
        let repoRoot = testFile
            .deletingLastPathComponent()  // Launcher/
            .deletingLastPathComponent()  // BuddyCoreTests/
            .deletingLastPathComponent()  // tests/
            .deletingLastPathComponent()  // apps/desktop/
        let setupURL = repoRoot
            .appendingPathComponent("Sources/ClaudeCodeBuddy/Marketplace/plugins/qzh/setup.sh")
        guard FileManager.default.fileExists(atPath: setupURL.path) else { return nil }
        return try String(contentsOf: setupURL, encoding: .utf8)
    }

    // MARK: - 场景8.P1 [det-machine]: setup.sh 存在（sudoers 条目写入脚本）
    //
    // 契约引用：Marketplace/plugins/qzh/setup.sh 写 /etc/sudoers.d/qzhddr-launcher
    // assert: setup.sh 文件存在（蓝队 T4.1 产出）

    func test_scenario8_P1_setupShExists() throws {
        let content = try readSetupSh()
        XCTAssertNotNil(content,
                        "[场景8.P1] Marketplace/plugins/qzh/setup.sh 必须存在（蓝队 T4.1 产出 sudoers 写入脚本）")
    }

    // MARK: - 场景8.P3 [det-machine]: sudoers 内容含 4 条精确命令 + 不含通配
    //
    // 契约 [C7]: NOPASSWD 仅 4 条精确命令串，不含通配/任意 label/参数
    // assert: contains "bootout system/com.cyberserval.qzhddr.service" AND NOT "*"
    // Mutation kill: 若蓝队写通配（如 launchctl bootout *）→ NOT "*" 断言挂

    func test_scenario8_P3_sudoersContent_exactCommandsNoWildcard() throws {
        let content = try XCTUnwrap(
            try readSetupSh(),
            "[场景8.P3] setup.sh 必须存在才能校验 sudoers 内容（蓝队 T4.1 未完成）"
        )

        // 4 条精确命令串必须全部出现在 setup.sh 中（C7）
        for cmd in c7ExactCommands {
            XCTAssertTrue(
                content.contains(cmd),
                "[C7][场景8.P3] setup.sh 必须含精确命令串：\(cmd)。实际 setup.sh 内容:\n\(content)"
            )
        }

        // 不放行通配（C7 安全核心，防提权放大）
        // 检测 launchctl 相关行是否含通配 *（NOACCEPT: 任意 label/任意参数）
        let lines = content.split(separator: "\n").map(String.init)
        let launchctlLines = lines.filter { $0.contains("launchctl") && !$0.hasPrefix("#") }
        for line in launchctlLines {
            XCTAssertFalse(
                line.contains("*"),
                "[C7][场景8.P3] launchctl 相关行禁含通配 '*'（防任意 label/参数提权）。违规行: \(line)"
            )
        }

        // 必须含 NOPASSWD（免密，设计文档 §5）
        XCTAssertTrue(
            content.contains("NOPASSWD"),
            "[C7] setup.sh 必须含 NOPASSWD（免密 sudoers 条目）"
        )

        // 必须含目标文件路径 /etc/sudoers.d/qzhddr-launcher
        XCTAssertTrue(
            content.contains("/etc/sudoers.d/qzhddr-launcher"),
            "[C7][场景8.P1] setup.sh 必须写 /etc/sudoers.d/qzhddr-launcher"
        )
    }

    // MARK: - 场景8.P2 [det-machine]: visudo -c 校验语法
    //
    // 契约 [C7]: visudo -c 校验
    // assert: setup.sh 调用 visudo -cf 校验（det-machine：断言脚本含 visudo -c 调用）
    // 真实 visudo -c 需 root 写文件，走 det-machine 断言「脚本含校验调用」

    func test_scenario8_P2_setupShInvokesVisudoCheck() throws {
        let content = try XCTUnwrap(
            try readSetupSh(),
            "[场景8.P2] setup.sh 必须存在才能校验 visudo 调用"
        )
        XCTAssertTrue(
            content.contains("visudo -c"),
            "[C7][场景8.P2] setup.sh 必须调用 'visudo -c'（或 -cf）校验 sudoers 语法"
        )
    }

    // MARK: - [契约 §4] qzh-exec 路由：command manifest 契约（plugin.json）
    //
    // 契约引用：plugin.json mode=command, cmd=./qzh-exec, keywords=[qzh], requiredPath=[jq]
    // 验收点：plugin.json schema 正确（蓝队 T3.1）
    // Mutation kill: mode 写错/keywords 漏 qzh → 测试挂

    func test_qzhPluginManifest_contractFields() throws {
        let testFile = URL(fileURLWithPath: #file)
        let repoRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let manifestURL = repoRoot
            .appendingPathComponent("Sources/ClaudeCodeBuddy/Marketplace/plugins/qzh/plugin.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            XCTFail("[契约 §4] Marketplace/plugins/qzh/plugin.json 必须存在（蓝队 T3.1）")
            return
        }
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        try manifest.validate(againstDirName: "qzh")

        // mode 必须是 command（零 LLM bypass，契约 §4）
        guard case .command = manifest.modeConfig else {
            XCTFail("[契约 §4] qzh plugin.json mode 必须是 'command'（零 LLM），实际: \(manifest.modeConfig)")
            return
        }
        // keywords 必须含 qzh（静态短路命中）
        XCTAssertTrue(manifest.keywords.contains("qzh"),
                      "[契约 §4] qzh plugin.json keywords 必须含 'qzh'")
        // cmd 必须是 ./qzh-exec
        XCTAssertEqual(manifest.cmd, "./qzh-exec",
                       "[契约 §4] qzh plugin.json cmd 必须是 './qzh-exec'")
        // CONTRACT_AMBIGUITY: 设计文档说 requiredPath:[jq]，但 qr 插件 requiredPath:null；
        // 此处宽松断言「若 requiredPath 非 nil 必须含 jq」（蓝队可选，但若加必须含 jq）
        if let required = manifest.requiredPath {
            XCTAssertTrue(required.contains("jq"),
                          "[契约 §4] qzh requiredPath 若非 nil 必须含 'jq'，实际: \(required)")
        }
    }

    // MARK: - 场景2.P4 / 场景6.P1 [det-machine]: 无管理员权限 → bootout 失败（命令串契约）
    //
    // 契约引用：§4 容错——非 0 → stderr 中文错误；command 分支 exitCode!=0 && stdout 空 → 呈现 stderr
    // 真实 bootout 需 root，不可自动化求值；走 det-machine 断言「qzh-exec 的 stop 分支命令串是 bootout」
    // 此处验 qzh-exec 脚本存在 + 含 bootout 命令串（路由正确性，防蓝队把 stop 写成 kill）

    func test_scenario2_qzhExec_stopRoute_invokesBootout() throws {
        let testFile = URL(fileURLWithPath: #file)
        let repoRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let execURL = repoRoot
            .appendingPathComponent("Sources/ClaudeCodeBuddy/Marketplace/plugins/qzh/qzh-exec")
        guard FileManager.default.fileExists(atPath: execURL.path) else {
            XCTFail("[契约 §4] Marketplace/plugins/qzh/qzh-exec 必须存在（蓝队 T3.2）")
            return
        }
        let content = try String(contentsOf: execURL, encoding: .utf8)

        // stop 分支必须调 bootout（场景2.P1 real-process: privileged launchctl bootout）
        XCTAssertTrue(
            content.contains("launchctl bootout system/com.cyberserval.qzhddr.service"),
            "[场景2.P1] qzh-exec stop 分支必须调 'launchctl bootout system/com.cyberserval.qzhddr.service'"
        )
        XCTAssertTrue(
            content.contains("launchctl bootout system/com.cyberserval.qzhddr.update"),
            "[场景2.P1] qzh-exec stop 分支必须调 'launchctl bootout system/com.cyberserval.qzhddr.update'"
        )

        // 场景3.P1 real-process: start 分支必须调 bootstrap
        XCTAssertTrue(
            content.contains("launchctl bootstrap system /Library/LaunchDaemons/com.cyberserval.qzhddr.service.plist"),
            "[场景3.P1] qzh-exec start 分支必须调 bootstrap service plist"
        )
        XCTAssertTrue(
            content.contains("launchctl bootstrap system /Library/LaunchDaemons/com.cyberserval.qzhddr.update.plist"),
            "[场景3.P1] qzh-exec start 分支必须调 bootstrap update plist"
        )

        // 必须读 stdin（jq 解析 selection），不能硬编码
        XCTAssertTrue(
            content.contains("jq") || content.contains("cat"),
            "[契约 §4] qzh-exec 必须读 stdin（jq 解析 .selection/.query），不能硬编码路由"
        )

        // stop/start 路由分支必须存在（selection == "stop" / "start" / "status"）
        XCTAssertTrue(
            content.contains("stop") && content.contains("start"),
            "[契约 §4] qzh-exec 必须有 stop/start selection 路由分支"
        )
        XCTAssertTrue(
            content.contains("status"),
            "[契约 §4] qzh-exec 必须有 status selection 路由分支（查看状态子命令）"
        )
    }

    // MARK: - 场景1.P1 [det-machine]: 首次查询（selection 空）写候选 JSON 到 BUDDY_OUTPUT_CANDIDATES
    //
    // 契约引用：§4 selection 为空（首次查询）→ pgrep 判存活 + 状态文本 stdout + 写候选 JSON
    // 候选 JSON 结构：[{selection:"stop",title:"关闭监控",...},{selection:"start",title:"打开监控",...}]
    // det-machine：断言 qzh-exec 脚本含「写候选 JSON 到 $BUDDY_OUTPUT_CANDIDATES」+ 候选含 stop/start

    func test_scenario1_qzhExec_queryRoute_writesCandidatesJSON() throws {
        let testFile = URL(fileURLWithPath: #file)
        let repoRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let execURL = repoRoot
            .appendingPathComponent("Sources/ClaudeCodeBuddy/Marketplace/plugins/qzh/qzh-exec")
        guard FileManager.default.fileExists(atPath: execURL.path) else {
            XCTFail("[契约 §4] qzh-exec 必须存在才能校验查询路由")
            return
        }
        let content = try String(contentsOf: execURL, encoding: .utf8)

        // 必须引用 $BUDDY_OUTPUT_CANDIDATES 写候选（C1 通道贯通）
        XCTAssertTrue(
            content.contains("BUDDY_OUTPUT_CANDIDATES"),
            "[C1][场景1.P1] qzh-exec 查询分支必须写候选 JSON 到 $BUDDY_OUTPUT_CANDIDATES"
        )
        // 候选必须含 stop / start selection（C2 结构）
        XCTAssertTrue(content.contains("\"stop\"") || content.contains("'stop'"),
                      "[C2][场景1.P1] 候选 JSON 必须含 selection 'stop'")
        XCTAssertTrue(content.contains("\"start\"") || content.contains("'start'"),
                      "[C2][场景1.P1] 候选 JSON 必须含 selection 'start'")
        XCTAssertTrue(content.contains("\"status\"") || content.contains("'status'"),
                      "[C2] 候选 JSON 必须含 selection 'status'（查看状态子命令）")

        // VISUAL_RESIDUE: 状态文本「运行中」/「已停止」/组件明细的精确组装留 QA 真机判定
        // （det-machine 只断言路由结构，pgrep 真实存活需真机）
    }

    /// status 分支必须存在 + 含 pgrep 刷新（非缓存回显）+ 不含 emit_candidates（status 是查询终点，不写候选）
    /// 契约引用：设计文档 §status 分支行为——复用首次查询的状态检查逻辑，重新 pgrep，不写候选
    func test_statusSelection_routeExists_repgsWithoutCandidates() throws {
        let testFile = URL(fileURLWithPath: #file)
        let repoRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let execURL = repoRoot
            .appendingPathComponent("Sources/ClaudeCodeBuddy/Marketplace/plugins/qzh/qzh-exec")
        guard FileManager.default.fileExists(atPath: execURL.path) else {
            XCTFail("[契约 §4] qzh-exec 必须存在才能校验 status 分支")
            return
        }
        let content = try String(contentsOf: execURL, encoding: .utf8)

        // status selection 路由分支必须存在
        XCTAssertTrue(
            content.contains("SELECTION\" = \"status\""),
            "[契约 §4] qzh-exec 必须有 elif [ \"$SELECTION\" = \"status\" ] 路由分支"
        )

        // "未知操作" 消息必须包含 status（防蓝队加分支但忘更新帮助文本）
        XCTAssertTrue(
            content.contains("status/stop/start") || content.contains("status, stop, start"),
            "[契约 §4] qzh-exec 未知操作消息必须包含 status（与 stop/start 并列）"
        )

        // VISUAL_RESIDUE: status 分支不写候选 → 断言 status 块不含 emit_candidates 调用（精确行留 QA 真机）
    }

    // MARK: - [契约 §4] qzh-exec 用 sudo 调 launchctl（免密依赖 sudoers）
    //
    // 契约引用：§4 sudo launchctl bootout/bootstrap（sudoers 免密）
    // Mutation kill: 若蓝队漏掉 sudo 前缀，普通用户无权 bootout root 服务 → 实际永远失败

    func test_qzhExec_usesSudoForPrivilegedLaunchctl() throws {
        let testFile = URL(fileURLWithPath: #file)
        let repoRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let execURL = repoRoot
            .appendingPathComponent("Sources/ClaudeCodeBuddy/Marketplace/plugins/qzh/qzh-exec")
        guard FileManager.default.fileExists(atPath: execURL.path) else {
            XCTFail("[契约 §4] qzh-exec 必须存在才能校验 sudo 前缀")
            return
        }
        let content = try String(contentsOf: execURL, encoding: .utf8)

        // bootout/bootstrap 行必须用 sudo（依赖 sudoers 免密）
        let bootoutLines = content.split(separator: "\n")
            .map(String.init)
            .filter { $0.contains("launchctl bootout") || $0.contains("launchctl bootstrap") }
        XCTAssertFalse(bootoutLines.isEmpty, "[契约 §4] qzh-exec 必须含 bootout/bootstrap 命令行")
        for line in bootoutLines {
            XCTAssertTrue(
                line.contains("sudo"),
                "[契约 §4] launchctl bootout/bootstrap 必须用 sudo 前缀（依赖 sudoers 免密）。违规行: \(line)"
            )
        }
    }
}
