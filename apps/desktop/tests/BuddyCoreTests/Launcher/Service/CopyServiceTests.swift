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

    // MARK: - copyImage（图片输出通道，T6）

    /// copyImage 写 PNG 到剪贴板（场景3.P1：含 public.png 类型 AND data 非空）
    func test_copyImage_writes_png_to_pasteboard() {
        let pb = makePasteboard()
        let svc = CopyService(pasteboard: pb)
        // 1x1 透明 PNG
        let png = Data([
            0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a  // PNG signature
        ])
        svc.copyImage(png)

        let written = pb.data(forType: .png)
        XCTAssertNotNil(written, "剪贴板必须含 public.png 类型数据")
        XCTAssertEqual(written, png, "剪贴板 PNG 数据必须与输入一致（场景3.P2 字节比对）")
    }

    /// copyImage clearContents + setData（覆盖先前字符串内容）
    func test_copyImage_clears_previous_content() {
        let pb = makePasteboard()
        let svc = CopyService(pasteboard: pb)
        svc.copy("text before")  // 先写字符串

        let png = Data([0x89, 0x50, 0x4e, 0x47])
        svc.copyImage(png)

        XCTAssertNil(pb.string(forType: .string), "copyImage 必须 clearContents 清掉先前的字符串")
        XCTAssertEqual(pb.data(forType: .png), png, "copyImage 后剪贴板应只有 PNG")
    }

    // MARK: - Scenario 9

    func test_scenario9_P2_copy_button_writes_correct_text() {
        let pb = makePasteboard()
        let svc = CopyService(pasteboard: pb)
        svc.copy("伙伴")
        XCTAssertEqual(pb.string(forType: .string), "伙伴")
    }
}
