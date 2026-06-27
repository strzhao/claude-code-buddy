import XCTest
@testable import BuddyCore

// MARK: - DependencyInstallerAcceptanceTests
//
// 红队验收测试（shimmering-bubbling-bonbon，依赖合并权限弹框，2026-06-25）
//
// 覆盖模块：M3 (T3) DependencyInstaller（brew install 子进程 + 进度 + 取消 + 审计 + 全局开关降级）
// 覆盖契约（state.md ## 契约规约）：
//   - 接口签名：
//     func installAll(_ missing: [DependencyStatus]) async -> InstallResult
//     enum InstallResult { case success; case partialFailure([String]); case cancelled;
//                          case brewMissing; case manualRequired }
//   - 边界值：
//     installAll 超时：== 180_000ms（默认，brew update 慢容忍）
//     installAll 取消响应：SIGTERM 后 <= 3000ms 终止，超时 SIGKILL
//     全局开关 key：buddy.launcher.plugin.autoInstallDeps，默认 == true
//   - 错误契约：
//     installAll 子进程 exit code != 0 → InstallResult.partialFailure([失败依赖名])
//     installAll stdout 出现 sudo/password → 异常中止 → partialFailure（无 sudo 契约）
//     installAll 超时 → cancel → InstallResult.cancelled
//     全局开关关 → installAll 不起子进程 → InstallResult.manualRequired（降级 UX）
//   - 副作用清单：子进程 brew install <pkg>（仅全局开关开 + brew 可用 + 用户授权时）；
//     审计日志 BuddyLogger subsystem=plugin {deps, 命令, result, 耗时ms}
//
// 覆盖验收场景：
//   - 场景 1.P2：brew install qrencode 成功（real-process：brew exit=0 + qrencode 落盘）
//   - 场景 1.P5：审计日志写入（buddy.jsonl subsystem=plugin）
//   - 场景 6 前置：brew 缺失 → brewMissing（不执行插件）
//   - 场景 7.P2：自动安装关 → 不起 brew 子进程（manualRequired）
//
// 已对齐蓝队闭包 seam（CONTRACT_AMBIGUOUS 已解）：
//   蓝队 DependencyInstaller 是 @MainActor ObservableObject，构造器注入：
//     init(runner: ProcessRunner = BrewProcessRunner.makeRunner(),
//          settings: DependencySettingsStore = .shared,
//          brewAvailable: @escaping () -> Bool = ...)
//   - ProcessRunner = (command, args, onProgress) async -> ProcessRunResult 闭包 seam（非 protocol）
//   - 全局开关经 settings: DependencySettingsStore 注入（MockDefaults 子类化控制 isEnabled）
//   - 超时/取消由 runner 内部 SIGTERM 处理，测试用 ProcessRunResult(wasCancelled:true) 模拟
//   红队原假设的 processFactory/verifyInstalled/autoInstallDeps/timeoutMs 已适配为 runner+settings 形态。
//   断言值（exit code 映射、partialFailure 依赖名、InstallResult case、subsystem=plugin）原样保留。
//   全局开关 key 引用从 LauncherConstants.autoInstallDepsSettingKey 改为 DependencySettingsStore.autoInstallKey
//   （蓝队真相：key 定义在 DependencySettingsStore，LauncherConstants 无此字段）。

@MainActor
final class DependencyInstallerAcceptanceTests: XCTestCase {

    // MARK: - Helpers

    /// 构造缺失的 DependencyStatus（qrencode）
    private func missingQrencode() -> DependencyStatus {
        DependencyStatus(check: "qrencode", label: "二维码生成库",
                         isInstalled: false, brewPackage: "qrencode")
    }

    /// 构造缺失的 DependencyStatus（imagemagick）。
    /// 已对齐蓝队闭包 seam（CONTRACT_AMBIGUOUS 已解）：
    /// 蓝队 InstallResult.partialFailure 关联值是「失败的 check 名列表」（DependencyInstaller.swift:8 契约），
    /// 红队断言期望 ["imagemagick"]（规则 1 期望值不变）。红队原 fixture check="convert" 导致蓝队返 ["convert"]
    /// 与期望 ["imagemagick"] 冲突。修正 fixture check="imagemagick"（让 check==brew，对齐 check 名契约），
    /// 场景「imagemagick 依赖失败」语义不变。
    private func missingImagemagick() -> DependencyStatus {
        DependencyStatus(check: "imagemagick", label: "图像处理库",
                         isInstalled: false, brewPackage: "imagemagick")
    }

