import XCTest
@testable import BuddyCore

// MARK: - ScreenshotOverlayHookTests
//
// 红队验收测试：ScreenshotOverlayController 程序化 test hook（C-OVERLAY-TEST-HOOK）
//
// 本切片仅测 overlay 的「拖框选区 + 确认/取消回调」逻辑层（程序化驱动，零 TCC、零真实截图）。
// 不测 overlay 视觉/快照/真机交互（延后到快照层 + XCUITest 真机层）。
//
// 覆盖：
//   - C-OVERLAY-TEST-HOOK：_simulateDrag(from:to:) + _simulateConfirm()/_simulateCancel() 可用
//   - 确认路径：_simulateDrag + _simulateConfirm → onConfirm(CGRect) 被调，收到非空 rect
//   - 取消路径：_simulateCancel → onCancel 被调，onConfirm 未被调
//   - 选区几何：拖框起点终点 → onConfirm 收到的 CGRect 正向归一化（origin/min,size 绝对值）
//
// 红队红线：
//   - 绝不 Read apps/desktop/Sources/ClaudeCodeBuddy/Launcher/Builtin/Screenshot/ 下任何 .swift
//   - 全程序化驱动，不依赖 osascript / XCUITest 鼠标 / 真实屏幕捕获
//   - 不触发 TCC（controller 的 present() 在 headless 测试环境可能 no-op 或仅初始化，不视为副作用）
//
// CONTRACT_AMBIGUOUS:
//   1. onConfirm 签名：契约写 `var onConfirm: ((CGRect) async -> Void)?`。
//      测试用同步哨兵标志位 + XCTestExpectation 验证 async 回调被调。
//   2. _simulateConfirm 是否在未 _simulateDrag 时仍触发（空选区）：
//      按 C-MIN-SELECTION 契约（选区 < 阈值时 Enter 不确认），未拖框应视为空选区不确认。
//      本测试不强制此行为（视蓝队实现），但会断言「拖框后确认」必收到非零 rect。
//   3. controller 是否需 .shared 单例还是直接 init()：契约写 `final class ScreenshotOverlayController`，
//      假设可直接 `ScreenshotOverlayController()` 构造（便于测试隔离）。若蓝队用 .shared 单例，
//      测试改用 .shared（但优先假设可实例化）。
//   4. _simulateDrag 坐标系：CGPoint（屏幕坐标）。测试用任意固定坐标，不依赖真实显示器布局。
//
// 测试 WILL NOT compile 直到蓝队合并实现 — 这是预期的 TDD 红灯。

@MainActor
final class ScreenshotOverlayHookTests: XCTestCase {

    // MARK: - C-OVERLAY-TEST-HOOK：hook 存在性与基本可用

    /// C-OVERLAY-TEST-HOOK: controller 可实例化 + hook 方法存在（编译期验证 + 运行期无 crash）
    func test_HOOK_controllerInstantiable_noCrash() {
        let controller = ScreenshotOverlayController()
        // 仅验证可构造不 crash（hook 方法签名编译期验证）
        XCTAssertNotNil(controller,
            "C-OVERLAY-TEST-HOOK: ScreenshotOverlayController 必须可直接实例化（测试隔离），实际为 nil")
    }

    // MARK: - 确认路径：_simulateDrag + _simulateConfirm → onConfirm 被调

