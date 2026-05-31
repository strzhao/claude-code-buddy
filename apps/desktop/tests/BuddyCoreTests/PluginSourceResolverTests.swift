import XCTest
@testable import BuddyCore

/// 蓝队单元测试：覆盖 PluginSourceResolver 4 case 实现细节 + cleanupOrphans + env 白名单 +
/// verifySHA 边界。红队 acceptance 测试在 PluginSourceResolverAcceptanceTests 单独覆盖端到端。
final class PluginSourceResolverTests: XCTestCase {

    private var fixture: TestGitFixture?

    override func setUpWithError() throws {
        // CI 前置：/usr/bin/git 必须存在
        guard FileManager.default.fileExists(atPath: "/usr/bin/git") else {
            throw XCTSkip("/usr/bin/git not available")
        }
        fixture = try TestGitFixture()
    }

    override func tearDownWithError() throws {
        fixture?.cleanup()
        fixture = nil
        // 清残留 temp dir（避免测试相互污染）
        PluginSourceResolver.cleanupOrphans()
    }

    // MARK: - localSubdir

    func testResolve_localSubdir_returnsBundleRootAppendedPath() async throws {
        let (bundleRoot, _) = try makeLocalPluginDir(subdir: "plugins/translate")
        let resolver = PluginSourceResolver()
        let result = try await resolver.resolve(
            .localSubdir(path: "plugins/translate"),
            bundleRoot: bundleRoot
        )
        XCTAssertEqual(
            result.standardizedFileURL.path,
            bundleRoot.appending(path: "plugins/translate").standardizedFileURL.path
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: result.appending(path: "plugin.json").path)
        )
    }

    func testResolve_localSubdir_nilBundleRoot_throwsPluginInvalid() async {
        let resolver = PluginSourceResolver()
        do {
            _ = try await resolver.resolve(
                .localSubdir(path: "plugins/x"),
                bundleRoot: nil
            )
            XCTFail("expected pluginInvalid")
        } catch let error as LauncherError {
            guard case .pluginInvalid(let reason) = error else {
                XCTFail("expected pluginInvalid, got \(error)")
                return
            }
            XCTAssertTrue(reason.contains("bundleRoot"), "reason=\(reason)")
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }

    // MARK: - file

    func testResolve_file_returnsURLWhenPluginJSONExists() async throws {
        let (dir, _) = try makeLocalPluginDir(subdir: "")
        let resolver = PluginSourceResolver()
        let result = try await resolver.resolve(
            .file(path: dir.path),
            bundleRoot: nil
        )
        XCTAssertEqual(result.standardizedFileURL.path, dir.standardizedFileURL.path)
    }

    func testResolve_file_missingPluginJSON_throwsPluginInvalid() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "buddy-test-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let resolver = PluginSourceResolver()
        do {
            _ = try await resolver.resolve(.file(path: dir.path), bundleRoot: nil)
            XCTFail("expected pluginInvalid")
        } catch let error as LauncherError {
            guard case .pluginInvalid = error else {
                XCTFail("expected pluginInvalid, got \(error)")
                return
            }
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }

    // MARK: - gitURL

    func testResolve_gitURL_clonesIntoTempDirWithBuddyPrefix() async throws {
        let fixture = try XCTUnwrap(self.fixture)
        let resolver = PluginSourceResolver()
        let result = try await resolver.resolve(
            .gitURL(url: fixture.fileURL, sha: nil),
            bundleRoot: nil
        )
        XCTAssertTrue(
            result.lastPathComponent.hasPrefix(PluginSourceResolver.tempPrefix),
            "expected temp prefix, got \(result.lastPathComponent)"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: result.appending(path: "plugin.json").path)
        )
    }

    func testResolve_gitURL_shaMatch_succeeds() async throws {
        let fixture = try XCTUnwrap(self.fixture)
        let resolver = PluginSourceResolver()
        let result = try await resolver.resolve(
            .gitURL(url: fixture.fileURL, sha: fixture.headSha),
            bundleRoot: nil
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: result.appending(path: "plugin.json").path)
        )
    }

    func testResolve_gitURL_shaMismatch_throwsAndCleansTemp() async throws {
        let fixture = try XCTUnwrap(self.fixture)
        let resolver = PluginSourceResolver()
        let beforeCount = countResolverTempDirs()
        do {
            _ = try await resolver.resolve(
                .gitURL(url: fixture.fileURL, sha: "deadbeefdeadbeef"),
                bundleRoot: nil
            )
            XCTFail("expected pluginInvalid")
        } catch let error as LauncherError {
            guard case .pluginInvalid(let reason) = error else {
                XCTFail("expected pluginInvalid, got \(error)")
                return
            }
            XCTAssertTrue(reason.contains("sha mismatch"), "reason=\(reason)")
        } catch {
            XCTFail("unexpected: \(error)")
        }
        let afterCount = countResolverTempDirs()
        XCTAssertEqual(afterCount, beforeCount, "temp dir leaked on sha mismatch")
    }

    // MARK: - gitSubdir

    func testResolve_gitSubdir_returnsSubdirURLWhenValid() async throws {
        let fixture = try XCTUnwrap(self.fixture)
        let resolver = PluginSourceResolver()
        let result = try await resolver.resolve(
            .gitSubdir(
                url: fixture.fileURL,
                path: "subdir",
                ref: fixture.mainBranch,
                sha: fixture.headSha
            ),
            bundleRoot: nil
        )
        XCTAssertEqual(result.lastPathComponent, "subdir")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: result.appending(path: "plugin.json").path)
        )
    }

    func testResolve_gitSubdir_missingSubdir_throwsAndCleansTemp() async throws {
        let fixture = try XCTUnwrap(self.fixture)
        let resolver = PluginSourceResolver()
        let beforeCount = countResolverTempDirs()
        do {
            _ = try await resolver.resolve(
                .gitSubdir(
                    url: fixture.fileURL,
                    path: "nope",
                    ref: fixture.mainBranch,
                    sha: fixture.headSha
                ),
                bundleRoot: nil
            )
            XCTFail("expected pluginInvalid")
        } catch let error as LauncherError {
            guard case .pluginInvalid(let reason) = error else {
                XCTFail("expected pluginInvalid, got \(error)")
                return
            }
            XCTAssertTrue(reason.contains("subdir"), "reason=\(reason)")
        } catch {
            XCTFail("unexpected: \(error)")
        }
        let afterCount = countResolverTempDirs()
        XCTAssertEqual(afterCount, beforeCount, "temp dir leaked on missing subdir")
    }

    // MARK: - verifySHA 边界

    func testResolve_gitURL_shaTooShort_throwsPluginInvalid() async throws {
        let fixture = try XCTUnwrap(self.fixture)
        let resolver = PluginSourceResolver()
        do {
            _ = try await resolver.resolve(
                .gitURL(url: fixture.fileURL, sha: "abc"),
                bundleRoot: nil
            )
            XCTFail("expected pluginInvalid")
        } catch let error as LauncherError {
            guard case .pluginInvalid(let reason) = error else {
                XCTFail("expected pluginInvalid, got \(error)")
                return
            }
            XCTAssertTrue(reason.contains("sha too short"), "reason=\(reason)")
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }

    // MARK: - cleanupOrphans

    func testCleanupOrphans_removesBuddyResolverPrefixedDirsOnly() throws {
        let tempBase = FileManager.default.temporaryDirectory
        let orphan = tempBase.appending(
            path: "\(PluginSourceResolver.tempPrefix)orphan-\(UUID().uuidString)"
        )
        let unrelated = tempBase.appending(path: "buddy-test-unrelated-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: unrelated) }

        PluginSourceResolver.cleanupOrphans()

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path), "orphan should be deleted")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: unrelated.path),
            "unrelated dir must not be touched"
        )
    }

    // MARK: - Helpers

    /// 在 temp 创建一个本地插件目录（含 plugin.json）。
    private func makeLocalPluginDir(subdir: String) throws -> (root: URL, pluginDir: URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "buddy-test-bundle-\(UUID().uuidString)")
        let pluginDir = subdir.isEmpty ? root : root.appending(path: subdir)
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        let pluginJSON = #"{"name":"x","mode":"prompt","systemPrompt":"x","maxIterations":1}"#
        try pluginJSON.write(
            to: pluginDir.appending(path: "plugin.json"),
            atomically: true,
            encoding: .utf8
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, pluginDir)
    }

    private func countResolverTempDirs() -> Int {
        let tempBase = FileManager.default.temporaryDirectory
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: tempBase,
            includingPropertiesForKeys: nil
        ) else { return 0 }
        return entries.filter { $0.lastPathComponent.hasPrefix(PluginSourceResolver.tempPrefix) }.count
    }
}

