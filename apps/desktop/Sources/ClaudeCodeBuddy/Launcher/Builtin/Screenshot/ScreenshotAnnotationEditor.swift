import AppKit
import AnnotationKit
import CoreGraphics
import Foundation

/// 截屏标注编辑器（C-EDITOR-* / C-UNDO-REDO / C-EDITOR-ESC / C-CONCURRENCY 契约）。
///
/// 设计（对标微信截屏标注阶段）：
/// - **C-CONCURRENCY**：AnnotationDocument（@MainActor @Observable）全程 @MainActor 持有，
///   创建 / 编辑 / 渲染均在主线程；本编辑器是跨模块调用 AnnotationKit 的唯一入口。
/// - **C-EDITOR-TOOLS**：cycle 2 核心 5 工具 —— 矩形(RectangleObject) / 箭头(ArrowObject) /
///   画笔(FreehandObject) / 文字(TextObject) / 马赛克(PixelateObject)。ellipse/line/counter/
///   highlighter/select 延后到 cycle 2.1。
/// - **C-EDITOR-RENDER**：mouseDragged 期间实时 `AnnotationRenderer.render(sourceImage:objects:cropRect:)`
///   合成预览到画布，mouseUp 提交对象进 document（可 undo/redo）。
/// - **C-UNDO-REDO**：⌘Z/⌘⇧Z 走 AnnotationDocument.undo/redo。
/// - **C-EDITOR-ESC**：ESC → onCancel（取消编辑器，不复制）；绘制中 ESC 先放弃当前笔画（C-EDITOR-ESC）。
/// - **C-EDITOR-TEST-HOOK**：暴露 `_simulateDraw(tool:from:to:)` / `_simulateConfirm() async -> Data?` /
///   `_simulateCancel()` test-only hook，供 XCTest 程序化驱动（禁 osascript / XCUITest 鼠标）。
///
/// @MainActor：全程主线程编排（NSPanel / NSEvent / 鼠标 / AnnotationDocument），规避跨 actor Sendable 风险。
@MainActor
final class ScreenshotAnnotationEditor {

    // MARK: - 回调注入（生产/测试可换）

    /// 确认标注时回调（参数 = 合成后的 PNG `Data`）。生产路径触发复制；测试断言调用。
    var onConfirm: ((Data) -> Void)?

    /// 取消（ESC / 失焦）时回调。生产路径仅清理；测试断言调用。
    var onCancel: (() -> Void)?

    // MARK: - 状态

    /// 捕获的源图（已选区裁剪后的 CGImage）。渲染合成时作 sourceImage。
    private let sourceImage: CGImage
    /// 源图尺寸（points，与画布 1:1）。
    private let imageSize: CGSize

    /// AnnotationKit 文档（@MainActor @Observable）。所有标注对象的真源。
    let document: AnnotationDocument

    /// 当前选中的工具（cycle 2：rectangle/arrow/freehand/text/pixelate）。
    private(set) var currentTool: EditorTool = .rectangle
    /// 当前颜色。
    private(set) var currentColor: AnnotationColor = .red
    /// 当前线宽（pt）。
    private(set) var currentLineWidth: CGFloat = 4

    /// 编辑器是否已 present（防重入）。
    private(set) var isPresented: Bool = false

    /// 标注编辑器面板（生产 GUI）。
    private var panel: NSPanel?
    /// 画布视图（捕获图 + 标注合成）。
    private var canvas: ScreenshotEditorCanvas?
    /// 工具栏视图。
    private var toolbar: ScreenshotEditorToolbar?
    /// 全局本地事件监视器（编辑器期间捕获 ESC/Enter/⌘Z）。
    private var localKeyMonitor: Any?
    /// 文本工具输入框（inline 输入，mouseDown 放置 → 编辑 → Enter 提交）。
    private var activeTextInput: NSTextField?

    /// 正在绘制的临时对象（mouseDown → mouseDragged → mouseUp 期间）。提交前进 document，
    /// 仅画布本地预览（避免 undo 栈污染）；mouseUp 才 addObject 进 document。
    private var drawingObject: (any AnnotationObject)?

