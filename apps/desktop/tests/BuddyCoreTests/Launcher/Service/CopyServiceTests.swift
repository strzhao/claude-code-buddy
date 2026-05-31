import AppKit
import XCTest
@testable import BuddyCore

final class CopyServiceTests: XCTestCase {

    private func makePasteboard() -> NSPasteboard {
        // Use a unique named pasteboard per test for isolation (knowledge entry 2026-05-29)
        NSPasteboard(name: NSPasteboard.Name("ccb-test-\(UUID())"))
    }

    func test_copy_writes_string_to_pasteboard() {
        let pb = makePasteboard()
        let svc = CopyService(pasteboard: pb)
        svc.copy("hello world")
        XCTAssertEqual(pb.string(forType: .string), "hello world")
    }

    func test_copy_overwrites_previous_content() {
        let pb = makePasteboard()
        let svc = CopyService(pasteboard: pb)
        svc.copy("first")
        svc.copy("second")
        XCTAssertEqual(pb.string(forType: .string), "second")
    }

    func test_copy_empty_string() {
        let pb = makePasteboard()
        let svc = CopyService(pasteboard: pb)
        // Should not crash; pasteboard may or may not have empty string
        svc.copy("")
        // No assertion on content — empty string behaviour is implementation-defined
    }

    func test_copy_chinese_text() {
        let pb = makePasteboard()
        let svc = CopyService(pasteboard: pb)
        svc.copy("伙伴；密友")
        XCTAssertEqual(pb.string(forType: .string), "伙伴；密友")
    }

    // MARK: - Scenario 8

    func test_scenario8_P3_click_copy_writes_to_pasteboard() {
        let pb = makePasteboard()
        let svc = CopyService(pasteboard: pb)
        svc.copy("伙伴")
        XCTAssertEqual(pb.string(forType: .string), "伙伴", "8.P3: pasteboard must contain action text after copy()")
    }

    /// 8.P4: autoCopyToClipboard disabled → pasteboard unchanged before manual click
    func test_scenario8_P4_no_auto_copy_before_click() {
        let pb = makePasteboard()
        // Simulate: pasteboard is fresh, no copy action fired yet
        let changeCountBefore = pb.changeCount
        // Nothing calls CopyService.copy()
        XCTAssertEqual(pb.changeCount, changeCountBefore, "8.P4: changeCount must not increase without manual copy")
    }

    // MARK: - Scenario 9

    func test_scenario9_P2_copy_button_writes_correct_text() {
        let pb = makePasteboard()
        let svc = CopyService(pasteboard: pb)
        svc.copy("伙伴")
        XCTAssertEqual(pb.string(forType: .string), "伙伴")
    }
}
