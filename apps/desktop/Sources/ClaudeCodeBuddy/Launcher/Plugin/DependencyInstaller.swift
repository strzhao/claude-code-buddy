import Foundation

// MARK: - InstallResult

/// M3：installAll 结果（契约 state.md ## 接口签名 + 错误契约）。
///
/// - `.success`：全部依赖装好
/// - `.partialFailure([String])`：部分失败，参数为失败的 check 名列表
/// - `.cancelled`：用户取消
/// - `.brewMissing`：brew 未装（无法自动安装 brew 映射依赖）
/// - `.manualRequired`：全局开关关（降级，不起子进程，UI 回退显示命令 + 复制）
enum InstallResult: Equatable {
    case success
    case partialFailure([String])
    case cancelled
    case brewMissing
    case manualRequired
}

// MARK: - DependencySettingsStore（全局开关，T6 同源）

/// M3/M7：自动安装依赖全局开关持久化。
///
/// 存储：`UserDefaults.standard`，key `buddy.launcher.plugin.autoInstallDeps`（Bool）。
/// 默认 ON（无 key = true）。
///
/// 关闭语义（M7）：installAll 不起子进程，返回 .manualRequired，TrustPromptView 回退显示命令 + 复制。
/// 与 BuiltinPluginEnabledStore / MarketplaceAutoUpdateStore 同模式（UserDefaults Bool 默认 true）。
final class DependencySettingsStore {

    static let shared = DependencySettingsStore()

    /// M7 契约 key 逐字：`buddy.launcher.plugin.autoInstallDeps`。
    static let autoInstallKey = "buddy.launcher.plugin.autoInstallDeps"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 自动安装是否启用。默认（无 key）= true。
    var isEnabled: Bool {
        if defaults.object(forKey: Self.autoInstallKey) == nil { return true }
        return defaults.bool(forKey: Self.autoInstallKey)
    }

    /// 设置开关。
    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.autoInstallKey)
    }

    /// 测试用：重置到默认（移除 key，回默认 true）。
    func reset() {
        defaults.removeObject(forKey: Self.autoInstallKey)
    }
}

// MARK: - ProcessRunner（子进程执行抽象）

/// M3：子进程执行闭包类型（seam，供测试注入 mock，生产用 brewProcessRunner 默认实现）。
///
/// 采用闭包而非 protocol，避免 `any ProcessRunner` 跨 @MainActor 边界的 strict concurrency 限制
/// （与 BinaryLocator / brewLocator 同模式）。
/// 签名：(command, arguments, onProgress 回调) async -> ProcessRunResult
typealias ProcessRunner = (
    _ command: String,
    _ arguments: [String],
    _ onProgress: ((String) -> Void)?
) async -> ProcessRunResult

/// 子进程执行结果。
struct ProcessRunResult: Equatable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let wasCancelled: Bool
}

/// 子进程执行的可变状态（readabilityHandler 闭包捕获 + cancel 标记，B3 cancel 通道）。
///
/// 提升为文件级类型：BrewProcessRunner.runOnce 与 cancel() 共享访问 cancelled 标记。
final class BrewRunState: @unchecked Sendable {
    let lock = NSLock()
    var stdoutAccum = Data()
    var stderrAccum = Data()
    var cancelled = false
}

// MARK: - CancellableBrewRunnerProtocol（cancel 通道 seam，B3）

/// M3：可取消的 brew 子进程执行器协议（B3 cancel 通道）。
///
/// 生产实现 = `BrewProcessRunner`（持有当前 Process 句柄，cancel 调 terminate）；
/// 测试用 spy 注入（`CancellableBrewRunnerSpy`，记录 cancel 调用）。
///
/// 协议化目的：DependencyInstaller 持有可取消 runner 引用，cancel() 委托给 runner.cancel()，
/// 避免 DependencyInstaller 直接管理 Process 句柄（关注点分离）。
@MainActor
protocol CancellableBrewRunnerProtocol: AnyObject {
    /// 构造 ProcessRunner 闭包（seam 兼容，供 installAll 内 await runner(...) 调用）。
    func makeRunner(timeoutSec: Int, sigkillGraceSec: Int) -> ProcessRunner
    /// 取消当前子进程（SIGTERM + sigkillGraceSec 后 SIGKILL 兜底）。
    func cancel()
}

