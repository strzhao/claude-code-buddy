import Foundation

/// PluginSourceResolver 协议：把 PluginSourceConfig 解析为本地插件目录 URL（含 plugin.json）。
///
/// 设计要点（见 task 002 design）：
/// - 不修改任何 runtime（PluginManager / TrustStore / MarketplaceManager 等），仅返回路径
/// - localSubdir / file 返回**永久路径**，调用方不得删除
/// - gitSubdir / gitURL 返回 **temp 目录**（前缀 `/tmp/buddy-resolver-`），调用方须拷走后清理
/// - resolve 失败时若已创建 temp，自身负责清理（无泄漏）
protocol PluginSourceResolving {
    func resolve(_ source: PluginSourceConfig, bundleRoot: URL?) async throws -> URL
}

/// 默认 PluginSourceResolver 实现。
///
/// 通过 init 注入 `gitExecutable` 路径 + `timeoutSeconds`，方便测试 mock（替换为 /bin/sleep 等）。
final class PluginSourceResolver: PluginSourceResolving {
    static let shared = PluginSourceResolver()

    private let gitExecutable: URL
    private let timeoutSeconds: TimeInterval

    init(
        gitExecutable: URL = URL(fileURLWithPath: "/usr/bin/git"),
        timeoutSeconds: TimeInterval = 60
    ) {
        self.gitExecutable = gitExecutable
        self.timeoutSeconds = timeoutSeconds
    }

    /// Temp 目录前缀（cleanupOrphans 也用此前缀过滤）。
    static let tempPrefix = "buddy-resolver-"

    func resolve(_ source: PluginSourceConfig, bundleRoot: URL?) async throws -> URL {
        // 仅追踪 clone **成功后** 的 dir；gitClone 内部失败已自清。
        var tempDirToCleanOnFailure: URL?
        do {
            switch source {
            case .localSubdir(let path):
                guard let bundleRoot else {
                    throw LauncherError.pluginInvalid("localSubdir requires bundleRoot")
                }
                let resolved = bundleRoot.appending(path: path)
                guard FileManager.default.fileExists(
                    atPath: resolved.appending(path: "plugin.json").path
                ) else {
                    throw LauncherError.pluginInvalid("plugin.json not found at \(resolved.path)")
                }
                return resolved

            case .file(let path):
                let url = URL(fileURLWithPath: path)
                guard FileManager.default.fileExists(
                    atPath: url.appending(path: "plugin.json").path
                ) else {
                    throw LauncherError.pluginInvalid("plugin.json not found at \(path)")
                }
                return url

            case .gitURL(let url, let sha):
                let cloneDir = try await gitClone(url: url, ref: nil)
                tempDirToCleanOnFailure = cloneDir
                if let sha {
                    try verifySHA(in: cloneDir, expected: sha)
                }
                guard FileManager.default.fileExists(
                    atPath: cloneDir.appending(path: "plugin.json").path
                ) else {
                    throw LauncherError.pluginInvalid("plugin.json not found at \(cloneDir.path)")
                }
                return cloneDir

            case .gitSubdir(let url, let path, let ref, let sha):
                let cloneDir = try await gitClone(url: url, ref: ref)
                tempDirToCleanOnFailure = cloneDir
                try verifySHA(in: cloneDir, expected: sha)
                let resolved = cloneDir.appending(path: path)
                guard FileManager.default.fileExists(
                    atPath: resolved.appending(path: "plugin.json").path
                ) else {
                    throw LauncherError.pluginInvalid("plugin.json not found at subdir \(path)")
                }
                return resolved
            }
        } catch {
            if let tempDir = tempDirToCleanOnFailure {
                try? FileManager.default.removeItem(at: tempDir)
            }
            throw error
        }
    }

    // MARK: - 私有 helper

