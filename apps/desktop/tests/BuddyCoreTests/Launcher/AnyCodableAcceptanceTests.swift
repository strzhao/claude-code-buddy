import XCTest
import Security
import CryptoKit
@testable import BuddyCore

// MARK: - AnyCodableAcceptanceTests
//
// 验收测试：AnyCodable 解码顺序契约
//
// 设计文档覆盖点（task 002 AnyCodable.swift 草图）：
//   A. JSON `true` 解码后 value is Bool == true（不被解为 Int 1）
//   B. JSON `42` 解码后 value is Int == true（不是 Bool）
//   C. JSON `1.5` 解码后 value is Double == true
//   D. JSON `"hi"` 解码后 value is String == true
//   E. JSON `[1, "two"]` 解码后是 [Any] 含 Int(1) 和 String("two")
//   F. JSON `{"k":"v"}` 解码后是 [String: Any] 含 k:v
//   G. AnyCodable == Equatable 语义（JSON 字符串比较）
//   H. encode(true) 不产生 1（Bool 优先于 Int）
//   I. null 解码后 value is NSNull
//   J. 嵌套结构（array of dict）round-trip 正确
//
// 黑盒原则：仅通过 AnyCodable.init(from:) 和 encode(to:) 公开接口测试。
// 解码顺序是防止 mutation 的关键：Bool 必须在 Int 之前尝试。
// 测试 WILL NOT compile 直到蓝队合并实现 — 这是预期的 TDD 红灯。

final class AnyCodableAcceptanceTests: XCTestCase {

    // MARK: - Helper

    private func decode<T>(_ jsonString: String, as: T.Type = AnyCodable.self) throws -> AnyCodable {
        let data = jsonString.data(using: .utf8)!
        return try JSONDecoder().decode(AnyCodable.self, from: data)
    }

    private func decodeArray(_ jsonString: String) throws -> [AnyCodable] {
        let data = jsonString.data(using: .utf8)!
        return try JSONDecoder().decode([AnyCodable].self, from: data)
    }

    private func decodeDict(_ jsonString: String) throws -> [String: AnyCodable] {
        let data = jsonString.data(using: .utf8)!
        return try JSONDecoder().decode([String: AnyCodable].self, from: data)
    }

    // MARK: - A. Bool 解码优先于 Int

    /// JSON `true` 必须解码为 Bool（不是 Int 1）
    /// 设计文档解码顺序：Bool → Int → Double → String
    func test_decode_boolTrue_isBoolNotInt() throws {
        let result = try decode("true")
        XCTAssertTrue(result.value is Bool,
                      "JSON true 必须解码为 Bool，不是 Int（Bool 在 Int 之前解码）")
        XCTAssertEqual(result.value as? Bool, true,
                       "Bool 值必须是 true")
    }

    func test_decode_boolFalse_isBoolNotInt() throws {
        let result = try decode("false")
        XCTAssertTrue(result.value is Bool,
                      "JSON false 必须解码为 Bool，不是 Int 0")
        XCTAssertEqual(result.value as? Bool, false,
                       "Bool 值必须是 false")
    }

    // MARK: - B. Int 解码

    /// JSON `42` 必须解码为 Int（不是 Bool 或 Double）
    func test_decode_int42_isInt() throws {
        let result = try decode("42")
        XCTAssertTrue(result.value is Int,
                      "JSON 42 必须解码为 Int，不是 Double 或 Bool")
        XCTAssertEqual(result.value as? Int, 42,
                       "Int 值必须精确为 42")
    }

    func test_decode_intZero_isIntNotBool() throws {
        let result = try decode("0")
        XCTAssertTrue(result.value is Int,
                      "JSON 0 必须解码为 Int，不是 Bool false")
        XCTAssertEqual(result.value as? Int, 0,
                       "Int 值必须是 0")
    }

    func test_decode_intOne_isIntNotBool() throws {
        // 关键 mutation 探针：如果 Bool 在 Int 之后，1 会被解为 true
        let result = try decode("1")
        XCTAssertTrue(result.value is Int,
                      "JSON 1 必须解码为 Int，不是 Bool true（Bool 先于 Int decode，但 1 不是有效 Bool JSON literal）")
        // 注意：在 Swift JSONDecoder 中，1 在 singleValueContainer 里 decode(Bool.self) 会失败
        // 所以 1 应该落到 Int 分支
        XCTAssertEqual(result.value as? Int, 1,
                       "Int 值必须是 1")
    }

