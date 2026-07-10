import XCTest
@testable import BuddyCore

final class ContentColumnViewTests: XCTestCase {
    func test_init_hasScrollViewAndContentColumn() {
        let cv = ContentColumnView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        cv.layoutSubtreeIfNeeded()
        XCTAssertNotNil(cv.scrollView)
        XCTAssertNotNil(cv.contentColumn)
    }

    func test_contentColumn_widthCappedToMaxWidth_whenViewportWide() {
        let cv = ContentColumnView(frame: NSRect(x: 0, y: 0, width: 1200, height: 600))
        cv.layoutSubtreeIfNeeded()
        // 视口 1200 > 780+padding，contentColumn 应被限到 780
        XCTAssertLessThanOrEqual(cv.contentColumn.bounds.width, SettingsTheme.contentMaxWidth + 1)
    }

    func test_maxWidth_seamAdjustsCap() {
        let cv = ContentColumnView(frame: NSRect(x: 0, y: 0, width: 1200, height: 600))
        cv.maxWidth = 500
        cv.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(cv.contentColumn.bounds.width, 500 + 1)
    }

    func test_addContent_toContentColumn() {
        let cv = ContentColumnView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        let label = NSTextField(labelWithString: "hi")
        label.translatesAutoresizingMaskIntoConstraints = false
        cv.contentColumn.addSubview(label)
        cv.layoutSubtreeIfNeeded()
        XCTAssertTrue(label.superview === cv.contentColumn)
    }

    func test_documentView_fillsViewportHeight_noBottomAlign() {
        // patterns/2026-07-03：documentView height ≥ contentView height，防内容少时贴底空顶
        let cv = ContentColumnView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        cv.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(
            cv.scrollView.documentView!.bounds.height,
            cv.scrollView.contentView.bounds.height
        )
    }
}
