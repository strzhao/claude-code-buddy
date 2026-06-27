import XCTest
@testable import BuddyCore

// MARK: - DependencyInstallerSyncTests
//
// 蓝队单测（M4 弹框内 modal runloop 修复）：installAllSync 同步版。
//
// 根因（铁证日志）：NSApp.runModal 的 modal runloop（NSModalPanelRunLoopMode）不 pump GCD main queue，
// Task @MainActor { installAll } 在弹框关闭后才执行（实测 51s 延迟）→ 进度不刷新 + 按钮永不 enable。
// 修复：installAllSync 同步执行（Process.run + while RunLoop.run pump），绕 Task @MainActor。
//
// 测试策略：
// - syncCommandBuilder seam 注入假命令（/bin/sh -c "exit 0" 等），避免真跑 brew
// - 业务分支与 installAll async 逐字一致（红队 lock 对照）：全局开关/brewMissing/空/success/
//   partialFailure/sudo/cancelled/Q1（statuses.isInstalled 更新）
// - while pump 在测试主线程也工作（RunLoop.current.run 非模态下 pump common，process 正常退出）
//
// 红队 lock 不破坏：installAll async 签名 + 行为不变（DependencyInstallerAcceptanceTests 13 全绿）。

@MainActor
final class DependencyInstallerSyncTests: XCTestCase {

    // MARK: - Helpers

    private func status(_ check: String, brew: String? = "pkg", label: String? = "工具") -> DependencyStatus {
        DependencyStatus(check: check, label: label, isInstalled: false, brewPackage: brew)
    }

    /// 构造注入 syncCommandBuilder seam 的 installer（同步路径专用）。
    /// 注：installAllSync 用真实 Process + syncCommandBuilder，不走 runner 闭包 seam。
    private func makeInstaller(
        command: @escaping (String) -> (command: String, arguments: [String]),
        settings: DependencySettingsStore = DependencySettingsStore(defaults: SyncMockDefaults(enabled: true)),
        brewAvailable: @escaping () -> Bool = { true }
    ) -> DependencyInstaller {
        let installer = DependencyInstaller(settings: settings, brewAvailable: brewAvailable)
        installer.syncCommandBuilder = command
        return installer
    }

    // MARK: - 全局开关降级（.manualRequired）

    /// 契约 M3（同步版对齐）：全局开关 OFF → installAllSync 不起子进程，返回 .manualRequired。
    func test_ST01_globalSwitchOff_returnsManualRequired() {
        let settings = DependencySettingsStore(defaults: SyncMockDefaults(enabled: false))
        let installer = makeInstaller(
            command: { _ in ("/bin/sh", ["-c", "exit 0"]) },
            settings: settings
        )
        let result = installer.installAllSync([status("qrencode")])
        if case .manualRequired = result {
            // ok
        } else {
            XCTFail("全局开关 OFF 应返回 .manualRequired，实际：\(result)")
        }
    }

    // MARK: - brewMissing

    /// 契约 M3（同步版对齐）：brew 不可用 + 依赖有 brew 映射 → .brewMissing。
    func test_ST02_brewMissing_returnsBrewMissing() {
        let installer = makeInstaller(
            command: { _ in ("/bin/sh", ["-c", "exit 0"]) },
            brewAvailable: { false }
        )
        let result = installer.installAllSync([status("qrencode", brew: "qrencode")])
        if case .brewMissing = result {
            // ok
        } else {
            XCTFail("brew 缺失应返回 .brewMissing，实际：\(result)")
        }
    }

    // MARK: - success

    /// 契约 M3（同步版对齐）：所有依赖 exit=0 → .success。
    func test_ST03_allSucceed_returnsSuccess() {
        let installer = makeInstaller(
            command: { _ in ("/bin/sh", ["-c", "exit 0"]) }
        )
        let result = installer.installAllSync([status("qrencode")])
        if case .success = result {
            // ok
        } else {
            XCTFail("全成功应返回 .success，实际：\(result)")
        }
    }

    // MARK: - Q1：installAllSync success 后更新 statuses.isInstalled（按钮 enable 前置）

    /// M4 弹框内 Q1 修复（同步版）：installAllSync 成功装完依赖后，重查 locateBinary
    /// 更新 statuses[i].isInstalled = true → TrustPrompt Combine sink allSatisfy(isInstalled)
    /// → enable「允许并运行」按钮。用系统命令 ls（locateBinary 必返回非 nil）验证。
    func test_ST11_installAllSync_success_updatesStatusIsInstalled() {
        let installer = makeInstaller(
            command: { _ in ("/bin/sh", ["-c", "exit 0"]) }
        )
        let dep = DependencyStatus(check: "ls", label: "列表命令", isInstalled: false, brewPackage: "ls")
        _ = installer.installAllSync([dep])
        let lsStatus = installer.statuses.first { $0.check == "ls" }
        XCTAssertNotNil(lsStatus, "installAllSync 后 statuses 应含 ls")
        XCTAssertTrue(lsStatus?.isInstalled == true,
                      "installAllSync success 后 statuses[ls].isInstalled 必须 true（locateBinary('ls') 系统有 → 按钮 enable 契约，Q1）")
    }

