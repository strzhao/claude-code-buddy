import XCTest
@testable import BuddyCore

/// 蓝队单元测试 (task 007): CLI mirror schema + sanitize 白名单 + buildCLIInspection 各分支。
///
/// 因 BuddyCLI 是独立 Foundation-only executable target（无 library），CLI 内部 `private`
/// 类型不可 import。本套测试通过两条路径覆盖：
/// 1. **JSON schema 双绑**：用 BuddyCore 的 `PluginSourceConfig` decode CLI 期望的 JSON 形态，
///    保证 CLI mirror 与 BuddyCore source-of-truth 的 wire format 一致（任何 BuddyCore schema
///    改动都会让此测试失败 → 提醒同步 CLI mirror）。
/// 2. **行为契约（exit code 规范）**：通过 Process 启 buddy-cli 子进程断言（与红队验收交叠）。
///
/// 参考 CLILauncherInstallDisableEnableAcceptanceTests（红队）作为端到端补集。
final class CLILauncherInstallDisableEnableTests: XCTestCase {

    // MARK: - 1. PluginSourceConfig JSON 双绑 (CLI mirror 与 BuddyCore 同 schema)

    func test_pluginSourceConfig_decodes_localSubdir_fromString() throws {
        let json = Data("\"./plugins/translate\"".utf8)
        let decoded = try JSONDecoder().decode(PluginSourceConfig.self, from: json)
        guard case .localSubdir(let path) = decoded else {
            return XCTFail("expected localSubdir, got \(decoded)")
        }
        XCTAssertEqual(path, "./plugins/translate")
    }

    func test_pluginSourceConfig_decodes_gitURL_fromObject() throws {
        let json = Data("""
        {"source":"url","url":"https://github.com/x/y.git","sha":"abc123"}
        """.utf8)
        let decoded = try JSONDecoder().decode(PluginSourceConfig.self, from: json)
        guard case .gitURL(let url, let sha) = decoded else {
            return XCTFail("expected gitURL, got \(decoded)")
        }
        XCTAssertEqual(url, "https://github.com/x/y.git")
        XCTAssertEqual(sha, "abc123")
    }

    func test_pluginSourceConfig_decodes_gitSubdir_fromObject() throws {
        let json = Data("""
        {"source":"git-subdir","url":"https://example.com/repo.git","path":"plugins/weather","ref":"main","sha":"deadbeef"}
        """.utf8)
        let decoded = try JSONDecoder().decode(PluginSourceConfig.self, from: json)
        guard case .gitSubdir(let url, let path, let ref, let sha) = decoded else {
            return XCTFail("expected gitSubdir, got \(decoded)")
        }
        XCTAssertEqual(url, "https://example.com/repo.git")
        XCTAssertEqual(path, "plugins/weather")
        XCTAssertEqual(ref, "main")
        XCTAssertEqual(sha, "deadbeef")
    }

    func test_pluginSourceConfig_decodes_file_fromObject() throws {
        let json = Data("""
        {"source":"file","path":"/tmp/my-plugin"}
        """.utf8)
        let decoded = try JSONDecoder().decode(PluginSourceConfig.self, from: json)
        guard case .file(let path) = decoded else {
            return XCTFail("expected file, got \(decoded)")
        }
        XCTAssertEqual(path, "/tmp/my-plugin")
    }

    func test_pluginSourceConfig_roundTrip_allVariants() throws {
        let cases: [PluginSourceConfig] = [
            .localSubdir(path: "./plugins/translate"),
            .gitURL(url: "https://github.com/x/y.git", sha: "abc"),
            .gitSubdir(url: "https://github.com/x/y.git", path: "p", ref: "main", sha: "def"),
            .file(path: "/tmp/x")
        ]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for c in cases {
            let data = try encoder.encode(c)
            let back = try decoder.decode(PluginSourceConfig.self, from: data)
            XCTAssertEqual(c, back, "round-trip failed for \(c)")
        }
    }

