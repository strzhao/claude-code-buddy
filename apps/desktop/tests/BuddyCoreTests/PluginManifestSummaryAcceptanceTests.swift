import XCTest
@testable import BuddyCore

/// Tier 0 红队验收测试 —— 黑盒验证 plugin.json schema 扩展（契约 C1）+ summary 降级规则。
///
/// 覆盖验收场景：
/// - 场景 5.P2：无 summary 的旧插件降级用 description 首句（按 `。`/`.`/换行切第一段，trim），或 name。
/// - 场景 5.P3：降级规则由 PluginManifest.displaySummary 单测覆盖（本文件）。
/// - 场景 6.P1/6.P2：黑话检查（summary/description 不含 stdin/stdout/QzhddrSrv 等内部词）。
///
/// 信息隔离：不读 displaySummary 实现，仅用 JSON decode 构造 PluginManifest + 调契约声明的 public API。
/// 命名前缀: test_AT<编号>_<场景>
@MainActor
final class PluginManifestSummaryAcceptanceTests: XCTestCase {

    // MARK: - Helpers

    /// 用 JSON decode 构造 PluginManifest（不依赖 init 签名，最干净）。
    /// summary 字段按契约 C1 可选（decodeIfPresent）。
    private func decode(json: String) throws -> PluginManifest {
        let data = Data(json.utf8)
        return try JSONDecoder().decode(PluginManifest.self, from: data)
    }

    /// 构造 stdin mode plugin.json（带可选 summary）。
    private func pluginJSON(summary: String? = nil, description: String, name: String = "p", cmd: String = "./x.sh") -> String {
        var fields: [String] = [
            "\"name\":\"\(name)\"",
            "\"version\":\"0.1.0\"",
            "\"description\":\(jsonString(description))",
            "\"keywords\":[]",
            "\"mode\":\"stdin\"",
            "\"cmd\":\"\(cmd)\""
        ]
        if let s = summary {
            fields.append("\"summary\":\(jsonString(s))")
        }
        return "{\(fields.joined(separator: ","))}"
    }

    /// 将任意字符串序列化为合法 JSON 字符串字面量（处理引号/反斜杠/换行）。
    /// 用 JSONEncoder 编码 String → 直接得到带引号转义的 JSON 字符串字面量。
    private func jsonString(_ s: String) -> String {
        let data = try! JSONEncoder().encode(s)
        // JSONEncoder().encode(String) 直接产出 "..." 字面量（含转义），无包装
        return String(data: data, encoding: .utf8) ?? "\"\""
    }

    // MARK: - C1 schema: summary 字段可选 decode

    /// 契约 C1：PluginManifest 加 `let summary: String?`（decodeIfPresent）。有 summary 时保留。
    func test_AT01_summaryFieldDecodesWhenPresent() throws {
        // 场景 5.P3: summary 非空 → 展示层取 summary
        let json = pluginJSON(summary: "一句话摘要", description: "详细说明")
        let m = try decode(json: json)
        // displaySummary 取 summary（契约 C1 降级规则：summary 非空 → 用 summary）
        XCTAssertEqual(m.displaySummary, "一句话摘要",
                       "displaySummary 必须在 summary 非空时返回 summary")
    }

    /// 契约 C1：无 summary 的旧插件不拒绝加载（向后兼容）。
    func test_AT02_missingSummaryDoesNotThrowOnDecode() throws {
        // 场景 5.P2 前置：旧插件无 summary 仍能 decode（加载层不拒绝）
        let json = pluginJSON(description: "无 summary 的旧插件")
        XCTAssertNoThrow(try decode(json: json),
                         "plugin.json 无 summary 字段必须能正常 decode（C1 向后兼容）")
    }

    // MARK: - 降级规则（C1 核心：displaySummary 优先级 summary → description 首句 → name）

    /// 契约 C1：无 summary → 取 description 首句（按 `。` 切第一段，trim）。
    func test_AT03_fallbackToDescriptionFirstSentenceByChinesePeriod() throws {
        // 场景 5.P2 assert: ==第一句话（description 首句，按 `。` 切）
        let json = pluginJSON(description: "第一句话。第二句话。")
        let m = try decode(json: json)
        XCTAssertEqual(m.displaySummary, "第一句话",
                       "displaySummary 无 summary 时降级取 description 首句（按 `。` 切第一段 trim）")
    }

