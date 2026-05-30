import XCTest
import Foundation
@testable import BuddyCore

// MARK: - TranslatePluginManifestAcceptanceTests
//
// 红队验收测试：场景 12（plugin 无 Swift 代码约束验证）
//
// 场景 12：plugin 无 Swift 代码约束验证
//   - 12.P1 translate plugin 目录不含任何 .swift 文件（det-machine）
//   - 12.P2 manifest systemPrompt 字段非空（det-machine）
//   - 12.P3 manifest autoCopyToClipboard == false（det-machine，C4 契约）
//
// 契约来源：C4（autoCopyToClipboard 演进） + D5（新 systemPrompt 模板）
//
// 测试策略：
//   - 用 FileManager 扫描 translate plugin 目录下所有 .swift 文件
//   - 用 JSONDecoder 解码 plugin.json，断言字段值
//
// ⚠️ TDD 红灯预期：
//   - plugin.json 尚未更新 autoCopyToClipboard=false → 12.P3 断言失败。
//   - plugin.json 尚未更新新 systemPrompt → 12.P2 字数断言可能失败。

// MARK: - TranslatePluginManifestAcceptanceTests

final class TranslatePluginManifestAcceptanceTests: XCTestCase {

    // MARK: - Plugin 目录路径

    /// 根据测试 bundle 定位 translate plugin 目录
    /// Package.swift 将 Marketplace 目录作为 bundle resource 复制到 BuddyCore
    private var translatePluginDir: URL? {
        // 尝试从 Bundle.module（SPM 测试 bundle）查找
        // 路径：Sources/ClaudeCodeBuddy/Marketplace/plugins/translate/
        let possiblePaths = [
            // 相对于 package root
            Bundle.module.resourceURL?
                .appendingPathComponent("Marketplace/plugins/translate"),
            // 直接在源码目录（本地开发时）
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()  // tests/BuddyCoreTests/Launcher
                .deletingLastPathComponent()  // tests/BuddyCoreTests
                .deletingLastPathComponent()  // tests
                .deletingLastPathComponent()  // apps/desktop
                .appendingPathComponent("apps/desktop/Sources/ClaudeCodeBuddy/Marketplace/plugins/translate")
        ]

        // 通过 Package.swift 里 .copy("Marketplace") resource 拷贝后的标准路径
        // 走 Bundle.main（tests target runtime）
        if let moduleURL = Bundle.module.resourceURL {
            let fromModule = moduleURL.appendingPathComponent("Marketplace/plugins/translate")
            if FileManager.default.fileExists(atPath: fromModule.path) {
                return fromModule
            }
        }

        // fallback：直接用源码路径（CI/本地开发）
        let srcPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ClaudeCodeBuddy/Marketplace/plugins/translate")

        if FileManager.default.fileExists(atPath: srcPath.path) {
            return srcPath
        }

        return possiblePaths.compactMap { $0 }.first { url in
            FileManager.default.fileExists(atPath: url.path)
        }
    }

    // MARK: - 辅助：解码 plugin.json

    private struct TranslatePluginManifestJSON: Decodable {
        let name: String
        let version: String
        let systemPrompt: String?
        let autoCopyToClipboard: Bool?
        let mode: String?
    }

    private func loadManifestJSON() throws -> TranslatePluginManifestJSON {
        guard let pluginDir = translatePluginDir else {
            throw XCTSkip("translate plugin 目录未找到，跳过 manifest 验证")
        }
        let jsonURL = pluginDir.appendingPathComponent("plugin.json")
        guard FileManager.default.fileExists(atPath: jsonURL.path) else {
            throw XCTSkip("plugin.json 未找到：\(jsonURL.path)")
        }
        let data = try Data(contentsOf: jsonURL)
        return try JSONDecoder().decode(TranslatePluginManifestJSON.self, from: data)
    }

    // MARK: - 场景 12.P1：translate plugin 目录不含任何 .swift 文件

    /// 12.P1 [det-machine]
    /// While translate plugin 目录存在, shall 不含任何 .swift 文件
    ///
    /// observe: find <plugin-dir> -name "*.swift"
    /// assert: 结果为空（stdout == ""）
    ///
    /// Mutation 探针（No-op）：若意外引入 .swift 文件，此测试红灯（设计原则：plugin 纯 JSON + 脚本）。
    func test_scene12_P1_translatePluginDir_containsNoSwiftFiles() throws {
        guard let pluginDir = translatePluginDir else {
            throw XCTSkip("translate plugin 目录未找到，跳过 .swift 文件检查")
        }

        // 递归扫描 translate plugin 目录下所有 .swift 文件
        let enumerator = FileManager.default.enumerator(
            at: pluginDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        var swiftFiles: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension == "swift" {
                swiftFiles.append(url)
            }
        }

        // assert: stdout == ""（无 .swift 文件）
        XCTAssertTrue(
            swiftFiles.isEmpty,
            "12.P1: translate plugin 目录不应含任何 .swift 文件，实际发现: \(swiftFiles.map(\.lastPathComponent))"
        )
    }

    // MARK: - 场景 12.P2：manifest systemPrompt 字段非空

