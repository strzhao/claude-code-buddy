import XCTest
import AppKit
@testable import BuddyCore

// MARK: - T6 单测：AIToolItem 模型 + loadToolGroups 数据层

/// T6 AI 工具分组数据模型单测（2026-07-02）。
///
/// 覆盖：
/// - AIToolItem 构造 + 字段
/// - jargonHits() 黑话检测（AC-TOOLS-NO-JARGON 数据层守护）
/// - ProviderSettingsViewController.loadToolGroups() 数据结构：
///   * 固定 2 分组（内置能力 / 已装插件）
///   * 内置项固定 2 条（朗读回复 / 复制到剪贴板），summary 人话无黑话
///   * 插件项 summary 来自 PluginManifest.displaySummary（人话降级）
@MainActor
final class ProviderSettingsToolsTests: XCTestCase {

    // MARK: - AIToolItem 模型

    func test_AIToolItem_init_preservesAllFields() {
        let item = AIToolItem(
            symbol: "🔊",
            title: "朗读回复",
            summary: "把 AI 回复读出声",
            source: "内置"
        )
        XCTAssertEqual(item.symbol, "🔊")
        XCTAssertEqual(item.title, "朗读回复")
        XCTAssertEqual(item.summary, "把 AI 回复读出声")
        XCTAssertEqual(item.source, "内置")
    }

    // MARK: - AC-TOOLS-NO-JARGON 数据层（jargonHits）

    func test_AIToolItem_jargonHits_emptyForHumanReadableItem() {
        let item = AIToolItem(
            symbol: "🔊", title: "朗读回复",
            summary: "把 AI 回复读出声", source: "内置"
        )
        XCTAssertTrue(item.jargonHits().isEmpty,
                      "人话化 item 不得命中黑话，实际命中: \(item.jargonHits())")
    }

    func test_AIToolItem_jargonHits_catchesStdinCommandPrompt() {
        let stdinItem = AIToolItem(symbol: "x", title: "tool", summary: "stdin 工具", source: "p")
        XCTAssertTrue(stdinItem.jargonHits().contains("stdin"),
                      "stdin 黑话必须被 jargonHits 命中")

        let commandItem = AIToolItem(symbol: "x", title: "tool", summary: "command 直接产出", source: "p")
        XCTAssertTrue(commandItem.jargonHits().contains("command"),
                      "command 黑话必须被 jargonHits 命中")

        let promptItem = AIToolItem(symbol: "x", title: "tool", summary: "prompt LLM 单轮", source: "p")
        XCTAssertTrue(promptItem.jargonHits().contains("prompt"),
                      "prompt 黑话必须被 jargonHits 命中")

        let attachItem = AIToolItem(symbol: "x", title: "tool", summary: "attach_action speak", source: "p")
        XCTAssertTrue(attachItem.jargonHits().contains("attach_action"),
                      "attach_action 黑话必须被 jargonHits 命中")
    }

    // MARK: - loadToolGroups 数据结构

    /// loadToolGroups 返回固定 2 个分组，顺序：内置能力 → 已装插件。
    func test_loadToolGroups_returnsTwoGroupsInOrder() {
        let vc = ProviderSettingsViewController()
        let groups = vc.loadToolGroups()

        XCTAssertEqual(groups.count, 2,
                       "loadToolGroups 必须返回 2 个分组（内置能力 / 已装插件），实际: \(groups.count)")
        XCTAssertEqual(groups[0].title, "内置能力",
                       "第 0 组标题必须为「内置能力」，实际: \(groups[0].title)")
        XCTAssertEqual(groups[1].title, "已装插件",
                       "第 1 组标题必须为「已装插件」，实际: \(groups[1].title)")
    }

    /// 内置能力组固定含 2 条：朗读回复 + 复制到剪贴板，summary 人话化无黑话。
    func test_loadToolGroups_builtinContainsSpeakAndCopyWithHumanSummary() {
        let vc = ProviderSettingsViewController()
        let groups = vc.loadToolGroups()
        let builtin = groups.first { $0.title == "内置能力" }
        XCTAssertNotNil(builtin, "必须含「内置能力」分组")

        let titles = builtin!.items.map { $0.title }
        XCTAssertTrue(titles.contains("朗读回复"),
                      "内置能力必须含「朗读回复」，实际: \(titles)")
        XCTAssertTrue(titles.contains("复制到剪贴板"),
                      "内置能力必须含「复制到剪贴板」，实际: \(titles)")

        // AC-TOOLS-NO-JARGON：所有内置项的 title/summary/source 不得含黑话
        for item in builtin!.items {
            let hits = item.jargonHits()
            XCTAssertTrue(hits.isEmpty,
                          "内置项「\(item.title)」不得含黑话，实际命中: \(hits)")
        }

        // source 徽标固定「内置」
        for item in builtin!.items {
            XCTAssertEqual(item.source, "内置",
                           "内置项 source 必须为「内置」，实际: \(item.source)")
        }
    }

    /// AC-TOOLS-SUMMARY：插件项 summary 必须来自 manifest.displaySummary（人话降级，永不空）。
    func test_loadToolGroups_pluginItemsSummaryNonEmpty() {
        let vc = ProviderSettingsViewController()
        let groups = vc.loadToolGroups()
        let plugins = groups.first { $0.title == "已装插件" }

        // 已装插件可能为空（无插件场景），跳过；有则 summary 必须非空
        guard let pluginsGroup = plugins, !pluginsGroup.items.isEmpty else {
            return  // 无插件场景，summary 检查 N/A
        }

        for item in pluginsGroup.items {
            XCTAssertFalse(item.summary.isEmpty,
                           "插件项「\(item.title)」summary 必须非空（来自 displaySummary 降级），实际: '\(item.summary)'")
            // source 必须是 manifest.name（非空，非「内置」）
            XCTAssertFalse(item.source.isEmpty,
                           "插件项 source 必须为 manifest.name（非空），实际: '\(item.source)'")
            XCTAssertNotEqual(item.source, "内置",
                              "插件项 source 不得为「内置」（应为 manifest.name），实际: '\(item.source)'")
        }
    }

    /// AC-TOOLS-NO-JARGON：插件项 summary 也不得含 stdin/command/prompt mode 黑话。
    func test_loadToolGroups_pluginItemsNoJargon() {
        let vc = ProviderSettingsViewController()
        let groups = vc.loadToolGroups()
        let plugins = groups.first { $0.title == "已装插件" }
        guard let pluginsGroup = plugins, !pluginsGroup.items.isEmpty else {
            return  // 无插件场景
        }

        for item in pluginsGroup.items {
            let hits = item.jargonHits()
            XCTAssertTrue(hits.isEmpty,
                          "插件项「\(item.title)」summary 不得含 mode 黑话，实际命中: \(hits)")
        }
    }
}