// MARK: - BrewProcessRunner（生产实现，B3：可取消实例）

/// M3：生产 brew install 子进程执行器（B3 改造：从 enum 闭包工厂改为 final class 实例，支持 cancel）。
///
/// 知识库引用：
/// - swift-process-async-bridge-terminationhandler：terminationHandler async 桥（禁 waitUntilExit 死锁）
/// - process-sigkill-orphan-pipe-readtoend-deadlock：Pipe readabilityHandler 异步读避免 orphan pipe 死锁
///
/// 取消（B3 cancel 通道）：
/// - `cancel()` 调 `currentProcess?.terminate()`（SIGTERM）
/// - sigkillGraceSec（默认 3）后若仍运行 → SIGKILL（对进程组发 -pid）
/// - 与原超时路径 SIGTERM/SIGKILL 同模式，复用 RunState.cancelled 标记
///
/// 向后兼容：`makeRunner(timeoutSec:sigkillGraceSec:)` 返回 `ProcessRunner` 闭包，
/// 签名与红队测试注入的闭包 seam 一致（installAll 内 `await runner(...)` 调用形态不变）。
@MainActor
final class BrewProcessRunner: CancellableBrewRunnerProtocol {

    /// 默认超时（brew update 慢容忍）。
    static let defaultTimeoutSec = 180
    /// SIGTERM 后 SIGKILL 兜底宽限期。
    static let defaultSigkillGraceSec = 3

    /// 当前活跃子进程句柄（cancel 用，nil = 无活跃进程）。
    private var currentProcess: Process?
    /// 当前活跃子进程的 BrewRunState（cancel 时标记 cancelled）。
    private var currentRunState: BrewRunState?

    init() {}

    /// 构造 ProcessRunner 闭包（实例方法，捕获 self 持有 Process 句柄）。
    func makeRunner(
        timeoutSec: Int = defaultTimeoutSec,
        sigkillGraceSec: Int = defaultSigkillGraceSec
    ) -> ProcessRunner {
        return { [weak self] command, arguments, onProgress in
            await self?.runOnce(
                command: command,
                arguments: arguments,
                onProgress: onProgress,
                timeoutSec: timeoutSec,
                sigkillGraceSec: sigkillGraceSec
            ) ?? ProcessRunResult(exitCode: -1, stdout: "", stderr: "runner released", wasCancelled: false)
        }
    }

    /// B3 cancel：终止当前子进程（SIGTERM + sigkillGraceSec 后 SIGKILL 兜底）。
    func cancel() {
        guard let process = currentProcess, process.isRunning else { return }
        currentRunState?.lock.lock()
        currentRunState?.cancelled = true
        currentRunState?.lock.unlock()
        let pid = process.processIdentifier
        process.terminate()  // SIGTERM
        // sigkillGraceSec 后 SIGKILL 兜底（与超时路径同模式）
        let grace = BrewProcessRunner.defaultSigkillGraceSec
        Task.detached { [weak process] in
            try? await Task.sleep(for: .seconds(grace))
            guard let p = process, p.isRunning else { return }
            kill(-pid, SIGKILL)
            kill(pid, SIGKILL)
        }
    }

    /// 单次执行（实例方法，记录 currentProcess/currentRunState 供 cancel 用）。
    private func runOnce(
        command: String,
        arguments: [String],
        onProgress: ((String) -> Void)?,
        timeoutSec: Int,
        sigkillGraceSec: Int
    ) async -> ProcessRunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // 进度状态（文件级 BrewRunState，readabilityHandler 闭包捕获 + cancel 标记）
        let state = BrewRunState()
        // 记录当前 Process + BrewRunState 供 cancel() 用（B3 cancel 通道）
        currentProcess = process
        currentRunState = state

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            state.lock.lock()
            state.stdoutAccum.append(chunk)
            state.lock.unlock()
            if !chunk.isEmpty, let str = String(data: chunk, encoding: .utf8) {
                onProgress?(str)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            state.lock.lock()
            state.stderrAccum.append(chunk)
            state.lock.unlock()
        }

