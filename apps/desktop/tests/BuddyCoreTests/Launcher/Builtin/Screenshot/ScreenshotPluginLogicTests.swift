import XCTest
import AppKit
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

    // MARK: - handleConfirm 流程（overlay.onConfirm 的实现目标，捕获+复制）

    func test_handleConfirm_callsCaptureAndWritesPNG() async throws {
        let spy = CaptureSpy()
        let (copy, pb) = makeIsolatedCopyService()
        let plugin = ScreenshotPlugin(capture: spy, copy: copy)

        // handleConfirm 前 seam 未调、pb 空
        XCTAssertEqual(spy.callCount, 0)
        XCTAssertNil(pb.data(forType: .png))

        await plugin.handleConfirm(CGRect(x: 0, y: 0, width: 100, height: 100))

        // handleConfirm 后 captureArea 被调恰好 1 次 + pb 写 stubPNG
        XCTAssertEqual(spy.callCount, 1)
        XCTAssertEqual(pb.data(forType: .png), spy.stubbedData)
    }

    func test_handleConfirm_permissionDenied_friendlyNoCrashNoCopy() async {
        let spy = CaptureSpy()
        spy.stubbedError = LauncherError.systemCommandFailed("权限未授予")
        let (copy, pb) = makeIsolatedCopyService()
        let plugin = ScreenshotPlugin(capture: spy, copy: copy)

        await plugin.handleConfirm(CGRect(x: 0, y: 0, width: 100, height: 100))

        // 权限拒绝：seam 被调（捕获尝试过）但 pb 未写（友好降级）
        XCTAssertEqual(spy.callCount, 1)
        XCTAssertNil(pb.data(forType: .png), "权限拒绝时 pasteboard 不应被写")
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
