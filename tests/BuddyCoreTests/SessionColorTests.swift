import XCTest
@testable import BuddyCore

final class SessionColorTests: XCTestCase {

    func testAllCasesCount() {
        XCTAssertEqual(SessionColor.allCases.count, 8)
    }

    func testHexFormat() {
        for color in SessionColor.allCases {
            let hex = color.hex
            XCTAssertTrue(hex.hasPrefix("#"), "\(color) hex should start with #")
            XCTAssertEqual(hex.count, 7, "\(color) hex should be 7 chars (#RRGGBB)")
        }
    }

    func testNSColorNotNil() {
        for color in SessionColor.allCases {
            let nsColor = color.nsColor
            XCTAssertNotNil(nsColor, "\(color) should produce a valid NSColor")
        }
    }

    func testAnsi256InRange() {
        for color in SessionColor.allCases {
            let ansi = color.ansi256
            XCTAssertTrue((0...255).contains(ansi), "\(color) ANSI code \(ansi) should be 0-255")
        }
    }

    func testSpecificHexValues() {
        XCTAssertEqual(SessionColor.coral.hex, "#FF6B6B")
        XCTAssertEqual(SessionColor.teal.hex, "#4ECDC4")
        XCTAssertEqual(SessionColor.gold.hex, "#FFD93D")
        XCTAssertEqual(SessionColor.violet.hex, "#6C5CE7")
    }

    func testRawValueRoundTrip() {
        for color in SessionColor.allCases {
            let raw = color.rawValue
            XCTAssertEqual(SessionColor(rawValue: raw), color)
        }
    }
}