    // MARK: - C. Double 解码

    /// JSON `1.5` 必须解码为 Double
    func test_decode_double_isDouble() throws {
        let result = try decode("1.5")
        XCTAssertTrue(result.value is Double,
                      "JSON 1.5 必须解码为 Double")
        XCTAssertEqual(result.value as? Double, 1.5,
                       "Double 值必须精确为 1.5")
    }

    func test_decode_doubleNegative_isDouble() throws {
        let result = try decode("-3.14")
        XCTAssertTrue(result.value is Double,
                      "负浮点数必须解码为 Double")
        XCTAssertEqual(result.value as? Double ?? 0, -3.14, accuracy: 1e-10,
                       "Double 值必须精确为 -3.14")
    }

    // MARK: - D. String 解码

    /// JSON `"hi"` 必须解码为 String
    func test_decode_string_isString() throws {
        let result = try decode("\"hi\"")
        XCTAssertTrue(result.value is String,
                      "JSON \"hi\" 必须解码为 String")
        XCTAssertEqual(result.value as? String, "hi",
                       "String 值必须是 \"hi\"")
    }

    func test_decode_emptyString_isString() throws {
        let result = try decode("\"\"")
        XCTAssertTrue(result.value is String,
                      "空字符串必须解码为 String")
        XCTAssertEqual(result.value as? String, "",
                       "空字符串值必须是 \"\"")
    }

    // MARK: - E. 数组解码

    /// JSON `[1, "two"]` 解码后是 [Any] 含 Int(1) 和 String("two")
    func test_decode_array_containsIntAndString() throws {
        let result = try decode("[1, \"two\"]")
        let arr = result.value as? [Any]
        XCTAssertNotNil(arr, "JSON 数组必须解码为 [Any]")
        XCTAssertEqual(arr?.count, 2, "数组必须有 2 项")
        XCTAssertEqual(arr?[0] as? Int, 1,
                       "数组第一项必须是 Int(1)")
        XCTAssertEqual(arr?[1] as? String, "two",
                       "数组第二项必须是 String(\"two\")")
    }

    /// 混合类型数组：[true, 42, 1.5, "x", null]
    func test_decode_mixedArray_eachTypeCorrect() throws {
        let result = try decode("[true, 42, 1.5, \"x\"]")
        let arr = result.value as? [Any]
        XCTAssertNotNil(arr, "混合数组必须解码为 [Any]")
        XCTAssertEqual(arr?.count, 4, "数组必须有 4 项")
        XCTAssertTrue(arr?[0] is Bool, "arr[0] 必须是 Bool")
        XCTAssertEqual(arr?[0] as? Bool, true, "arr[0] 值必须是 true")
        XCTAssertTrue(arr?[1] is Int, "arr[1] 必须是 Int")
        XCTAssertEqual(arr?[1] as? Int, 42, "arr[1] 值必须是 42")
        XCTAssertTrue(arr?[2] is Double, "arr[2] 必须是 Double")
        XCTAssertTrue(arr?[3] is String, "arr[3] 必须是 String")
    }

    // MARK: - F. 字典解码

    /// JSON `{"k":"v"}` 解码后是 [String: Any] 含 k:v
    func test_decode_dict_containsStringValue() throws {
        let result = try decode("{\"k\":\"v\"}")
        let dict = result.value as? [String: Any]
        XCTAssertNotNil(dict, "JSON object 必须解码为 [String: Any]")
        XCTAssertEqual(dict?["k"] as? String, "v",
                       "dict[\"k\"] 必须是 String \"v\"")
    }

    /// 字典含数值类型
    func test_decode_dict_withIntValue() throws {
        let result = try decode("{\"count\":5, \"active\":true}")
        let dict = result.value as? [String: Any]
        XCTAssertNotNil(dict)
        XCTAssertEqual(dict?["count"] as? Int, 5,
                       "dict[\"count\"] 必须是 Int(5)")
        XCTAssertEqual(dict?["active"] as? Bool, true,
                       "dict[\"active\"] 必须是 Bool(true)")
    }