    /// 鼠标按下起点（画布坐标系，左上原点）。
    private var dragStart: CGPoint?

    // MARK: - Init

    /// 创建编辑器。`image` = 捕获并裁剪后的 CGImage（选区内容）。
    init(image: CGImage) {
        self.sourceImage = image
        self.imageSize = CGSize(width: image.width, height: image.height)
        self.document = AnnotationDocument(imageSize: imageSize)
    }

    // MARK: - Present / Dismiss

    /// 显示编辑器面板（盖住主屏中央，按源图尺寸适配）。
    func present() {
        guard !isPresented else { return }
        isPresented = true

        // 测试环境：跳过真实 NSPanel 创建（避免 GUI 副作用 + 无屏幕时仍可断言 isPresented）。
        if RuntimeEnvironment.isRunningTests {
            BuddyLogger.shared.info(
                "screenshot editor present (test mode, skip GUI)",
                subsystem: "builtin"
            )
            return
        }

        guard let mainScreen = NSScreen.main else {
            cancel()
            return
        }

        BuddyLogger.shared.info(
            "screenshot editor present",
            subsystem: "builtin",
            meta: ["imgW": imageSize.width, "imgH": imageSize.height]
        )

        // 按源图适配窗口尺寸（居中、不超过屏 90%）
        let maxW = mainScreen.visibleFrame.width * 0.9
        let maxH = mainScreen.visibleFrame.height * 0.9
        var winW = imageSize.width
        var winH = imageSize.height + 56  // 工具栏高度
        let scale: CGFloat = min(1, maxW / winW, maxH / winH)
        winW *= scale
        winH *= scale

        let frame = NSRect(
            x: mainScreen.visibleFrame.midX - winW / 2,
            y: mainScreen.visibleFrame.midY - winH / 2,
            width: winW,
            height: winH
        )

        let editorPanel = ScreenshotEditorPanel(contentRect: frame, screen: mainScreen)
        self.panel = editorPanel

        // 工具栏（顶部 56pt）
        let toolbarHeight: CGFloat = 56
        let toolbarView = ScreenshotEditorToolbar(
            frame: NSRect(x: 0, y: winH - toolbarHeight, width: winW, height: toolbarHeight)
        )
        toolbarView.onSelectTool = { [weak self] tool in
            self?.selectTool(tool)
        }
        toolbarView.onSelectColor = { [weak self] color in
            self?.currentColor = color
        }
        toolbarView.onChangeLineWidth = { [weak self] w in
            self?.currentLineWidth = w
        }
        toolbarView.onUndo = { [weak self] in self?.undo() }
        toolbarView.onRedo = { [weak self] in self?.redo() }
        toolbarView.onConfirm = { [weak self] in self?.confirm() }
        toolbarView.onCancel = { [weak self] in self?.cancel() }
        toolbarView.syncState(
            tool: currentTool, color: currentColor, lineWidth: currentLineWidth,
            canUndo: document.canUndo, canRedo: document.canRedo
        )
        self.toolbar = toolbarView

        // 画布（剩余区域）
        let canvasFrame = NSRect(x: 0, y: 0, width: winW, height: winH - toolbarHeight)
        let canvasView = ScreenshotEditorCanvas(frame: canvasFrame, sourceImage: sourceImage, scale: scale)
        canvasView.delegate = self
        self.canvas = canvasView

        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        container.addSubview(canvasView)
        container.addSubview(toolbarView)
        editorPanel.contentView = container

        editorPanel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
    }

