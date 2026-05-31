import XCTest
@testable import BuddyCore

/// Tier 0 红队验收测试 —— 独立基于 task 002 设计文档与契约规约。
///
/// 信息隔离原则：本测试不读取蓝队的 PluginSourceResolver.swift 实现，仅依赖：
/// - MarketplaceManifest.swift（task 001 契约 PluginSourceConfig）
/// - LauncherError.swift（错误契约：pluginInvalid / networkFailure 任一变体）
///
/// 命名前缀: test_AT<编号>_<场景>
/// swiftlint:disable type_body_length file_length
final class PluginSourceResolverAcceptanceTests: XCTestCase {

    // MARK: - Test Git Fixture（设计文档 §测试基础设施）

    /// 本地裸仓库 fixture（替代外部网络依赖）
    final class TestGitFixture {
        let bareRepo: URL          // 裸仓库，供 file:// URL 使用
        let workRepo: URL          // 工作仓库
        let headSha: String        // HEAD commit full sha
        let mainBranch: String

        init() throws {
            let base = FileManager.default.temporaryDirectory
                .appending(path: "buddy-test-fixture-\(UUID().uuidString)")
            bareRepo = base.appending(path: "remote.git")
            workRepo = base.appending(path: "work")
            try FileManager.default.createDirectory(at: bareRepo, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: workRepo, withIntermediateDirectories: true)

            Self.runGit(in: bareRepo, "init", "--bare", "--initial-branch=main")
            Self.runGit(in: workRepo, "init", "--initial-branch=main")
            Self.runGit(in: workRepo, "config", "user.email", "test@test.com")
            Self.runGit(in: workRepo, "config", "user.name", "Test")
            Self.runGit(in: workRepo, "config", "commit.gpgsign", "false")

            let pluginJSON = #"{"name":"fixture","mode":"prompt","systemPrompt":"x","maxIterations":1}"#
            try pluginJSON.write(
                to: workRepo.appending(path: "plugin.json"),
                atomically: true, encoding: .utf8
            )
            try FileManager.default.createDirectory(
                at: workRepo.appending(path: "subdir"),
                withIntermediateDirectories: true
            )
            try pluginJSON.write(
                to: workRepo.appending(path: "subdir/plugin.json"),
                atomically: true, encoding: .utf8
            )
            // empty subdir without plugin.json
            try FileManager.default.createDirectory(
                at: workRepo.appending(path: "emptydir"),
                withIntermediateDirectories: true
            )

            Self.runGit(in: workRepo, "add", ".")
            Self.runGit(in: workRepo, "commit", "-m", "init", "--no-gpg-sign")
            Self.runGit(in: workRepo, "remote", "add", "origin", bareRepo.path)
            Self.runGit(in: workRepo, "push", "origin", "main")
            headSha = Self.runGitOutput(in: workRepo, "rev-parse", "HEAD")
            mainBranch = "main"
        }

        /// 供 PluginSourceConfig.gitURL.url / gitSubdir.url 使用
        var fileURL: String { "file://\(bareRepo.path)" }

        func cleanup() {
            try? FileManager.default.removeItem(at: bareRepo.deletingLastPathComponent())
        }

        @discardableResult
        static func runGit(in directory: URL, _ args: String...) -> Int32 {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            proc.arguments = ["-C", directory.path] + args
            // 隔离 env 防止用户 ~/.gitconfig 引入 sign 等副作用
            var env: [String: String] = [:]
            if let path = ProcessInfo.processInfo.environment["PATH"] { env["PATH"] = path }
            env["HOME"] = directory.path     // 避免读用户 gitconfig
            env["GIT_TERMINAL_PROMPT"] = "0"
            env["GIT_CONFIG_GLOBAL"] = "/dev/null"
            env["GIT_CONFIG_SYSTEM"] = "/dev/null"
            proc.environment = env
            try? proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus
        }

        static func runGitOutput(in directory: URL, _ args: String...) -> String {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            proc.arguments = ["-C", directory.path] + args
            var env: [String: String] = [:]
            if let path = ProcessInfo.processInfo.environment["PATH"] { env["PATH"] = path }
            env["HOME"] = directory.path
            env["GIT_TERMINAL_PROMPT"] = "0"
            env["GIT_CONFIG_GLOBAL"] = "/dev/null"
            env["GIT_CONFIG_SYSTEM"] = "/dev/null"
            proc.environment = env
            let pipe = Pipe()
            proc.standardOutput = pipe
            try? proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
    }