    // MARK: - G. AnyCodable Equatable 语义

    /// 相同值的 AnyCodable 应该 == 相等
    func test_equatable_sameStringValue_isEqual() throws {
        let a = AnyCodable("hello")
        let b = AnyCodable("hello")
        XCTAssertEqual(a, b, "相同 String 值的 AnyCodable 必须 == 相等")
    }

    /// 不同值的 AnyCodable 应该 != 不等
    func test_equatable_differentValues_notEqual() throws {
        let a = AnyCodable("hello")
        let b = AnyCodable("world")
        XCTAssertNotEqual(a, b, "不同值的 AnyCodable 必须 != 不等")
    }

    /// Bool true 与 Int 1 不应 == 相等（类型语义不同）
    func test_equatable_boolTrue_notEqualToInt1() throws {
        let a = AnyCodable(true)
        let b = AnyCodable(1)
        XCTAssertNotEqual(a, b,
                          "Bool(true) 与 Int(1) 的 AnyCodable 不应相等（类型不同）")
    }

    // MARK: - H. encode(true) 不产生 1

    /// AnyCodable(true) 编码后 JSON 是 `true`，不是数字 1
    func test_encode_boolTrue_producesLiteralTrue() throws {
        let val = AnyCodable(true)
        let data = try JSONEncoder().encode(val)
        let str = String(data: data, encoding: .utf8)!
        XCTAssertEqual(str, "true",
                       "Bool(true) 编码后必须是 JSON literal `true`，不是数字 1")
    }

    func test_encode_boolFalse_producesLiteralFalse() throws {
        let val = AnyCodable(false)
        let data = try JSONEncoder().encode(val)
        let str = String(data: data, encoding: .utf8)!
        XCTAssertEqual(str, "false",
                       "Bool(false) 编码后必须是 JSON literal `false`，不是数字 0")
    }

    // MARK: - I. null 解码

    /// JSON `null` 解码后 value is NSNull
    func test_decode_null_isNSNull() throws {
        let result = try decode("null")
        XCTAssertTrue(result.value is NSNull,
                      "JSON null 必须解码为 NSNull")
    }

    // MARK: - J. 嵌套结构 round-trip

    /// 嵌套字典 + 数组 round-trip：encode 后 decode 得到等价结构
    func test_nestedStructure_roundTrip() throws {
        let original: [String: AnyCodable] = [
            "name": AnyCodable("test"),
            "count": AnyCodable(3),
            "tags": AnyCodable(["a", "b"]),
            "meta": AnyCodable(["active": true])
        ]
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode([String: AnyCodable].self, from: data)

        XCTAssertEqual(decoded["name"]?.value as? String, "test",
                       "嵌套 round-trip：name 必须正确还原")
        XCTAssertEqual(decoded["count"]?.value as? Int, 3,
                       "嵌套 round-trip：count 必须正确还原为 Int")

        let tags = decoded["tags"]?.value as? [Any]
        XCTAssertEqual(tags?.count, 2, "嵌套 round-trip：tags 数组必须有 2 项")
        XCTAssertEqual(tags?[0] as? String, "a", "tags[0] 必须是 \"a\"")
    }

    /// AnyCodable 作为 AgentTool inputSchema 使用场景 round-trip
    func test_anyCodable_asInputSchema_roundTrip() throws {
        // Given: 典型 JSON Schema
        let schema: [String: AnyCodable] = [
            "type": AnyCodable("object"),
            "required": AnyCodable(["location"]),
            "properties": AnyCodable([
                "location": ["type": "string", "description": "City name"]
            ])
        ]
        let tool = AgentTool(name: "weather", description: "Get weather", inputSchema: schema)

        // When
        let data = try JSONEncoder().encode(tool)
        let decoded = try JSONDecoder().decode(AgentTool.self, from: data)

        // Then
        XCTAssertEqual(decoded.name, "weather")
        XCTAssertEqual(decoded.inputSchema["type"]?.value as? String, "object",
                       "inputSchema round-trip：type 必须还原为 \"object\"")
    }
}