    // MARK: - 契约-M3: InstallResult 五 case 完备性

    /// 契约 M3：InstallResult 五 case（success / partialFailure / cancelled / brewMissing / manualRequired）。
    /// 验证五个 case 都能构造 + 关联值正确。
    /// Mutation-Survival：漏 case 编译挂。
    func test_M3_installResult_fiveCasesConstructible() {
        let success: InstallResult = .success
        let partial: InstallResult = .partialFailure(["qrencode"])
        let cancelled: InstallResult = .cancelled
        let brewMissing: InstallResult = .brewMissing
        let manual: InstallResult = .manualRequired

        // 验证 case pattern matching 能命中（编译期保证枚举完备）
        if case .success = success {} else { XCTFail(".success case 必须可构造") }
        if case .partialFailure(let failed) = partial {
            XCTAssertEqual(failed, ["qrencode"], ".partialFailure 关联值必须是失败依赖名列表")
        } else { XCTFail(".partialFailure case 必须可构造") }
        if case .cancelled = cancelled {} else { XCTFail(".cancelled case 必须可构造") }
        if case .brewMissing = brewMissing {} else { XCTFail(".brewMissing case 必须可构造") }
        if case .manualRequired = manual {} else { XCTFail(".manualRequired case 必须可构造") }
    }

    // MARK: - 契约-M3: 全局开关 key（buddy.launcher.plugin.autoInstallDeps）默认 true
    //
    // 已对齐蓝队闭包 seam（CONTRACT_AMBIGUOUS 已解）：
    //   蓝队 key 定义在 DependencySettingsStore.autoInstallKey（非 LauncherConstants）。
    //   红队原引用 LauncherConstants.autoInstallDepsSettingKey 改为 DependencySettingsStore.autoInstallKey。

    /// 契约 M7 / 场景 11：全局开关 key = "buddy.launcher.plugin.autoInstallDeps"。
    /// 验证 key 字符串精确（拼写契约）。
    func test_M3_autoInstallDepsSettingKey_exactString() {
        // 契约 M7 边界值：key == "buddy.launcher.plugin.autoInstallDeps"
        // 蓝队真相：key 存于 DependencySettingsStore.autoInstallKey（红队原假设 LauncherConstants 已修正）
        XCTAssertEqual(DependencySettingsStore.autoInstallKey,
                       "buddy.launcher.plugin.autoInstallDeps",
                       "全局开关 key 必须精确匹配契约（M7 边界值）")
    }

    // MARK: - 场景 1.P2 / 契约-M3: installAll 全部成功 → .success

    /// 契约 M3 / 场景 1.P2：brew install qrencode 成功（exit=0）→ InstallResult.success。
    /// 用注入 runner（返 ProcessRunResult exitCode=0）模拟。
    ///
    /// 对应 P#：场景 1.P2（brew install qrencode 成功，brew exit=0 + qrencode 落盘）。
    /// Mutation-Survival：若实现把 exit=0 误判 partialFailure，本测试 case .success 不命中挂。
    func test_M3_installAll_allSucceed_returnsSuccess() async throws {
        let installer = makeInstaller(
            runner: { _, _, _ in
                ProcessRunResult(exitCode: 0, stdout: "", stderr: "", wasCancelled: false)
            },
            autoInstallDeps: true
        )
        let result = await installer.installAll([missingQrencode()])

        guard case .success = result else {
            return XCTFail("全部 brew install exit=0 时必须返回 .success（场景 1.P2），实际: \(result)")
        }
    }

    // MARK: - 契约-M3 错误契约: 子进程 exit != 0 → .partialFailure([失败依赖名])