    // MARK: - Test lifecycle

    private var fixture: TestGitFixture?
    private var sandboxRoots: [URL] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard FileManager.default.fileExists(atPath: "/usr/bin/git") else {
            throw XCTSkip("/usr/bin/git not available")
        }
        fixture = try TestGitFixture()
    }

    override func tearDownWithError() throws {
        fixture?.cleanup()
        fixture = nil
        for root in sandboxRoots {
            try? FileManager.default.removeItem(at: root)
        }
        sandboxRoots.removeAll()
        PluginSourceResolver.cleanupOrphans()
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func makeSandbox(_ tag: String = #function) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "buddy-resolver-at-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        sandboxRoots.append(dir)
        return dir
    }

    private func writePluginJSON(at dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let content = #"{"name":"x","mode":"prompt","systemPrompt":"y","maxIterations":1}"#
        try content.write(
            to: dir.appending(path: "plugin.json"),
            atomically: true, encoding: .utf8
        )
    }

    /// 设计文档契约错误为 `LauncherError.pluginInvalid(String)`。
    /// 容忍 `pluginManifestInvalid` 作为同语义兼容变体（避免命名分歧导致脆性）。
    private func assertPluginInvalid(
        _ error: Error,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let le = error as? LauncherError else {
            XCTFail("expected LauncherError, got \(type(of: error)): \(error)", file: file, line: line)
            return
        }
        switch le {
        case .pluginInvalid, .pluginManifestInvalid:
            return
        default:
            XCTFail("expected pluginInvalid-class error, got \(le)", file: file, line: line)
        }
    }

    private func assertNetworkFailure(
        _ error: Error,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let le = error as? LauncherError else {
            XCTFail("expected LauncherError, got \(type(of: error)): \(error)", file: file, line: line)
            return
        }
        if case .networkFailure = le { return }
        XCTFail("expected networkFailure, got \(le)", file: file, line: line)
    }

    // MARK: - AT01 localSubdir + bundleRoot + plugin.json 存在 → 成功

    func test_AT01_localSubdir_resolvesToBundleRootSubdir() async throws {
        let bundleRoot = try makeSandbox()
        try writePluginJSON(at: bundleRoot.appending(path: "plugins/x"))

        let resolver = PluginSourceResolver()
        let url = try await resolver.resolve(
            .localSubdir(path: "./plugins/x"),
            bundleRoot: bundleRoot
        )

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.appending(path: "plugin.json").path),
            "expected plugin.json under resolved url, got: \(url.path)"
        )
        // 关键点：路径应在 bundleRoot 下
        XCTAssertTrue(
            url.path.hasPrefix(bundleRoot.path),
            "resolved url should be under bundleRoot, got: \(url.path)"
        )
    }

    // MARK: - AT02 localSubdir + bundleRoot=nil → pluginInvalid

    func test_AT02_localSubdir_nilBundleRoot_throwsPluginInvalid() async throws {
        let resolver = PluginSourceResolver()
        do {
            _ = try await resolver.resolve(
                .localSubdir(path: "./plugins/x"),
                bundleRoot: nil
            )
            XCTFail("expected throw")
        } catch {
            assertPluginInvalid(error)
        }
    }

    // MARK: - AT03 localSubdir 路径下无 plugin.json → pluginInvalid

    func test_AT03_localSubdir_missingPluginJSON_throwsPluginInvalid() async throws {
        let bundleRoot = try makeSandbox()
        // 故意不写 plugin.json
        try FileManager.default.createDirectory(
            at: bundleRoot.appending(path: "plugins/empty"),
            withIntermediateDirectories: true
        )

        let resolver = PluginSourceResolver()
        do {
            _ = try await resolver.resolve(
                .localSubdir(path: "./plugins/empty"),
                bundleRoot: bundleRoot
            )
            XCTFail("expected throw")
        } catch {
            assertPluginInvalid(error)
        }
    }

    // MARK: - AT04 file 路径含 plugin.json → 成功

    func test_AT04_file_withPluginJSON_resolves() async throws {
        let dir = try makeSandbox()
        try writePluginJSON(at: dir)

        let resolver = PluginSourceResolver()
        let url = try await resolver.resolve(
            .file(path: dir.path),
            bundleRoot: nil
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.appending(path: "plugin.json").path)
        )
    }

    // MARK: - AT05 file 路径无 plugin.json → pluginInvalid

    func test_AT05_file_missingPluginJSON_throwsPluginInvalid() async throws {
        let dir = try makeSandbox()   // 不写 plugin.json
        let resolver = PluginSourceResolver()
        do {
            _ = try await resolver.resolve(
                .file(path: dir.path),
                bundleRoot: nil
            )
            XCTFail("expected throw")
        } catch {
            assertPluginInvalid(error)
        }
    }

    // MARK: - AT06 gitURL + sha=nil → clone 成功，返回 temp URL（buddy-resolver- 前缀）

    func test_AT06_gitURL_noSha_clonesToTempDir() async throws {
        guard let fixture else { return XCTFail("fixture missing") }
        let resolver = PluginSourceResolver()
        let url = try await resolver.resolve(
            .gitURL(url: fixture.fileURL, sha: nil),
            bundleRoot: nil
        )

        // 返回路径包含 "buddy-resolver-" 前缀（无论 /tmp/ 还是 /var/folders/.../T/）
        XCTAssertTrue(
            url.path.contains("/buddy-resolver-"),
            "expected /buddy-resolver-<UUID>/ in path, got: \(url.path)"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.appending(path: "plugin.json").path),
            "expected plugin.json in clone dir"
        )
    }

    // MARK: - AT07 gitURL + sha 正确 → clone + verifySHA PASS

    func test_AT07_gitURL_correctSha_verifyPasses() async throws {
        guard let fixture else { return XCTFail("fixture missing") }
        let resolver = PluginSourceResolver()
        let url = try await resolver.resolve(
            .gitURL(url: fixture.fileURL, sha: fixture.headSha),
            bundleRoot: nil
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.appending(path: "plugin.json").path)
        )
    }

    // MARK: - AT08 gitURL + sha 错误（≥7 字符）→ pluginInvalid + temp 已清理

    func test_AT08_gitURL_wrongSha_throwsAndCleansTemp() async throws {
        guard let fixture else { return XCTFail("fixture missing") }
        let wrongSha = String(repeating: "d", count: 40)
        let resolver = PluginSourceResolver()

        // 提前快照 tmp 中现有 buddy-resolver-* 目录列表
        let beforeOrphans = listResolverTempDirs()

        do {
            _ = try await resolver.resolve(
                .gitURL(url: fixture.fileURL, sha: wrongSha),
                bundleRoot: nil
            )
            XCTFail("expected throw")
        } catch {
            assertPluginInvalid(error)
        }

        // 不变量 #3：失败后 temp 已被清理 —— 新增的 buddy-resolver-* dir 应为 0
        let afterOrphans = listResolverTempDirs()
        let leaked = afterOrphans.subtracting(beforeOrphans)
        XCTAssertEqual(
            leaked.count, 0,
            "expected no leaked temp dirs after failure, got: \(leaked)"
        )
    }

    // MARK: - AT09 gitURL + sha < 7 字符 → pluginInvalid (sha too short)

    func test_AT09_gitURL_shaTooShort_throwsPluginInvalid() async throws {
        guard let fixture else { return XCTFail("fixture missing") }
        let resolver = PluginSourceResolver()
        do {
            _ = try await resolver.resolve(
                .gitURL(url: fixture.fileURL, sha: "abc12"), // 5 chars
                bundleRoot: nil
            )
            XCTFail("expected throw")
        } catch {
            assertPluginInvalid(error)
        }
    }

    // MARK: - AT10 gitSubdir + ref=main + sha 正确 + subdir 含 plugin.json → 成功

    func test_AT10_gitSubdir_validRefShaAndSubdir_resolves() async throws {
        guard let fixture else { return XCTFail("fixture missing") }
        let resolver = PluginSourceResolver()
        let url = try await resolver.resolve(
            .gitSubdir(
                url: fixture.fileURL,
                path: "subdir",
                ref: fixture.mainBranch,
                sha: fixture.headSha
            ),
            bundleRoot: nil
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.appending(path: "plugin.json").path),
            "expected plugin.json in subdir url"
        )
        // 期望返回 subdir URL（即末段为 "subdir"）
        XCTAssertEqual(url.lastPathComponent, "subdir")
    }

    // MARK: - AT11 gitSubdir + subdir 缺 plugin.json → pluginInvalid + temp 已清理

    func test_AT11_gitSubdir_subdirMissingPluginJSON_throwsAndCleansTemp() async throws {
        guard let fixture else { return XCTFail("fixture missing") }
        let resolver = PluginSourceResolver()

        let beforeOrphans = listResolverTempDirs()

        do {
            _ = try await resolver.resolve(
                .gitSubdir(
                    url: fixture.fileURL,
                    path: "emptydir",          // 没有 plugin.json
                    ref: fixture.mainBranch,
                    sha: fixture.headSha
                ),
                bundleRoot: nil
            )
            XCTFail("expected throw")
        } catch {
            assertPluginInvalid(error)
        }

        let afterOrphans = listResolverTempDirs()
        let leaked = afterOrphans.subtracting(beforeOrphans)
        XCTAssertEqual(
            leaked.count, 0,
            "expected no leaked temp dirs after failure, got: \(leaked)"
        )
    }

    // MARK: - AT12 gitClone timeout → networkFailure + temp 已清理

    func test_AT12_gitClone_timeout_throwsNetworkFailureAndCleansTemp() async throws {
        // 用 /bin/sleep 作为 gitExecutable 模拟阻塞
        // /bin/sleep 接收任意 args 都 sleep 一段时间（这里只是不会执行 git，会一直 sleep）
        let resolver = PluginSourceResolver(
            gitExecutable: URL(fileURLWithPath: "/bin/sleep"),
            timeoutSeconds: 1
        )

        let beforeOrphans = listResolverTempDirs()

        let start = Date()
        do {
            _ = try await resolver.resolve(
                .gitURL(url: "file:///tmp/nonexistent-AT12.git", sha: nil),
                bundleRoot: nil
            )
            XCTFail("expected throw")
        } catch {
            assertNetworkFailure(error)
        }
        let elapsed = Date().timeIntervalSince(start)
        // 1s timeout + 一点容差，断言不会 hang 太久
        XCTAssertLessThan(elapsed, 10.0, "timeout did not fire in reasonable time: \(elapsed)s")

        let afterOrphans = listResolverTempDirs()
        let leaked = afterOrphans.subtracting(beforeOrphans)
        XCTAssertEqual(
            leaked.count, 0,
            "expected no leaked temp dirs after timeout, got: \(leaked)"
        )
    }

    // MARK: - AT13 cleanupOrphans 清理 buddy-resolver-* 前缀

    func test_AT13_cleanupOrphans_removesResolverTempPrefix() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let orphan = tempDir.appending(path: "buddy-resolver-test-AT13-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))

        PluginSourceResolver.cleanupOrphans()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: orphan.path),
            "cleanupOrphans should remove buddy-resolver-* dir, but \(orphan.path) still exists"
        )
    }

    // MARK: - AT14 cleanupOrphans 不误删其他 temp 文件

    func test_AT14_cleanupOrphans_doesNotTouchUnrelatedTemp() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let unrelated = tempDir.appending(path: "other-temp-AT14-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: unrelated) }

        PluginSourceResolver.cleanupOrphans()

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: unrelated.path),
            "cleanupOrphans should NOT remove non buddy-resolver-* dirs"
        )
    }

    // MARK: - Helpers

    /// 列出 NSTemporaryDirectory 中所有 buddy-resolver-* 目录路径集合
    private func listResolverTempDirs() -> Set<String> {
        let tempDir = FileManager.default.temporaryDirectory
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: tempDir, includingPropertiesForKeys: nil
        ) else { return [] }
        return Set(entries
            .filter { $0.lastPathComponent.hasPrefix("buddy-resolver-") }
            .map { $0.path })
    }
}
// swiftlint:enable type_body_length file_length