        guard (try? process.run()) != nil else {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            currentProcess = nil
            currentRunState = nil
            return ProcessRunResult(exitCode: -1, stdout: "", stderr: "process.run 失败", wasCancelled: false)
        }

        // terminationHandler async 桥（不阻塞线程）
        final class ResumeGuard: @unchecked Sendable {
            let lock = NSLock()
            var done = false
            func tryResume(_ block: () -> Void) {
                lock.lock()
                defer { lock.unlock() }
                guard !done else { return }
                done = true
                block()
            }
        }
        let guard_ = ResumeGuard()

        let timedOut: Bool = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let timeoutTask = Task.detached {
                try? await Task.sleep(for: .seconds(timeoutSec))
                guard !Task.isCancelled else { return }
                guard process.isRunning else { return }
                state.lock.lock()
                state.cancelled = true
                state.lock.unlock()
                guard_.tryResume { cont.resume(returning: true) }
                let pid = process.processIdentifier
                process.terminate()
                Task.detached {
                    try? await Task.sleep(for: .seconds(sigkillGraceSec))
                    if process.isRunning {
                        kill(-pid, SIGKILL)
                        kill(pid, SIGKILL)
                    }
                }
            }
            process.terminationHandler = { _ in
                timeoutTask.cancel()
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                guard_.tryResume { cont.resume(returning: false) }
            }
            if !process.isRunning {
                timeoutTask.cancel()
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                guard_.tryResume { cont.resume(returning: false) }
            }
        }

        let stdoutStr = String(data: state.stdoutAccum, encoding: .utf8) ?? ""
        let stderrStr = String(data: state.stderrAccum, encoding: .utf8) ?? ""

        // 清理 currentProcess/RunState（进程已终止，cancel 不应再触发）
        currentProcess = nil
        currentRunState = nil

        // cancelled 标记：超时或用户 cancel 触发 SIGTERM 后，state.cancelled == true
        state.lock.lock()
        let cancelledFlag = state.cancelled
        state.lock.unlock()
        let wasCancelled = timedOut || cancelledFlag
        if wasCancelled {
            return ProcessRunResult(exitCode: process.terminationStatus, stdout: stdoutStr, stderr: stderrStr, wasCancelled: true)
        }
        return ProcessRunResult(exitCode: process.terminationStatus, stdout: stdoutStr, stderr: stderrStr, wasCancelled: false)
    }
}

// MARK: - NoOpCancellableRunner（注入 runner 闭包测试路径的 cancel 占位）

/// B3：注入 runner 闭包测试路径的 cancel 占位 runner。
///
/// DependencyInstaller 的 `init(runner:)` 闭包 seam 路径（红队测试注入 mock ProcessRunner），
/// cancel 走此 no-op（测试用 wasCancelled=true 模拟取消语义，cancel() 不应真触发进程终止）。
@MainActor
final class NoOpCancellableRunner: CancellableBrewRunnerProtocol {
    func makeRunner(timeoutSec: Int = 180, sigkillGraceSec: Int = 3) -> ProcessRunner {
        return { _, _, _ in
            ProcessRunResult(exitCode: 0, stdout: "", stderr: "", wasCancelled: false)
        }
    }
    func cancel() {}
}

// MARK: - DependencyInstaller

/// M3：装缺失依赖，报告进度。
///
/// 职责（契约 state.md ## 契约规约 M3）：
/// - 子进程 `brew install <brewPackage>`（Process + terminationHandler async 桥）
/// - 无 sudo，stdout 出现 sudo/password 视为异常中止
/// - 实时读 stdout → 解析阶段（Updating / Downloading / Installing）→ progressPhase（兜底降级「安装中…」）
/// - 超时 180s + 用户取消（SIGTERM 3s→SIGKILL）
/// - 审计日志 BuddyLogger subsystem=plugin 记 {dep, 命令, result, 耗时ms}
/// - 全局开关 `buddy.launcher.plugin.autoInstallDeps`（默认 true）关时返回 .manualRequired
@MainActor
final class DependencyInstaller: ObservableObject {