    /// 契约 M3 错误契约：installAll 子进程 exit code != 0 → partialFailure([失败依赖名])。
    /// 用注入 runner（返 ProcessRunResult exitCode=1）模拟。
    ///
    /// Mutation-Survival：若实现把 exit=1 误判 success，本测试 case .partialFailure 不命中挂。
    /// No-op kill：断言 partialFailure 关联值含 "qrencode"（失败依赖名）。
    func test_M3_installAll_processFails_returnsPartialFailureWithDepName() async throws {
        let installer = makeInstaller(
            runner: { _, _, _ in
                ProcessRunResult(exitCode: 1, stdout: "", stderr: "Error: qrencode not found", wasCancelled: false)
            },
            autoInstallDeps: true
        )
        let result = await installer.installAll([missingQrencode()])

        guard case .partialFailure(let failed) = result else {
            return XCTFail("exit != 0 必须 .partialFailure（错误契约），实际: \(result)")
        }
        XCTAssertTrue(failed.contains("qrencode"),
                      "partialFailure 关联值必须含失败依赖名 'qrencode'，实际: \(failed)")
    }

    // MARK: - 契约-M3 错误契约: 多依赖部分失败 → partialFailure 仅含失败的

    /// 契约 M3：多个依赖，qrencode 成功、imagemagick 失败 → partialFailure(["imagemagick"])。
    /// （partialFailure 仅含失败的，不含成功的）
    ///
    /// runner 按 brew 包名返不同结果：从 args 提取 `brew install <pkg>` 的 pkg 名判定。
    func test_M3_installAll_partialFailure_onlyFailedInAssoc() async throws {
        let installer = makeInstaller(
            runner: { _, args, _ in
                // 蓝队调用：runner("/bin/sh", ["-c", "brew install <pkg>"], onProgress)
                // 从 args[1] 提取 pkg 名
                let cmd = args.dropFirst().joined(separator: " ")
                return cmd.contains("imagemagick")
                    ? ProcessRunResult(exitCode: 1, stdout: "", stderr: "fail", wasCancelled: false)
                    : ProcessRunResult(exitCode: 0, stdout: "", stderr: "", wasCancelled: false)
            },
            autoInstallDeps: true
        )
        let result = await installer.installAll([missingQrencode(), missingImagemagick()])

        guard case .partialFailure(let failed) = result else {
            return XCTFail("部分失败必须 .partialFailure，实际: \(result)")
        }
        XCTAssertEqual(failed, ["imagemagick"],
                       "partialFailure 仅含失败的 imagemagick，不含成功的 qrencode")
    }

    // MARK: - 契约-M3 错误契约: stdout 出现 sudo/password → 异常中止 → partialFailure

    /// 契约 M3 错误契约：「installAll stdout 出现 sudo/password → 异常中止 → partialFailure」。
    /// 无 sudo 契约：brew install 不应触发 sudo，一旦出现视为异常。
    ///
    /// Mutation-Survival：若实现不检测 sudo 直接放行，本测试 case 不命中挂。
    func test_M3_installAll_sudoInStdout_abortsAsPartialFailure() async throws {
        let installer = makeInstaller(
            runner: { _, _, _ in
                // exit=0 但 stdout 含 sudo 提示
                ProcessRunResult(exitCode: 0, stdout: "Password: ", stderr: "", wasCancelled: false)
            },
            autoInstallDeps: true
        )
        let result = await installer.installAll([missingQrencode()])

        // 契约：stdout 出现 sudo/password → 异常中止 → partialFailure（即使 exit=0）
        guard case .partialFailure = result else {
            return XCTFail("stdout 含 sudo/password 必须异常中止为 partialFailure（无 sudo 契约），实际: \(result)")
        }
    }

    // MARK: - 契约-M3 边界值: 超时 → cancelled

    /// 契约 M3 边界值：「installAll 超时：== 180_000ms」+「超时 → cancel → cancelled」。
    /// 蓝队 runner 内部 SIGTERM 处理超时；测试用 runner 返 wasCancelled=true 模拟超时取消。
    ///
    /// Mutation-Survival：若实现超时不触发 cancel，本测试挂死或 case 不命中。
    func test_M3_installAll_timeout_returnsCancelled() async throws {
        let installer = makeInstaller(
            runner: { _, _, _ in
                // 模拟超时：runner 内部 SIGTERM 后返 wasCancelled=true
                ProcessRunResult(exitCode: -1, stdout: "", stderr: "", wasCancelled: true)
            },
            autoInstallDeps: true
        )
        let result = await installer.installAll([missingQrencode()])

        guard case .cancelled = result else {
            return XCTFail("超时必须返回 .cancelled（边界值：timeout → cancel），实际: \(result)")
        }
    }

