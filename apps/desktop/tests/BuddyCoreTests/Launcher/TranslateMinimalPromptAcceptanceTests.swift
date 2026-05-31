import XCTest
@testable import BuddyCore

// MARK: - TranslateMinimalPromptAcceptanceTests
//
// 红队验收测试：P0.5 — translate plugin.json systemPrompt 极简化
//
// 设计文档契约：
//   - systemPrompt 改为约 100 字（vs 原 1273 字），上限断言 < 300 字符
//   - 必须含 <action:speak 字符串（告知协议）
//   - 必须含 <action:copy 字符串（告知协议）
//   - 版本号 0.5.0
//   - marketplace 源（apps/desktop/Sources/.../plugins/translate/plugin.json）
//     必须和 ~/.buddy/launcher-plugins/translate/plugin.json 同步
//
// 测试策略：
//   直接读磁盘 JSON 文件，解析 PluginManifest，做字段级断言。
//   本地 dev 同步文件不存在时 XCTSkip（不 FAIL）。

final class TranslateMinimalPromptAcceptanceTests: XCTestCase {

    // MARK: - 文件路径

    /// marketplace 源 plugin.json 路径（相对工程根目录推算）
    private var marketplacePluginURL: URL {
        // 测试 bundle 在 .build/ 深处；通过 #file 反推工程根
        // #file = .../apps/desktop/tests/BuddyCoreTests/Launcher/TranslateMinimalPromptAcceptanceTests.swift
        let thisFile = URL(fileURLWithPath: #file)
        // 上溯 5 层：Launcher/ → BuddyCoreTests/ → tests/ → desktop/ → apps/ → 工程根
        var projectRoot = thisFile
        for _ in 0..<6 { projectRoot = projectRoot.deletingLastPathComponent() }
        return projectRoot
            .appendingPathComponent("apps/desktop/Sources/ClaudeCodeBuddy/Marketplace/plugins/translate/plugin.json")
    }

    /// 本地 dev 安装路径（~/.buddy/launcher-plugins/translate/plugin.json）
    private var localPluginURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".buddy/launcher-plugins/translate/plugin.json")
    }

    // MARK: - 加载 helper

    private func loadManifest(from url: URL) throws -> PluginManifest {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(PluginManifest.self, from: data)
    }

    // MARK: - P0.5-A: 版本号 == "0.5.0"

    /// marketplace 源 plugin.json version 必须精确是 "0.5.0"
    func test_translatePlugin_version_is0dot5dot0() throws {
        let manifest = try loadManifest(from: marketplacePluginURL)
        XCTAssertEqual(manifest.version, "0.5.0",
                       "translate plugin 版本必须是 0.5.0（P0.5 极简化版本），实际: \(manifest.version)")
    }

    // MARK: - P0.5-B: systemPrompt 含 <action:speak

    /// systemPrompt 必须含 <action:speak 字符串
    func test_translatePlugin_systemPrompt_containsActionSpeak() throws {
        let manifest = try loadManifest(from: marketplacePluginURL)
        let systemPrompt = extractSystemPrompt(from: manifest)

        XCTAssertTrue(systemPrompt.contains("<action:speak"),
                      "systemPrompt 必须含 <action:speak（action 协议标记），实际 prompt: \(systemPrompt.prefix(200))")
    }

    // MARK: - P0.5-C: systemPrompt 含 <action:copy

    /// systemPrompt 必须含 <action:copy 字符串
    func test_translatePlugin_systemPrompt_containsActionCopy() throws {
        let manifest = try loadManifest(from: marketplacePluginURL)
        let systemPrompt = extractSystemPrompt(from: manifest)

        XCTAssertTrue(systemPrompt.contains("<action:copy"),
                      "systemPrompt 必须含 <action:copy（action 协议标记），实际 prompt: \(systemPrompt.prefix(200))")
    }

    // MARK: - P0.5-D: systemPrompt 长度 < 300 字符（极简化约束）

    /// systemPrompt 长度必须 < 300 字符（原 1273 字 → 约 100 字 + 缓冲）
    func test_translatePlugin_systemPrompt_lengthUnder300() throws {
        let manifest = try loadManifest(from: marketplacePluginURL)
        let systemPrompt = extractSystemPrompt(from: manifest)

        XCTAssertLessThan(systemPrompt.count, 300,
                          "systemPrompt 必须 < 300 字符（P0.5 极简化，原 1273 字 → ~100 字），实际长度: \(systemPrompt.count)")
    }

    // MARK: - P0.5-E: systemPrompt 不含 5 个示例（与旧 v0.3.0 行为相反）

    /// v0.5.0 极简化后 systemPrompt 不应含完整 5 个 few-shot 示例块
    func test_translatePlugin_systemPrompt_notContainsFiveShotExamples() throws {
        let manifest = try loadManifest(from: marketplacePluginURL)
        let systemPrompt = extractSystemPrompt(from: manifest)

        // 计算 "## 示例" 出现次数（旧版有 5 个）
        let exampleCount = systemPrompt.components(separatedBy: "## 示例").count - 1

        XCTAssertLessThan(exampleCount, 5,
                          "极简 systemPrompt 不应含 5 个 '## 示例' 块（旧 v0.3.0 特征），实际 '## 示例' 数量: \(exampleCount)")
    }

    // MARK: - P0.5-F: mode == "prompt"

    /// translate plugin 必须是 prompt mode
    func test_translatePlugin_mode_isPrompt() throws {
        let manifest = try loadManifest(from: marketplacePluginURL)
        guard case .prompt = manifest.modeConfig else {
            XCTFail("translate plugin mode 必须是 prompt，实际 modeConfig: \(manifest.modeConfig)")
            return
        }
        // 验证通过
    }

    // MARK: - P0.5-G: 本地 dev 安装路径版本与 marketplace 一致（XCTSkip 若不存在）

    /// ~/.buddy/launcher-plugins/translate/plugin.json 若存在，版本必须与 marketplace 源一致
    func test_translatePlugin_localDevFile_versionMatchesMarketplace() throws {
        // 若本地文件不存在，这是正常 dev 环境，XCTSkip 而非 FAIL
        guard FileManager.default.fileExists(atPath: localPluginURL.path) else {
            throw XCTSkip("本地 dev 文件 \(localPluginURL.path) 不存在，跳过同步检查（非 CI 环境）")
        }

        let marketplaceManifest = try loadManifest(from: marketplacePluginURL)
        let localManifest = try loadManifest(from: localPluginURL)

        XCTAssertEqual(localManifest.version, marketplaceManifest.version,
                       "本地 dev 安装版本 '\(localManifest.version)' 必须与 marketplace 源版本 '\(marketplaceManifest.version)' 一致")
    }

    // MARK: - P0.5-H: 本地 dev 安装路径 systemPrompt 与 marketplace 源一致

    /// ~/.buddy/launcher-plugins/translate/plugin.json 若存在，systemPrompt 必须与 marketplace 源一致
    func test_translatePlugin_localDevFile_systemPromptMatchesMarketplace() throws {
        guard FileManager.default.fileExists(atPath: localPluginURL.path) else {
            throw XCTSkip("本地 dev 文件 \(localPluginURL.path) 不存在，跳过同步检查")
        }

        let marketplaceManifest = try loadManifest(from: marketplacePluginURL)
        let localManifest = try loadManifest(from: localPluginURL)

        let marketplacePrompt = extractSystemPrompt(from: marketplaceManifest)
        let localPrompt = extractSystemPrompt(from: localManifest)

        XCTAssertEqual(localPrompt, marketplacePrompt,
                       "本地 dev 安装的 systemPrompt 必须与 marketplace 源完全一致（同步检查）")
    }

    // MARK: - Helper

    /// 从 manifest 提取 systemPrompt（prompt mode only）
    private func extractSystemPrompt(from manifest: PluginManifest) -> String {
        if case .prompt(let cfg) = manifest.modeConfig {
            return cfg.systemPrompt
        }
        return ""
    }
}