    /// 关闭编辑器，清理资源（确认/取消后统一调用）。
    func dismiss() {
        guard isPresented else { return }
        isPresented = false

        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyMonitor = nil
        }
        panel?.orderOut(nil)
        panel = nil
        canvas = nil
        toolbar = nil
        activeTextInput?.removeFromSuperview()
        activeTextInput = nil
        drawingObject = nil
        dragStart = nil
    }

    // MARK: - 工具选择

    enum EditorTool: String, CaseIterable {
        case rectangle, arrow, freehand, text, pixelate

        var displayName: String {
            switch self {
            case .rectangle: "矩形"
            case .arrow: "箭头"
            case .freehand: "画笔"
            case .text: "文字"
            case .pixelate: "马赛克"
            }
        }

        var symbolName: String {
            switch self {
            case .rectangle: "rectangle"
            case .arrow: "arrow.up.right"
            case .freehand: "scribble"
            case .text: "textformat"
            case .pixelate: "square.grid.3x3"
            }
        }
    }

    func selectTool(_ tool: EditorTool) {
        currentTool = tool
        toolbar?.syncState(
            tool: currentTool, color: currentColor, lineWidth: currentLineWidth,
            canUndo: document.canUndo, canRedo: document.canRedo
        )
        BuddyLogger.shared.debug(
            "screenshot editor select tool",
            subsystem: "builtin",
            meta: ["tool": tool.rawValue]
        )
    }

    // MARK: - 确认 / 取消

    /// 确认：`AnnotationRenderer.render(sourceImage:objects:cropRect:nil)` → CGImage → PNG → `onConfirm(PNG)`。
    /// 失败友好降级（不崩、不写剪贴板）。
    @discardableResult
    func confirm() -> Data? {
        BuddyLogger.shared.info(
            "screenshot editor confirm（渲染合成 + 回调）",
            subsystem: "builtin",
            meta: ["objects": document.objects.count]
        )

        guard let rendered = AnnotationRenderer.render(
            sourceImage: sourceImage,
            objects: document.objects,
            cropRect: nil
        ) else {
            BuddyLogger.shared.warn(
                "screenshot editor render 失败（友好降级，不复制）",
                subsystem: "builtin"
            )
            return nil
        }

        guard let pngData = Self.pngData(from: rendered) else {
            BuddyLogger.shared.warn(
                "screenshot editor CGImage→PNG 失败（友好降级）",
                subsystem: "builtin"
            )
            return nil
        }

        let callback = onConfirm
        dismiss()
        callback?(pngData)
        BuddyLogger.shared.info(
            "screenshot editor 已合成并回调 PNG",
            subsystem: "builtin",
            meta: ["bytes": pngData.count]
        )
        return pngData
    }

    /// 取消（C-EDITOR-ESC）：不渲染、不复制，触发 onCancel。
    func cancel() {
        BuddyLogger.shared.info(
            "screenshot editor cancel（不渲染、不复制）",
            subsystem: "builtin"
        )
        let callback = onCancel
        dismiss()
        callback?()
    }

    // MARK: - Undo / Redo（C-UNDO-REDO）

    func undo() {
        guard document.canUndo else { return }
        document.undo()
        toolbar?.syncState(
            tool: currentTool, color: currentColor, lineWidth: currentLineWidth,
            canUndo: document.canUndo, canRedo: document.canRedo
        )
        canvas?.needsDisplay = true
    }

    func redo() {
        guard document.canRedo else { return }
        document.redo()
        toolbar?.syncState(
            tool: currentTool, color: currentColor, lineWidth: currentLineWidth,
            canUndo: document.canUndo, canRedo: document.canRedo
        )
        canvas?.needsDisplay = true
    }

    // MARK: - 键盘监听（ESC / ⌘Z / ⌘⇧Z / Enter）

    private func installKeyMonitor() {
        let mask: NSEvent.EventTypeMask = [.keyDown]
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self = self, self.isPresented else { return event }

            // ESC：绘制中先放弃当前笔画；否则取消编辑器
            if event.keyCode == 53 {
                if self.drawingObject != nil {
                    self.drawingObject = nil
                    self.dragStart = nil
                    self.canvas?.needsDisplay = true
                } else {
                    self.cancel()
                }
                return nil
            }

            // Enter（不做主语义；工具栏「✓」按钮触发 confirm；这里仅防 Enter 透传到下层）
            if event.keyCode == 36 {
                return nil
            }

            // ⌘Z / ⌘⇧Z（undo/redo）
            if event.modifierFlags.contains(.command) {
                let z = event.charactersIgnoringModifiers?.lowercased() == "z"
                guard z else { return event }
                if event.modifierFlags.contains(.shift) {
                    self.redo()
                } else {
                    self.undo()
                }
                return nil
            }

            return event
        }
    }

    // MARK: - 文字工具（点击放置 → inline NSTextField → Enter 提交）

    /// 在画布坐标 `point`（左上原点）放置文字输入框，Enter 提交创建 TextObject。
    private func placeTextInput(at point: CGPoint, in canvasBounds: NSRect) {
        // 移除上一个未提交的输入框
        activeTextInput?.removeFromSuperview()

        let fontSize: CGFloat = 24
        let field = NSTextField(frame: NSRect(
            x: point.x, y: canvasBounds.height - point.y - fontSize,
            width: 200, height: fontSize + 8
        ))
        field.font = .systemFont(ofSize: fontSize, weight: .medium)
        field.textColor = currentColor.nsColor
        field.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.9)
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.placeholderString = "输入文字 ⏎"
        field.target = self
        field.action = #selector(_textFieldSubmitted(_:))

        canvas?.addSubview(field)
        field.window?.makeFirstResponder(field)
        activeTextInput = field
    }

    @objc private func _textFieldSubmitted(_ sender: NSTextField) {
        let text = sender.stringValue
        sender.removeFromSuperview()
        if activeTextInput === sender { activeTextInput = nil }

        guard !text.isEmpty,
              let canvasView = canvas,
              let canvasSuper = canvasView.superview else { return }

        // field 在 canvas 坐标系；origin.y 是 field 左下，转 canvas 左上原点
        let fieldFrameInCanvas = sender.frame
        let originLeftTop = CGPoint(
            x: fieldFrameInCanvas.origin.x,
            y: canvasView.bounds.height - fieldFrameInCanvas.maxY
        )

        // 创建 TextObject（AnnotationKit 坐标系：左上原点）
        let textObj = TextObject(
            text: text,
            origin: originLeftTop,
            fontSize: 24,
            style: StrokeStyle(color: currentColor, lineWidth: currentLineWidth)
        )
        document.addObject(textObj)
        canvasView.needsDisplay = true

        // unused param warning 抑制
        _ = canvasSuper
    }

    // MARK: - Helpers

    private static func pngData(from image: CGImage) -> Data? {
        let bitmapRep = NSBitmapImageRep(cgImage: image)
        return bitmapRep.representation(using: .png, properties: [:])
    }

    // MARK: - C-EDITOR-TEST-HOOK（test-only 程序化驱动）

    /// 程序化模拟绘制（test-only，禁 osascript / XCUITest 鼠标）。
    /// `from` / `to` 是画布坐标系（左上原点，与 AnnotationObject.bounds 一致）。
    /// 按 `tool` 创建对应 AnnotationObject 进 document（直接 addObject，模拟 mouseUp 提交路径）。
    @discardableResult
    func _simulateDraw(tool: EditorTool, from start: CGPoint, to end: CGPoint) -> (any AnnotationObject)? {
        let style = StrokeStyle(color: currentColor, lineWidth: currentLineWidth)
        let object: any AnnotationObject
        switch tool {
        case .rectangle:
            let rect = CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(end.x - start.x),
                height: abs(end.y - start.y)
            )
            object = RectangleObject(rect: rect, style: style)
        case .arrow:
            object = ArrowObject(start: start, end: end, style: style)
        case .freehand:
            // 简化：from → to 两点 freehand（BezierSmoothing 单段也 OK）
            let freehand = FreehandObject(points: [start, end], style: style)
            object = freehand
        case .text:
            // text 用 _simulateDrawText；这里若误调则放占位文字
            let textObj = TextObject(
                text: "测试", origin: start, fontSize: 24, style: style
            )
            object = textObj
        case .pixelate:
            let rect = CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(end.x - start.x),
                height: abs(end.y - start.y)
            )
            object = PixelateObject(rect: rect, blockSize: 12, mode: .pixelate)
        }

        document.addObject(object)
        BuddyLogger.shared.info(
            "screenshot editor _simulateDraw",
            subsystem: "builtin",
            meta: ["tool": tool.rawValue, "from": "\(start)", "to": "\(end)"]
        )
        return object
    }

    /// 程序化模拟文字绘制（test-only）。在 `origin`（左上原点）创建 TextObject。
    @discardableResult
    func _simulateDrawText(text: String, at origin: CGPoint) -> TextObject {
        let style = StrokeStyle(color: currentColor, lineWidth: currentLineWidth)
        let obj = TextObject(text: text, origin: origin, fontSize: 24, style: style)
        document.addObject(obj)
        return obj
    }

    /// 程序化模拟确认（test-only）：render + onConfirm 回调，返回 PNG Data。
    @discardableResult
    func _simulateConfirm() async -> Data? {
        BuddyLogger.shared.info(
            "screenshot editor _simulateConfirm（inline render+callback）",
            subsystem: "builtin"
        )
        // inline 执行（不走 dismiss GUI 路径，但同样调 onConfirm），测试可立即断言
        guard isPresented || !RuntimeEnvironment.isRunningTests else {
            // 未 present（headless 测试模式）仍允许确认：直接 render + 回调
            return confirm()
        }
        return confirm()
    }

    /// 程序化模拟取消（test-only）。
    func _simulateCancel() {
        BuddyLogger.shared.info(
            "screenshot editor _simulateCancel",
            subsystem: "builtin"
        )
        let callback = onCancel
        if isPresented { dismiss() }
        callback?()
    }
}

