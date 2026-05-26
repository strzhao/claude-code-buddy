import XCTest
import Security
import CryptoKit
@testable import BuddyCore

// MARK: - LauncherConfigAcceptanceTests
//
// 验收测试：LauncherConfig JSON Codable + 0600 文件权限契约
//
// 设计文档覆盖点（task 002 输出契约）：
//   A. 文件不存在 → load 返回 .empty（activeProvider == ""）
//   B. 空数据 / 无效 JSON 文件 → load 返回 .empty（不抛错）
//   C. save → 文件存在 + 权限 == 0600
//   D. round-trip：save(cfg) → load() 返回 cfg（Equatable 精确断言）
//   E. JSON schema 含 activeProvider / providers / hotkey 字段（CodingKey 验证）
//   F. ProviderConfig 的 baseURL 和 hotkey 是 Optional（缺失时不报错）
//   G. LauncherConfig.empty 的 activeProvider 精确是 ""
//   H. save 写入到测试目录（通过 fixture path 注入）
//   I. providers 字典 round-trip 正确（含 ProviderConfig 各字段）
//
// 测试隔离：所有文件读写使用 NSTemporaryDirectory + UUID 临时路径，
// setUp/tearDown 负责清理，不写 ~/.buddy/（真实 home 目录）。
//
// 注意：LauncherConfig.load() / save() 默认读写 LauncherConstants.launcherConfigPath。
// 红队通过 save(to:) / load(from:) 注入路径，或通过 fixture 文件验证 Codable schema。
// 测试 WILL NOT compile 直到蓝队合并实现 — 这是预期的 TDD 红灯。

final class LauncherConfigAcceptanceTests: XCTestCase {

