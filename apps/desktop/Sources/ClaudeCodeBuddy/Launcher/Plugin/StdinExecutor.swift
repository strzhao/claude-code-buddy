import Foundation

class StdinExecutor {
    static let shared = StdinExecutor()

    init() {}

    func execute(_ plugin: PluginManifest, pluginDir: URL, input: PluginInput) async throws -> PluginResult {
        // 1. 预检查 requiredPath（每个 binary 在扩展 PATH 中查找，缺失抛 pluginMissingDependency）
        if let required = plugin.requiredPath {
            let extPath = makeExtendedPath()
            for binary in required {
                guard locateBinary(binary, in: extPath) != nil else {
                    BuddyLogger.shared.warn("stdin executor: binary not found", subsystem: "plugin", meta: ["binary": binary, "plugin": plugin.name])
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

        // 通用图片通道（T3）：注入 BUDDY_OUTPUT_IMAGE，子进程写 PNG，框架读文件成 Data。
        // 用局部常量 outputImagePath 贯穿 env 注入与退出后读文件（UUID 一致性，禁重算）。
        // stdin + command mode 共享此能力（非 command 专属）。
        // 引用知识库：设计文档 §2 通用图片通道。
        let outputImagePath = "/tmp/buddy-plugin-\(UUID().uuidString).png"
        env["BUDDY_OUTPUT_IMAGE"] = outputImagePath
        // 通用候选通道（C1）：注入 BUDDY_OUTPUT_CANDIDATES，子进程写候选 JSON 数组，框架读文件解码。
        // 完全对称 image 通道（同 UUID 生命周期、defer 删、readXxxOutputSafely 安全校验、降级 nil）。
        // stdin + command 共享；候选可选，损坏/超限/symlink/缺失 → nil（非 error）。
        let outputCandidatesPath = "/tmp/buddy-plugin-\(UUID().uuidString).json"
        env["BUDDY_OUTPUT_CANDIDATES"] = outputCandidatesPath
        // finally 删临时文件（覆盖所有 return/throw 路径，场景9 资源清理）
        defer {
            try? FileManager.default.removeItem(atPath: outputImagePath)
            try? FileManager.default.removeItem(atPath: outputCandidatesPath)
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
            BuddyLogger.shared.info("stdin executor: process started", subsystem: "plugin", meta: ["cmd": plugin.cmd, "plugin": plugin.name])
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
                BuddyLogger.shared.warn("stdin executor: timeout, killing process", subsystem: "plugin", meta: ["pid": pid, "timeoutSec": timeoutSec, "plugin": plugin.name])
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
            BuddyLogger.shared.warn("stdin executor: non-zero exit", subsystem: "plugin", meta: ["exitCode": Int(process.terminationStatus), "plugin": plugin.name])
            throw LauncherError.pluginCrash(
                process.terminationStatus,
                String(stderrStr.prefix(200))
            )
        }

        // 读图片通道（T3）：exit 0 后读 BUDDY_OUTPUT_IMAGE → Data → PluginResult.image。
        // 任何失败（文件不存在/读失败/路径被篡改/超限）→ image = nil（降级，不报错）。
        let imageData = readImageOutputSafely(at: outputImagePath)
        // 读候选通道（C1）：exit 0 后读 BUDDY_OUTPUT_CANDIDATES → [LauncherCandidate] → PluginResult.candidates。
        // 完全对称 image 通道；失败降级 nil（候选可选，非 error）。
        let candidatesData = readCandidatesOutputSafely(at: outputCandidatesPath)

        BuddyLogger.shared.info("stdin executor: process succeeded", subsystem: "plugin", meta: ["exitCode": Int(process.terminationStatus), "durationMs": durationMs, "plugin": plugin.name])
        return PluginResult(
            stdout: stdoutStr,
            stderr: stderrStr,
            exitCode: process.terminationStatus,
            durationMs: durationMs,
            stdoutTruncated: stdoutTruncated,
            image: imageData,
            candidates: candidatesData
        )
    }

    /// 安全读取图片输出（T3 通用图片通道）。
    ///
    /// 契约（state.md ## 契约规约 边界值）：
    /// - 读前校验 `resolvedPath == expectedPath`（防 symlink，/tmp 防御）
    /// - `count > pluginMaxImageBytes` → 返回 nil（丢弃，UI 不渲染）
    /// - 文件不存在/读失败 → 返回 nil
    ///
    /// 不抛错：图片是可选产物，缺失走降级（占位文本「未生成图片」）。
    private func readImageOutputSafely(at expectedPath: String) -> Data? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: expectedPath) else { return nil }
        // 防 symlink：resolvedPath 必须等于注入的 outputImagePath（outputImagePath 本身是绝对规范路径）
        guard let resolved = try? (URL(fileURLWithPath: expectedPath)
                                    .resolvingSymlinksInPath().path) as String?,
              resolved == expectedPath else {
            // 路径被 symlink 篡改 → 丢弃（不读不信任的内容）
            BuddyLogger.shared.warn("stdin executor: image output symlink mismatch", subsystem: "plugin")
            return nil
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: expectedPath)) else {
            BuddyLogger.shared.warn("stdin executor: image output read failed", subsystem: "plugin")
            return nil
        }
        guard data.count <= LauncherConstants.pluginMaxImageBytes else {
            // 超限丢弃（边界值反例：image.count > 5MB → image = nil）
            BuddyLogger.shared.warn("stdin executor: image output too large", subsystem: "plugin", meta: ["bytes": data.count])
            return nil
        }
        // PNG 完整性校验（场景6.P2）：末尾必须含 IEND chunk（49 45 4E 44 AE 42 60 82）。
        // 子进程崩溃/中断会写出不完整 PNG（缺 IEND）→ 丢弃，不渲染损坏图片。
        let pngIENDSuffix = Data([0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82])
        guard data.count >= pngIENDSuffix.count, data.suffix(pngIENDSuffix.count) == pngIENDSuffix else {
            BuddyLogger.shared.warn("stdin executor: image output missing IEND chunk", subsystem: "plugin")
            return nil
        }
        return data
    }