    /// C-OVERLAY-TEST-HOOK: 设 onConfirm → _simulateDrag + _simulateConfirm → onConfirm 被调且收到 CGRect
    ///
    /// Mutation-Survival 自检：
    /// - onConfirm 未触发 mutant → expectation 不 fulfill → 超时失败（捕获）
    /// - 传零 rect mutant → receivedRect 为 zero → 非空断言失败（捕获）
    func test_HOOK_dragAndConfirm_invokesOnConfirmWithRect() async {
        let controller = ScreenshotOverlayController()

        let expectation = XCTestExpectation(description: "onConfirm 被调")
        var receivedRect: CGRect?

        controller.onConfirm = { rect in
            receivedRect = rect
            expectation.fulfill()
        }
        controller.onCancel = { XCTFail("确认路径不应触发 onCancel") }

        // 程序化拖框（任意固定坐标，不依赖真实显示器）
        controller._simulateDrag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 250))
        _ = try? await controller._simulateConfirm()

        await fulfillment(of: [expectation], timeout: 2.0)

        XCTAssertNotNil(receivedRect,
            "C-OVERLAY-TEST-HOOK (mutation-killer): _simulateDrag + _simulateConfirm 后 onConfirm 必须被调并收到 CGRect")
        XCTAssertFalse(receivedRect?.isEmpty ?? true,
            "C-OVERLAY-TEST-HOOK: onConfirm 收到的 CGRect 不能为空（拖框 100,100→300,250 应产出非零选区）")
    }

    // MARK: - 选区几何：onConfirm 收到的 CGRect 与拖框坐标正向归一化一致

    /// C-OVERLAY-TEST-HOOK: 拖框 from→to 后 onConfirm 收到的 rect 经归一化（origin 是 min，size 是绝对值）
    /// 测试反向拖框（从右下到左上）也应归一化为正向 rect
    func test_HOOK_reverseDrag_normalizesRect() async throws {
        let controller = ScreenshotOverlayController()

        let expectation = XCTestExpectation(description: "onConfirm 反向拖框")
        var receivedRect: CGRect?

        controller.onConfirm = { rect in
            receivedRect = rect
            expectation.fulfill()
        }

        // 反向拖框：起点在右下，终点在左上
        controller._simulateDrag(from: CGPoint(x: 300, y: 250), to: CGPoint(x: 100, y: 100))
        _ = try await controller._simulateConfirm()

        await fulfillment(of: [expectation], timeout: 2.0)

        guard let rect = receivedRect else {
            XCTFail("C-OVERLAY-TEST-HOOK precondition: onConfirm 必须被调")
            return
        }

        // 归一化后：origin 应是左上角 (min)，size 为正（绝对值）
        // 拖框 300,250 → 100,100：宽度 200，高度 150
        XCTAssertEqual(rect.width, 200, accuracy: 1.0,
            "C-OVERLAY-TEST-HOOK: 反向拖框归一化后 rect.width 应 == 200（|300-100|），实际 \(rect.width)")
        XCTAssertEqual(rect.height, 150, accuracy: 1.0,
            "C-OVERLAY-TEST-HOOK: 反向拖框归一化后 rect.height 应 == 150（|250-100|），实际 \(rect.height)")
    }

    // MARK: - 取消路径：_simulateCancel → onCancel 被调、onConfirm 未被调

    /// C-OVERLAY-TEST-HOOK: _simulateCancel → onCancel 被调，onConfirm 未被调
    ///
    /// Mutation-Survival 自检：
    /// - cancel 误触 onConfirm mutant → onConfirmExpectation fulfill → 失败（捕获）
    func test_HOOK_cancel_invokesOnCancel_notOnConfirm() async {
        let controller = ScreenshotOverlayController()

        let cancelExpectation = XCTestExpectation(description: "onCancel 被调")
        let onConfirmExpectation = XCTestExpectation(description: "onConfirm 不应被调")
        onConfirmExpectation.isInverted = true

        controller.onConfirm = { _ in
            onConfirmExpectation.fulfill()
        }
        controller.onCancel = {
            cancelExpectation.fulfill()
        }

        // 先拖框（建立选区），再取消
        controller._simulateDrag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 250))
        controller._simulateCancel()

        await fulfillment(of: [cancelExpectation, onConfirmExpectation], timeout: 2.0)

        // onCancel fulfilled + onConfirm 未 fulfilled（isInverted）
        XCTAssertTrue(true,
            "C-OVERLAY-TEST-HOOK: _simulateCancel 后 onCancel 被调，onConfirm 未被调（验证通过）")
    }

    // MARK: - 未设回调不 crash（防御性）

    /// C-OVERLAY-TEST-HOOK: 未设 onConfirm/onCancel 时 _simulateConfirm/_simulateCancel 不 crash
    func test_HOOK_noCallbacks_noCrash() async throws {
        let controller = ScreenshotOverlayController()
        // 不设任何回调

        controller._simulateDrag(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 10, y: 10))
        // _simulateConfirm 在 10×10 选区（>= 8pt 阈值）下应成功；async throws 不能直接进 XCTAssertNoThrow autoclosure
        do {
            _ = try await controller._simulateConfirm()
        } catch {
            XCTFail("C-OVERLAY-TEST-HOOK: 未设 onConfirm 时 _simulateConfirm 不应抛错（回调可选），实际抛：\(error)")
        }
        controller._simulateCancel()  // 不抛错，直接调
    }
}