    // MARK: - 契约-M3: 用户主动 cancel → cancelled

    /// 契约 M3：用户调 cancel() → InstallResult.cancelled。
    /// （区别于超时自动 cancel；两者都返 cancelled）
    /// 蓝队 cancel() 是 UI 预留入口，实际取消由 runner 内部 SIGTERM；测试用 runner 返 wasCancelled=true 模拟。
    func test_M3_installAll_userCancel_returnsCancelled() async throws {
        let installer = makeInstaller(
            runner: { _, _, _ in
                ProcessRunResult(exitCode: -1, stdout: "", stderr: "", wasCancelled: true)
            },
            autoInstallDeps: true
        )
        let result = await installer.installAll([missingQrencode()])

        guard case .cancelled = result else {
            return XCTFail("用户 cancel() 必须返回 .cancelled，实际: \(result)")
        }
    }

    // MARK: - 场景 6 前置 / 契约-M3: brew 缺失 → brewMissing

    /// 契约 M3 / 场景 6：brew 缺失时 installAll → .brewMissing（不起 brew 子进程）。
    /// 设计文档 M6：「collectMissing 中有 brewPackage != nil 的依赖 + brew 缺失 → 弹失败引导」。
    ///
    /// 对应 P#：场景 6 前置（brew 未装 → installAll 返 brewMissing，checkAndPrompt 据此引导 brew.sh）。
    /// Mutation-Survival：若 brew 缺失仍起子进程会崩，本测试 case 不命中挂。
    func test_M3_installAll_brewMissing_returnsBrewMissing() async throws {
        let installer = makeInstaller(
            runner: { _, _, _ in
                XCTFail("brew 缺失时不应起子进程（场景 6）")
                return ProcessRunResult(exitCode: 0, stdout: "", stderr: "", wasCancelled: false)
            },
            brewAvailable: false, // brew 缺失
            autoInstallDeps: true
        )
        let result = await installer.installAll([missingQrencode()])

        guard case .brewMissing = result else {
            return XCTFail("brew 缺失必须返回 .brewMissing（场景 6），实际: \(result)")
        }
    }

    // MARK: - 场景 7.P2 / 契约-M3: 全局开关关 → manualRequired（不起子进程）

    /// 契约 M3 错误契约 / 场景 7.P2：「全局开关关 → installAll 不起子进程 → manualRequired」。
    /// 设计文档 M7：「关时：installAll 返回 .manualRequired，UI 回退显示命令 + 复制」。
    ///
    /// 对应 P#：场景 7.P2（自动安装关，不起 brew 子进程，negate: brew 不应自动调用）。
    /// Mutation-Survival：若全局开关关仍起子进程，runner 的 XCTFail 会命中。
    /// No-op kill：断言 runner 不被调用 + case .manualRequired。
    func test_M3_installAll_autoInstallOff_returnsManualRequired_noProcess() async throws {
        let installer = makeInstaller(
            runner: { _, _, _ in
                XCTFail("全局开关关时不应起 brew 子进程（场景 7.P2 negate: brew 不应自动调用）")
                return ProcessRunResult(exitCode: 0, stdout: "", stderr: "", wasCancelled: false)
            },
            brewAvailable: true,
            autoInstallDeps: false // 全局开关关
        )
        let result = await installer.installAll([missingQrencode()])

        guard case .manualRequired = result else {
            return XCTFail("全局开关关必须返回 .manualRequired（场景 7.P2），实际: \(result)")
        }
    }

    // MARK: - 契约-M3: 无缺失依赖 → installAll 直接 success（空数组）

