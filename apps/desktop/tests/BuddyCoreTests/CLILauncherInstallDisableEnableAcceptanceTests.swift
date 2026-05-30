import XCTest

/// Task 007 红队验收测试 — 通过 Process 启动 buddy-cli 二进制，验证契约。
/// 15 AT 覆盖 install/disable/enable/reseed/list 的契约规约。
/// 用 HOME env 覆盖隔离真实 ~/.buddy/，避免污染用户数据。
final class CLILauncherInstallDisableEnableAcceptanceTests: XCTestCase {

    private var tempHome: URL!
    private var buddyDir: URL!
    private var pluginsDir: URL!
    private var cliBinary: String!

    override func setUpWithError() throws {
        tempHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("buddy-cli-acc-\(UUID().uuidString)")
        buddyDir = tempHome.appendingPathComponent(".buddy")
        pluginsDir = buddyDir.appendingPathComponent("launcher-plugins")
        try FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)

        cliBinary = try locateBinary()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempHome)
    }

    // MARK: - Helpers

    private func locateBinary() throws -> String {
        let candidates = [
            ".build/debug/buddy-cli",
            ".build/release/buddy-cli",
            ".build/arm64-apple-macosx/debug/buddy-cli",
            ".build/arm64-apple-macosx/release/buddy-cli"
        ]
        let url = URL(fileURLWithPath: #filePath)
        var packageRoot = url
        for _ in 0..<6 {
            packageRoot = packageRoot.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: packageRoot.appendingPathComponent("Package.swift").path) {
                break
            }
        }
        for candidate in candidates {
            let path = packageRoot.appendingPathComponent(candidate).path
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        throw XCTSkip("buddy-cli binary not found; run `swift build` first")
    }

    @discardableResult
    private func run(_ args: [String]) -> (exit: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliBinary)
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = tempHome.path
        process.environment = env
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            return (-1, "", "spawn failed: \(error)")
        }
        process.waitUntilExit()
        let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, stdout, stderr)
    }

    private func writePluginDir(_ name: String, validManifest: Bool = true) {
        let dir = pluginsDir.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if validManifest {
            let manifest = #"{"name":"\#(name)","version":"1.0.0","description":"test","mode":"prompt","systemPrompt":"x","maxIterations":1}"#
            try? manifest.write(to: dir.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
        }
    }

    private func writeMarketplaceCache(plugins: [(name: String, version: String, sourceJSON: String)]) {
        let entries = plugins.map { p in
            #"{"name":"\#(p.name)","version":"\#(p.version)","source":\#(p.sourceJSON)}"#
        }.joined(separator: ",")
        let json = #"{"schemaVersion":1,"name":"buddy-official","plugins":[\#(entries)]}"#
        try? json.write(to: buddyDir.appendingPathComponent("marketplace.json"), atomically: true, encoding: .utf8)
    }

    private func writeMarketplaceMeta(lastSyncedAt: String?, failures: Int) {
        let lastPart = lastSyncedAt.map { "\"lastSyncedAt\":\"\($0)\"," } ?? ""
        let json = "{\(lastPart)\"consecutiveSyncFailures\":\(failures)}"
        try? json.write(to: buddyDir.appendingPathComponent("marketplace-meta.json"), atomically: true, encoding: .utf8)
    }

    // MARK: - AT01-AT07: disable/enable/sanitize

    func test_AT01_disable_notExist_exit3() {
        let result = run(["launcher", "disable", "ghost"])
        XCTAssertEqual(result.exit, 3, "stderr=\(result.stderr)")
    }

    func test_AT02_disable_existing_createsMarker() {
        writePluginDir("translate")
        let result = run(["launcher", "disable", "translate"])
        XCTAssertEqual(result.exit, 0, "stderr=\(result.stderr)")
        let marker = pluginsDir.appendingPathComponent("translate/.disabled")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    func test_AT03_disable_idempotent() {
        writePluginDir("translate")
        XCTAssertEqual(run(["launcher", "disable", "translate"]).exit, 0)
        XCTAssertEqual(run(["launcher", "disable", "translate"]).exit, 0)
        let marker = pluginsDir.appendingPathComponent("translate/.disabled")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    func test_AT04_enable_notExist_exit3() {
        XCTAssertEqual(run(["launcher", "enable", "ghost"]).exit, 3)
    }

    func test_AT05_enable_removesMarker() {
        writePluginDir("translate")
        try? Data().write(to: pluginsDir.appendingPathComponent("translate/.disabled"))
        let result = run(["launcher", "enable", "translate"])
        XCTAssertEqual(result.exit, 0)
        let marker = pluginsDir.appendingPathComponent("translate/.disabled")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func test_AT06_enable_noOpIfNotDisabled() {
        writePluginDir("translate")
        XCTAssertEqual(run(["launcher", "enable", "translate"]).exit, 0)
    }

    func test_AT07_sanitize_rejectsBadName() {
        let result = run(["launcher", "disable", "../../etc"])
        XCTAssertEqual(result.exit, 2)
        XCTAssertTrue(result.stderr.contains("Invalid name"), "stderr=\(result.stderr)")
    }

    // MARK: - AT08-AT11: install error cases

    func test_AT08_install_notInMarketplace_exit3() {
        writeMarketplaceCache(plugins: [("hello", "0.1.0", "\"./plugins/hello\"")])
        let result = run(["launcher", "install", "ghost"])
        XCTAssertEqual(result.exit, 3, "stderr=\(result.stderr)")
    }

    func test_AT09_install_localSubdir_exit6() {
        writeMarketplaceCache(plugins: [("translate", "0.1.0", "\"./plugins/translate\"")])
        let result = run(["launcher", "install", "translate"])
        XCTAssertEqual(result.exit, 6, "stderr=\(result.stderr)")
        XCTAssertTrue(result.stderr.lowercased().contains("reseed") || result.stderr.contains("bundle"),
                      "stderr=\(result.stderr)")
    }

    func test_AT10_install_cacheMissing_exit4() {
        let result = run(["launcher", "install", "translate"])
        XCTAssertEqual(result.exit, 4, "stderr=\(result.stderr)")
    }

    func test_AT11_install_alreadyInstalled_exit5() {
        writeMarketplaceCache(plugins: [("translate", "0.1.0", "\"./plugins/translate\"")])
        writePluginDir("translate")
        let result = run(["launcher", "install", "translate"])
        // already-installed (exit 5) OR bundled-only check could come first (exit 6)
        XCTAssertTrue([5, 6].contains(result.exit),
                      "expected 5 or 6, got \(result.exit), stderr=\(result.stderr)")
    }

    // MARK: - AT12: reseed

    func test_AT12_reseed_deletesAndStagesPending() {
        writeMarketplaceCache(plugins: [
            ("translate", "0.1.0", "\"./plugins/translate\""),
            ("hello", "0.1.0", "\"./plugins/hello\"")
        ])
        writeMarketplaceMeta(lastSyncedAt: "2026-05-30T01:00:00Z", failures: 0)
        writePluginDir("translate")
        writePluginDir("hello")
        try? Data().write(to: pluginsDir.appendingPathComponent("translate/.disabled"))

        let result = run(["launcher", "reseed"])
        XCTAssertEqual(result.exit, 0, "stderr=\(result.stderr)")

        XCTAssertFalse(FileManager.default.fileExists(atPath: buddyDir.appendingPathComponent("marketplace.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: buddyDir.appendingPathComponent("marketplace-meta.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pluginsDir.appendingPathComponent("translate").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pluginsDir.appendingPathComponent("hello").path))

        let pending = buddyDir.appendingPathComponent("reseed-pending-disabled.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.path))
        if let data = try? Data(contentsOf: pending),
           let names = try? JSONDecoder().decode([String].self, from: data) {
            XCTAssertEqual(names, ["translate"])
        } else {
            XCTFail("pending file is not valid JSON array")
        }
    }

    // MARK: - AT13-AT14: list

    func test_AT13_listJSON_outputsValidStructure() {
        writeMarketplaceCache(plugins: [("translate", "0.1.0", "\"./plugins/translate\"")])
        writeMarketplaceMeta(lastSyncedAt: "2026-05-30T01:00:00Z", failures: 0)
        writePluginDir("translate")

        let result = run(["launcher", "list", "--json"])
        XCTAssertEqual(result.exit, 0, "stderr=\(result.stderr)")
        guard let data = result.stdout.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("stdout is not valid JSON: \(result.stdout)"); return
        }
        XCTAssertNotNil(obj["plugins"])
        XCTAssertNotNil(obj["sideloadedPlugins"])
        XCTAssertNotNil(obj["consecutiveSyncFailures"])
        XCTAssertEqual(obj["lastSyncedAt"] as? String, "2026-05-30T01:00:00Z")
    }

    func test_AT14_list_showsDisabledSuffix() {
        writePluginDir("translate")
        try? Data().write(to: pluginsDir.appendingPathComponent("translate/.disabled"))

        let result = run(["launcher", "list"])
        XCTAssertEqual(result.exit, 0)
        XCTAssertTrue(result.stdout.contains("禁用") || result.stdout.contains("disabled"),
                      "stdout=\(result.stdout)")
    }

    // MARK: - AT15: help

    func test_AT15_help_listsNewSubcommands() {
        // 通过 `buddy launcher` 不带子命令查看 usage
        let result = run(["launcher"])
        let combined = result.stdout + result.stderr
        for keyword in ["install", "disable", "enable", "reseed"] {
            XCTAssertTrue(combined.contains(keyword), "missing '\(keyword)' in usage: \(combined)")
        }
    }
}
