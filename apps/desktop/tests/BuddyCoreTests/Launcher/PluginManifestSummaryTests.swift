import XCTest
@testable import BuddyCore

/// 蓝队单元测试 — C1 PluginManifest.displaySummary 降级规则（场景 5.P3）
///
/// 降级优先级（SOURCE OF TRUTH: PluginManifest.displaySummary）：
/// 1. summary 非空（trim 后）→ summary
/// 2. 否则取 description 首句（按 。/换行/". "切第一段，trim；句末单独 "." 也算）
/// 3. 都空 → name
///
/// 与 CLI mirror cliDisplaySummary 同语义（C5 双绑，cliFirstSentence 与 firstSentence 逐字一致）。
final class PluginManifestSummaryTests: XCTestCase {

    // MARK: - 优先级 1：summary 非空 → 用 summary

    func test_displaySummary_usesSummaryWhenPresent() throws {
        let manifest = makeManifest(name: "p", description: "详细说明。", summary: "一句话摘要")
        XCTAssertEqual(manifest.displaySummary, "一句话摘要")
    }

    func test_displaySummary_trimsWhitespaceInSummary() throws {
        let manifest = makeManifest(name: "p", description: "详细", summary: "  带空格的摘要  ")
        XCTAssertEqual(manifest.displaySummary, "带空格的摘要")
    }

    func test_displaySummary_emptySummaryFallsBackToDescription() throws {
        // summary 是空串（trim 后空）→ 降级到 description 首句
        let manifest = makeManifest(name: "p", description: "第一句话。第二句话。", summary: "")
        XCTAssertEqual(manifest.displaySummary, "第一句话")
    }

    func test_displaySummary_whitespaceOnlySummaryFallsBack() throws {
        let manifest = makeManifest(name: "p", description: "首句。", summary: "   ")
        XCTAssertEqual(manifest.displaySummary, "首句")
    }

    // MARK: - 优先级 2：description 首句降级

    func test_displaySummary_descriptionFirstSentence_chinesePeriod() throws {
        let manifest = makeManifest(name: "p", description: "第一句话。第二句话。", summary: nil)
        XCTAssertEqual(manifest.displaySummary, "第一句话")
    }

    func test_displaySummary_descriptionFirstSentence_newline() throws {
        let manifest = makeManifest(name: "p", description: "第一行\n第二行", summary: nil)
        XCTAssertEqual(manifest.displaySummary, "第一行")
    }

    func test_displaySummary_descriptionFirstSentence_englishPeriodWithSpace() throws {
        let manifest = makeManifest(name: "p", description: "First sentence. Second.", summary: nil)
        XCTAssertEqual(manifest.displaySummary, "First sentence")
    }

    func test_displaySummary_descriptionFirstSentence_trailingPeriod() throws {
        // 句末单独 "." 也算句末（无其他分隔符）
        let manifest = makeManifest(name: "p", description: "只有一句.", summary: nil)
        XCTAssertEqual(manifest.displaySummary, "只有一句")
    }

    func test_displaySummary_descriptionNoSentenceEnd_returnsWholeTrimmed() throws {
        // 无任何句末分隔符 → 返回整个 trim 后的 description
        let manifest = makeManifest(name: "p", description: "没有句号的一整段", summary: nil)
        XCTAssertEqual(manifest.displaySummary, "没有句号的一整段")
    }

    func test_displaySummary_description_trimsLeadingTrailingWhitespace() throws {
        let manifest = makeManifest(name: "p", description: "  首句。  ", summary: nil)
        XCTAssertEqual(manifest.displaySummary, "首句")
    }

    // MARK: - 优先级 3：都空 → name

    func test_displaySummary_bothEmpty_fallsBackToName() throws {
        let manifest = makeManifest(name: "my-plugin", description: "", summary: nil)
        XCTAssertEqual(manifest.displaySummary, "my-plugin")
    }

    func test_displaySummary_bothWhitespace_fallsBackToName() throws {
        let manifest = makeManifest(name: "plug", description: "   ", summary: "  ")
        XCTAssertEqual(manifest.displaySummary, "plug")
    }

    // MARK: - 边界：场景 5.P2 造的 legacy 插件

    func test_displaySummary_legacyPlugin_descriptionFirstSentence() throws {
        // 场景 5.P2：legacy 插件无 summary，description = "第一句话。第二句话。"
        let manifest = makeManifest(name: "legacy", description: "第一句话。第二句话。", summary: nil)
        XCTAssertEqual(manifest.displaySummary, "第一句话")
    }

    // MARK: - Codable：summary 可选 decode（向后兼容）

    func test_decode_oldPluginJsonWithoutSummary_decodesNilSummary() throws {
        // 旧 plugin.json 无 summary 字段 → decode 成功，summary == nil，displaySummary 降级
        let json = """
        {"name":"old","version":"0.1.0","description":"旧插件说明","keywords":[],"mode":"stdin","cmd":"./x"}
        """.data(using: .utf8)!
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: json)
        XCTAssertNil(manifest.summary)
        XCTAssertEqual(manifest.displaySummary, "旧插件说明")
    }

    func test_decode_newPluginJsonWithSummary_decodesSummary() throws {
        let json = """
        {"name":"new","version":"0.1.0","summary":"新摘要","description":"详细","keywords":[],"mode":"stdin","cmd":"./x"}
        """.data(using: .utf8)!
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: json)
        XCTAssertEqual(manifest.summary, "新摘要")
        XCTAssertEqual(manifest.displaySummary, "新摘要")
    }

    func test_encode_includesSummaryWhenPresent() throws {
        let manifest = makeManifest(name: "p", description: "d", summary: "s")
        let data = try JSONEncoder().encode(manifest)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["summary"] as? String, "s")
    }

    func test_encode_omitsSummaryWhenNil() throws {
        let manifest = makeManifest(name: "p", description: "d", summary: nil)
        let data = try JSONEncoder().encode(manifest)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNil(obj?["summary"])
    }

    // MARK: - 官方插件文案回归（场景 6：无黑话）

    func test_displaySummary_noJargon_forHelloQrQzhStyle() throws {
        // 验证降级产物不含黑话词（summary 非空时直接用，不会触降级）
        let hello = makeManifest(name: "hello", description: "详细", summary: "问候示例：输入任意内容回显一句问候")
        XCTAssertFalse(hello.displaySummary.lowercased().contains("stdin"))
        XCTAssertFalse(hello.displaySummary.lowercased().contains("stdout"))
    }

    // MARK: - Helper

    private func makeManifest(name: String, description: String, summary: String?) -> PluginManifest {
        PluginManifest(
            name: name,
            version: "0.1.0",
            description: description,
            keywords: [],
            cmd: "./x",
            summary: summary
        )
    }
}
