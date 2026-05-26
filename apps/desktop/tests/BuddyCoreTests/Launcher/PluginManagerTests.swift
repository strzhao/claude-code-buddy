import XCTest
@testable import BuddyCore

final class PluginManagerTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PluginManagerTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    // MARK: - list()

    func test_list_returnsEmpty_whenRootDirAbsent() throws {
        let mgr = PluginManager(rootDir: tmpDir.appendingPathComponent("nonexistent"))
        let result = try mgr.list()
        XCTAssertEqual(result, [])
    }

    func test_list_returnsManifest_forValidPlugin() throws {
        let pluginDir = tmpDir.appendingPathComponent("builtin-hello")
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        try validManifestJSON(name: "builtin-hello").write(
            to: pluginDir.appendingPathComponent("plugin.json"),
            atomically: true, encoding: .utf8
        )

        let mgr = PluginManager(rootDir: tmpDir)
        let result = try mgr.list()
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].name, "builtin-hello")
    }

    func test_list_skips_dirWithNoManifest() throws {
        // 建一个空目录（无 plugin.json）
        let emptyDir = tmpDir.appendingPathComponent("broken-dir")
        try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)

        let mgr = PluginManager(rootDir: tmpDir)
        let result = try mgr.list()
        XCTAssertEqual(result, [])
    }

    func test_list_skips_invalidJSON() throws {
        let pluginDir = tmpDir.appendingPathComponent("bad-plugin")
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        try "not valid json".write(
            to: pluginDir.appendingPathComponent("plugin.json"),
            atomically: true, encoding: .utf8
        )

        let mgr = PluginManager(rootDir: tmpDir)
        let result = try mgr.list()
        XCTAssertEqual(result, [])
    }

    func test_list_skips_manifestWithInvalidName() throws {
        let pluginDir = tmpDir.appendingPathComponent("user-repo")
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        // name="unrelated" 既不等于 dirName "user-repo" 也不等于最后一段 "repo"
        try validManifestJSON(name: "unrelated").write(
            to: pluginDir.appendingPathComponent("plugin.json"),
            atomically: true, encoding: .utf8
        )

        let mgr = PluginManager(rootDir: tmpDir)
        let result = try mgr.list()
        XCTAssertEqual(result, [])
    }

    func test_list_returnsBothValid_skipsBadJSON() throws {
        // valid
        let dir1 = tmpDir.appendingPathComponent("builtin-hello")
        try FileManager.default.createDirectory(at: dir1, withIntermediateDirectories: true)
        try validManifestJSON(name: "builtin-hello").write(
            to: dir1.appendingPathComponent("plugin.json"),
            atomically: true, encoding: .utf8
        )
        // bad json
        let dir2 = tmpDir.appendingPathComponent("user-broken")
        try FileManager.default.createDirectory(at: dir2, withIntermediateDirectories: true)
        try "bad".write(to: dir2.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)

        let mgr = PluginManager(rootDir: tmpDir)
        let result = try mgr.list()
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].name, "builtin-hello")
    }

    // MARK: - find()

    func test_find_returnsManifest_whenPluginExists() throws {
        let pluginDir = tmpDir.appendingPathComponent("builtin-hello")
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        try validManifestJSON(name: "builtin-hello").write(
            to: pluginDir.appendingPathComponent("plugin.json"),
            atomically: true, encoding: .utf8
        )

        let mgr = PluginManager(rootDir: tmpDir)
        let found = try mgr.find(name: "builtin-hello")
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.name, "builtin-hello")
    }

    func test_find_returnsNil_whenPluginAbsent() throws {
        let mgr = PluginManager(rootDir: tmpDir)
        let found = try mgr.find(name: "nonexistent")
        XCTAssertNil(found)
    }

    // MARK: - pluginDir()

    func test_pluginDir_returnsDir_whenDirectMatch() throws {
        let pluginDir = tmpDir.appendingPathComponent("builtin-hello")
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        try validManifestJSON(name: "builtin-hello").write(
            to: pluginDir.appendingPathComponent("plugin.json"),
            atomically: true, encoding: .utf8
        )

        let mgr = PluginManager(rootDir: tmpDir)
        let manifest = try mgr.list().first!
        let dir = try mgr.pluginDir(for: manifest)
        XCTAssertEqual(dir.lastPathComponent, "builtin-hello")
    }

    func test_pluginDir_returnsDir_whenSuffixMatch() throws {
        // 目录名 "user-hello"，manifest.name = "hello"
        let pluginDir = tmpDir.appendingPathComponent("user-hello")
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        try validManifestJSON(name: "hello").write(
            to: pluginDir.appendingPathComponent("plugin.json"),
            atomically: true, encoding: .utf8
        )

        let mgr = PluginManager(rootDir: tmpDir)
        let manifest = try mgr.list().first!
        let dir = try mgr.pluginDir(for: manifest)
        XCTAssertEqual(dir.lastPathComponent, "user-hello")
    }

    func test_pluginDir_throws_pluginNotFound() throws {
        let mgr = PluginManager(rootDir: tmpDir)
        let manifest = PluginManifest(
            name: "ghost", version: "0.1.0", description: "x",
            keywords: [], cmd: "./run.sh", args: [], env: nil,
            timeout: nil, requiredPath: nil
        )
        XCTAssertThrowsError(try mgr.pluginDir(for: manifest)) { error in
            guard case LauncherError.pluginNotFound(let name) = error else {
                return XCTFail("expected pluginNotFound, got \(error)")
            }
            XCTAssertEqual(name, "ghost")
        }
    }

    // MARK: - Helpers

    private func validManifestJSON(name: String) -> String {
        """
        {
          "name": "\(name)",
          "version": "0.1.0",
          "description": "test plugin",
          "keywords": [],
          "cmd": "./run.sh",
          "args": [],
          "env": null,
          "timeout": 5,
          "requiredPath": null
        }
        """
    }
}