// MARK: - ScreenshotEditorCanvasDelegate（画布 → 编辑器）

@MainActor
protocol ScreenshotEditorCanvasDelegate: AnyObject {
    func canvasMouseDown(_ point: CGPoint)
    func canvasMouseDragged(_ point: CGPoint)
    func canvasMouseUp(_ point: CGPoint)
    func canvasCurrentTool() -> ScreenshotAnnotationEditor.EditorTool
    func canvasCurrentStyle() -> StrokeStyle
    func canvasDocument() -> AnnotationDocument
    func canvasDrawingObject() -> (any AnnotationObject)?
    func canvasSetDrawingObject(_ object: (any AnnotationObject)?)
}

// MARK: - ScreenshotAnnotationEditor + CanvasDelegate

extension ScreenshotAnnotationEditor: ScreenshotEditorCanvasDelegate {

    func canvasMouseDown(_ point: CGPoint) {
        dragStart = point

        let style = StrokeStyle(color: currentColor, lineWidth: currentLineWidth)

        switch currentTool {
        case .rectangle:
            drawingObject = RectangleObject(rect: CGRect(origin: point, size: .zero), style: style)
        case .arrow:
            drawingObject = ArrowObject(start: point, end: point, style: style)
        case .freehand:
            let freehand = FreehandObject(points: [point], style: style)
            drawingObject = freehand
        case .pixelate:
            drawingObject = PixelateObject(rect: CGRect(origin: point, size: .zero), blockSize: 12, mode: .pixelate)
        case .text:
            // text 不走 drawingObject；mouseDown 时放置输入框（canvas 坐标已转左上原点）
            if let canvas = self.canvas {
                placeTextInput(at: point, in: canvas.bounds)
            }
            drawingObject = nil
        }
    }

