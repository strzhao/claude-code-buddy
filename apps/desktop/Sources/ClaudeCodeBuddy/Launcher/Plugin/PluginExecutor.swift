import Foundation

final class PluginExecutor {
    static let shared = PluginExecutor()

    init() {}

    func execute(_ plugin: PluginManifest, pluginDir: URL, input: PluginInput) async throws -> PluginResult {
        // 1. 预检查 requiredPath（每个 binary 在扩展 PATH 中查找，缺失抛 pluginMissingDependency）
        if let required = plugin.requiredPath {
            let extPath = makeExtendedPath()
            for binary in required {
                guard locateBinary(binary, in: extPath) != nil else {
                    throw LauncherError.pluginMissingDependency(binary)
                }
            }
        }

        // 2. 构造 Process
        let process = Process()
        process.executableURL = pluginDir.appending(path: plugin.cmd)
        process.arguments = plugin.args
        process.currentDirectoryURL = pluginDir

        // 3. 构造 environment（PATH 前缀在前 + 当前环境 + manifest.env）
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = makeExtendedPath()
        if let pluginEnv = plugin.env {
            for (key, value) in pluginEnv { env[key] = value }
        }
        process.environment = env

        // 4. Pipe
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // 5. 启动（设置进程组，方便 SIGKILL 整组终止）
        let startTime = Date()
        do {
            // 设置 qualityOfService 不影响 pgid；Process.run() 后可用 setsid 或直接用 pid 负数 kill
            try process.run()
        } catch {
            throw LauncherError.pluginCrash(-1, "process.run 失败：\(error.localizedDescription)")
        }

        // 6. 写入 stdin（JSON 输入）+ 关闭
        let inputData = try JSONEncoder().encode(input)
        try stdinPipe.fileHandleForWriting.write(contentsOf: inputData)
        try stdinPipe.fileHandleForWriting.close()

        // 7. 并发读 stdout/stderr（deadline = timeout + grace + 余量，超时强制 close 避免 orphan child block）
        let readDeadline = Date().addingTimeInterval(
            TimeInterval(plugin.effectiveTimeout + LauncherConstants.pluginSigkillGraceSec + 3)
        )
        async let stdoutDataTask = readBounded(
            handle: stdoutPipe.fileHandleForReading,
            maxBytes: LauncherConstants.pluginMaxStdoutBytes,
            deadline: readDeadline
        )
        async let stderrDataTask = readBounded(
            handle: stderrPipe.fileHandleForReading,
            maxBytes: LauncherConstants.pluginMaxStderrBytes,
            deadline: readDeadline
        )

        // 8. 超时控制：双 detached task 竞速 + NSLock ResumeGuard once-flag
        //    waitUntilExit 在 detached task 内（不阻塞主线程）
        let timeoutSec = plugin.effectiveTimeout

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
            // timeout 守护任务
            let timeoutTask = Task.detached {
                try? await Task.sleep(for: .seconds(timeoutSec))
                guard !Task.isCancelled else { return }
                guard process.isRunning else { return }
                // 超时：立即 resume(true) 后再发 SIGTERM，异步等待 SIGKILL 兜底
                guard_.tryResume { cont.resume(returning: true) }
                let pid = process.processIdentifier
                process.terminate()  // SIGTERM（对 bash 主进程）
                Task.detached {
                    try? await Task.sleep(for: .seconds(LauncherConstants.pluginSigkillGraceSec))
                    if process.isRunning {
                        // 对整个进程组发 SIGKILL（-pid 代表进程组），杀死 bash + 其子进程（如 sleep）
                        // 这样 pipe 写端全部关闭，readDataToEndOfFile 能正常返回
                        kill(-pid, SIGKILL)
                        kill(pid, SIGKILL)  // 兜底：直接杀 bash 本身
                    }
                }
            }
            // 等进程退出（正常路径）——事件驱动，绝不阻塞线程。
            // 历史教训：早期用 `process.waitUntilExit()` 阻塞等待，无论放在 Swift 协作线程池
            // （Task.detached）还是 GCD 全局池，连续派生大量子进程时都会把对应线程池占满；而
            // readBounded 的 deadline 兜底也调度在 GCD 全局池上，池一饱和 deadline 就永不触发 →
            // readBounded continuation 永不 resume → execute() 卡死。terminationHandler 由 Foundation
            // 在进程退出时回调，不占用任何等待线程，从根上消除线程池饱和。
            process.terminationHandler = { _ in
                timeoutTask.cancel()      // 正常退出 → 取消 timeout 守护
                guard_.tryResume { cont.resume(returning: false) }
            }
            // 竞态兜底：若进程在设置 handler 之前就已退出，handler 不会被回调，这里补一次检查。
            if !process.isRunning {
                timeoutTask.cancel()
                guard_.tryResume { cont.resume(returning: false) }
            }
        }

