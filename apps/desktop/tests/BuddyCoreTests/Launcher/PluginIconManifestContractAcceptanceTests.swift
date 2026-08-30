import XCTest
@testable import BuddyCore

// MARK: - PluginIconManifestContractAcceptanceTests
//
// 红队验收测试（TDD 红灯）：PluginManifest.icon 可选字段 + 插件行 iconEmoji + CLI mirror 源码契约
//
// 设计文档契约引用（## 设计决策 D7/D1 + ## 契约规约 C-ICON-FIELD）：
//   D7：PluginManifest.icon（decodeIfPresent ?? nil，旧 json 缺字段必须整体 decode 成功）；
//       CLI mirror CLIPluginManifestCheck.icon 同步；inspect 输出 icon（nil 省略）
//   D1：插件行 iconEmoji = manifest.icon
//   C-ICON-FIELD：icon 可选；缺字段 decode 成功 icon==nil；CLI mirror 双绑一致；inspect 含/省略 icon key
//
// CONTRACT_AMBIGUOUS：
//   1. `buddy launcher inspect` 的 JSON 构造无声明可测入口（CLI 经 socket，BuddyCLI target
//      不在 BuddyCoreTests 依赖内不可 import）——inspect「nil 省略」以 PluginManifest Codable
//      encode 对称行为断言（nil 键省略 / 非 nil 键出现），即 inspect JSON 构造的同一数据源。
//   2. CLI mirror 双绑（6.P3）以 fs-grep 源码契约断言（Sources/BuddyCLI/main.swift 中
//      CLIPluginManifestCheck 区域含 icon 处理），沿用 LauncherSourceContractAcceptanceTests 先例。
//
// TDD 红灯：PluginManifest.icon 未加时编译失败（manifest.icon 引用），属预期。

@MainActor
final class PluginIconManifestContractAcceptanceTests: XCTestCase {

    // MARK: - 路径辅助（沿用 LauncherSourceContractAcceptanceTests 的仓库根定位法）

    private var projectRoot: String {
        var url = URL(fileURLWithPath: #file)
        for _ in 0..<12 {
            url = url.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) {
                return url.path
            }
        }
        return "/Users/stringzhao/workspace_sync/personal_projects/claude-code-buddy"
    }

    private var cliMainPath: String {
        "\(projectRoot)/apps/desktop/Sources/BuddyCLI/main.swift"
    }

    // MARK: - manifest 构造

    private func decodeManifest(_ json: String) throws -> PluginManifest {
        try JSONDecoder().decode(PluginManifest.self, from: json.data(using: .utf8)!)
    }

    private func manifestJSON(name: String, icon: String?) -> String {
        let iconField: String
        if let icon = icon {
            iconField = "\"icon\": \"\(icon)\","
        } else {
            iconField = ""
        }
        return """
        {
          "name": "\(name)",
          "version": "0.1.0",
          "description": "icon contract test",
          "keywords": ["kw"],
          \(iconField)
          "mode": "command",
          "cmd": "echo",
          "args": []
        }
        """
    }

    // MARK: - 场景6.P2 [det-machine]：缺 icon 字段整体 decode 成功且 icon==nil

    /// 场景6.P2：旧 plugin.json 无 icon 字段 → decode 不抛错、icon == nil（向后兼容红线）。
    /// Mutation kill：icon 声明为非可选（缺 key 抛 keyNotFound）→ 本测试直接编译期/运行期挂。
    func test_scenario6_P2_legacyJsonWithoutIcon_decodesWithNilIcon() throws {
        // 最简 legacy 形态（对称 PluginManifestSummaryTests 的旧 json 回归）
        let legacy = """
        {"name":"old","version":"0.1.0","description":"旧插件","keywords":[],"mode":"stdin","cmd":"./x"}
        """
        let manifest = try decodeManifest(legacy)
        XCTAssertEqual(manifest.name, "old", "场景6.P2: 缺 icon 字段必须整体 decode 成功")
        XCTAssertNil(manifest.icon, "场景6.P2: 缺 icon 字段 decode 后 icon 必须为 nil")

        // 带 summary 的 legacy 形态同样必须兼容
        let legacy2 = """
        {"name":"old2","version":"0.1.0","description":"旧插件2","keywords":["kw"],"summary":"摘要","mode":"command","cmd":"echo","args":[]}
        """
        let manifest2 = try decodeManifest(legacy2)
        XCTAssertNil(manifest2.icon, "场景6.P2: legacy+summary json decode 后 icon 必须为 nil")
    }

    // MARK: - icon 字段 decode 双向

    /// C-ICON-FIELD [det-machine]：icon 非 nil 时 decode 保真（emoji 逐字）。
    func test_C_ICON_FIELD_iconDecodedVerbatim() throws {
        let manifest = try decodeManifest(manifestJSON(name: "qr", icon: "🏷"))
        XCTAssertEqual(manifest.icon, "🏷",
            "C-ICON-FIELD: icon 字段必须逐字 decode，实际=\(manifest.icon ?? "<nil>")")
    }

