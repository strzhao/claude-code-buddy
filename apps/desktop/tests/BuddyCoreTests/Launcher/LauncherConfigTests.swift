import XCTest
@testable import BuddyCore

final class LauncherConfigTests: XCTestCase {

    // 临时测试路径（避免污染真实 ~/.buddy）
    private var tmpDir: URL!
    private var configPath: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        configPath = tmpDir.appendingPathComponent("launcher.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
        try super.tearDownWithError()
    }

    // MARK: - Codable Round-trip

    func test_codable_roundTrip() throws {
        let cfg = LauncherConfig(
            activeProvider: "anthropic",
            providers: [
                "anthropic": ProviderConfig(kind: "anthropic", baseURL: nil, model: "claude-sonnet-4-5", keyRef: "anthropic.apiKey")
            ],
            hotkey: HotkeyConfig(key: "space", modifiers: ["command", "shift"])
        )
        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(LauncherConfig.self, from: data)
        XCTAssertEqual(decoded, cfg)
    }

    func test_empty_config() {
        let cfg = LauncherConfig.empty
        XCTAssertEqual(cfg.activeProvider, "")
        XCTAssertTrue(cfg.providers.isEmpty)
        XCTAssertNil(cfg.hotkey)
    }

    // MARK: - 使用 LauncherConfig 直接操作文件系统（通过写入默认路径测试）

    func test_save_creates_file_with_correct_permissions() throws {
        // 使用真实 LauncherConstants 路径进行测试
        // 备份现有文件
        let realPath = LauncherConstants.launcherConfigPath
        let backupPath = LauncherConstants.buddyDir.appendingPathComponent("launcher.json.test-bak-\(UUID().uuidString)")
        let existedBefore = FileManager.default.fileExists(atPath: realPath.path)
        if existedBefore {
            try FileManager.default.copyItem(at: realPath, to: backupPath)
        }
        defer {
            if existedBefore {
                try? FileManager.default.removeItem(at: realPath)
                try? FileManager.default.moveItem(at: backupPath, to: realPath)
            } else {
                try? FileManager.default.removeItem(at: realPath)
            }
        }

        let cfg = LauncherConfig(
            activeProvider: "anthropic",
            providers: [
                "anthropic": ProviderConfig(kind: "anthropic", baseURL: nil, model: "claude-sonnet-4-5", keyRef: "anthropic.apiKey")
            ],
            hotkey: nil
        )
        try cfg.save()

        // 验证文件存在
        XCTAssertTrue(FileManager.default.fileExists(atPath: realPath.path))

        // 验证权限 0600
        let attrs = try FileManager.default.attributesOfItem(atPath: realPath.path)
        let perms = attrs[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600, "launcher.json 权限必须为 0600")

        // 验证可 load 回来
        let loaded = try LauncherConfig.load()
        XCTAssertEqual(loaded, cfg)
    }

    func test_load_returns_empty_when_file_not_found() throws {
        // 确保文件不存在
        let realPath = LauncherConstants.launcherConfigPath
        let existedBefore = FileManager.default.fileExists(atPath: realPath.path)
        let backupPath = LauncherConstants.buddyDir.appendingPathComponent("launcher.json.test-bak-\(UUID().uuidString)")
        if existedBefore {
            try FileManager.default.copyItem(at: realPath, to: backupPath)
            try FileManager.default.removeItem(at: realPath)
        }
        defer {
            if existedBefore {
                try? FileManager.default.moveItem(at: backupPath, to: realPath)
            }
        }

        let loaded = try LauncherConfig.load()
        XCTAssertEqual(loaded, .empty)
    }

    // MARK: - ProviderConfig 含 baseURL

    func test_providerConfig_openaiCompatible_roundTrip() throws {
        let cfg = LauncherConfig(
            activeProvider: "ollama",
            providers: [
                "ollama": ProviderConfig(kind: "openai-compatible", baseURL: "http://localhost:11434/v1", model: "llama3", keyRef: "ollama.apiKey")
            ],
            hotkey: nil
        )
        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(LauncherConfig.self, from: data)
        XCTAssertEqual(decoded.providers["ollama"]?.baseURL, "http://localhost:11434/v1")
    }
}
