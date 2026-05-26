import XCTest
@testable import BuddyCore

final class AnyCodableTests: XCTestCase {

    // MARK: - 基本类型解码顺序（Bool 优先于 Int）

    func test_decode_bool_true() throws {
        let data = Data(#"true"#.utf8)
        let val = try JSONDecoder().decode(AnyCodable.self, from: data)
        XCTAssertTrue(val.value is Bool, "true 应解码为 Bool，而非 Int")
        XCTAssertEqual(val.value as? Bool, true)
    }

    func test_decode_bool_false() throws {
        let data = Data(#"false"#.utf8)
        let val = try JSONDecoder().decode(AnyCodable.self, from: data)
        XCTAssertTrue(val.value is Bool, "false 应解码为 Bool，而非 Int")
        XCTAssertEqual(val.value as? Bool, false)
    }

    func test_decode_int() throws {
        let data = Data(#"42"#.utf8)
        let val = try JSONDecoder().decode(AnyCodable.self, from: data)
        XCTAssertEqual(val.value as? Int, 42)
    }

    func test_decode_double() throws {
        let data = Data(#"3.14"#.utf8)
        let val = try JSONDecoder().decode(AnyCodable.self, from: data)
        let doubleVal = val.value as? Double ?? 0.0
        XCTAssertEqual(doubleVal, 3.14, accuracy: 0.001)
    }

    func test_decode_string() throws {
        let data = Data(#""hello""#.utf8)
        let val = try JSONDecoder().decode(AnyCodable.self, from: data)
        XCTAssertEqual(val.value as? String, "hello")
    }

    func test_decode_null() throws {
        let data = Data(#"null"#.utf8)
        let val = try JSONDecoder().decode(AnyCodable.self, from: data)
        XCTAssertTrue(val.value is NSNull)
    }

    // MARK: - 复合结构

    func test_decode_array() throws {
        let data = Data(#"[1, "two", true]"#.utf8)
        let val = try JSONDecoder().decode(AnyCodable.self, from: data)
        XCTAssertTrue(val.value is [Any])
    }

    func test_decode_dict() throws {
        let data = Data(#"{"a": 1, "b": "hello"}"#.utf8)
        let val = try JSONDecoder().decode(AnyCodable.self, from: data)
        XCTAssertTrue(val.value is [String: Any])
    }

    func test_decode_nested() throws {
        let json = #"{"count": 5, "enabled": true, "name": "test", "ratio": 1.5}"#
        let data = Data(json.utf8)
        let val = try JSONDecoder().decode([String: AnyCodable].self, from: data)
        XCTAssertEqual(val["count"]?.value as? Int, 5)
        XCTAssertEqual(val["enabled"]?.value as? Bool, true)
        XCTAssertEqual(val["name"]?.value as? String, "test")
        let ratio = val["ratio"]?.value as? Double ?? 0.0
        XCTAssertEqual(ratio, 1.5, accuracy: 0.001)
    }

    // MARK: - Codable Round-trip

    func test_roundTrip_primitives() throws {
        let original: [String: AnyCodable] = [
            "a": AnyCodable(1),
            "b": AnyCodable(1.5),
            "c": AnyCodable("hello"),
            "d": AnyCodable(true)
        ]
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode([String: AnyCodable].self, from: encoded)
        XCTAssertEqual(decoded["a"], original["a"])
        XCTAssertEqual(decoded["c"], original["c"])
        XCTAssertEqual(decoded["d"], original["d"])
    }

    // MARK: - Equatable

    func test_equality_sameValues() throws {
        let a = AnyCodable(42)
        let b = AnyCodable(42)
        XCTAssertEqual(a, b)
    }

    func test_equality_differentValues() throws {
        let a = AnyCodable(42)
        let b = AnyCodable(43)
        XCTAssertNotEqual(a, b)
    }

    func test_equality_differentTypes() throws {
        let a = AnyCodable(1)       // Int
        let b = AnyCodable(true)    // Bool
        XCTAssertNotEqual(a, b)
    }
}
