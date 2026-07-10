import XCTest
import AppKit
@testable import BuddyCore

// MARK: - 红队验收测试：ContentColumnView stage-1 内容容器（2026-07-10）
//
// 黑盒验收测试：基于设计文档承诺的 stage-1 ContentColumnView 外部可观测行为下断言。
//
// 本文件**不读取**蓝队 `Sources/ClaudeCodeBuddy/Settings/Components/ContentColumnView.swift` 实现，
// 也不读蓝队的 `ContentColumnViewTests.swift`，仅对设计文档承诺的「外部可观测结构 + 布局约束」下断言。
//
// 设计权威源（唯一真相）：
// - **容器层级**：ContentColumnView（NSView 子类）
//   → scrollView（NSScrollView，撑满四边，hasVerticalScroller，drawsBackground=false）
//   → documentView（NSView，宽度跟随 contentView 只竖滚 + height ≥ contentView.height 防贴底盲区）
//   → contentColumn（NSView，width ≤ maxWidth + centerX 居中）
// - **暴露属性**：
//   - `scrollView: NSScrollView`（let）
//   - `contentColumn: NSView`（private(set)）
//   - `maxWidth: CGFloat`（var，test seam，默认 780）
// - **AX**：透明容器不挂 id
//
// 验收维度：
// - D1（结构存在性）：scrollView / contentColumn 实例化后非 nil，且 scrollView 是 ContentColumnView 的子树。
// - D2（宽度上限）：视口宽于 maxWidth 时 contentColumn.bounds.width ≤ 780（默认 cap）。
// - D3（test seam 可调）：设 maxWidth=500 后 contentColumn.bounds.width ≤ 500（cap 跟随 test seam）。
// - D4（内容挂载）：addSubview 到 contentColumn 后子视图 superview === contentColumn（透明容器语义）。
// - D5（防贴底盲区）：documentView.bounds.height ≥ contentView.bounds.height
//   （patterns/2026-07-03：内容少时 documentView 不能塌缩到比可见区还小，否则底部出现无法滚到的盲区）。

@MainActor
final class ContentColumnViewAcceptanceTests: XCTestCase {

    // MARK: - D1：结构存在性

    /// D1 [structure-existence]：实例化后 scrollView / contentColumn 必须非 nil，
    /// 且 scrollView 在 ContentColumnView 子树内（证明撑满容器）。
    /// 杀死「容器结构缺失」（如 contentColumn 未挂载、scrollView 未作为子视图）回归。
    func test_hasScrollViewAndContentColumn() {
        let cv = ContentColumnView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        cv.layoutSubtreeIfNeeded()

        XCTAssertNotNil(cv.scrollView,
            "D1 违反：scrollView 必须非 nil（NSScrollView 是内容容器顶层）")
        XCTAssertNotNil(cv.contentColumn,
            "D1 违反：contentColumn 必须非 nil（实际内容挂载点）")

        // scrollView 必须是 ContentColumnView 子树的一部分（直接或间接子视图）
        XCTAssertTrue(isDescendant(cv.scrollView, of: cv),
            "D1 违反：scrollView 必须在 ContentColumnView 子树内（撑满四边）")
    }

    // MARK: - D2：宽度上限（默认 cap 780）

    /// D2 [width-capped-default]：frame width 1000（远大于默认 maxWidth 780）时，
    /// contentColumn.bounds.width 必须 ≤ 780。
    /// 杀死「内容区在宽屏溢出 / 不居中 cap 失效」回归。
    func test_contentColumnWidthCapped_whenViewportWide() {
        let cv = ContentColumnView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        cv.layoutSubtreeIfNeeded()

        XCTAssertLessThanOrEqual(cv.contentColumn.bounds.width, 780,
            "D2 违反：视口 1000 宽时 contentColumn.bounds.width 必须 ≤ 780（默认 cap），实际 \(cv.contentColumn.bounds.width)")
    }

    // MARK: - D3：test seam（maxWidth 可调 cap）

    /// D3 [test-seam-maxWidth]：设 maxWidth=500 后 contentColumn.bounds.width 必须 ≤ 500。
    /// 证明 maxWidth 是真正的 test seam（var 可写 + 实际驱动 contentColumn 宽度 cap），
    /// 而非硬编码常量。杀死「maxWidth 是死字段 / cap 值硬编码 780 不跟随」回归。
    func test_maxWidth_seamAdjustsCap() {
        let cv = ContentColumnView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        cv.maxWidth = 500
        cv.layoutSubtreeIfNeeded()

        XCTAssertLessThanOrEqual(cv.contentColumn.bounds.width, 500,
            "D3 违反：设 maxWidth=500 后 contentColumn.bounds.width 必须 ≤ 500（test seam 驱动 cap），实际 \(cv.contentColumn.bounds.width)")
    }

    // MARK: - D4：内容挂载到 contentColumn

    /// D4 [content-mount]：把 NSTextField addSubview 到 contentColumn 后，
    /// 其 superview 必须 === contentColumn（证明 contentColumn 是真正的「用户内容挂载点」，
    /// ContentColumnView 本身是透明容器语义，不直接承接业务子视图）。
    /// 杀死「内容挂到错误层级（scrollView/documentView/ContentColumnView 本身）」回归。
    func test_addContent_toContentColumn() {
        let cv = ContentColumnView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        cv.layoutSubtreeIfNeeded()

        let label = NSTextField(labelWithString: "hello")
        cv.contentColumn.addSubview(label)

        XCTAssertTrue(label.superview === cv.contentColumn,
            "D4 违反：加到 contentColumn 的子视图其 superview 必须 === contentColumn，实际 \(String(describing: label.superview))")
    }

    // MARK: - D5：documentView 高度 ≥ contentView 高度（防贴底盲区，关键）
    //
    // patterns/2026-07-03：NSScrollView 的 documentView 若高度 < contentView（可见区），
    // 内容少时 documentView 会贴顶，底部出现「滚动不到 / 看不见的盲区」。stage-1 设计要求
    // documentView.bounds.height ≥ contentView.bounds.height，保证 documentView 至少撑满
    // 可见区（内容多则自然超出 → 可竖滚；内容少则撑满 → 无盲区）。

    /// D5 [documentView-height-geq-contentView]：frame 1000×600 layoutSubtreeIfNeeded 后，
    /// documentView.bounds.height 必须 ≥ contentView.bounds.height。
    /// 杀死「documentView 塌缩到内容 intrinsic 高度导致底部盲区」回归。
    func test_documentViewHeight_geq_contentViewHeight防贴底() {
        let cv = ContentColumnView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        cv.layoutSubtreeIfNeeded()

        guard let documentView = cv.scrollView.documentView else {
            XCTFail("D5 违反：scrollView.documentView 必须 非 nil（防贴底盲区的前提）")
            return
        }

        let contentViewHeight = cv.scrollView.contentView.bounds.height
        let documentViewHeight = documentView.bounds.height

        XCTAssertGreaterThanOrEqual(documentViewHeight, contentViewHeight,
            "D5 违反：documentView.bounds.height(\(documentViewHeight)) 必须 ≥ contentView.bounds.height(\(contentViewHeight))（防贴底盲区，patterns/2026-07-03）")
    }

    // MARK: - Helpers

    /// 判断 candidate 是否是 ancestor 的（直接或间接）后代视图。
    private func isDescendant(_ candidate: NSView, of ancestor: NSView) -> Bool {
        if candidate === ancestor { return true }
        var current: NSView? = candidate
        while let view = current {
            if view === ancestor { return true }
            current = view.superview
        }
        return false
    }
}
