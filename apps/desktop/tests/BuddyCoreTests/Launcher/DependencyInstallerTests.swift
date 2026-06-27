import XCTest
@testable import BuddyCore

// MARK: - DependencyInstallerTests
//
// 蓝队单测 T3：DependencyInstaller（brew install 子进程 + 进度 + 取消 + 审计 + 全局开关降级）。
//
// 契约引用（state.md ## 契约规约 M3 + 接口签名 + 错误契约）：
//   final class DependencyInstaller: ObservableObject
//   func installAll(_ missing: [DependencyStatus]) async -> InstallResult
//   enum InstallResult { case success; case partialFailure([String]); case cancelled; case brewMissing; case manualRequired }
//   超时 180s + 取消 SIGTERM 3s→SIGKILL + sudo 中止 + 全局开关关 → .manualRequired
//   审计日志 BuddyLogger subsystem=plugin
//
// 测试策略：注入 ProcessRunner seam（mock 子进程），避免真跑 brew。
// 全局开关注入 DependencySettingsStore mock。
//
// TDD：本文件先于实现编写，最初编译失败（RED），实现后转 GREEN。

@MainActor
final class DependencyInstallerTests: XCTestCase {

    // MARK: - Helpers

    private func status(_ check: String, brew: String? = "pkg", label: String? = "工具") -> DependencyStatus {
        DependencyStatus(check: check, label: label, isInstalled: false, brewPackage: brew)
    }

    /// 构造 installer 注入 mock runner + settings。
    private func makeInstaller(
        runner: @escaping ProcessRunner,
        settings: DependencySettingsStore = DependencySettingsStore(defaults: MockDefaults(enabled: true)),
        brewAvailable: @escaping () -> Bool = { true }
    ) -> DependencyInstaller {
        DependencyInstaller(runner: runner, settings: settings, brewAvailable: brewAvailable)
    }

    // MARK: - 全局开关降级（.manualRequired）

    /// 契约 M3：全局开关 OFF → installAll 不起子进程，返回 .manualRequired。
    func test_AT01_globalSwitchOff_returnsManualRequired() async {
        let settings = DependencySettingsStore(defaults: MockDefaults(enabled: false))
        let runner = MockRunnerFactory.make(behaviors: [])
        let installer = makeInstaller(runner: runner.runner, settings: settings)
        let result = await installer.installAll([status("qrencode")])
        if case .manualRequired = result {
            // ok
        } else {
            XCTFail("全局开关 OFF 应返回 .manualRequired，实际：\(result)")
        }
        XCTAssertEqual(runner.runCount, 0, "全局开关 OFF 不应起任何子进程")
    }

    // MARK: - brewMissing

    /// 契约 M3：brew 不可用 + 依赖有 brew 映射 → .brewMissing。
    func test_AT02_brewMissing_returnsBrewMissing() async {
        let runner = MockRunnerFactory.make(behaviors: [])
        let installer = makeInstaller(runner: runner.runner, brewAvailable: { false })
        let result = await installer.installAll([status("qrencode", brew: "qrencode")])
        if case .brewMissing = result {
            // ok
        } else {
            XCTFail("brew 缺失应返回 .brewMissing，实际：\(result)")
        }
    }

    // MARK: - success

    /// 契约 M3：所有依赖 brew install 成功 → .success。
    func test_AT03_allSucceed_returnsSuccess() async {
        let runner = MockRunnerFactory.make(behaviors: [
            .success(exitCode: 0),
        ])
        let installer = makeInstaller(runner: runner.runner)
        let result = await installer.installAll([status("qrencode")])
        if case .success = result {
            // ok
        } else {
            XCTFail("全成功应返回 .success，实际：\(result)")
        }
        XCTAssertEqual(runner.runCount, 1)
    }

    // MARK: - Q1 弹框内：installAll success 后更新 statuses.isInstalled（按钮 enable 前置）

    /// M4 弹框内 Q1 修复（qa-reviewer Critical）：installAll 成功装完依赖后，重查 locateBinary
    /// 更新 statuses[i].isInstalled = true → TrustPrompt Combine sink allSatisfy(isInstalled)
    /// → enable「允许并运行」按钮（否则按钮永远 disabled，弹框卡死）。
    /// 用系统命令 ls（locateBinary 必返回非 nil）验证更新逻辑。
    func test_AT11_installAll_success_updatesStatusIsInstalled() async {
        let runner = MockRunnerFactory.make(behaviors: [.success(exitCode: 0)])
        let installer = makeInstaller(runner: runner.runner)
        let dep = DependencyStatus(check: "ls", label: "列表命令", isInstalled: false, brewPackage: "ls")
        _ = await installer.installAll([dep])
        let lsStatus = installer.statuses.first { $0.check == "ls" }
        XCTAssertNotNil(lsStatus, "installAll 后 statuses 应含 ls")
        XCTAssertTrue(lsStatus?.isInstalled == true,
                      "installAll success 后 statuses[ls].isInstalled 必须 true（locateBinary('ls') 系统有 → 按钮 enable 契约，Q1）")
    }

    // MARK: - partialFailure

    /// 契约 M3：子进程 exit code != 0 → .partialFailure([失败依赖名])。
    func test_AT04_nonZeroExit_returnsPartialFailure() async {
        let runner = MockRunnerFactory.make(behaviors: [
            .failure(exitCode: 1),
        ])
        let installer = makeInstaller(runner: runner.runner)
        let result = await installer.installAll([status("qrencode")])
        if case .partialFailure(let failed) = result {
            XCTAssertEqual(failed, ["qrencode"])
        } else {
            XCTFail("非零 exit 应 .partialFailure，实际：\(result)")
        }
    }

