import XCTest
import AppKit
import CoreGraphics
@testable import BuddyCore

/// 蓝队单元测试 — ScreenshotPlugin 截屏插件逻辑层（不覆盖红队验收测试）。
///
/// 验证蓝队实现的关键契约（C-SCREENSHOT-KEYWORDS / C-PRIORITY / C-CAPTURE-SEAM /
/// C-COPY-SEAM / C-REGISTRY-REGISTER），用 seam mock 驱动，零 TCC、零真实捕获。
@MainActor
final class ScreenshotPluginLogicTests: XCTestCase {

    // MARK: - Mock ScreenCapturing
    //
    // **nonisolated**（非 @MainActor）：handleConfirm(@MainActor) `await capture.captureArea(rect)` 时，
    // 非 @MainActor 隔离的 mock 在 cooperative pool 上跑（main actor 在 await 期间释放，不死锁）。
    // 生产 SCScreenCapture(@MainActor) 的 captureArea 在 main 上 inline cooperative 跑（亦不死锁，
    // 因 handleConfirm 不再用 semaphore.wait 阻塞 main——auto-fix SC-3 修复）。

    private final class CaptureSpy: ScreenCapturing {
        private let lock = NSLock()
        private var _callCount = 0
        private var _lastRect: CGRect?
        var callCount: Int { lock.lock(); defer { lock.unlock() }; return _callCount }
        var lastRect: CGRect? { lock.lock(); defer { lock.unlock() }; return _lastRect }
        var stubbedData: Data = Data([0x89, 0x50, 0x4E, 0x47])
        var stubbedError: Error?

        func captureArea(_ rect: CGRect) async throws -> Data {
            lock.lock()
            _callCount += 1
            _lastRect = rect
            let err = stubbedError
            let data = stubbedData
            lock.unlock()
            if let error = err { throw error }
            return data
        }
    }