    // MARK: - partialFailure

    /// 契约 M3（同步版对齐）：子进程 exit code != 0 → .partialFailure([失败依赖名])。
    func test_ST04_nonZeroExit_returnsPartialFailure() {
        let installer = makeInstaller(
            command: { _ in ("/bin/sh", ["-c", "exit 1"]) }
        )
        let result = installer.installAllSync([status("qrencode")])
        if case .partialFailure(let failed) = result {
            XCTAssertEqual(failed, ["qrencode"])
        } else {
            XCTFail("非零 exit 应 .partialFailure，实际：\(result)")
        }
    }

    /// 契约 M3（同步版对齐）：stdout 出现 sudo/password → 异常中止 → .partialFailure。
    func test_ST05_sudoInOutput_abortsPartialFailure() {
        let installer = makeInstaller(
            command: { _ in ("/bin/sh", ["-c", "echo 'Please enter your password:'; exit 0"]) }
        )
        let result = installer.installAllSync([status("qrencode")])
        if case .partialFailure(let failed) = result {
            XCTAssertEqual(failed, ["qrencode"])
        } else {
            XCTFail("sudo/password 出现应中止为 .partialFailure，实际：\(result)")
        }
    }

    // MARK: - 无 brew 映射依赖

    /// 契约 M3（同步版对齐）：依赖无 brew 映射（brewPackage=nil）→ 无法自动装 → .partialFailure。
    func test_ST06_depWithoutBrew_partialFailure() {
        let installer = makeInstaller(
            command: { _ in ("/bin/sh", ["-c", "exit 0"]) }
        )
        let result = installer.installAllSync([status("custom-tool", brew: nil)])
        if case .partialFailure(let failed) = result {
            XCTAssertEqual(failed, ["custom-tool"])
        } else {
            XCTFail("无 brew 映射应 .partialFailure，实际：\(result)")
        }
    }

    // MARK: - 空列表

    /// 契约 M3（同步版对齐）：空 missing 列表 → .success（无操作）。
    func test_ST08_emptyMissing_returnsSuccess() {
        let installer = makeInstaller(
            command: { _ in ("/bin/sh", ["-c", "exit 0"]) }
        )
        let result = installer.installAllSync([])
        if case .success = result {
            // ok
        } else {
            XCTFail("空列表应返回 .success，实际：\(result)")
        }
    }

    // MARK: - 多依赖部分失败

    /// 契约 M3（同步版对齐）：多依赖逐个装，部分失败只报失败的。
    /// 用 brewPackage 名分流：qrencode → exit 0，imagemagick → exit 1。
    func test_ST09_multipleDeps_partialFailureReportsOnlyFailed() {
        let installer = makeInstaller(
            command: { pkg in
                if pkg == "imagemagick" {
                    return ("/bin/sh", ["-c", "exit 1"])
                }
                return ("/bin/sh", ["-c", "exit 0"])
            }
        )
        let result = installer.installAllSync([
            status("qrencode", brew: "qrencode"),
            status("imagemagick", brew: "imagemagick"),
        ])
        if case .partialFailure(let failed) = result {
            XCTAssertEqual(failed, ["imagemagick"])
        } else {
            XCTFail("部分失败应 .partialFailure 只报失败的，实际：\(result)")
        }
    }

    // MARK: - 进度阶段刷新（@Published progressPhase 非空）

    /// 契约 M3（同步版对齐）：installAllSync 后 progressPhase 非空（pump 期间 onProgress 更新或兜底「安装中…」）。
    /// 验证 @Published 在同步主线程赋值生效（不靠 MainActor.run/Task）。
    func test_ST07_progressPhase_nonEmptyAfterInstall() {
        let installer = makeInstaller(
            command: { _ in ("/bin/sh", ["-c", "echo 'Downloading...'; exit 0"]) }
        )
        _ = installer.installAllSync([status("qrencode")])
        XCTAssertFalse(installer.progressPhase.isEmpty,
                       "progressPhase 必须非空（同步主线程赋值，pump 期间 onProgress 更新或兜底「安装中…」）")
    }

    // MARK: - installingLabel 清空（安装结束）

    /// 契约：installAllSync 结束后 installingLabel = nil（无活跃安装标记，进度窗关闭条件）。
    func test_ST10_installingLabel_clearedAfterInstall() {
        let installer = makeInstaller(
            command: { _ in ("/bin/sh", ["-c", "exit 0"]) }
        )
        _ = installer.installAllSync([status("qrencode")])
        XCTAssertNil(installer.installingLabel,
                     "installAllSync 结束后 installingLabel 必须 nil（无活跃安装标记）")
    }
}

// MARK: - Mock UserDefaults（全局开关测试，与 DependencyInstallerTests.MockDefaults 同模式）

final class SyncMockDefaults: UserDefaults {
    private let enabled: Bool
    init(enabled: Bool) {
        self.enabled = enabled
        super.init(suiteName: "sync-mock-\(UUID().uuidString)")!
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