    /// 契约 M3：stdout 出现 sudo/password → 异常中止 → .partialFailure。
    func test_AT05_sudoInOutput_abortsPartialFailure() async {
        let runner = MockRunnerFactory.make(behaviors: [
            .successWithStderr(stdout: "We trust you have received the usual instructions.\nPlease enter your password:", exitCode: 0),
        ])
        let installer = makeInstaller(runner: runner.runner)
        let result = await installer.installAll([status("qrencode")])
        if case .partialFailure(let failed) = result {
            XCTAssertEqual(failed, ["qrencode"])
        } else {
            XCTFail("sudo/password 出现应中止为 .partialFailure，实际：\(result)")
        }
    }

    // MARK: - 无 brew 映射依赖（无 sudo 场景）

    /// 契约 M3：依赖无 brew 映射（brewPackage=nil）→ 无法自动装 → .partialFailure。
    func test_AT06_depWithoutBrew_partialFailure() async {
        let runner = MockRunnerFactory.make(behaviors: [])
        let installer = makeInstaller(runner: runner.runner)
        let result = await installer.installAll([status("custom-tool", brew: nil)])
        if case .partialFailure(let failed) = result {
            XCTAssertEqual(failed, ["custom-tool"])
        } else {
            XCTFail("无 brew 映射应 .partialFailure，实际：\(result)")
        }
        XCTAssertEqual(runner.runCount, 0, "无 brew 映射不应起子进程")
    }

    // MARK: - cancelled

    /// 契约 M3：用户取消 → .cancelled。
    func test_AT07_cancel_returnsCancelled() async {
        let runner = MockRunnerFactory.make(behaviors: [
            .cancelled,
        ])
        let installer = makeInstaller(runner: runner.runner)
        let result = await installer.installAll([status("qrencode")])
        if case .cancelled = result {
            // ok
        } else {
            XCTFail("取消应返回 .cancelled，实际：\(result)")
        }
    }

    // MARK: - 空列表

    /// 契约 M3：空 missing 列表 → .success（无操作）。
    func test_AT08_emptyMissing_returnsSuccess() async {
        let runner = MockRunnerFactory.make(behaviors: [])
        let installer = makeInstaller(runner: runner.runner)
        let result = await installer.installAll([])
        if case .success = result {
            // ok
        } else {
            XCTFail("空列表应返回 .success，实际：\(result)")
        }
        XCTAssertEqual(runner.runCount, 0)
    }

    // MARK: - 多依赖顺序安装

    /// 契约 M3：多依赖逐个装，部分失败只报失败的。
    func test_AT09_multipleDeps_partialFailureReportsOnlyFailed() async {
        let runner = MockRunnerFactory.make(behaviors: [
            .success(exitCode: 0),   // qrencode ok
            .failure(exitCode: 1),   // imagemagick fail
        ])
        let installer = makeInstaller(runner: runner.runner)
        let result = await installer.installAll([
            status("qrencode"),
            status("imagemagick"),
        ])
        if case .partialFailure(let failed) = result {
            XCTAssertEqual(failed, ["imagemagick"])
        } else {
            XCTFail("部分失败应 .partialFailure 只报失败的，实际：\(result)")
        }
        XCTAssertEqual(runner.runCount, 2)
    }
}

// MARK: - Mock ProcessRunner（闭包 seam）

/// 测试 mock runner：返回闭包 + runCount 访问器（闭包内递增共享 Counter）。
final class MockRunnerFactory {
    enum Behavior {
        case success(exitCode: Int32)
        case failure(exitCode: Int32)
        case successWithStderr(stdout: String, exitCode: Int32)
        case cancelled
    }

    /// 计数器引用（闭包内可变，测试外可读）。
    final class Counter {
        var runCount: Int = 0
        var index: Int = 0
    }

    let runner: ProcessRunner
    let counter: Counter

    private init(runner: @escaping ProcessRunner, counter: Counter) {
        self.runner = runner
        self.counter = counter
    }

    var runCount: Int { counter.runCount }

    static func make(behaviors: [Behavior]) -> MockRunnerFactory {
        let counter = Counter()
        let runner: ProcessRunner = { _, _, _ in
            let behavior = behaviors[min(counter.index, behaviors.count - 1)]
            counter.index += 1
            counter.runCount += 1
            switch behavior {
            case .success(let code):
                return ProcessRunResult(exitCode: code, stdout: "Installed", stderr: "", wasCancelled: false)
            case .failure(let code):
                return ProcessRunResult(exitCode: code, stdout: "", stderr: "Error", wasCancelled: false)
            case .successWithStderr(let stdout, let code):
                return ProcessRunResult(exitCode: code, stdout: stdout, stderr: "", wasCancelled: false)
            case .cancelled:
                return ProcessRunResult(exitCode: -1, stdout: "", stderr: "", wasCancelled: true)
            }
        }
        return MockRunnerFactory(runner: runner, counter: counter)
    }
}

// MARK: - Mock UserDefaults（全局开关测试）

final class MockDefaults: UserDefaults {
    private let enabled: Bool
    init(enabled: Bool) {
        self.enabled = enabled
        super.init(suiteName: "mock-\(UUID().uuidString)")!
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
