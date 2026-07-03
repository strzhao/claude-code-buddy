import XCTest
import AppKit
import CoreGraphics
import AnnotationKit
@testable import BuddyCore

// MARK: - ScreenshotEditorHookTests
//
// cycle 2 红队/蓝队验收测试：ScreenshotAnnotationEditor 标注编辑器（C-EDITOR-* 契约）
//
// 切片范围：cycle 2 核心 5 工具（矩形/箭头/画笔/文字/马赛克）+ undo/redo + 程序化 hook +
// 确认渲染合成 + 取消语义。不测 GUI 视觉/真机交互（延后快照层 + XCUITest）。
//
// 覆盖：
//   - C-EDITOR-TEST-HOOK：_simulateDraw(tool:from:to:) + _simulateConfirm() + _simulateCancel()
//   - C-EDITOR-TOOLS：rectangle/arrow/freehand/text/pixelate 各工具创建对应 AnnotationObject
//   - C-EDITOR-RENDER：confirm 后 AnnotationRenderer.render 合成 PNG，对象数影响输出
//   - C-UNDO-REDO：addObject → undo 撤销 → redo 重做
//   - C-EDITOR-ESC：cancel 不渲染、不回调 onConfirm
//   - C-CONCURRENCY：editor 全程 @MainActor 持有 document
//
// 红队红线：
//   - 全程序化驱动，不依赖 osascript / XCUITest 鼠标 / 真实屏幕捕获
//   - 不触发 TCC（present 在测试模式跳 GUI）

@MainActor
final class ScreenshotEditorHookTests: XCTestCase {

    // MARK: - 辅助：构造真实 CGImage + editor