    // MARK: - 2. CLI marketplace.json 完整 fixture 解析

    func test_marketplaceManifest_decodes_completeFixture() throws {
        let json = Data("""
        {
          "schemaVersion": 1,
          "name": "buddy-official",
          "description": "official",
          "owner": {"name": "stringzhao"},
          "plugins": [
            {
              "name": "translate",
              "description": "translate plugin",
              "version": "0.1.0",
              "author": {"name": "stringzhao"},
              "source": "./plugins/translate"
            },
            {
              "name": "weather",
              "description": "weather plugin",
              "version": "0.2.0",
              "author": {"name": "alice"},
              "source": {"source": "url", "url": "https://github.com/alice/weather.git"}
            }
          ]
        }
        """.utf8)
        let manifest = try JSONDecoder().decode(MarketplaceManifest.self, from: json)
        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.plugins.count, 2)
        XCTAssertEqual(manifest.plugins[0].name, "translate")
        XCTAssertEqual(manifest.plugins[1].name, "weather")
        guard case .localSubdir = manifest.plugins[0].source else {
            return XCTFail("translate should be localSubdir")
        }
        guard case .gitURL(let url, _) = manifest.plugins[1].source else {
            return XCTFail("weather should be gitURL")
        }
        XCTAssertEqual(url, "https://github.com/alice/weather.git")
    }

    // MARK: - 3. sanitize 白名单 (深度防御，正则 ^[a-z0-9-]+$)

    /// 复制 CLI 的 sanitize 实现来直接测试规则（不可 import private func）。
    private func sanitize(_ name: String) -> Bool {
        name.range(of: "^[a-z0-9-]+$", options: .regularExpression) != nil
    }

    func test_sanitize_accepts_validNames() {
        XCTAssertTrue(sanitize("translate"))
        XCTAssertTrue(sanitize("buddy-translate"))
        XCTAssertTrue(sanitize("plugin-123"))
        XCTAssertTrue(sanitize("a"))
    }

    func test_sanitize_rejects_emptyName() {
        XCTAssertFalse(sanitize(""))
    }

    func test_sanitize_rejects_uppercase() {
        XCTAssertFalse(sanitize("Translate"))
        XCTAssertFalse(sanitize("PLUGIN"))
    }

    func test_sanitize_rejects_pathTraversal() {
        XCTAssertFalse(sanitize("../etc"))
        XCTAssertFalse(sanitize("../../etc/passwd"))
        XCTAssertFalse(sanitize("/etc/passwd"))
        XCTAssertFalse(sanitize("./local"))
    }

    func test_sanitize_rejects_specialChars() {
        XCTAssertFalse(sanitize("foo bar"))
        XCTAssertFalse(sanitize("foo.bar"))
        XCTAssertFalse(sanitize("foo_bar"))
        XCTAssertFalse(sanitize("foo:bar"))
        XCTAssertFalse(sanitize("foo\\bar"))
    }

    // MARK: - 4. lastSyncedAt ISO8601 string 契约（B3 不变量）

    func test_marketplaceMeta_lastSyncedAt_isISO8601String() throws {
        struct CLIMeta: Codable {
            let lastSyncedAt: String?
            let consecutiveSyncFailures: Int
        }
        let json = Data("""
        {"lastSyncedAt":"2026-05-30T01:00:00Z","consecutiveSyncFailures":0}
        """.utf8)
        let meta = try JSONDecoder().decode(CLIMeta.self, from: json)
        XCTAssertEqual(meta.lastSyncedAt, "2026-05-30T01:00:00Z")
        XCTAssertEqual(meta.consecutiveSyncFailures, 0)
    }

    func test_marketplaceMeta_lastSyncedAt_nullable() throws {
        struct CLIMeta: Codable {
            let lastSyncedAt: String?
            let consecutiveSyncFailures: Int
        }
        let json = Data("""
        {"lastSyncedAt":null,"consecutiveSyncFailures":3}
        """.utf8)
        let meta = try JSONDecoder().decode(CLIMeta.self, from: json)
        XCTAssertNil(meta.lastSyncedAt)
        XCTAssertEqual(meta.consecutiveSyncFailures, 3)
    }

    // MARK: - 5. exit code 规范 (subprocess via Process)
    //
    // 因 CLI 是独立 executable，所有 exit code 必须通过 fork 子进程验证。
    // HOME env 隔离 fixture，避免污染开发者 ~/.buddy/。

    private func runCLI(_ args: [String], home: URL) -> (exit: Int32, stdout: String, stderr: String) {
        let fm = FileManager.default
        let fileURL = URL(fileURLWithPath: #filePath)
        let packageRoot = fileURL.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let candidates = [
            packageRoot.appendingPathComponent(".build/debug/buddy-cli").path,
            packageRoot.appendingPathComponent(".build/arm64-apple-macosx/debug/buddy-cli").path,
            packageRoot.appendingPathComponent(".build/x86_64-apple-macosx/debug/buddy-cli").path,
            "\(fm.currentDirectoryPath)/.build/debug/buddy-cli"
        ]
        guard let binary = candidates.first(where: { fm.fileExists(atPath: $0) }) else {
            return (-1, "", "buddy-cli binary not found; tried: \(candidates)")
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home.path
        proc.environment = env
        let outPipe = Pipe(); let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do { try proc.run() } catch {
            return (-1, "", "launch failed: \(error)")
        }
        proc.waitUntilExit()
        let o = outPipe.fileHandleForReading.readDataToEndOfFile()
        let e = errPipe.fileHandleForReading.readDataToEndOfFile()
        return (proc.terminationStatus,
                String(data: o, encoding: .utf8) ?? "",
                String(data: e, encoding: .utf8) ?? "")
    }

    private func makeTempHome() throws -> URL {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("buddy-cli-blue-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".buddy/launcher-plugins"),
            withIntermediateDirectories: true
        )
        return home
    }

    /// 用 fixture 字符串写一个 plugin.json 的 prompt 模式 plugin
    private func writePromptPlugin(_ name: String, home: URL) throws {
        let dir = home.appendingPathComponent(".buddy/launcher-plugins/\(name)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = """
        {"name":"\(name)","version":"0.1.0","description":"x","keywords":[],"mode":"prompt","systemPrompt":"x","maxIterations":1,"autoCopyToClipboard":false}
        """
        try json.write(to: dir.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
    }

    func test_subprocess_disable_invalidName_exitCode2() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let r = runCLI(["launcher", "disable", "../../etc"], home: home)
        XCTAssertEqual(r.exit, 2, "stderr=\(r.stderr)")
        XCTAssertTrue(r.stderr.contains("Invalid name"), "stderr=\(r.stderr)")
    }

    func test_subprocess_disable_notFound_exitCode3() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let r = runCLI(["launcher", "disable", "ghost"], home: home)
        XCTAssertEqual(r.exit, 3, "stderr=\(r.stderr)")
    }

    func test_subprocess_install_cacheMissing_exitCode4() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let r = runCLI(["launcher", "install", "translate"], home: home)
        XCTAssertEqual(r.exit, 4, "stderr=\(r.stderr)")
    }

    func test_subprocess_help_listsNewSubcommands() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let r = runCLI(["help"], home: home)
        XCTAssertEqual(r.exit, 0)
        for keyword in ["install", "disable", "enable", "reseed"] {
            XCTAssertTrue(r.stdout.contains(keyword), "missing '\(keyword)' in help; stdout=\(r.stdout)")
        }
    }

    // MARK: - 6. buildCLIInspection 各分支 (subprocess list --json)

    func test_subprocess_listJSON_emptyEverything_validJSON() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let r = runCLI(["launcher", "list", "--json"], home: home)
        XCTAssertEqual(r.exit, 0, "stderr=\(r.stderr)")
        guard let data = r.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return XCTFail("invalid JSON: \(r.stdout)")
        }
        XCTAssertNotNil(json["plugins"])
        XCTAssertNotNil(json["sideloadedPlugins"])
        XCTAssertNotNil(json["consecutiveSyncFailures"])
        // 空状态：lastSyncedAt nil → 默认 JSONEncoder 行为是省略 key（不强制）
        // 验证若存在则必须为 NSNull
        if let last = json["lastSyncedAt"] {
            XCTAssertTrue(last is NSNull, "expected null, got: \(last)")
        }
    }

    func test_subprocess_listJSON_sideloadedBranch() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        // 无 marketplace.json，仅有 sideloaded plugin
        try writePromptPlugin("my-sideloaded", home: home)
        let r = runCLI(["launcher", "list", "--json"], home: home)
        XCTAssertEqual(r.exit, 0)
        let data = r.stdout.data(using: .utf8)!
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let side = json["sideloadedPlugins"] as? [[String: Any]] ?? []
        XCTAssertTrue(side.contains(where: { ($0["name"] as? String) == "my-sideloaded" }),
                      "sideloaded array: \(side)")
        let mp = json["plugins"] as? [[String: Any]] ?? []
        XCTAssertEqual(mp.count, 0, "no marketplace plugins expected; got: \(mp)")
    }

    func test_subprocess_listJSON_marketplaceBranch_withMeta() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        // 写 marketplace.json + meta
        let cacheJSON = """
        {"schemaVersion":1,"name":"buddy-official","description":"x","owner":{"name":"x"},"plugins":[{"name":"translate","description":"t","version":"0.1.0","author":{"name":"x"},"source":"./plugins/translate"}]}
        """
        try cacheJSON.write(
            to: home.appendingPathComponent(".buddy/marketplace.json"),
            atomically: true, encoding: .utf8
        )
        let metaJSON = """
        {"lastSyncedAt":"2026-05-30T01:00:00Z","consecutiveSyncFailures":2}
        """
        try metaJSON.write(
            to: home.appendingPathComponent(".buddy/marketplace-meta.json"),
            atomically: true, encoding: .utf8
        )
        let r = runCLI(["launcher", "list", "--json"], home: home)
        XCTAssertEqual(r.exit, 0, "stderr=\(r.stderr)")
        let data = r.stdout.data(using: .utf8)!
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        XCTAssertEqual(json["lastSyncedAt"] as? String, "2026-05-30T01:00:00Z")
        XCTAssertEqual(json["consecutiveSyncFailures"] as? Int, 2)
        let mp = json["plugins"] as? [[String: Any]] ?? []
        XCTAssertEqual(mp.count, 1)
        XCTAssertEqual(mp.first?["name"] as? String, "translate")
        XCTAssertEqual(mp.first?["enabled"] as? Bool, true, "no .disabled marker, should be enabled")
    }

    func test_subprocess_listJSON_disabledEnabledFlag() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let cacheJSON = """
        {"schemaVersion":1,"name":"buddy-official","description":"x","owner":{"name":"x"},"plugins":[{"name":"translate","description":"t","version":"0.1.0","author":{"name":"x"},"source":"./plugins/translate"}]}
        """
        try cacheJSON.write(
            to: home.appendingPathComponent(".buddy/marketplace.json"),
            atomically: true, encoding: .utf8
        )
        try writePromptPlugin("translate", home: home)
        try Data().write(to: home.appendingPathComponent(".buddy/launcher-plugins/translate/.disabled"))
        let r = runCLI(["launcher", "list", "--json"], home: home)
        XCTAssertEqual(r.exit, 0)
        let data = r.stdout.data(using: .utf8)!
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let mp = json["plugins"] as? [[String: Any]] ?? []
        XCTAssertEqual(mp.first?["enabled"] as? Bool, false, ".disabled marker → enabled=false")
    }
}