// MARK: - TestGitFixture

/// 本地裸 git 仓库 fixture，零外部网络依赖。
/// 包含一个 plugin.json（根目录 + `subdir/`），main 分支 1 个 commit。
final class TestGitFixture {
    let baseDir: URL
    let bareRepo: URL
    let workRepo: URL
    let headSha: String
    let mainBranch: String = "main"

    var fileURL: String { "file://\(bareRepo.path)" }

    init() throws {
        baseDir = FileManager.default.temporaryDirectory
            .appending(path: "buddy-test-fixture-\(UUID().uuidString)")
        bareRepo = baseDir.appending(path: "remote.git")
        workRepo = baseDir.appending(path: "work")
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
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createDirectory(
            at: workRepo.appending(path: "subdir"),
            withIntermediateDirectories: true
        )
        try pluginJSON.write(
            to: workRepo.appending(path: "subdir/plugin.json"),
            atomically: true,
            encoding: .utf8
        )

        Self.runGit(in: workRepo, "add", ".")
        Self.runGit(in: workRepo, "commit", "-m", "init")
        Self.runGit(in: workRepo, "remote", "add", "origin", bareRepo.path)
        Self.runGit(in: workRepo, "push", "origin", "main")
        headSha = Self.runGitOutput(in: workRepo, "rev-parse", "HEAD")
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: baseDir)
    }

    @discardableResult
    private static func runGit(in dir: URL, _ args: String...) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", dir.path] + args
        var env: [String: String] = [:]
        if let path = ProcessInfo.processInfo.environment["PATH"] { env["PATH"] = path }
        if let home = ProcessInfo.processInfo.environment["HOME"] { env["HOME"] = home }
        // 防 git 在 CI 上要求 user/email 全局配置
        env["GIT_AUTHOR_NAME"] = "Test"
        env["GIT_AUTHOR_EMAIL"] = "test@test.com"
        env["GIT_COMMITTER_NAME"] = "Test"
        env["GIT_COMMITTER_EMAIL"] = "test@test.com"
        process.environment = env
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return -1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    private static func runGitOutput(in dir: URL, _ args: String...) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", dir.path] + args
        var env: [String: String] = [:]
        if let path = ProcessInfo.processInfo.environment["PATH"] { env["PATH"] = path }
        if let home = ProcessInfo.processInfo.environment["HOME"] { env["HOME"] = home }
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return ""
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