    private var tempDir: URL!
    private var configPath: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LauncherConfigTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        configPath = tempDir.appendingPathComponent("launcher.json")
    }

    override func tearDown() async throws {
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDir = nil
        configPath = nil
        try await super.tearDown()
    }

    // MARK: - A. 文件不存在 → load 返回 .empty

    /// 文件不存在时 load(from:) 返回 LauncherConfig.empty
    /// activeProvider 精确为空字符串，providers 为空字典
    func test_load_fileNotExists_returnsEmpty() throws {
        let result = try LauncherConfig.load(from: configPath)

        XCTAssertEqual(result.activeProvider, "",
                       "文件不存在时 activeProvider 必须精确是空字符串")
        XCTAssertTrue(result.providers.isEmpty,
                      "文件不存在时 providers 必须是空字典")
        XCTAssertNil(result.hotkey,
                     "文件不存在时 hotkey 必须是 nil")
    }

    // MARK: - B. 空 JSON / 无效 JSON → load 返回 .empty

    /// 空文件 load 不抛错，返回 .empty
    func test_load_emptyFile_returnsEmpty() throws {
        // Given: 写入空文件
        try Data().write(to: configPath)

        // When / Then: 不抛错，返回 empty
        let result = try LauncherConfig.load(from: configPath)
        XCTAssertEqual(result.activeProvider, "",
                       "空文件 load 必须返回 .empty（activeProvider 为空字符串）")
    }

    /// 无效 JSON load 不抛错，返回 .empty
    func test_load_invalidJSON_returnsEmpty() throws {
        try "not valid json }{".data(using: .utf8)!.write(to: configPath)
        let result = try LauncherConfig.load(from: configPath)
        XCTAssertEqual(result.activeProvider, "",
                       "无效 JSON 的 load 必须静默降级为 .empty，不抛错")
    }

    // MARK: - C. save → 文件存在 + 权限 == 0600

    /// save 后文件必须存在
    func test_save_fileExists_afterSave() throws {
        let cfg = LauncherConfig.empty
        try cfg.save(to: configPath)

        XCTAssertTrue(FileManager.default.fileExists(atPath: configPath.path),
                      "save 后文件必须存在于指定路径")
    }

    /// save 后文件权限必须是 0600
    func test_save_filePermission_is0600() throws {
        let cfg = LauncherConfig.empty
        try cfg.save(to: configPath)

        let attrs = try FileManager.default.attributesOfItem(atPath: configPath.path)
        let permissions = attrs[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600,
                       "launcher.json 文件权限必须精确为 0600（-rw-------）")
    }

    // MARK: - D. round-trip：save → load 返回相同值

    /// 空 config round-trip
    func test_roundTrip_emptyConfig() throws {
        let original = LauncherConfig.empty
        try original.save(to: configPath)
        let loaded = try LauncherConfig.load(from: configPath)
        XCTAssertEqual(loaded, original,
                       "LauncherConfig.empty round-trip 必须 Equatable 相等")
    }

    /// 含 anthropic provider 的 config round-trip
    func test_roundTrip_withAnthropicProvider() throws {
        let providerCfg = ProviderConfig(
            kind: "anthropic",
            baseURL: nil,
            model: "claude-sonnet-4-5",
            keyRef: "anthropic.apiKey"
        )
        let original = LauncherConfig(
            activeProvider: "anthropic",
            providers: ["anthropic": providerCfg],
            hotkey: nil
        )

        try original.save(to: configPath)
        let loaded = try LauncherConfig.load(from: configPath)

        XCTAssertEqual(loaded, original,
                       "含 Anthropic provider 的 config round-trip 必须 Equatable 相等")
        XCTAssertEqual(loaded.activeProvider, "anthropic",
                       "activeProvider 必须精确还原为 \"anthropic\"")
        XCTAssertEqual(loaded.providers["anthropic"]?.kind, "anthropic",
                       "providers[\"anthropic\"].kind 必须是 \"anthropic\"")
        XCTAssertEqual(loaded.providers["anthropic"]?.model, "claude-sonnet-4-5",
                       "providers[\"anthropic\"].model 必须精确还原")
        XCTAssertEqual(loaded.providers["anthropic"]?.keyRef, "anthropic.apiKey",
                       "providers[\"anthropic\"].keyRef 必须精确还原")
    }

    /// 含 openai-compatible provider（含 baseURL）的 config round-trip
    func test_roundTrip_withOpenAICompatibleProvider() throws {
        let providerCfg = ProviderConfig(
            kind: "openai-compatible",
            baseURL: "http://localhost:11434/v1",
            model: "qwen2.5:7b",
            keyRef: "ollama.apiKey"
        )
        let original = LauncherConfig(
            activeProvider: "ollama",
            providers: ["ollama": providerCfg],
            hotkey: nil
        )

        try original.save(to: configPath)
        let loaded = try LauncherConfig.load(from: configPath)

        XCTAssertEqual(loaded, original)
        XCTAssertEqual(loaded.providers["ollama"]?.baseURL, "http://localhost:11434/v1",
                       "openai-compatible 的 baseURL 必须精确还原")
        XCTAssertEqual(loaded.providers["ollama"]?.kind, "openai-compatible",
                       "kind 必须精确还原为 \"openai-compatible\"")
    }

    /// 含 hotkey 的 config round-trip
    func test_roundTrip_withHotkey() throws {
        let original = LauncherConfig(
            activeProvider: "anthropic",
            providers: [:],
            hotkey: HotkeyConfig(key: "space", modifiers: ["command", "shift"])
        )
        try original.save(to: configPath)
        let loaded = try LauncherConfig.load(from: configPath)

        XCTAssertEqual(loaded, original)
        XCTAssertEqual(loaded.hotkey?.key, "space",
                       "hotkey.key 必须还原为 \"space\"")
        XCTAssertEqual(loaded.hotkey?.modifiers, ["command", "shift"],
                       "hotkey.modifiers 必须还原为 [\"command\", \"shift\"]")
    }

    // MARK: - E. JSON schema CodingKey 验证

    /// save 后的 JSON 含正确的 snake_case / camelCase 字段名
    /// 验证 CodingKey 按设计文档定义（activeProvider / providers / hotkey）
    func test_jsonSchema_containsExpectedKeys() throws {
        let providerCfg = ProviderConfig(
            kind: "anthropic",
            baseURL: nil,
            model: "claude-sonnet-4-5",
            keyRef: "anthropic.apiKey"
        )
        let cfg = LauncherConfig(
            activeProvider: "anthropic",
            providers: ["anthropic": providerCfg],
            hotkey: nil
        )
        try cfg.save(to: configPath)

        let data = try Data(contentsOf: configPath)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertNotNil(json?["activeProvider"],
                        "JSON 必须含 activeProvider 字段")
        XCTAssertNotNil(json?["providers"],
                        "JSON 必须含 providers 字段")
        // hotkey 是 nil，可能不含该字段或含 null
        XCTAssertEqual(json?["activeProvider"] as? String, "anthropic",
                       "activeProvider 值必须是 \"anthropic\"")

        let providers = json?["providers"] as? [String: Any]
        XCTAssertNotNil(providers?["anthropic"],
                        "providers[\"anthropic\"] 必须存在")
        let ap = providers?["anthropic"] as? [String: Any]
        XCTAssertEqual(ap?["kind"] as? String, "anthropic",
                       "ProviderConfig.kind 必须编码为 \"kind\"")
        XCTAssertEqual(ap?["model"] as? String, "claude-sonnet-4-5",
                       "ProviderConfig.model 必须编码为 \"model\"")
        XCTAssertEqual(ap?["keyRef"] as? String, "anthropic.apiKey",
                       "ProviderConfig.keyRef 必须编码为 \"keyRef\"")
    }

    // MARK: - F. Optional 字段缺失不报错

    /// 从缺少 hotkey 和 baseURL 的 JSON 解码不报错
    func test_decode_optionalFieldsMissing_doesNotThrow() throws {
        let json = """
        {
            "activeProvider": "anthropic",
            "providers": {
                "anthropic": {
                    "kind": "anthropic",
                    "model": "claude-sonnet-4-5",
                    "keyRef": "anthropic.apiKey"
                }
            }
        }
        """
        // 写入文件
        try json.data(using: .utf8)!.write(to: configPath)
        let cfg = try LauncherConfig.load(from: configPath)

        XCTAssertNil(cfg.hotkey, "缺少 hotkey 字段时必须解码为 nil")
        XCTAssertNil(cfg.providers["anthropic"]?.baseURL,
                     "缺少 baseURL 字段时 ProviderConfig.baseURL 必须解码为 nil")
        XCTAssertEqual(cfg.providers["anthropic"]?.kind, "anthropic",
                       "其他字段必须正确解码")
    }

    // MARK: - G. LauncherConfig.empty 精确值

    /// LauncherConfig.empty 的各字段精确值
    func test_empty_exactValues() {
        let empty = LauncherConfig.empty
        XCTAssertEqual(empty.activeProvider, "",
                       "LauncherConfig.empty.activeProvider 必须精确是空字符串 \"\"")
        XCTAssertTrue(empty.providers.isEmpty,
                      "LauncherConfig.empty.providers 必须是空字典")
        XCTAssertNil(empty.hotkey,
                     "LauncherConfig.empty.hotkey 必须是 nil")
    }

    // MARK: - I. providers 字典多项 round-trip

    /// 多个 provider 的字典 round-trip 正确
    func test_roundTrip_multipleProviders() throws {
        let original = LauncherConfig(
            activeProvider: "anthropic",
            providers: [
                "anthropic": ProviderConfig(kind: "anthropic", baseURL: nil,
                                             model: "claude-opus-4-5", keyRef: "anthropic.apiKey"),
                "ollama": ProviderConfig(kind: "openai-compatible",
                                         baseURL: "http://localhost:11434/v1",
                                         model: "qwen2.5:7b", keyRef: "ollama.apiKey")
            ],
            hotkey: nil
        )
        try original.save(to: configPath)
        let loaded = try LauncherConfig.load(from: configPath)

        XCTAssertEqual(loaded, original,
                       "多 provider 字典 round-trip 必须 Equatable 相等")
        XCTAssertEqual(loaded.providers.count, 2,
                       "providers 数量必须是 2")
    }
}