    func canvasMouseDragged(_ point: CGPoint) {
        guard let start = dragStart, currentTool != .text else { return }

        switch currentTool {
        case .rectangle:
            if let obj = drawingObject as? RectangleObject {
                obj.rect = CGRect(
                    x: min(start.x, point.x),
                    y: min(start.y, point.y),
                    width: abs(point.x - start.x),
                    height: abs(point.y - start.y)
                )
            }
        case .arrow:
            if let obj = drawingObject as? ArrowObject {
                obj.end = point
            }
        case .freehand:
            if let obj = drawingObject as? FreehandObject {
                obj.addPoint(point)
            }
        case .pixelate:
            if let obj = drawingObject as? PixelateObject {
                obj.rect = CGRect(
                    x: min(start.x, point.x),
                    y: min(start.y, point.y),
                    width: abs(point.x - start.x),
                    height: abs(point.y - start.y)
                )
            }
        case .text:
            break
        }

        canvas?.needsDisplay = true
    }

    func canvasMouseUp(_ point: CGPoint) {
        guard currentTool != .text else {
            dragStart = nil
            return
        }

        // 提交进 document（mouseUp 才 addObject，避免 undo 栈污染）
        if let obj = drawingObject {
            // 过滤零尺寸对象（误触 / 单击）
            let bounds = obj.bounds
            if bounds.width >= 2 || bounds.height >= 2
                || (currentTool == .freehand && (obj as? FreehandObject)?.points.count ?? 0 > 1)
                || currentTool == .arrow {
                document.addObject(obj)
                toolbar?.syncState(
                    tool: currentTool, color: currentColor, lineWidth: currentLineWidth,
                    canUndo: document.canUndo, canRedo: document.canRedo
                )
            }
        }

        drawingObject = nil
        dragStart = nil
        canvas?.needsDisplay = true
    }