    /// 辅助：构造 2×2 纯色 CGImage → PNG（handleConfirm 现在需要解码出 CGImage 才能构造 editor）。
    /// stubbedData 默认是 PNG 签名片段（无法解码为 CGImage），故 handleConfirm 会走「解码失败」降级。
    /// 测试 present editor 链路时需用真实 PNG；helper 见 `makePNG(size:)`。
    private func makePNG(width: Int = 4, height: Int = 4) -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: bitmapInfo
        ),
            let cgImage = ctx.makeImage() else {
            return Data([0x89, 0x50, 0x4E, 0x47])
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .png, properties: [:]) ?? Data([0x89, 0x50, 0x4E, 0x47])
    }

    /// spy mock：记录 editor present / onConfirm / onCancel（避免真 GUI）。
    private final class EditorSpy {
        var presentCount = 0
        var onConfirmCount = 0
        var onCancelCount = 0
        var lastConfirmData: Data?
        var realEditor: ScreenshotAnnotationEditor?
    }

    /// 工厂 spy：用 mock editor 替代真实 ScreenshotAnnotationEditor，记录 present / callback。
    private func makeEditorFactorySpy(spy: EditorSpy) -> (CGImage) -> ScreenshotAnnotationEditor {
        return { image in
            // 用真实 editor 但拦截回调计数（present 在测试模式跳 GUI）
            let editor = ScreenshotAnnotationEditor(image: image)
            editor.onConfirm = { data in
                spy.onConfirmCount += 1
                spy.lastConfirmData = data
            }
            editor.onCancel = {
                spy.onCancelCount += 1
            }
            spy.realEditor = editor
            return editor
        }
    }

    private func makeIsolatedCopyService() -> (CopyService, NSPasteboard) {
        let pb = NSPasteboard(name: NSPasteboard.Name("ccb-test-screenshot-\(UUID().uuidString)"))
        pb.clearContents()
        return (CopyService(pasteboard: pb), pb)
    }

    // MARK: - 属性契约

    func test_id_isScreenshot() {
        XCTAssertEqual(ScreenshotPlugin.shared.id, "screenshot")
    }

    func test_priority_is90() {
        XCTAssertEqual(ScreenshotPlugin.shared.priority, 90)
    }

    func test_priority_between_systemCommand_and_appLauncher() {
        // 90 < SystemCommand 100, 90 > AppLauncher 0
        XCTAssertLessThan(ScreenshotPlugin.shared.priority, SystemCommandPlugin.shared.priority)
        XCTAssertGreaterThan(ScreenshotPlugin.shared.priority, AppLauncherPlugin.shared.priority)
    }

    func test_sectionTitle_nonEmpty() {
        XCTAssertFalse(ScreenshotPlugin.shared.sectionTitle.isEmpty)
    }

    // MARK: - C-SCREENSHOT-KEYWORDS

    func test_keywords_exactMatch_allFour() async {
        let (copy, _) = makeIsolatedCopyService()
        let plugin = ScreenshotPlugin(capture: CaptureSpy(), copy: copy)
        for kw in ["截屏", "截图", "screenshot", "jietu"] {
            let actions = await plugin.actions(for: kw)
            XCTAssertEqual(actions.count, 1, "query==\(kw) 应产出 1 候选")
            XCTAssertEqual(actions.first?.pluginId, "screenshot")
            XCTAssertEqual(actions.first?.score, 1000, "完全匹配 score==1000")
        }
    }

    func test_keywords_caseInsensitive() async {
        let (copy, _) = makeIsolatedCopyService()
        let plugin = ScreenshotPlugin(capture: CaptureSpy(), copy: copy)
        let actions = await plugin.actions(for: "SCREENSHOT")
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions.first?.score, 1000, "大小写不敏感完全匹配")
    }

    func test_keywords_prefixMatch_score800() async {
        let (copy, _) = makeIsolatedCopyService()
        let plugin = ScreenshotPlugin(capture: CaptureSpy(), copy: copy)
        let actions = await plugin.actions(for: "截")
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions.first?.score, 800, "前缀匹配 score==800")
    }

    func test_keywords_negate_unrelated() async {
        let (copy, _) = makeIsolatedCopyService()
        let plugin = ScreenshotPlugin(capture: CaptureSpy(), copy: copy)
        for q in ["微信", "lock", "cat", "hello", "图", "屏"] {
            let actions = await plugin.actions(for: q)
            XCTAssertTrue(actions.isEmpty, "query==\(q) 不应产出 screenshot 候选")
        }
    }

    func test_keywords_emptyQuery_returnsEmpty() async {
        let (copy, _) = makeIsolatedCopyService()
        let plugin = ScreenshotPlugin(capture: CaptureSpy(), copy: copy)
        let actions = await plugin.actions(for: "")
        XCTAssertTrue(actions.isEmpty)
    }

    // MARK: - 惰性执行（构造/查询不触发 seam）

    func test_construction_doesNotCapture() {
        let spy = CaptureSpy()
        let (copy, _) = makeIsolatedCopyService()
        _ = ScreenshotPlugin(capture: spy, copy: copy)
        XCTAssertEqual(spy.callCount, 0)
    }

    func test_actionsQuery_doesNotCapture() async {
        let spy = CaptureSpy()
        let (copy, _) = makeIsolatedCopyService()
        let plugin = ScreenshotPlugin(capture: spy, copy: copy)
        _ = await plugin.actions(for: "截屏")
        XCTAssertEqual(spy.callCount, 0)
    }

    // MARK: - handleConfirm 流程（cycle 2 改造：捕获 → 解码 → present editor，不再直接 copy）

    func test_handleConfirm_capturesAndPresentsEditor() async throws {
        let spy = CaptureSpy()
        spy.stubbedData = makePNG(width: 8, height: 8)  // 真实可解码 PNG
        let (copy, pb) = makeIsolatedCopyService()
        let editorSpy = EditorSpy()
        let plugin = ScreenshotPlugin(
            capture: spy, copy: copy,
            editorFactory: makeEditorFactorySpy(spy: editorSpy)
        )

        // handleConfirm 前：seam 未调、editor 未 present、pb 空
        XCTAssertEqual(spy.callCount, 0)
        XCTAssertNil(plugin.editorController)
        XCTAssertNil(pb.data(forType: .png))

        await plugin.handleConfirm(CGRect(x: 0, y: 0, width: 100, height: 100))

        // captureArea 被调 1 次
        XCTAssertEqual(spy.callCount, 1, "handleConfirm 后 captureArea 必须被调 1 次")
        // editorController 被赋值（present editor 链路通）
        XCTAssertNotNil(plugin.editorController, "handleConfirm 后 editorController 必须 present")
        // pb 未写（copy 不在 handleConfirm 了；移到 editor.onConfirm）
        XCTAssertNil(pb.data(forType: .png),
            "cycle 2: handleConfirm 不直接 copy，pb 不应被写")
    }

    func test_handleConfirm_permissionDenied_noCrash_noEditor() async {
        let spy = CaptureSpy()
        spy.stubbedError = LauncherError.systemCommandFailed("权限未授予")
        let (copy, pb) = makeIsolatedCopyService()
        let editorSpy = EditorSpy()
        let plugin = ScreenshotPlugin(
            capture: spy, copy: copy,
            editorFactory: makeEditorFactorySpy(spy: editorSpy)
        )

        await plugin.handleConfirm(CGRect(x: 0, y: 0, width: 100, height: 100))

        // 权限拒绝：seam 被调（捕获尝试过）但 editor 未 present、pb 未写（友好降级）
        XCTAssertEqual(spy.callCount, 1)
        XCTAssertNil(plugin.editorController, "权限拒绝时不应 present editor")
        XCTAssertNil(pb.data(forType: .png), "权限拒绝时 pasteboard 不应被写")
    }

    func test_handleConfirm_decodeFailure_friendlyNoEditor() async {
        // stubbedData 是 PNG 签名片段，无法解码为 CGImage → 走解码失败降级
        let spy = CaptureSpy()
        let (copy, pb) = makeIsolatedCopyService()
        let editorSpy = EditorSpy()
        let plugin = ScreenshotPlugin(
            capture: spy, copy: copy,
            editorFactory: makeEditorFactorySpy(spy: editorSpy)
        )

        await plugin.handleConfirm(CGRect(x: 0, y: 0, width: 100, height: 100))

        XCTAssertEqual(spy.callCount, 1, "captureArea 仍被调")
        XCTAssertNil(plugin.editorController, "解码失败时不应 present editor")
        XCTAssertNil(pb.data(forType: .png), "解码失败时 pasteboard 不应被写")
    }

    // MARK: - editor confirm 路径（render 合成 + copy）

    /// 注：plugin.handleConfirm 会覆盖 editorFactory 里 wire 的 onConfirm/onCancel（把 copy 接进来）。
    /// 故测试不依赖 spy 的 callback 计数，改断言 pb 写入（plugin.onConfirm → copyImage 的副作用）。
    func test_editorConfirm_rendersAndCopies() async throws {
        let spy = CaptureSpy()
        spy.stubbedData = makePNG(width: 32, height: 32)
        let (copy, pb) = makeIsolatedCopyService()
        let editorSpy = EditorSpy()
        let plugin = ScreenshotPlugin(
            capture: spy, copy: copy,
            editorFactory: makeEditorFactorySpy(spy: editorSpy)
        )

        await plugin.handleConfirm(CGRect(x: 0, y: 0, width: 32, height: 32))

        let editor = try XCTUnwrap(plugin.editorController)
        XCTAssertTrue(editorSpy.realEditor === editor)
        // editor present（测试模式跳 GUI，但 isPresented=true）
        XCTAssertTrue(editor.isPresented, "present() 后 isPresented 必须 true")

        // 程序化绘制一个矩形进 document
        _ = editor._simulateDraw(
            tool: .rectangle,
            from: CGPoint(x: 2, y: 2),
            to: CGPoint(x: 20, y: 20)
        )
        XCTAssertEqual(editor.document.objects.count, 1, "_simulateDraw 后 document 必须含 1 对象")

        // confirm → render → onConfirm（plugin 覆盖的，触发 copyImage）→ pb 写 PNG
        let pngData = await editor._simulateConfirm()
        XCTAssertNotNil(pngData, "editor confirm 必须 render 出 PNG")

        // 副作用断言：plugin 注入的 onConfirm 调了 copyImage，pb 含合成 PNG（数据不变形）
        let written = pb.data(forType: .png)
        XCTAssertNotNil(written, "editor confirm 后 pb 必须含合成 PNG（plugin.onConfirm → copyImage）")
        XCTAssertEqual(written, pngData, "pb PNG 必须 == editor render 输出")
    }

    func test_editorCancel_doesNotCopy() async throws {
        let spy = CaptureSpy()
        spy.stubbedData = makePNG(width: 16, height: 16)
        let (copy, pb) = makeIsolatedCopyService()
        let editorSpy = EditorSpy()
        let plugin = ScreenshotPlugin(
            capture: spy, copy: copy,
            editorFactory: makeEditorFactorySpy(spy: editorSpy)
        )

        await plugin.handleConfirm(CGRect(x: 0, y: 0, width: 16, height: 16))
        let editor = try XCTUnwrap(plugin.editorController)

        editor._simulateCancel()
        // 副作用断言：cancel 不调 copyImage（plugin.onCancel 仅清理），pb 仍空
        XCTAssertNil(pb.data(forType: .png), "取消时 pasteboard 不应被写")
    }

    func test_handleConfirm_doesNotTouchSystemPasteboard() async throws {
        let sentinel = "ccb-sentinel-\(UUID().uuidString)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sentinel, forType: .string)

        let spy = CaptureSpy()
        spy.stubbedData = makePNG(width: 8, height: 8)
        let (copy, _) = makeIsolatedCopyService()
        let plugin = ScreenshotPlugin(
            capture: spy, copy: copy,
            editorFactory: makeEditorFactorySpy(spy: EditorSpy())
        )

        await plugin.handleConfirm(CGRect(x: 0, y: 0, width: 8, height: 8))

        // handleConfirm 不写系统剪贴板（用注入隔离 pb）
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), sentinel,
            "handleConfirm 用注入 CopyService 不应触碰系统剪贴板")
    }

    // MARK: - C-REGISTRY-REGISTER

    func test_registry_defaultInit_containsScreenshot() {
        let registry = BuiltinPluginRegistry()
        XCTAssertTrue(registry.plugins.contains { $0.id == "screenshot" })
    }

    func test_registry_reset_stillContainsScreenshot() {
        let registry = BuiltinPluginRegistry()
        registry.reset()
        XCTAssertTrue(registry.plugins.contains { $0.id == "screenshot" })
    }

    func test_registry_actionsFor_截屏_containsScreenshot() async {
        let registry = BuiltinPluginRegistry(plugins: [ScreenshotPlugin.shared])
        let result = await registry.actions(for: "截屏")
        XCTAssertTrue(result.contains { $0.pluginId == "screenshot" })
    }
}

