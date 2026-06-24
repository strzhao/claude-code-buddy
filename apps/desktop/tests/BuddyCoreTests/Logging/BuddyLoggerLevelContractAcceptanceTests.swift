import XCTest
@testable import BuddyCore

// MARK: - BuddyLoggerLevelContractAcceptanceTests
//
// 黑盒验收测试 —— 仅依据契约 C1/C2/C3（LogLevel 枚举 / Comparable / 级别序）编写。
// 专注 LogLevel 类型契约与级别过滤语义（覆盖场景 2/5 的级别相关谓词前置）。
//
// 契约引用：
//  - C3: `enum LogLevel: String, Codable, Comparable { case debug, info, warn, error }`
//        Comparable 按 C1 级别序 debug(0) < info(1) < warn(2) < error(3)
//  - C1: 级别序 debug(0) < info(1) < warn(2) < error(3)
//  - C2: BUDDY_LOG_LEVEL 取值 debug|info|warn|error|off
//
// 本文件不验证文件 IO（已在 BuddyLoggerAcceptanceTests 覆盖），专注 LogLevel 类型 + Comparable 语义。

final class BuddyLoggerLevelContractAcceptanceTests: XCTestCase {

    // MARK: - C3: LogLevel rawValue 逐字一致

    /// covers C3 / C5 镜像: LogLevel 四个 case 的 rawValue 必须逐字为 debug/info/warn/error。
    /// 契约 C5: CLI 侧级别字符串集合 {debug,info,warn,error} 须与 BuddyCore LogLevel.rawValue 完全一致。
    func test_LogLevelRawValuesAreLiteralContract() {
        XCTAssertEqual(LogLevel.debug.rawValue, "debug", "C3/C5: rawValue 必须逐字 'debug'")
        XCTAssertEqual(LogLevel.info.rawValue, "info", "C3/C5: rawValue 必须逐字 'info'")
        XCTAssertEqual(LogLevel.warn.rawValue, "warn", "C3/C5: rawValue 必须逐字 'warn'")
        XCTAssertEqual(LogLevel.error.rawValue, "error", "C3/C5: rawValue 必须逐字 'error'")
    }

    /// covers C3: LogLevel 从 String 初始化（Codable round-trip）。
    func test_LogLevelInitFromRawValueRoundTrip() {
        for raw in ["debug", "info", "warn", "error"] {
            guard let level = LogLevel(rawValue: raw) else {
                XCTFail("C3: LogLevel(rawValue: \"\(raw)\") 必须成功")
                continue
            }
            XCTAssertEqual(level.rawValue, raw, "C3: round-trip 一致")
        }
    }

    /// covers C3: 非法 rawValue 不应构造出 LogLevel（闭合枚举）。
    func test_LogLevelRejectsInvalidRawValue() {
        XCTAssertNil(LogLevel(rawValue: "DEBUG"), "C3: 大写不应被接受（契约为小写 debug）")
        XCTAssertNil(LogLevel(rawValue: "trace"), "C3: trace 不在闭集 {debug,info,warn,error}")
        XCTAssertNil(LogLevel(rawValue: "fatal"), "C3: fatal 不在闭集")
        XCTAssertNil(LogLevel(rawValue: ""), "C3: 空串非法")
    }

    // MARK: - C1: Comparable 级别序

    /// covers C1: 级别序 debug(0) < info(1) < warn(2) < error(3)。
    /// 全序关系：用 < 比较 4 个 case 的所有相邻对。
    func test_LogLevelOrderingDebugInfoWarnError() {
        XCTAssertLessThan(LogLevel.debug, LogLevel.info, "C1: debug < info")
        XCTAssertLessThan(LogLevel.info, LogLevel.warn, "C1: info < warn")
        XCTAssertLessThan(LogLevel.warn, LogLevel.error, "C1: warn < error")
        // 传递性（全序）。
        XCTAssertLessThan(LogLevel.debug, LogLevel.error, "C1: debug < error (传递)")
        XCTAssertLessThan(LogLevel.debug, LogLevel.warn, "C1: debug < warn (传递)")
        XCTAssertLessThan(LogLevel.info, LogLevel.error, "C1: info < error (传递)")
    }

    /// covers C1: Comparable 反身性 / 等价关系（== 自反，<= 自反）。
    func test_LogLevelEqualityIsReflexive() {
        for level in [LogLevel.debug, .info, .warn, .error] {
            XCTAssertEqual(level, level, "C1: == 自反")
            XCTAssertLessThanOrEqual(level, level, "C1: <= 自反")
            XCTAssertGreaterThanOrEqual(level, level, "C1: >= 自反")
        }
    }

    /// covers C1: Comparable 反对称（a<b ⟹ !(b<a)）。
    func test_LogLevelAntisymmetry() {
        XCTAssertTrue(LogLevel.debug < LogLevel.error, "debug < error")
        XCTAssertFalse(LogLevel.error < LogLevel.debug, "C1: 反对称 error 不 < debug")
    }

    // MARK: - C3: LogLevel Codable

    /// covers C3: LogLevel Codable —— JSON 编码后是小写 rawValue 字符串。
    func test_LogLevelCodableEncodesAsRawValueString() throws {
        let encoder = JSONEncoder()
        for level in [LogLevel.debug, .info, .warn, .error] {
            let data = try encoder.encode(level)
            let decoded = String(data: data, encoding: .utf8) ?? ""
            // JSON 编码字符串会带引号。
            XCTAssertEqual(decoded, "\"\(level.rawValue)\"",
                           "C3: Codable 编码后应为 \"\(level.rawValue)\"")
        }
    }

    /// covers C3: LogLevel Codable 解码（从 JSON 字符串）。
    func test_LogLevelCodableDecodesFromRawValueString() throws {
        let decoder = JSONDecoder()
        for raw in ["\"debug\"", "\"info\"", "\"warn\"", "\"error\""] {
            let data = Data(raw.utf8)
            let level = try decoder.decode(LogLevel.self, from: data)
            XCTAssertEqual(level.rawValue, raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"")),
                           "C3: Codable 解码一致")
        }
    }

    // MARK: - 场景 5 级别过滤语义前置（级别集合）

    /// covers 5.P1 辅助 / 3.P2 语义: 级别集合 {debug,info,warn,error} 的全序覆盖。
    /// 这保证 `--level warn` 过滤逻辑（warn 及以上 = warn ∪ error）在类型层有依据。
    func test_LevelSetCoversAllComparableCases() {
        let all: [LogLevel] = [.debug, .info, .warn, .error]
        // 排序后应严格递增。
        let sorted = all.sorted()
        XCTAssertEqual(sorted, [.debug, .info, .warn, .error],
                       "C1: sorted([debug,info,warn,error]) 必须为 [debug,info,warn,error]")
        // 互异。
        XCTAssertEqual(Set(all.map { $0.rawValue }).count, 4, "C1: 四个 case 互异")
    }
}