    /// 12.P2 [det-machine]
    /// When 检查 manifest, systemPrompt 字段 shall 非空
    ///
    /// assert: systemPrompt.count > 0
    ///
    /// Mutation 探针（Return-Value）：systemPrompt 被清空 → count == 0 → 断言失败。
    func test_scene12_P2_manifest_systemPromptIsNonEmpty() throws {
        let manifest = try loadManifestJSON()

        guard let systemPrompt = manifest.systemPrompt else {
            XCTFail("12.P2: plugin.json 必须包含 systemPrompt 字段（mode=prompt 模式必填）")
            return
        }

        // assert: systemPrompt.count > 0
        XCTAssertGreaterThan(
            systemPrompt.count, 0,
            "12.P2: systemPrompt 字段必须非空"
        )

        // P0.5 极简 prompt 后：不再断言具体格式指令，只断言 action 标签说明存在
        // 原"含'单词'/'句子'/'输入类型'"断言已删，验收转交红队 acceptance
    }

    /// 12.P2 补充：systemPrompt 包含 action 标签规则（D5 模板的核心）
    ///
    /// Mutation 探针（Return-Value）：旧 systemPrompt（无 action 标签）不触发 TTS → 此测试红灯。
    func test_scene12_P2_manifest_systemPromptContainsActionTagInstructions() throws {
        let manifest = try loadManifestJSON()

        guard let systemPrompt = manifest.systemPrompt else {
            throw XCTSkip("systemPrompt 字段缺失，跳过 action 标签规则验证")
        }

        // assert: systemPrompt 包含 action 标签语法指导
        let containsActionTag = systemPrompt.contains("<action:speak") || systemPrompt.contains("action:speak")
        XCTAssertTrue(
            containsActionTag,
            "12.P2: 新 systemPrompt 必须包含 action:speak 标签示例（驱动 LLM 输出 TTS 标签），当前内容开头: \(systemPrompt.prefix(200))"
        )
    }

    // MARK: - 场景 12.P3：autoCopyToClipboard == false

    /// 12.P3 [det-machine]
    /// When 检查 manifest, autoCopyToClipboard shall == false
    ///
    /// assert: autoCopyToClipboard == false
    ///
    /// 契约 C4：所有内置 marketplace plugin 改为 false，新 plugin 不再自动复制。
    ///
    /// Mutation 探针（Conditional Flip）：若字段为 true → 旧自动复制行为被保留 → 断言失败。
    func test_scene12_P3_manifest_autoCopyToClipboardIsFalse() throws {
        let manifest = try loadManifestJSON()

        // assert: autoCopyToClipboard == false
        // C4 契约：新 translate plugin.json 改为 false
        let autoCopy = manifest.autoCopyToClipboard ?? true  // 默认视为 true（保持旧行为兼容）

        XCTAssertFalse(
            autoCopy,
            "12.P3: translate plugin.json 的 autoCopyToClipboard 必须为 false（C4 契约），实际: \(autoCopy)"
        )
    }

    // MARK: - 补充：manifest name 字段正确

    /// plugin.json name 必须是 "translate"（或符合 PluginManifest validate 规则）
    func test_scene12_manifest_nameIsTranslate() throws {
        let manifest = try loadManifestJSON()

        XCTAssertEqual(
            manifest.name, "translate",
            "manifest name 必须精确是 'translate'"
        )
    }

    /// plugin.json mode 必须是 "prompt"（translate 是 prompt-mode plugin）
    func test_scene12_manifest_modeIsPrompt() throws {
        let manifest = try loadManifestJSON()

        XCTAssertEqual(
            manifest.mode, "prompt",
            "translate plugin 必须是 mode=prompt（prompt-mode plugin），实际: \(manifest.mode ?? "nil")"
        )
    }

    // MARK: - 补充：PromptConfig.autoCopyToClipboard 兼容性（C4）

    /// C4：autoCopyToClipboard=true 旧值仍应触发自动复制（保留兼容）
    /// 此测试通过 PluginManifest JSON 解码验证字段保留（不是行为测试）
    ///
    /// ASSUMES: PluginManifest 仍保留 autoCopyToClipboard 字段（deprecated 但保留）
    func test_c4_autoCopyToClipboard_fieldStillDecodable_forBackwardCompatibility() throws {
        let jsonWithAutoCopyTrue = """
        {
          "name": "test",
          "version": "1.0.0",
          "description": "test",
          "keywords": ["test"],
          "mode": "prompt",
          "systemPrompt": "test",
          "autoCopyToClipboard": true
        }
        """

        // 应能解码（字段保留兼容）
        let manifest = try JSONDecoder().decode(
            PluginManifest.self,
            from: Data(jsonWithAutoCopyTrue.utf8)
        )

        // 字段解码后值为 true（保留兼容，不被忽略）
        XCTAssertEqual(
            manifest.autoCopyToClipboard, true,
            "C4 向后兼容：autoCopyToClipboard=true 旧值必须被正确解码，不应被忽略"
        )
    }

    /// C4：autoCopyToClipboard=false 解码后精确为 false
    func test_c4_autoCopyToClipboard_falseValueDecodedCorrectly() throws {
        let jsonWithAutoCopyFalse = """
        {
          "name": "test",
          "version": "1.0.0",
          "description": "test",
          "keywords": ["test"],
          "mode": "prompt",
          "systemPrompt": "test",
          "autoCopyToClipboard": false
        }
        """

        let manifest = try JSONDecoder().decode(
            PluginManifest.self,
            from: Data(jsonWithAutoCopyFalse.utf8)
        )

        XCTAssertEqual(
            manifest.autoCopyToClipboard, false,
            "C4: autoCopyToClipboard=false 必须被正确解码为 false"
        )
    }
}