        let stdoutBytes = await stdoutDataTask
        let stderrBytes = await stderrDataTask
        let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)

        // 截断标记
        let stdoutTruncated = stdoutBytes.count >= LauncherConstants.pluginMaxStdoutBytes
        var stdoutStr = String(data: stdoutBytes, encoding: .utf8) ?? ""
        if stdoutTruncated {
            stdoutStr += "\n[...output truncated]"
        }
        let stderrStr = String(data: stderrBytes, encoding: .utf8) ?? ""

        if timedOut {
            throw LauncherError.pluginTimeout(timeoutSec)
        }
        if process.terminationStatus != 0 {
            throw LauncherError.pluginCrash(
                process.terminationStatus,
                String(stderrStr.prefix(200))
            )
        }

        return PluginResult(
            stdout: stdoutStr,
            stderr: stderrStr,
            exitCode: process.terminationStatus,
            durationMs: durationMs,
            stdoutTruncated: stdoutTruncated
        )
    }

    /// 构造扩展 PATH：pluginPathPrefixes 在前 + 当前 PATH 在后
    private func makeExtendedPath() -> String {
        let currentPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return (LauncherConstants.pluginPathPrefixes + [currentPath]).joined(separator: ":")
    }

    /// 在扩展 PATH 中定位 binary，返回首个找到的绝对路径或 nil
    private func locateBinary(_ name: String, in path: String) -> URL? {
        for dir in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appending(path: name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// 限流读取：累积到 maxBytes 后停止 read；用 readabilityHandler 异步读避免阻塞。
    /// deadline 兜底：超时强制 close handle 让 readabilityHandler 收到 EOF，避免 orphan child（持有
    /// pipe 写端的孤立子进程，如 SIGKILL bash 后残留的 sleep）导致 readBounded 死锁。
    private func readBounded(handle: FileHandle, maxBytes: Int, deadline: Date) async -> Data {
        // 可变状态收进引用类型：readabilityHandler / asyncAfter 闭包捕获 class 引用，而非捕获并
        // 修改局部 var。否则在严格并发检查下（CI 工具链）会报「mutation of captured var in
        // concurrently-executing code」编译错误（本地 Swift 5 语言模式不报，CI 报）。NSLock 守护并发访问。
        final class State: @unchecked Sendable {
            let lock = NSLock()
            var resumed = false
            var accumulated = Data()
        }
        let state = State()

        return await withCheckedContinuation { (cont: CheckedContinuation<Data, Never>) in
            func tryResume() {
                state.lock.lock()
                defer { state.lock.unlock() }
                guard !state.resumed else { return }
                state.resumed = true
                handle.readabilityHandler = nil
                try? handle.close()
                cont.resume(returning: state.accumulated)
            }

            handle.readabilityHandler = { h in
                let chunk = h.availableData
                state.lock.lock()
                let alreadyResumed = state.resumed
                let remaining = maxBytes - state.accumulated.count
                if chunk.isEmpty {
                    state.lock.unlock()
                    if !alreadyResumed { tryResume() }
                    return
                }
                if remaining <= 0 {
                    state.lock.unlock()
                    if !alreadyResumed { tryResume() }
                    return
                }
                state.accumulated.append(chunk.prefix(remaining))
                let hitLimit = state.accumulated.count >= maxBytes
                state.lock.unlock()
                if hitLimit { tryResume() }
            }

            // Deadline 兜底：超时强制 close handle，触发 readabilityHandler 收到空 chunk → tryResume
            let deadlineMs = max(0, Int(deadline.timeIntervalSinceNow * 1000))
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(deadlineMs + 500)) {
                tryResume()
            }
        }
    }
}