    /// 安全读取候选输出（C1 通用候选通道，完全对称 image 通道）。
    ///
    /// 契约（state.md ## 契约规约 C1 边界值）：
    /// - 读前校验 `resolvedPath == expectedPath`（防 symlink，/tmp 防御，与 image 通道同）
    /// - `count > pluginMaxCandidatesBytes`（64 KiB）→ 返回 nil（丢弃，UI 不渲染候选）
    /// - JSON 解码 `[LauncherCandidate]` 失败（损坏/非数组/字段缺失）→ 返回 nil
    /// - 文件不存在/读失败 → 返回 nil
    ///
    /// 不抛错：候选是可选产物，缺失走降级（不渲染候选列表，stdout 仍展示）。
    private func readCandidatesOutputSafely(at expectedPath: String) -> [LauncherCandidate]? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: expectedPath) else { return nil }
        // 防 symlink：resolvedPath 必须等于注入的 outputCandidatesPath（绝对规范路径）
        guard let resolved = try? (URL(fileURLWithPath: expectedPath)
                                    .resolvingSymlinksInPath().path) as String?,
              resolved == expectedPath else {
            BuddyLogger.shared.warn("stdin executor: candidates output symlink mismatch", subsystem: "plugin")
            return nil
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: expectedPath)) else {
            BuddyLogger.shared.warn("stdin executor: candidates output read failed", subsystem: "plugin")
            return nil
        }
        guard data.count <= LauncherConstants.pluginMaxCandidatesBytes else {
            // 超限丢弃（边界值反例：count > 64KiB → nil）
            BuddyLogger.shared.warn("stdin executor: candidates output too large", subsystem: "plugin", meta: ["bytes": data.count])
            return nil
        }
        // JSON 完整性校验（对称 image 的 IEND 尾部校验）：解码失败 → nil（损坏候选不渲染）。
        // 字段缺失（如缺 selection）会抛 decodingError → 降级 nil（C2 所有字段必需）。
        guard let candidates = try? JSONDecoder().decode([LauncherCandidate].self, from: data) else {
            BuddyLogger.shared.warn("stdin executor: candidates output JSON decode failed", subsystem: "plugin")
            return nil
        }
        return candidates
    }

    /// 构造扩展 PATH：pluginPathPrefixes 在前 + 当前 PATH 在后
    private func makeExtendedPath() -> String {
        let currentPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return (LauncherConstants.pluginPathPrefixes + [currentPath]).joined(separator: ":")
    }

    /// 在扩展 PATH 中定位 binary，返回首个找到的绝对路径或 nil。
    ///
    /// M2（T2）：从 `private` 提升为 `internal`，供 `DependencyResolver` 跨文件复用
    /// （避免重复实现命令存在性检查逻辑；复用同一扩展 PATH 规则保证一致性）。
    internal func locateBinary(_ name: String, in path: String) -> URL? {
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