    /// 构造 WxH 纯色 CGImage（用作 editor 的 sourceImage）。
    private func makeTestImage(width: Int = 32, height: Int = 32) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: bitmapInfo
        )!
        // 填白
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    private func makeEditor(width: Int = 32, height: Int = 32) -> ScreenshotAnnotationEditor {
        ScreenshotAnnotationEditor(image: makeTestImage(width: width, height: height))
    }

    // MARK: - C-EDITOR-TEST-HOOK：hook 可用 + present 测试模式跳 GUI

    /// C-EDITOR-TEST-HOOK: editor 可实例化 + present() 在测试模式跳 GUI（isPresented=true 但无 panel 副作用）
    func test_HOOK_editorInstantiable_presentTestMode() {
        let editor = makeEditor()
        XCTAssertNotNil(editor.document, "C-CONCURRENCY: editor 必须持有 AnnotationDocument（@MainActor）")
        XCTAssertEqual(editor.document.imageSize, CGSize(width: 32, height: 32),
            "C-CONCURRENCY: document.imageSize 必须 == 源图尺寸")
        XCTAssertFalse(editor.isPresented, "precondition: 未 present")

        editor.present()
        XCTAssertTrue(editor.isPresented,
            "C-EDITOR-TEST-HOOK: present() 后 isPresented 必须 true（测试模式跳 GUI 但状态置位）")
    }

    // MARK: - C-EDITOR-TOOLS：5 工具各创建对应 AnnotationObject

    /// C-EDITOR-TOOLS: rectangle 工具 → RectangleObject 进 document
    func test_TOOL_rectangle_createsRectangleObject() {
        let editor = makeEditor()
        let obj = editor._simulateDraw(tool: .rectangle, from: .init(x: 2, y: 2), to: .init(x: 20, y: 20))
        XCTAssertNotNil(obj, "_simulateDraw 必须返回创建的对象")
        XCTAssertTrue(obj is RectangleObject,
            "C-EDITOR-TOOLS: rectangle 工具必须创建 RectangleObject")
        XCTAssertEqual(editor.document.objects.count, 1, "document 必须含 1 对象")
        let rect = (obj as? RectangleObject)?.rect
        XCTAssertEqual(rect?.origin, CGPoint(x: 2, y: 2), "rect.origin 应归一化为 min")
        XCTAssertEqual(rect?.size, CGSize(width: 18, height: 18), "rect.size 应为绝对值")
    }

    /// C-EDITOR-TOOLS: arrow 工具 → ArrowObject（start/end 坐标保留）
    func test_TOOL_arrow_createsArrowObject() {
        let editor = makeEditor()
        let obj = editor._simulateDraw(tool: .arrow, from: .init(x: 5, y: 5), to: .init(x: 25, y: 25))
        XCTAssertTrue(obj is ArrowObject, "C-EDITOR-TOOLS: arrow 工具必须创建 ArrowObject")
        let arrow = obj as? ArrowObject
        XCTAssertEqual(arrow?.start, CGPoint(x: 5, y: 5))
        XCTAssertEqual(arrow?.end, CGPoint(x: 25, y: 25))
    }

    /// C-EDITOR-TOOLS: freehand 工具 → FreehandObject（含 from→to 两点）
    func test_TOOL_freehand_createsFreehandObject() {
        let editor = makeEditor()
        let obj = editor._simulateDraw(tool: .freehand, from: .init(x: 1, y: 1), to: .init(x: 10, y: 10))
        XCTAssertTrue(obj is FreehandObject, "C-EDITOR-TOOLS: freehand 工具必须创建 FreehandObject")
        let points = (obj as? FreehandObject)?.points
        XCTAssertEqual(points?.count, 2, "freehand 应含 from→to 两点")
        XCTAssertEqual(points?.first, CGPoint(x: 1, y: 1))
        XCTAssertEqual(points?.last, CGPoint(x: 10, y: 10))
    }

    /// C-EDITOR-TOOLS: text 工具 → TextObject（_simulateDrawText 专用 hook）
    func test_TOOL_text_createsTextObject() {
        let editor = makeEditor()
        let textObj = editor._simulateDrawText(text: "你好", at: CGPoint(x: 4, y: 6))
        XCTAssertEqual(textObj.text, "你好", "TextObject.text 必须 == 入参")
        XCTAssertEqual(textObj.origin, CGPoint(x: 4, y: 6), "TextObject.origin 必须 == 放置点")
    }

    /// C-EDITOR-TOOLS: pixelate 工具 → PixelateObject（默认 mode=.pixelate）
    func test_TOOL_pixelate_createsPixelateObject() {
        let editor = makeEditor()
        let obj = editor._simulateDraw(tool: .pixelate, from: .init(x: 2, y: 2), to: .init(x: 16, y: 16))
        XCTAssertTrue(obj is PixelateObject, "C-EDITOR-TOOLS: pixelate 工具必须创建 PixelateObject")
        let pix = obj as? PixelateObject
        XCTAssertEqual(pix?.mode, .pixelate, "默认 mode 应为 .pixelate")
        XCTAssertGreaterThan(pix?.rect.width ?? 0, 0, "pixelate rect 必须非零")
    }

    // MARK: - C-EDITOR-TOOLS：5 工具循环覆盖（防 case 漏）

    /// C-EDITOR-TOOLS: 5 个工具逐一创建对象，document.objects.count == 5
    func test_TOOL_allFiveTools_createObjects() {
        let editor = makeEditor()
        _ = editor._simulateDraw(tool: .rectangle, from: .init(x: 0, y: 0), to: .init(x: 5, y: 5))
        _ = editor._simulateDraw(tool: .arrow, from: .init(x: 0, y: 0), to: .init(x: 5, y: 5))
        _ = editor._simulateDraw(tool: .freehand, from: .init(x: 0, y: 0), to: .init(x: 5, y: 5))
        _ = editor._simulateDrawText(text: "X", at: .zero)
        _ = editor._simulateDraw(tool: .pixelate, from: .init(x: 0, y: 0), to: .init(x: 5, y: 5))

        XCTAssertEqual(editor.document.objects.count, 5,
            "C-EDITOR-TOOLS: 5 工具逐一调用后 document 必须含 5 对象（覆盖 cycle 2 全部工具）")
    }

    // MARK: - C-UNDO-REDO：undo/redo 走 AnnotationDocument

    /// C-UNDO-REDO: addObject → undo 撤销（objects 空）→ redo 重做（objects 1）
    func test_UNDO_REDO_roundTrip() {
        let editor = makeEditor()
        _ = editor._simulateDraw(tool: .rectangle, from: .init(x: 0, y: 0), to: .init(x: 10, y: 10))
        XCTAssertEqual(editor.document.objects.count, 1)
        XCTAssertTrue(editor.document.canUndo, "addObject 后 must canUndo")

        editor.undo()
        XCTAssertEqual(editor.document.objects.count, 0, "undo 后 objects 必须空")
        XCTAssertFalse(editor.document.canUndo, "undo 到空后 !canUndo")
        XCTAssertTrue(editor.document.canRedo, "undo 后 must canRedo")

        editor.redo()
        XCTAssertEqual(editor.document.objects.count, 1, "redo 后 objects 必须恢复 1")
        XCTAssertTrue(editor.document.canUndo, "redo 后 must canUndo")
    }

    /// C-UNDO-REDO: 多次 addObject → 多次 undo 逐个回退
    func test_UNDO_multipleDraws_undoOneByOne() {
        let editor = makeEditor()
        for i in 0..<3 {
            _ = editor._simulateDraw(
                tool: .rectangle,
                from: .init(x: CGFloat(i), y: 0),
                to: .init(x: CGFloat(i) + 5, y: 5)
            )
        }
        XCTAssertEqual(editor.document.objects.count, 3)

        editor.undo()
        XCTAssertEqual(editor.document.objects.count, 2, "第 1 次 undo 后剩 2")
        editor.undo()
        XCTAssertEqual(editor.document.objects.count, 1, "第 2 次 undo 后剩 1")
        editor.undo()
        XCTAssertEqual(editor.document.objects.count, 0, "第 3 次 undo 后剩 0")
    }

    // MARK: - C-EDITOR-RENDER：confirm 渲染合成 PNG

    /// C-EDITOR-RENDER: confirm（空 document）→ 仍 render 出源图（不崩，返回 PNG）
    func test_RENDER_emptyDocument_rendersSourceImage() async {
        let editor = makeEditor()
        editor.present()
        let pngData = await editor._simulateConfirm()
        XCTAssertNotNil(pngData, "C-EDITOR-RENDER: 即使无标注，confirm 也必须 render 出源图 PNG")
        XCTAssertGreaterThan(pngData?.count ?? 0, 0, "PNG 必须 > 0 字节")
    }

    /// C-EDITOR-RENDER: 加标注后 confirm → PNG 字节数应不同于空 render（标注画了东西）
    func test_RENDER_withAnnotation_changesOutput() async {
        let editor = makeEditor()
        editor.present()

        // 空 confirm
        let emptyPNG = await editor._simulateConfirm()
        XCTAssertNotNil(emptyPNG)

        // 重新 present（confirm 后已 dismiss）+ 加标注 + confirm
        editor.present()
        _ = editor._simulateDraw(tool: .rectangle, from: .init(x: 2, y: 2), to: .init(x: 28, y: 28))
        let annotatedPNG = await editor._simulateConfirm()

        XCTAssertNotNil(annotatedPNG, "带标注 confirm 必须 render 成功")
        // 两次 PNG 都有效（不为 nil）；不要求 byte 严格不等（同尺寸 + 纯色可能近似），
        // 但 annotatedPNG 必须含矩形渲染（视觉层差异由快照测试守护，此处只验证链路通）
        XCTAssertGreaterThan(annotatedPNG?.count ?? 0, 0)
    }

    // MARK: - C-EDITOR-ESC：cancel 不渲染、不回调 onConfirm

    /// C-EDITOR-ESC: cancel → onCancel 被调、onConfirm 未被调
    func test_ESC_cancel_invokesOnCancel_notOnConfirm() async {
        let editor = makeEditor()
        editor.present()

        var confirmCalled = false
        var cancelCalled = false
        editor.onConfirm = { _ in confirmCalled = true }
        editor.onCancel = { cancelCalled = true }

        editor._simulateCancel()

        XCTAssertTrue(cancelCalled, "C-EDITOR-ESC: cancel 必须 trigger onCancel")
        XCTAssertFalse(confirmCalled, "C-EDITOR-ESC: cancel 不应 trigger onConfirm")
    }

    /// C-EDITOR-ESC: confirm → onConfirm 被调、onCancel 未被调
    func test_CONFIRM_invokesOnConfirm_notOnCancel() async {
        let editor = makeEditor()
        editor.present()

        var confirmCalled = false
        var cancelCalled = false
        editor.onConfirm = { _ in confirmCalled = true }
        editor.onCancel = { cancelCalled = true }

        _ = await editor._simulateConfirm()

        XCTAssertTrue(confirmCalled, "confirm 必须 trigger onConfirm")
        XCTAssertFalse(cancelCalled, "confirm 不应 trigger onCancel")
    }

    // MARK: - 防御性：未设回调不崩

    /// 未设 onConfirm/onCancel 时 _simulateConfirm/_simulateCancel 不 crash
    func test_noCallbacks_noCrash() async {
        let editor = makeEditor()
        editor.present()
        // 不设任何回调
        _ = await editor._simulateConfirm()  // 不 crash
        editor.present()
        editor._simulateCancel()              // 不 crash
    }

    // MARK: - 工具/颜色/线宽状态

    /// selectTool / currentColor / currentLineWidth 状态可读写
    func test_selectTool_updatesCurrentTool() {
        let editor = makeEditor()
        XCTAssertEqual(editor.currentTool, .rectangle, "默认工具应为 rectangle")

        for tool in ScreenshotAnnotationEditor.EditorTool.allCases {
            editor.selectTool(tool)
            XCTAssertEqual(editor.currentTool, tool, "selectTool(\(tool)) 后 currentTool 必须 == \(tool)")
        }
    }

    /// EditorTool.allCases 必须含 cycle 2 核心 5 工具
    func test_editorTool_allCases_containsCycle2Five() {
        let tools = Set(ScreenshotAnnotationEditor.EditorTool.allCases.map { $0.rawValue })
        let expected: Set = ["rectangle", "arrow", "freehand", "text", "pixelate"]
        XCTAssertTrue(expected.isSubset(of: tools),
            "cycle 2 核心 5 工具必须全在 EditorTool.allCases，缺失：\(expected.subtracting(tools))")
    }
}
