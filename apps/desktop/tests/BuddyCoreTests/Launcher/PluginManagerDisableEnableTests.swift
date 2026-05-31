import XCTest
@testable import BuddyCore

final class PluginManagerDisableEnableTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "buddy-pm-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    // MARK: - disable()

    func test_disable_createsMarker_forExistingPlugin() throws {
        let pluginDir = tmpDir.appending(path: "translate")
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)

        let mgr = PluginManager(rootDir: tmpDir)
        try mgr.disable(name: "translate")

        let marker = pluginDir.appending(path: ".disabled")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    func test_disable_throwsPluginNotFound_whenDirAbsent() throws {
        let mgr = PluginManager(rootDir: tmpDir)
        XCTAssertThrowsError(try mgr.disable(name: "ghost")) { error in
            guard case LauncherError.pluginNotFound(let name) = error else {
                return XCTFail("expected pluginNotFound, got \(error)")
            }
            XCTAssertEqual(name, "ghost")
        }
    }

    func test_disable_isIdempotent() throws {
        let pluginDir = tmpDir.appending(path: "translate")
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)

        let mgr = PluginManager(rootDir: tmpDir)
        try mgr.disable(name: "translate")
        XCTAssertNoThrow(try mgr.disable(name: "translate"))
        let marker = pluginDir.appending(path: ".disabled")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    // MARK: - enable()

    func test_enable_removesMarker_whenDisabled() throws {
        let pluginDir = tmpDir.appending(path: "translate")
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        try Data().write(to: pluginDir.appending(path: ".disabled"))

        let mgr = PluginManager(rootDir: tmpDir)
        try mgr.enable(name: "translate")

        let marker = pluginDir.appending(path: ".disabled")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func test_enable_throwsPluginNotFound_whenDirAbsent() throws {
        let mgr = PluginManager(rootDir: tmpDir)
        XCTAssertThrowsError(try mgr.enable(name: "ghost")) { error in
            guard case LauncherError.pluginNotFound(let name) = error else {
                return XCTFail("expected pluginNotFound, got \(error)")
            }
            XCTAssertEqual(name, "ghost")
        }
    }

    func test_enable_isNoOp_whenNotDisabled() throws {
        let pluginDir = tmpDir.appending(path: "translate")
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)

        let mgr = PluginManager(rootDir: tmpDir)
        XCTAssertNoThrow(try mgr.enable(name: "translate"))
        let marker = pluginDir.appending(path: ".disabled")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    // MARK: - disabledNames()

    func test_disabledNames_returnsAllDisabled() throws {
        let dirA = tmpDir.appending(path: "alpha")
        let dirB = tmpDir.appending(path: "beta")
        let dirC = tmpDir.appending(path: "gamma")
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirC, withIntermediateDirectories: true)

        let mgr = PluginManager(rootDir: tmpDir)
        try mgr.disable(name: "alpha")
        try mgr.disable(name: "gamma")

        let names = Set(try mgr.disabledNames())
        XCTAssertEqual(names, Set(["alpha", "gamma"]))
    }

    func test_disabledNames_returnsEmpty_whenNoneDisabled() throws {
        let dirA = tmpDir.appending(path: "alpha")
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)

        let mgr = PluginManager(rootDir: tmpDir)
        XCTAssertEqual(try mgr.disabledNames(), [])
    }

    func test_disabledNames_returnsEmpty_whenRootDirAbsent() throws {
        let mgr = PluginManager(rootDir: tmpDir.appending(path: "nonexistent"))
        XCTAssertEqual(try mgr.disabledNames(), [])
    }

    // MARK: - list() 集成

    func test_list_skipsDisabledPlugin() throws {
        // 建两个 valid plugin，其中一个 disable
        let dirA = tmpDir.appending(path: "alpha")
        let dirB = tmpDir.appending(path: "beta")
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
        try validManifestJSON(name: "alpha").write(
            to: dirA.appending(path: "plugin.json"),
            atomically: true, encoding: .utf8
        )
        try validManifestJSON(name: "beta").write(
            to: dirB.appending(path: "plugin.json"),
            atomically: true, encoding: .utf8
        )

        let mgr = PluginManager(rootDir: tmpDir)
        try mgr.disable(name: "alpha")

        let result = try mgr.list()
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].name, "beta")

        // enable 后恢复
        try mgr.enable(name: "alpha")
        let resultAfter = try mgr.list()
        XCTAssertEqual(Set(resultAfter.map { $0.name }), Set(["alpha", "beta"]))
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
