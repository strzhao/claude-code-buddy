import XCTest
@testable import BuddyCore

final class PluginManifestTests: XCTestCase {

    // MARK: - Codable round-trip

    func test_codable_roundTrip() throws {
        let json = """
        {
          "name": "builtin-hello",
          "version": "0.1.0",
          "description": "示例插件",
          "keywords": ["hello", "demo"],
          "cmd": "./hello.sh",
          "args": [],
          "env": null,
          "timeout": 5,
          "requiredPath": null
        }
        """.data(using: .utf8)!
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: json)
        XCTAssertEqual(manifest.name, "builtin-hello")
        XCTAssertEqual(manifest.version, "0.1.0")
        XCTAssertEqual(manifest.cmd, "./hello.sh")
        XCTAssertEqual(manifest.timeout, 5)
        XCTAssertNil(manifest.requiredPath)
        // re-encode
        let reencoded = try JSONEncoder().encode(manifest)
        let manifest2 = try JSONDecoder().decode(PluginManifest.self, from: reencoded)
        XCTAssertEqual(manifest, manifest2)
    }

    func test_effectiveTimeout_defaultWhenNil() {
        let m = makeManifest(name: "hello", timeout: nil)
        XCTAssertEqual(m.effectiveTimeout, LauncherConstants.pluginDefaultTimeoutSec)
    }

    func test_effectiveTimeout_usesExplicit() {
        let m = makeManifest(name: "hello", timeout: 60)
        XCTAssertEqual(m.effectiveTimeout, 60)
    }

    // MARK: - validate 正例

    func test_validate_passes_whenNameEqualsDir() throws {
        let m = makeManifest(name: "builtin-hello", timeout: 5)
        XCTAssertNoThrow(try m.validate(againstDirName: "builtin-hello"))
    }

    func test_validate_passes_whenNameEqualsDirLastSegment() throws {
        let m = makeManifest(name: "hello", timeout: 5)
        XCTAssertNoThrow(try m.validate(againstDirName: "user-hello"))
    }

    // MARK: - validate 5 个反例

    /// 反例 1：name 与目录名不匹配
    func test_validate_fails_nameMismatch() {
        let m = makeManifest(name: "other", timeout: 5)
        XCTAssertThrowsError(try m.validate(againstDirName: "builtin-hello")) { error in
            guard case LauncherError.pluginManifestInvalid(let reason) = error else {
                return XCTFail("expected pluginManifestInvalid, got \(error)")
            }
            XCTAssertTrue(reason.contains("other"))
        }
    }

    /// 反例 2：cmd 包含 /.. 路径穿越
    func test_validate_fails_cmdContainsDotDotSlash() {
        var m = makeManifest(name: "builtin-hello", timeout: 5)
        m = PluginManifest(
            name: m.name, version: m.version, description: m.description,
            keywords: m.keywords, cmd: "../evil.sh", args: [], env: nil,
            timeout: m.timeout, requiredPath: nil
        )
        XCTAssertThrowsError(try m.validate(againstDirName: "builtin-hello")) { error in
            guard case LauncherError.pluginManifestInvalid(let reason) = error else {
                return XCTFail("expected pluginManifestInvalid, got \(error)")
            }
            XCTAssertTrue(reason.contains(".."))
        }
    }

    /// 反例 3：cmd 是绝对路径
    func test_validate_fails_cmdAbsolutePath() {
        let m = PluginManifest(
            name: "builtin-hello", version: "0.1.0", description: "x",
            keywords: [], cmd: "/usr/bin/evil", args: [], env: nil,
            timeout: 5, requiredPath: nil
        )
        XCTAssertThrowsError(try m.validate(againstDirName: "builtin-hello")) { error in
            guard case LauncherError.pluginManifestInvalid(let reason) = error else {
                return XCTFail("expected pluginManifestInvalid, got \(error)")
            }
            XCTAssertTrue(reason.contains("绝对路径"))
        }
    }

    /// 反例 4：timeout = 200 超过上限 120
    func test_validate_fails_timeoutTooLarge() {
        let m = makeManifest(name: "builtin-hello", timeout: 200)
        XCTAssertThrowsError(try m.validate(againstDirName: "builtin-hello")) { error in
            guard case LauncherError.pluginManifestInvalid(let reason) = error else {
                return XCTFail("expected pluginManifestInvalid, got \(error)")
            }
            XCTAssertTrue(reason.contains("200"))
        }
    }

    /// 反例 5：requiredPath 包含 11 个元素（超过 10 的上限）
    func test_validate_fails_requiredPathTooMany() {
        let paths = (0...10).map { "bin\($0)" }  // 11 个
        let m = PluginManifest(
            name: "builtin-hello", version: "0.1.0", description: "x",
            keywords: [], cmd: "./run.sh", args: [], env: nil,
            timeout: 5, requiredPath: paths
        )
        XCTAssertThrowsError(try m.validate(againstDirName: "builtin-hello")) { error in
            guard case LauncherError.pluginManifestInvalid(let reason) = error else {
                return XCTFail("expected pluginManifestInvalid, got \(error)")
            }
            XCTAssertTrue(reason.contains("11"))
        }
    }

    // MARK: - Helpers

    private func makeManifest(name: String, timeout: Int?) -> PluginManifest {
        PluginManifest(
            name: name,
            version: "0.1.0",
            description: "test",
            keywords: [],
            cmd: "./run.sh",
            args: [],
            env: nil,
            timeout: timeout,
            requiredPath: nil
        )
    }
}