    // MARK: - 场景6.P4 [det-machine]：inspect icon key 含/省略（经 Codable encode 对称断言）

    /// 场景6.P4：icon 非 nil → JSON 含 "icon" 键；icon nil → "icon" 键省略。
    /// （CONTRACT_AMBIGUOUS：inspect 无声明可测入口，以其 JSON 数据源的 Codable 行为断言。）
    func test_scenario6_P4_encode_iconKeyIncludedWhenPresent_omittedWhenNil() throws {
        // 非 nil → 键必须出现且值保真
        let withIcon = try decodeManifest(manifestJSON(name: "qr", icon: "🏷"))
        let objWith = try JSONSerialization.jsonObject(with: JSONEncoder().encode(withIcon)) as? [String: Any]
        XCTAssertEqual(objWith?["icon"] as? String, "🏷",
            "场景6.P4: icon 非 nil 时 encode/inspect 必须含 icon 键（值逐字）")

        // nil → 键必须省略
        let noIcon = try decodeManifest(manifestJSON(name: "qr", icon: nil))
        let objWithout = try JSONSerialization.jsonObject(with: JSONEncoder().encode(noIcon)) as? [String: Any]
        XCTAssertNil(objWithout?["icon"],
            "场景6.P4: icon 为 nil 时 encode/inspect 必须省略 icon 键（nil 省略契约）")
    }

    // MARK: - 场景6.P3 [fs-grep]：CLI mirror icon 与 BuddyCore 一致

    /// 场景6.P3：Sources/BuddyCLI/main.swift 的 CLIPluginManifestCheck 区域必须含 icon 处理
    /// （mirror 双绑，与 BuddyCore PluginManifest.icon 同步）。文件缺失/无 icon 处理均判失败。
    func test_scenario6_P3_cliMirror_declaresIconHandling() throws {
        let path = cliMainPath
        XCTAssertTrue(FileManager.default.fileExists(atPath: path),
            "场景6.P3: CLI 源文件必须存在：\(path)")
        let source = try String(contentsOfFile: path, encoding: .utf8)

        let lines = source.components(separatedBy: "\n")
        // 找到 CLIPluginManifestCheck 声明行，在其后 60 行窗口内断言 icon mirror
        var window: String?
        for (idx, line) in lines.enumerated() where line.contains("CLIPluginManifestCheck") {
            let start = idx
            let end = min(lines.count - 1, idx + 60)
            window = lines[start...end].joined(separator: "\n")
            break
        }

        let region = try XCTUnwrap(window,
            "场景6.P3: Sources/BuddyCLI/main.swift 必须声明 CLIPluginManifestCheck（D7 CLI mirror 锚点）")
        XCTAssertTrue(region.contains("icon"),
            "场景6.P3: CLIPluginManifestCheck mirror 必须含 icon 字段处理（与 BuddyCore 双绑一致），实际区域：\n\(region.prefix(800))")
    }

    // MARK: - 场景6.P1 [det-machine]：无 icon → manifest.icon==nil 且行 iconEmoji==nil

    /// 场景6.P1：无 icon 插件 → manifest.icon==nil；updateQuery 产出的插件行 iconEmoji==nil
    /// （渲染层落到统一 SF Symbol fallback——fallback 视觉本体为 VISUAL_RESIDUE 留 QA 真机）。
    func test_scenario6_P1_noIcon_rowIconEmojiNil() async throws {
        let manifest = try decodeManifest(manifestJSON(name: "qr", icon: nil))
        LauncherManager.shared.registryOverride = BuiltinPluginRegistry(plugins: [EmptyActionsPluginForIconTest()])
        LauncherManager.shared.instantDebounceMsOverride = 0
        LauncherManager.shared.pluginsOverride = [manifest]

        LauncherManager.shared.updateQuery("qr")
        var lastCount = -1
        var stablePolls = 0
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline && stablePolls < 4 {
            let count = LauncherManager.shared.instantActions.count
            if count == lastCount { stablePolls += 1 } else { stablePolls = 0; lastCount = count }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        let row = try XCTUnwrap(
            LauncherManager.shared.instantActions.first { $0.pluginId == "qr" },
            "场景6.P1 前置: 必须产出 qr 插件行"
        )
        XCTAssertNil(manifest.icon, "场景6.P1: 无 icon 字段 manifest.icon 必须为 nil")
        XCTAssertNil(row.iconEmoji,
            "场景6.P1: manifest.icon==nil 时插件行 iconEmoji 必须为 nil（fallback 统一 symbol）")
        // VISUAL_RESIDUE: fallback 统一 SF Symbol 的视觉呈现留 QA 真机判定（不在 headless 断言）

        LauncherManager.shared.pluginsOverride = nil
        LauncherManager.shared.registryOverride = nil
        LauncherManager.shared.clearInstantActions()
    }
}

// MARK: - Mock 空内置插件

private struct EmptyActionsPluginForIconTest: BuiltinPlugin {
    let id = "empty-icon-test"
    let priority = 0
    let sectionTitle = "Empty"
    func actions(for query: String) async -> [LauncherAction] { [] }
}