    /// 浅克隆到唯一 temp 目录。
    ///
    /// - `--depth 1` 加速 + 节省磁盘
    /// - `--branch <ref>` 仅当 ref 是 branch/tag name；gitURL 无 ref 时省略
    /// - 失败时自身删 temp dir（避免泄漏）
    /// - 用 `terminationHandler` + `Task.sleep` 超时（非阻塞、无死锁）
    /// - env 白名单（仅 PATH / HOME），避免 GIT_* 污染
    private func gitClone(url: String, ref: String?) async throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "\(Self.tempPrefix)\(UUID().uuidString)")

        var args: [String] = ["clone", "--depth", "1"]
        if let ref {
            args += ["--branch", ref]
        }
        args += [url, tempDir.path]

        let process = Process()
        process.executableURL = gitExecutable
        process.arguments = args

        // env 白名单，避免外层 GIT_* 污染（如 GIT_DIR / GIT_WORK_TREE / GIT_CONFIG）
        var safeEnv: [String: String] = [:]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            safeEnv["PATH"] = path
        }
        if let home = ProcessInfo.processInfo.environment["HOME"] {
            safeEnv["HOME"] = home
        }
        process.environment = safeEnv

        // 静默 stdout/stderr（避免污染 swift test 输出）
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let lock = NSLock()
            var resumed = false
            let resumeOnce: (Result<URL, Error>) -> Void = { result in
                lock.lock()
                let already = resumed
                resumed = true
                lock.unlock()
                if already { return }
                continuation.resume(with: result)
            }

            process.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    resumeOnce(.success(tempDir))
                } else {
                    try? FileManager.default.removeItem(at: tempDir)
                    let underlying = NSError(
                        domain: "PluginSourceResolver",
                        code: Int(proc.terminationStatus),
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "git clone failed (exit \(proc.terminationStatus))"
                        ]
                    )
                    resumeOnce(.failure(LauncherError.networkFailure(underlying)))
                }
            }

            do {
                try process.run()
            } catch {
                try? FileManager.default.removeItem(at: tempDir)
                resumeOnce(.failure(LauncherError.networkFailure(error)))
                return
            }

            // Timeout：Task.sleep + terminate；超时后 terminationHandler 会以非 0 退出触发失败路径
            let timeoutNS = UInt64(timeoutSeconds * 1_000_000_000)
            Task {
                try? await Task.sleep(nanoseconds: timeoutNS)
                if process.isRunning {
                    process.terminate()
                }
            }
        }
    }

    /// 校验 clone 目录的 HEAD commit 是否等于 expected sha 的前缀。
    ///
    /// 关键约束：
    /// - expected 必须 ≥7 字符（防 short hash 碰撞）
    /// - 单向 `actual.hasPrefix(expected)`（仅允许 expected 是 actual 的 prefix）
    /// - **不在此处删 temp dir**：由 `resolve` 顶层 catch 统一清理，避免双删/路径竞争
    private func verifySHA(in directory: URL, expected: String) throws {
        guard expected.count >= 7 else {
            throw LauncherError.pluginInvalid("sha too short (< 7 chars): \(expected)")
        }

        let process = Process()
        process.executableURL = gitExecutable
        process.arguments = ["-C", directory.path, "rev-parse", "HEAD"]

        var safeEnv: [String: String] = [:]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            safeEnv["PATH"] = path
        }
        if let home = ProcessInfo.processInfo.environment["HOME"] {
            safeEnv["HOME"] = home
        }
        process.environment = safeEnv

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            throw LauncherError.networkFailure(error)
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw LauncherError.pluginInvalid(
                "git rev-parse HEAD failed (exit \(process.terminationStatus))"
            )
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let actual = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard actual.hasPrefix(expected) else {
            throw LauncherError.pluginInvalid("sha mismatch: expected \(expected) got \(actual)")
        }
    }
}

extension PluginSourceResolver {
    /// 清理孤儿 temp 目录（如 swift test 中断、crash 残留）。
    ///
    /// 仅删除 `FileManager.default.temporaryDirectory` 下以 `buddy-resolver-` 前缀的条目。
    /// 在 task 003 MarketplaceManager.seedFromBundle 启动时调用；测试 tearDown 也调用。
    static func cleanupOrphans() {
        let tempDir = FileManager.default.temporaryDirectory
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: tempDir,
            includingPropertiesForKeys: nil
        ) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix(Self.tempPrefix) {
            try? FileManager.default.removeItem(at: entry)
        }
    }
}