    static let shared = DependencyInstaller()

    /// 实时状态（供 SwiftUI 刷新，阶段 2 非模态进度窗用）。
    @Published var statuses: [DependencyStatus] = []
    /// 当前装的依赖 label。
    @Published var installingLabel: String?
    /// 进度阶段文字（"Updating" / "Downloading" / "Installing" / "安装中…"）。
    @Published var progressPhase: String = ""

    private var runner: ProcessRunner
    private let settings: DependencySettingsStore
    /// brew 可用性检查 seam（默认用 DependencyResolver.shared.brewAvailability）。
    private let brewAvailable: () -> Bool
    /// B3 cancel 通道：持有可取消 runner 实例（cancel 委托给 runner.cancel()）。
    /// 默认用 BrewProcessRunner 生产实例（持有当前 Process 句柄，cancel 调 terminate SIGTERM）。
    private let cancellableRunner: CancellableBrewRunnerProtocol
    /// M4 弹框内：modal-safe 刷新 Timer（NSApp.runModal modal runloop 用 NSModalPanelRunLoopMode，
    /// 不 pump common modes 的 GCD main queue / SwiftUI invalidation —— plan-reviewer 当初论证 common modes
    /// 含 modal 是错的，BLOCKER 5 担忧正确；靠 Timer .modal mode 定期 objectWillChange.send 强制 SwiftUI 刷新进度区）。
    private var refreshTimer: Timer?

    /// installAllSync cancel 通道：当前活跃同步子进程句柄（cancel 调 terminate SIGTERM）。
    /// nil = 无活跃同步安装（installAllSync 未运行或已结束）。
    private var currentSyncProcess: Process?
    /// installAllSync cancel 通道：当前活跃同步子进程的可变状态（cancel 标记 cancelled）。
    private var currentSyncState: BrewRunState?
    /// installAllSync 命令构造 seam（测试注入 `/bin/sh -c "exit 0"` 等假命令，生产默认 brew install）。
    /// 返回 (command, arguments) 元组，供 runProcessSync 起子进程。
    var syncCommandBuilder: (_ brewPackage: String) -> (command: String, arguments: [String]) = { pkg in
        ("/bin/sh", ["-c", "brew install \(pkg)"])
    }