    func canvasCurrentTool() -> EditorTool { currentTool }

    func canvasCurrentStyle() -> StrokeStyle {
        StrokeStyle(color: currentColor, lineWidth: currentLineWidth)
    }

    func canvasDocument() -> AnnotationDocument { document }

    func canvasDrawingObject() -> (any AnnotationObject)? { drawingObject }

    func canvasSetDrawingObject(_ object: (any AnnotationObject)?) {
        drawingObject = object
    }
}

// MARK: - ScreenshotEditorPanel

private final class ScreenshotEditorPanel: NSPanel {
    init(contentRect: NSRect, screen: NSScreen?) {
        // NSPanel 的 init(contentRect:styleMask:backing:defer:screen:) 是 convenience init，
        // 子类必须调 designated init（不带 screen 的），再手动 setScreen。
        super.init(
            contentRect: contentRect,
            styleMask: [],  // borderless：editor 有自己的 toolbar（取消/确认 + ESC），无需系统 title bar；.titled 的 title bar 会遮挡顶部 toolbar 致其点不到
            backing: .buffered,
            defer: false
        )
        // 不 setFrame(screen.visibleFrame) —— 那会把 panel 撑成全屏，覆盖调用方算好的居中 frame，
        // 导致 content（image+toolbar）落在全屏 panel 左下角（真机「editor 没居中、难操作」根因）。
        // panel 保持 contentRect（调用方 present() 算的居中 image-sized frame）；screen 关联由 frame 位置自然决定。
        _ = screen
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        titleVisibility = .hidden
        title = "标注"
        hidesOnDeactivate = false
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - ScreenshotEditorCanvas（画布：源图 + 标注合成预览）

private final class ScreenshotEditorCanvas: NSView {

    weak var delegate: ScreenshotEditorCanvasDelegate?

    private let sourceImage: CGImage
    private let displayScale: CGFloat  // 渲染缩放（窗口适配后）

    /// 坐标转换：画布 NSView 左下原点 → AnnotationObject 左上原点。
    /// AnnotationKit 用 top-left origin；NSView draw 用 bottom-left。
    /// isFlipped = true 让 NSView 也走左上原点，省去转换。
    override var isFlipped: Bool { true }

    init(frame: NSRect, sourceImage: CGImage, scale: CGFloat) {
        self.sourceImage = sourceImage
        self.displayScale = scale
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        delegate?.canvasMouseDown(p)
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        delegate?.canvasMouseDragged(p)
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        delegate?.canvasMouseUp(p)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // 画源图（isFlipped=true 时 CGContext 仍是左下原点；为对齐 AnnotationObject 左上原点，
        // 这里翻转 y 坐标绘制源图：translateBy + scaleBy(1,-1)）
        let drawRect = CGRect(origin: .zero, size: bounds.size)

        // 直接画 CGImage（CGContext 默认左下原点 → 与 isFlipped NSView 叠加 → 视觉正确）
        ctx.saveGState()
        // 让 CGImage 在 flipped view 里正向显示：CTM 已被 NSView flip，这里反向再 flip 一次
        ctx.translateBy(x: 0, y: drawRect.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(sourceImage, in: drawRect)
        ctx.restoreGState()

        // 画 document.objects + drawingObject（在 flipped NSView 的 CGContext 里，
        // AnnotationObject.render 用左上原点坐标系 —— 与 isFlipped=true 对齐）
        ctx.saveGState()

        let document = delegate?.canvasDocument()
        let objects = document?.objects ?? []
        for object in objects {
            object.render(in: ctx)
        }
        // 临时绘制对象（mouseDragged 期间）
        if let drawing = delegate?.canvasDrawingObject() {
            drawing.render(in: ctx)
        }
        ctx.restoreGState()
    }
}

// MARK: - ScreenshotEditorToolbar（顶部工具栏）

private final class ScreenshotEditorToolbar: NSView {

    // 回调
    var onSelectTool: ((ScreenshotAnnotationEditor.EditorTool) -> Void)?
    var onSelectColor: ((AnnotationColor) -> Void)?
    var onChangeLineWidth: ((CGFloat) -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?

    // 当前状态
    private var currentTool: ScreenshotAnnotationEditor.EditorTool = .rectangle
    private var currentColor: AnnotationColor = .red
    private var currentLineWidth: CGFloat = 4
    private var canUndoFlag = false
    private var canRedoFlag = false

    private var toolButtons: [ScreenshotAnnotationEditor.EditorTool: NSButton] = [:]
    private var colorButtons: [AnnotationColor: NSButton] = [:]
    private var undoButton: NSButton?
    private var redoButton: NSButton?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.95).cgColor
        buildUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildUI() {
        // 工具按钮（左对齐）
        var x: CGFloat = 12
        let y: CGFloat = bounds.midY - 14

        for tool in ScreenshotAnnotationEditor.EditorTool.allCases {
            let btn = makeSymbolButton(
                symbol: tool.symbolName, tooltip: tool.displayName,
                frame: NSRect(x: x, y: y, width: 32, height: 28)
            )
            btn.target = self
            btn.action = #selector(toolClicked(_:))
            btn.identifier = NSUserInterfaceItemIdentifier(tool.rawValue)
            btn.tag = ScreenshotAnnotationEditor.EditorTool.allCases.firstIndex(of: tool) ?? 0
            toolButtons[tool] = btn
            addSubview(btn)
            x += 36
        }

        // 分隔
        x += 8

        // 颜色按钮
        let colors: [AnnotationColor] = [.red, .orange, .yellow, .green, .blue, .white, .black]
        for color in colors {
            let btn = NSButton(frame: NSRect(x: x, y: y + 2, width: 24, height: 24))
            btn.wantsLayer = true
            btn.layer?.backgroundColor = color.cgColor
            btn.layer?.cornerRadius = 12
            btn.layer?.borderWidth = 1
            btn.layer?.borderColor = NSColor.separatorColor.cgColor
            btn.target = self
            btn.action = #selector(colorClicked(_:))
            btn.identifier = NSUserInterfaceItemIdentifier(color.rawValue)
            btn.toolTip = color.displayName
            btn.isBordered = false
            colorButtons[color] = btn
            addSubview(btn)
            x += 28
        }

        // 分隔
        x += 8

        // 粗细按钮（2 / 4 / 8）
        for w in [2, 4, 8] {
            let btn = makeSymbolButton(
                symbol: "circle.fill", tooltip: "粗细 \(w)",
                frame: NSRect(x: x, y: y, width: 32, height: 28)
            )
            btn.target = self
            btn.action = #selector(lineWidthClicked(_:))
            btn.tag = w
            btn.contentTintColor = .labelColor
            // 用 symbolic size 暗示粗细（小/中/大）
            btn.image?.size = NSSize(width: CGFloat(w * 2), height: CGFloat(w * 2))
            addSubview(btn)
            x += 36
        }

        // 右侧：undo / redo / 取消 / 确认
        let rightX = bounds.maxX
        let confirmBtn = makeSymbolButton(
            symbol: "checkmark.circle.fill", tooltip: "确认（复制）",
            frame: NSRect(x: rightX - 80, y: y, width: 68, height: 28)
        )
        confirmBtn.title = "确认"
        confirmBtn.imagePosition = .imageLeading
        confirmBtn.bezelColor = NSColor.systemBlue
        confirmBtn.contentTintColor = .white
        confirmBtn.target = self
        confirmBtn.action = #selector(confirmClicked)
        addSubview(confirmBtn)

        let cancelBtn = makeSymbolButton(
            symbol: "xmark.circle", tooltip: "取消（ESC）",
            frame: NSRect(x: rightX - 150, y: y, width: 60, height: 28)
        )
        cancelBtn.title = "取消"
        cancelBtn.imagePosition = .imageLeading
        cancelBtn.target = self
        cancelBtn.action = #selector(cancelClicked)
        addSubview(cancelBtn)

        let redo = makeSymbolButton(
            symbol: "arrow.uturn.forward", tooltip: "重做 ⌘⇧Z",
            frame: NSRect(x: rightX - 210, y: y, width: 28, height: 28)
        )
        redo.target = self
        redo.action = #selector(redoClicked)
        addSubview(redo)
        self.redoButton = redo

        let undo = makeSymbolButton(
            symbol: "arrow.uturn.backward", tooltip: "撤销 ⌘Z",
            frame: NSRect(x: rightX - 240, y: y, width: 28, height: 28)
        )
        undo.target = self
        undo.action = #selector(undoClicked)
        addSubview(undo)
        self.undoButton = undo
    }

    private func makeSymbolButton(symbol: String, tooltip: String, frame: NSRect) -> NSButton {
        let btn = NSButton(frame: frame)
        btn.bezelStyle = .regularSquare
        btn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        btn.imagePosition = .imageOnly
        btn.contentTintColor = .labelColor
        btn.toolTip = tooltip
        return btn
    }

    // MARK: - 状态同步

    func syncState(
        tool: ScreenshotAnnotationEditor.EditorTool,
        color: AnnotationColor,
        lineWidth: CGFloat,
        canUndo: Bool,
        canRedo: Bool
    ) {
        currentTool = tool
        currentColor = color
        currentLineWidth = lineWidth
        canUndoFlag = canUndo
        canRedoFlag = canRedo

        for (t, btn) in toolButtons {
            btn.state = (t == tool) ? .on : .off
            btn.contentTintColor = (t == tool) ? .controlAccentColor : .labelColor
        }
        for (c, btn) in colorButtons {
            btn.layer?.borderWidth = (c.rawValue == color.rawValue) ? 3 : 1
            btn.layer?.borderColor = (c.rawValue == color.rawValue)
                ? NSColor.controlAccentColor.cgColor
                : NSColor.separatorColor.cgColor
        }
        undoButton?.isEnabled = canUndo
        redoButton?.isEnabled = canRedo
    }

    // MARK: - Actions

    @objc private func toolClicked(_ sender: NSButton) {
        let idx = sender.tag
        let all = ScreenshotAnnotationEditor.EditorTool.allCases
        guard idx >= 0, idx < all.count else { return }
        let tool = all[idx]
        currentTool = tool
        onSelectTool?(tool)
    }

    @objc private func colorClicked(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let color = AnnotationColor(rawValue: raw) else { return }
        currentColor = color
        onSelectColor?(color)
    }

    @objc private func lineWidthClicked(_ sender: NSButton) {
        let w = CGFloat(sender.tag)
        currentLineWidth = w
        onChangeLineWidth?(w)
    }

    @objc private func undoClicked() { onUndo?() }
    @objc private func redoClicked() { onRedo?() }
    @objc private func confirmClicked() { onConfirm?() }
    @objc private func cancelClicked() { onCancel?() }
}