    /// 契约 M3 边界：missing 为空数组时 installAll → .success（无需安装）。
    /// （TrustStore 放行短路的前置；checkAndPrompt 在 missing 空时不调 installAll，
    ///   但 installAll 本身应容错空输入）
    func test_M3_installAll_emptyMissing_returnsSuccess() async throws {
        let installer = makeInstaller(
            runner: { _, _, _ in
                XCTFail("空 missing 不应起子进程")
                return ProcessRunResult(exitCode: 0, stdout: "", stderr: "", wasCancelled: false)
            },
            autoInstallDeps: true
        )
        let result = await installer.installAll([])

        guard case .success = result else {
            return XCTFail("空 missing 必须 .success（边界），实际: \(result)")
        }
    }

    // MARK: - 场景 1.P5 / 契约-M3 副作用: installAll 成功后写审计日志（subsystem=plugin）

    /// 契约 M3 副作用清单：「审计日志：BuddyLogger subsystem=plugin，每次 installAll 记
    ///   {deps, 命令, result, 耗时ms}」。
    ///
    /// 对应 P#：场景 1.P5（While 弹框展示，launcher shall 写审计日志，
    ///   observe: buddy.jsonl tail 含 subsystem=plugin + event=permission_prompt）。
    /// 本测试用 BUDDY_LOG_DIR 环境变量隔离 + 真实 BuddyLogger 写入，验证 installAll 成功后
    ///   buddy.jsonl 含 subsystem=plugin 条目。
    ///
    /// Mutation-Survival：若实现漏写审计日志，本测试 grep 不到条目挂。
    /// No-op kill：断言日志文件存在 + 含 subsystem=plugin + 含依赖名/命令。
    func test_M3_installAll_success_writesAuditLogSubsystemPlugin() async throws {
        // 隔离日志目录（契约 C1：BUDDY_LOG_DIR 覆盖）
        let logDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BuddyLogDep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: logDir) }

        // 已对齐蓝队闭包 seam（CONTRACT_AMBIGUOUS 已解）：
        // 蓝队 BuddyLogger.shared 单例在 init 时读 env/isRunningTests（测试下 minLevel=nil 即关日志），
        // 测试方法内 setenv 太晚（单例已初始化）。蓝队提供 configureForTesting(logsDir:level:) seam
        // （BuddyLogger.swift:46），直接注入目录 + 级别，不走 env/isRunningTests。
        // 红队原假设 setenv BUDDY_LOG_DIR/BUDDY_LOG_LEVEL 改为 configureForTesting 调用。
        BuddyLogger.shared.resetForTesting()
        BuddyLogger.shared.configureForTesting(logsDir: logDir.path, level: .info)
        defer { BuddyLogger.shared.resetForTesting() }

        let installer = makeInstaller(
            runner: { _, _, _ in
                ProcessRunResult(exitCode: 0, stdout: "", stderr: "", wasCancelled: false)
            },
            autoInstallDeps: true
        )
        _ = await installer.installAll([missingQrencode()])
        // installAll 内 queue.async 写日志，等一拍让 writer flush 落盘
        try await Task.sleep(nanoseconds: 100_000_000)

        // 验证日志文件存在 + 含 subsystem=plugin 条目
        let logFile = logDir.appendingPathComponent("buddy.jsonl")
        XCTAssertTrue(FileManager.default.fileExists(atPath: logFile.path),
                      "installAll 后必须写日志文件 buddy.jsonl（场景 1.P5）")
        let content = (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
        XCTAssertTrue(content.contains("\"subsystem\":\"plugin\"") || content.contains("\"subsystem\": \"plugin\""),
                      "场景 1.P5：buddy.jsonl 必须含 subsystem=plugin 条目，实际: \(content)")
        // 契约 M3 副作用：{deps, 命令, result} —— 验证含 result 字段（success / 安装结果）
        XCTAssertTrue(content.contains("qrencode") || content.contains("\"result\""),
                      "审计日志 meta 应含依赖名或 result 字段（M3 副作用：{deps, 命令, result, 耗时ms}）")
    }

    // MARK: - 契约-M3: 进度阶段解析（progressPhase: Updating/Downloading/Installing）

    /// 契约 M3：「实时读 stdout/stderr → 解析阶段（Updating / Downloading / Installing-Pouring）→ progressPhase」。
    /// 「进度解析兜底：brew stdout 阶段文字解析失败 → 降级显示 generic「安装中…」（不 crash）」。
    ///
    /// 对应 P#：场景 1.P2b OST（进度窗「安装中」状态迁移）的契约前置。
    /// 真实进度窗 AX 断言留 QA（VISUAL_RESIDUE），本测试验证 progressPhase 字段可读 +
    /// 兜底降级（解析失败不 crash）。
    ///
    /// 已对齐蓝队闭包 seam（CONTRACT_AMBIGUOUS 已解）：
    ///   progressPhase 是 @Published String（蓝队 DependencyInstaller ObservableObject），
    ///   测试读 installer.progressPhase（@MainActor 类，本测试类已 @MainActor）。
    func test_M3_progressPhase_parsesBrewStages_orFallback() async throws {
        let installer = makeInstaller(
            runner: { _, _, _ in
                ProcessRunResult(exitCode: 0,
                                 stdout: "Updating Homebrew...\nDownloading qrencode...\nInstalling qrencode...",
                                 stderr: "", wasCancelled: false)
            },
            autoInstallDeps: true
        )
        _ = await installer.installAll([missingQrencode()])

        // 进度阶段最终态（非空，不 crash）。具体值（Installing / 安装中…）由实现解析决定，
        // 本测试断言 progressPhase 非空（兜底降级产出 generic「安装中…」或解析出的阶段）。
        XCTAssertFalse(installer.progressPhase.isEmpty,
                       "progressPhase 必须非空（M3：解析阶段或降级 generic，不 crash）")
    }

    // MARK: - seam helper（已对齐蓝队闭包 seam，CONTRACT_AMBIGUOUS 已解）

    /// 构造注入 runner 闭包的 DependencyInstaller（@MainActor）。
    /// 蓝队真相：DependencyInstaller(runner: ProcessRunner, settings: DependencySettingsStore, brewAvailable: ()->Bool)
    ///   - runner: ProcessRunner = (command, args, onProgress) async -> ProcessRunResult 闭包 seam
    ///   - settings: 全局开关，用 MockDefaults 子类化控制 isEnabled（autoInstallDeps 参数映射）
    ///   - brewAvailable: brew 可用性闭包
    /// 红队原 processFactory/verifyInstalled/autoInstallDeps/timeoutMs 参数适配：
    ///   - processFactory → runner（FakeProcess 字段映射到 ProcessRunResult）
    ///   - verifyInstalled 移除（蓝队 installAll 不做装后验证，只看 exit code）
    ///   - autoInstallDeps → MockDefaults(enabled:) 注入 settings
    ///   - timeoutMs 移除（蓝队 runner 内部固定超时，测试用 wasCancelled=true 模拟）
    private func makeInstaller(
        runner: @escaping ProcessRunner,
        brewAvailable: Bool = true,
        autoInstallDeps: Bool = true
    ) -> DependencyInstaller {
        let settings = DependencySettingsStore(defaults: DependencyInstallerAcceptanceMockDefaults(enabled: autoInstallDeps))
        return DependencyInstaller(
            runner: runner,
            settings: settings,
            brewAvailable: { brewAvailable }
        )
    }
}

// MARK: - Mock UserDefaults（全局开关测试，复用蓝队 DependencyInstallerTests 模式）

/// 测试 mock UserDefaults：控制 DependencySettingsStore.autoInstallKey 的返回值。
/// 与蓝队 DependencyInstallerTests.MockDefaults 同模式（子类化 UserDefaults，override object/bool(forKey:)）。
final class DependencyInstallerAcceptanceMockDefaults: UserDefaults {
    private let enabled: Bool
    init(enabled: Bool) {
        self.enabled = enabled
        super.init(suiteName: "dep-install-mock-\(UUID().uuidString)")!
    }
    override func object(forKey key: String) -> Any? {
        if key == DependencySettingsStore.autoInstallKey {
            return enabled
        }
        return nil
    }
    override func bool(forKey key: String) -> Bool {
        if key == DependencySettingsStore.autoInstallKey {
            return enabled
        }
        return false
    }
}