    /// 启动 modal-safe 刷新（installAll 期间，runModal 内 @Published → SwiftUI 刷新靠 .modal mode pump）。
    private func startModalRefreshTimer() {
        refreshTimer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            // Timer block 在主线程（RunLoop.main .modal mode 触发），objectWillChange.send 强制 SwiftUI 读最新 @Published
            self?.objectWillChange.send()
        }
        if let t = refreshTimer {
            // 加 common + NSModalPanelRunLoopMode 双模式：Apple modal session runloop 跑 common modes，
            // 但实测 SwiftUI invalidation 在纯 common 也未必 pump，额外加 modal mode rawValue 兜底
            RunLoop.main.add(t, forMode: .common)
            RunLoop.main.add(t, forMode: RunLoop.Mode(rawValue: "NSModalPanelRunLoopMode"))
        }
    }

    private func stopModalRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    /// 默认 init：生产路径用 BrewProcessRunner 实例（runner 闭包 + cancellableRunner 都来自同一实例）。
    init(
        settings: DependencySettingsStore = .shared,
        brewAvailable: @escaping () -> Bool = { DependencyResolver.shared.brewAvailability() != .missing }
    ) {
        let brewRunner = BrewProcessRunner()
        self.cancellableRunner = brewRunner
        self.runner = brewRunner.makeRunner()
        self.settings = settings
        self.brewAvailable = brewAvailable
    }

    /// 注入 runner 闭包（红队测试 seam 兼容，cancel 走 no-op spy 避免误触发真进程）。
    init(
        runner: @escaping ProcessRunner,
        settings: DependencySettingsStore = .shared,
        brewAvailable: @escaping () -> Bool = { DependencyResolver.shared.brewAvailability() != .missing }
    ) {
        self.runner = runner
        self.settings = settings
        self.brewAvailable = brewAvailable
        // 注入 runner 闭包测试路径：cancel 用 no-op runner（测试用 wasCancelled=true 模拟）
        self.cancellableRunner = NoOpCancellableRunner()
    }

    /// M4 弹框内：注入可取消 runner（cancel 通道测试用，accessoryView 取消按钮调 installer.cancel()）。
    init(
        cancellableRunner: CancellableBrewRunnerProtocol,
        settings: DependencySettingsStore = .shared,
        brewAvailable: @escaping () -> Bool = { DependencyResolver.shared.brewAvailability() != .missing }
    ) {
        self.cancellableRunner = cancellableRunner
        self.runner = cancellableRunner.makeRunner(
            timeoutSec: BrewProcessRunner.defaultTimeoutSec,
            sigkillGraceSec: BrewProcessRunner.defaultSigkillGraceSec
        )
        self.settings = settings
        self.brewAvailable = brewAvailable
    }

    /// 装缺失依赖。
    /// - Parameter missing: 缺失依赖列表（DependencyResolver.collectMissing 结果）
    /// - Returns: InstallResult
    func installAll(_ missing: [DependencyStatus]) async -> InstallResult {
        // 全局开关降级（不起子进程）
        guard settings.isEnabled else {
            BuddyLogger.shared.info("installAll skipped: autoInstall disabled", subsystem: "plugin", meta: ["deps": missing.map(\.check)])
            return .manualRequired
        }

        // 空列表短路
        guard !missing.isEmpty else { return .success }

        // brew 可用性检查（有 brew 映射依赖时）
        let hasBrewDep = missing.contains { $0.brewPackage != nil }
        if hasBrewDep, !brewAvailable() {
            BuddyLogger.shared.warn("installAll aborted: brew missing", subsystem: "plugin", meta: ["deps": missing.map(\.check)])
            return .brewMissing
        }

        await MainActor.run {
            self.statuses = missing
        }
        // M4 弹框内：启动 modal-safe 刷新 Timer（runModal modal runloop 不 pump common modes，
        // 靠 Timer .modal mode 定期 objectWillChange.send 强制 SwiftUI 刷新进度区）
        startModalRefreshTimer()
        defer { stopModalRefreshTimer() }

        var failed: [String] = []
        for dep in missing {
            await MainActor.run {
                self.installingLabel = dep.label ?? dep.check
                self.progressPhase = "安装中…"
            }

            // 无 brew 映射依赖：无法自动装
            guard let brewPackage = dep.brewPackage else {
                BuddyLogger.shared.warn("installAll: dep has no brew mapping, skip", subsystem: "plugin", meta: ["dep": dep.check])
                failed.append(dep.check)
                continue
            }

            let startTime = Date()
            let result = await runner(
                "/bin/sh",
                ["-c", "brew install \(brewPackage)"],
                { [weak self] output in
                    Task { @MainActor in
                        self?.progressPhase = DependencyInstaller.parsePhase(from: output)
                    }
                }
            )
            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)

            // 取消
            if result.wasCancelled {
                BuddyLogger.shared.info("installAll cancelled", subsystem: "plugin", meta: ["dep": dep.check, "duration_ms": durationMs])
                await MainActor.run {
                    self.installingLabel = nil
                    self.progressPhase = ""
                }
                return .cancelled
            }

            // sudo/password 异常中止（无 sudo 契约）
            let combinedOutput = result.stdout + result.stderr
            if Self.containsSudoPrompt(combinedOutput) {
                BuddyLogger.shared.warn("installAll aborted: sudo prompt detected", subsystem: "plugin", meta: ["dep": dep.check, "duration_ms": durationMs])
                failed.append(dep.check)
                continue
            }

            // exit code 非 0
            if result.exitCode != 0 {
                BuddyLogger.shared.warn("installAll failed", subsystem: "plugin", meta: ["dep": dep.check, "exit": result.exitCode, "duration_ms": durationMs])
                failed.append(dep.check)
                continue
            }

            BuddyLogger.shared.info("installAll success", subsystem: "plugin", meta: ["dep": dep.check, "duration_ms": durationMs])
            // M4 弹框内 Q1 修复：装后重查命令存在性，更新 statuses[i].isInstalled
            // → TrustPrompt Combine sink allSatisfy(isInstalled) 为 true → enable「允许并运行」按钮
            let extPath = DependencyResolver.makeExtendedPathPublic()
            let nowInstalled = DependencyResolver.defaultBinaryLocator(dep.check, extPath) != nil
            await MainActor.run {
                if let idx = self.statuses.firstIndex(where: { $0.check == dep.check }) {
                    self.statuses[idx] = DependencyStatus(
                        check: dep.check, label: dep.label,
                        isInstalled: nowInstalled, brewPackage: dep.brewPackage)
                }
            }
        }

        await MainActor.run {
            self.installingLabel = nil
            // progressPhase 保留最后解析的阶段（供调用方验证阶段被解析过 + UI 完成态显示；
            // installingLabel=nil 标记无活跃安装，进度窗关闭后 progressPhase 不可见，下次 installAll 会重新设）
        }

        return failed.isEmpty ? .success : .partialFailure(failed)
    }

    // MARK: - installAllSync（modal runloop 同步版，绕 Task @MainActor 不 pump）

    /// M4 弹框内修订（蓝队 modal runloop 修复）：同步版装缺失依赖。
    ///
    /// **根因**（铁证日志）：`NSApp.runModal(for:)` 的 modal runloop（NSModalPanelRunLoopMode）
    /// **不 pump GCD main queue**，导致 `Task { @MainActor in installAll }` 在弹框关闭后才执行
    /// （实测点击后 51s 才 `Task started`）。所以 installAll async 在弹框内根本跑不动 →
    /// 进度不刷新 + 装后不重查 isInstalled + 按钮永不 enable。
    ///
    /// **修复**：installAllSync 在主线程同步执行（不 Task）：
    /// - `Process.run()` 非阻塞起子进程
    /// - `while process.isRunning { RunLoop.current.run(until: now+0.05) }` pump 嵌套 modal/common runloop
    ///   → process 期间 Timer（.common + NSModalPanelRunLoopMode）触发 objectWillChange.send
    ///   → @Published 刷新 → SwiftUI 重绘读最新 statuses/installingLabel/progressPhase
    /// - readabilityHandler 后台线程累积 stdout/stderr 到 BrewRunState（NSLock 保护）
    /// - onProgress 回调同步主线程更新 progressPhase（installAllSync 在主线程，@MainActor 类）
    ///
    /// **逻辑一致性**（红队 lock installAll async 不破坏）：业务分支与 installAll async 逐字一致 ——
    /// 全局开关关 → .manualRequired；空列表 → .success；brew 缺失 → .brewMissing；
    /// 循环逐 dep 装：无 brew 映射 → failed.append；装后 Q1 重查 locateBinary 更新 statuses[i].isInstalled；
    /// cancel → .cancelled；sudo 异常中止 → failed.append；exit != 0 → failed.append；
    /// 审计日志 BuddyLogger subsystem=plugin {dep, 命令, result, 耗时ms}；结束返 failed.isEmpty ? .success : .partialFailure(failed)。
    ///
    /// - Parameter missing: 缺失依赖列表
    /// - Returns: InstallResult（与 installAll async 同枚举同语义）
    func installAllSync(_ missing: [DependencyStatus]) -> InstallResult {
        // 全局开关降级（不起子进程）
        guard settings.isEnabled else {
            BuddyLogger.shared.info("installAllSync skipped: autoInstall disabled", subsystem: "plugin", meta: ["deps": missing.map(\.check)])
            return .manualRequired
        }

        // 空列表短路
        guard !missing.isEmpty else { return .success }

        // brew 可用性检查（有 brew 映射依赖时）
        let hasBrewDep = missing.contains { $0.brewPackage != nil }
        if hasBrewDep, !brewAvailable() {
            BuddyLogger.shared.warn("installAllSync aborted: brew missing", subsystem: "plugin", meta: ["deps": missing.map(\.check)])
            return .brewMissing
        }

        statuses = missing
        // modal-safe 刷新 Timer（process 期间 RunLoop.run pump → Timer 触发 objectWillChange.send）
        startModalRefreshTimer()
        defer { stopModalRefreshTimer() }

        var failed: [String] = []
        for dep in missing {
            installingLabel = dep.label ?? dep.check
            progressPhase = "安装中…"

            // 无 brew 映射依赖：无法自动装
            guard let brewPackage = dep.brewPackage else {
                BuddyLogger.shared.warn("installAllSync: dep has no brew mapping, skip", subsystem: "plugin", meta: ["dep": dep.check])
                failed.append(dep.check)
                continue
            }

            let startTime = Date()
            let cmd = syncCommandBuilder(brewPackage)
            let result = runProcessSync(
                command: cmd.command,
                arguments: cmd.arguments,
                onProgress: { [weak self] output in
                    // 同步主线程更新（installAllSync 在主线程调用，onProgress 由 readabilityHandler 后台线程触发，
                    // 但 self 是 @MainActor 类，赋值走 actor 隔离 —— RunLoop.run pump 期间主线程可执行）
                    // 注：readabilityHandler 在后台队列触发，此处用 DispatchQueue.main 同步派发（modal pump 期间执行）
                    DispatchQueue.main.sync {
                        self?.progressPhase = DependencyInstaller.parsePhase(from: output)
                    }
                }
            )
            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)

            // 取消
            if result.wasCancelled {
                BuddyLogger.shared.info("installAllSync cancelled", subsystem: "plugin", meta: ["dep": dep.check, "duration_ms": durationMs])
                installingLabel = nil
                progressPhase = ""
                return .cancelled
            }

            // sudo/password 异常中止（无 sudo 契约）
            let combinedOutput = result.stdout + result.stderr
            if Self.containsSudoPrompt(combinedOutput) {
                BuddyLogger.shared.warn("installAllSync aborted: sudo prompt detected", subsystem: "plugin", meta: ["dep": dep.check, "duration_ms": durationMs])
                failed.append(dep.check)
                continue
            }

            // exit code 非 0
            if result.exitCode != 0 {
                BuddyLogger.shared.warn("installAllSync failed", subsystem: "plugin", meta: ["dep": dep.check, "exit": result.exitCode, "duration_ms": durationMs])
                failed.append(dep.check)
                continue
            }

            BuddyLogger.shared.info("installAllSync success", subsystem: "plugin", meta: ["dep": dep.check, "duration_ms": durationMs])
            // Q1 修复：装后重查命令存在性，更新 statuses[i].isInstalled（按钮 enable 前置）
            let extPath = DependencyResolver.makeExtendedPathPublic()
            let nowInstalled = DependencyResolver.defaultBinaryLocator(dep.check, extPath) != nil
            if let idx = statuses.firstIndex(where: { $0.check == dep.check }) {
                statuses[idx] = DependencyStatus(
                    check: dep.check, label: dep.label,
                    isInstalled: nowInstalled, brewPackage: dep.brewPackage)
            }
        }

        installingLabel = nil
        // progressPhase 保留最后解析的阶段（同 installAll async 语义）

        return failed.isEmpty ? .success : .partialFailure(failed)
    }

    /// 同步执行子进程 + while pump modal/common runloop（process 期间刷新 @Published + SwiftUI）。
    ///
    /// 知识库引用：
    /// - process-while-pump-modal-runloop：modal session 下同步等子进程退出靠 RunLoop.current.run(until:) pump
    /// - process-sigkill-orphan-pipe-readtoend-deadlock：Pipe readabilityHandler 异步读避免死锁
    ///
    /// cancel 通道：currentSyncProcess + currentSyncState（cancel() 同步读取标记 cancelled + terminate）。
    private func runProcessSync(
        command: String,
        arguments: [String],
        onProgress: ((String) -> Void)?
    ) -> ProcessRunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let state = BrewRunState()
        // cancel 通道：记录当前 Process + RunState（cancel() 调 process.terminate + 标记 state.cancelled）
        currentSyncProcess = process
        currentSyncState = state

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            state.lock.lock()
            state.stdoutAccum.append(chunk)
            state.lock.unlock()
            if !chunk.isEmpty, let str = String(data: chunk, encoding: .utf8) {
                onProgress?(str)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            state.lock.lock()
            state.stderrAccum.append(chunk)
            state.lock.unlock()
        }

        guard (try? process.run()) != nil else {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            currentSyncProcess = nil
            currentSyncState = nil
            return ProcessRunResult(exitCode: -1, stdout: "", stderr: "process.run 失败", wasCancelled: false)
        }

        // 【关键】while pump：process 期间 pump modal/common runloop
        // （让 Timer（.common + NSModalPanelRunLoopMode）触发 objectWillChange.send 刷新 SwiftUI，
        //   让 DispatchQueue.main.sync 的 progressPhase 赋值执行，让 readabilityHandler 累积 stdout）
        while process.isRunning {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        }

        // process 完成：清理 readabilityHandler（防回调泄漏）
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        let stdoutStr = String(data: state.stdoutAccum, encoding: .utf8) ?? ""
        let stderrStr = String(data: state.stderrAccum, encoding: .utf8) ?? ""

        // 清理 cancel 通道（进程已终止）
        currentSyncProcess = nil
        currentSyncState = nil

        state.lock.lock()
        let cancelledFlag = state.cancelled
        state.lock.unlock()

        return ProcessRunResult(
            exitCode: process.terminationStatus,
            stdout: stdoutStr,
            stderr: stderrStr,
            wasCancelled: cancelledFlag
        )
    }

    /// B3：取消当前安装（阶段 2 进度窗的取消按钮调用）。
    ///
    /// 委托给 cancellableRunner.cancel()（SIGTERM + sigkillGraceSec=3 后 SIGKILL 兜底）。
    /// 审计日志 subsystem=plugin（B3 要求）。
    /// installAll 五结果语义不变（cancel 后 installAll 返回 .cancelled，红队 lock）。
    ///
    /// installAllSync 同样走此入口：currentSyncProcess.terminate + 标记 currentSyncState.cancelled
    /// → while pump 下一拍 process 终止 → runProcessSync 返 wasCancelled=true → installAllSync 返 .cancelled。
    func cancel() {
        BuddyLogger.shared.info("installAll cancel requested by user", subsystem: "plugin", meta: [:])
        // installAllSync 路径：终止当前同步子进程 + 标记 cancelled
        // （runProcessSync while pump 下一拍 process.isRunning=false → 读 cancelledFlag=true → 返 wasCancelled=true）
        if let proc = currentSyncProcess, proc.isRunning {
            currentSyncState?.lock.lock()
            currentSyncState?.cancelled = true
            currentSyncState?.lock.unlock()
            let pid = proc.processIdentifier
            proc.terminate()  // SIGTERM
            // SIGKILL 兜底（与 BrewProcessRunner.cancel 同模式，sigkillGraceSec=3）
            Task.detached { [weak proc] in
                try? await Task.sleep(for: .seconds(BrewProcessRunner.defaultSigkillGraceSec))
                guard let p = proc, p.isRunning else { return }
                kill(-pid, SIGKILL)
                kill(pid, SIGKILL)
            }
            return
        }
        // installAll async 路径（红队 lock 保留）：委托 cancellableRunner
        cancellableRunner.cancel()
    }

    // MARK: - 进度解析（兜底降级）

    /// 解析 brew stdout 阶段文字。失败降级「安装中…」（不 crash，不卡错误阶段）。
    private static func parsePhase(from output: String) -> String {
        let lower = output.lowercased()
        if lower.contains("updating") || lower.contains("already installed") { return "Updating" }
        if lower.contains("downloading") { return "Downloading" }
        if lower.contains("installing") || lower.contains("pouring") { return "Installing" }
        // 兜底：brew 版本升级改文案时容错
        return "安装中…"
    }

    /// 检测 sudo/password 提示（无 sudo 契约：出现即异常中止）。
    private static func containsSudoPrompt(_ output: String) -> Bool {
        let lower = output.lowercased()
        return lower.contains("password") || lower.contains("[sudo]")
    }
}