// MARK: - ScreenshotOverlayController 逻辑测试（C-OVERLAY-TEST-HOOK / C-MIN-SELECTION）

@MainActor
final class ScreenshotOverlayControllerLogicTests: XCTestCase {

    func test_dragAndConfirm_invokesOnConfirmWithRect() async throws {
        let controller = ScreenshotOverlayController()
        var receivedRect: CGRect?

        let exp = expectation(description: "onConfirm")
        controller.onConfirm = { rect in
            receivedRect = rect
            exp.fulfill()
        }

        controller._simulateDrag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 250))
        _ = try await controller._simulateConfirm()

        await fulfillment(of: [exp], timeout: 2.0)

        XCTAssertNotNil(receivedRect)
        XCTAssertEqual(receivedRect?.width ?? 0, 200, accuracy: 1.0)
        XCTAssertEqual(receivedRect?.height ?? 0, 150, accuracy: 1.0)
    }

    func test_reverseDrag_normalizesRect() async throws {
        let controller = ScreenshotOverlayController()
        var receivedRect: CGRect?
        controller.onConfirm = { rect in receivedRect = rect }

        controller._simulateDrag(from: CGPoint(x: 300, y: 250), to: CGPoint(x: 100, y: 100))
        _ = try await controller._simulateConfirm()

        XCTAssertEqual(receivedRect?.width ?? 0, 200, accuracy: 1.0)
        XCTAssertEqual(receivedRect?.height ?? 0, 150, accuracy: 1.0)
    }

    func test_cancel_invokesOnCancel_notOnConfirm() async {
        let controller = ScreenshotOverlayController()
        let cancelExp = expectation(description: "onCancel")
        let confirmExp = expectation(description: "onConfirm not called")
        confirmExp.isInverted = true

        controller.onConfirm = { _ in confirmExp.fulfill() }
        controller.onCancel = { cancelExp.fulfill() }

        controller._simulateDrag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 250))
        controller._simulateCancel()

        await fulfillment(of: [cancelExp, confirmExp], timeout: 2.0)
    }

    func test_minSelection_throwsOnTinyRect() async {
        let controller = ScreenshotOverlayController()
        // 5×5 pt < 8pt 阈值
        controller._simulateDrag(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 5, y: 5))

        do {
            _ = try await controller._simulateConfirm()
            XCTFail("选区 < 8pt 应抛错（C-MIN-SELECTION）")
        } catch {
            // 预期抛错
        }
    }

    func test_noCallbacks_noCrash() async throws {
        let controller = ScreenshotOverlayController()
        controller._simulateDrag(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 50, y: 50))
        _ = try await controller._simulateConfirm()  // 不 crash
        controller._simulateCancel()                  // 不 crash
    }
}