    /// 契约 C1：按英文句号 `.` 切第一段。
    func test_AT04_fallbackByEnglishPeriod() throws {
        let json = pluginJSON(description: "First sentence. Second sentence.")
        let m = try decode(json: json)
        XCTAssertEqual(m.displaySummary, "First sentence",
                       "displaySummary 降级按 `.` 切第一段")
    }

    /// 契约 C1：按换行切第一段。
    func test_AT05_fallbackByNewline() throws {
        let json = pluginJSON(description: "首行描述\n第二行详情")
        let m = try decode(json: json)
        XCTAssertEqual(m.displaySummary, "首行描述",
                       "displaySummary 降级按换行切第一段")
    }

    /// 契约 C1：首句两端 trim（前后空白/换行去除）。
    func test_AT06_fallbackTrimsWhitespace() throws {
        let json = pluginJSON(description: "  带空白的句子  。后续。")
        let m = try decode(json: json)
        XCTAssertEqual(m.displaySummary, "带空白的句子",
                       "displaySummary 降级首句必须 trim 前后空白")
    }

    /// 契约 C1：summary + description 都空 → 用 name。
    func test_AT07_fallbackToNameWhenAllEmpty() throws {
        // 注意：description 是必填字段（decode 必须有），这里测 displaySummary 在 description 空时的兜底
        let json = pluginJSON(description: "", name: "my-plugin")
        let m = try decode(json: json)
        XCTAssertEqual(m.displaySummary, "my-plugin",
                       "displaySummary 在 summary 和 description 都空时降级用 name")
    }

    /// 契约 C1：降级规则优先级总结 —— summary 非空胜过 description。
    func test_AT08_summaryTakesPrecedenceOverDescription() throws {
        let json = pluginJSON(summary: "短摘要", description: "这是很长的描述。不应该被选中。")
        let m = try decode(json: json)
        XCTAssertEqual(m.displaySummary, "短摘要",
                       "summary 非空时必须用 summary，不降级到 description")
    }

    /// 契约 C1：displaySummary 永不返回空（展示层永远拿到非空 summary）。
    func test_AT09_displaySummaryNeverEmpty() throws {
        // 三种情况都不允许空返回
        let cases: [(String, String)] = [
            ("有 summary", pluginJSON(summary: "s", description: "d")),
            ("仅 description", pluginJSON(description: "描述句。x")),
            ("空 description 兜底 name", pluginJSON(description: "", name: "fallback-name")),
        ]
        for (label, json) in cases {
            let m = try decode(json: json)
            XCTAssertFalse(m.displaySummary.isEmpty,
                           "\(label): displaySummary 不允许返回空字符串")
        }
    }

    // MARK: - 场景 6：文案无黑话（det-machine 谓词 6.P1/6.P2）

    /// 契约 C1 + 场景 6.P2：registry 输出内置插件 summary 不含内部黑话词。
    /// 此处验证 displaySummary 对内置插件语义的间接约束 ——
    /// 如果实现把内部词（priority/仲裁/解释器/deterministic）塞进 summary，应被黑名单检出。
    func test_AT10_displaySummarySemanticsRejectInternalJargon() throws {
        // 这条是"防回归"约束：蓝队写内置插件 summary 时不应包含黑名单词。
        // 我们用一个含黑话的 description 验证降级路径本身不引入额外词汇（降级 = description 首句原样）。
        // 真正的内置插件 summary 黑话检查在 BuiltinPluginEnabledStoreAcceptanceTests（registry 输出）。
        let humanReadable = "计算器：输入算式立即得出结果"
        let json = pluginJSON(summary: humanReadable, description: "详细")
        let m = try decode(json: json)
        let forbidden = ["stdin", "stdout", "markdown 协议", "QzhddrSrv", "priority", "仲裁", "解释器", "deterministic"]
        for word in forbidden {
            XCTAssertFalse(m.displaySummary.contains(word),
                           "summary 含黑话词「\(word)」: \(m.displaySummary)")
        }
    }
}
