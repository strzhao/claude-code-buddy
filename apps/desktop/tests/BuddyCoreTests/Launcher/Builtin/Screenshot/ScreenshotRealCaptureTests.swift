import XCTest
import AppKit
import CoreGraphics
import ScreenCaptureKit
@testable import BuddyCore

/// 真机 capture+render pipeline 集成测试（覆盖 mock 盲区）。
///
/// 用**真实 `SCScreenCapture`（ScreenCaptureKit）+ 真实 `AnnotationRenderer`（AnnotationKit）+ 编辑器
/// 真实确认路径**（`_simulateDraw`/`_simulateConfirm`），驱动 capture → decode → render → 合成 PNG 全链。
///
/// **为何用 XCTest 而非 app 真机调试**：app 是 ad-hoc 签名（`flags=0x2(adhoc) TeamIdentifier=not set`），
/// 每次 `make bundle` 重打包 cdhash 变 → TCC 失效，app 真机每轮 rebuild 要重授权（与 SC-3 死锁 / TCC
/// request / NSPanel init 同款 mock 盲区，patterns/2026-07-04-swift-async-sync-bridge 记录）。
/// 而 XCTest 进程经**终端**继承屏幕录制授权（终端身份稳定，重编译 cdhash 不变），可反复自跑验证
/// capture/render **代码**，无需 app 重打包 / 手动 GUI / TCC 重授权。
///
/// 无显示器 / 无 TCC 的环境（CI / headless）→ `XCTSkip`（不阻塞其它测试）。
///
/// **覆盖的真路径**（mock 测不出的）：
/// - 真实 `SCScreenshotManager.captureImage` + `SCShareableContent`（含 backingScaleFactor points→physical）
/// - 真实 PNG 解码（`CGImage(pngDataProviderSource:...)`）
/// - 真实 `AnnotationRenderer.render(sourceImage:objects:cropRect:)`（AnnotationKit 合成）
@MainActor
final class ScreenshotRealCaptureTests: XCTestCase {

    /// 真实捕获：`SCScreenCapture.captureArea` → 非空 PNG（带 PNG 签名头）。
    func test_realCapture_returnsNonEmptyPNG() async throws {
        try throwIfNoDisplayOrTCC()

        let rect = realScreenRect()
        let png = try await SCScreenCapture().captureArea(rect)

        XCTAssertGreaterThan(png.count, 500, "真实捕获应返回非空 PNG（>500 bytes），实际 \(png.count)")
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47],
            "PNG 签名头应是 89 50 4E 47")
    }

    /// 真实捕获**大选区**（近全屏）→ 必须不抛 -3812。
    /// 复现真机 bug：旧代码把 physicalRect（pixels）塞进 `config.sourceRect`（要 points），
    /// 大选区时 sourceRect 超 display points 边界 → `SCStreamError -3812 "参数无效"`。
    /// 小 rect 测试（test_realCapture_returnsNonEmptyPNG）没触发——小 rect 的 physicalRect 仍 < 屏 points 边界。
    /// 此测试用近全屏 rect：physicalRect 必然超屏 points → 旧代码 -3812，修复后应成功。
    func test_realCapture_largeRect_nearFullScreen_doesNotThrow() async throws {
        try throwIfNoDisplayOrTCC()

        let f = NSScreen.main!.frame
        // 近全屏选区（四周留 40pt），确保 physicalRect（×2）远超屏 points 边界
        let rect = f.insetBy(dx: 40, dy: 40)
        // captureArea 不应抛错（旧代码此处 -3812）
        let png = try await SCScreenCapture().captureArea(rect)
        XCTAssertGreaterThan(png.count, 500, "大选区捕获应返回非空 PNG，实际 \(png.count)")
    }


    /// 真实 capture → decode → 编辑器真实 render（AnnotationKit RectangleObject）→ 合成 PNG 可解码且尺寸不变。
    /// 这条链复刻生产 `handleConfirm → editor._simulateConfirm` 的 render 路径，只是 capture 用真实屏幕而非 mock。
    func test_realCapture_decode_render_producesCompositePNG() async throws {
        try throwIfNoDisplayOrTCC()

        let rect = realScreenRect()
        let png = try await SCScreenCapture().captureArea(rect)

        // decode PNG → CGImage（复刻 ScreenshotPlugin.cgImage(from:) 私有逻辑）
        guard let provider = CGDataProvider(data: png as CFData),
              let sourceImage = CGImage(
                pngDataProviderSource: provider, decode: nil,
                shouldInterpolate: true, intent: .defaultIntent
              ) else {
            XCTFail("真实捕获的 PNG 解码失败（CGImage 创建返回 nil）"); return
        }
        XCTAssertGreaterThan(sourceImage.width, 0, "源图 width 应 > 0")

        // 编辑器真实 render 路径：create（绑源图）→ draw 真实 RectangleObject → confirm → AnnotationRenderer 合成
        let editor = ScreenshotAnnotationEditor(image: sourceImage)
        let drawFrom = CGPoint(x: 5, y: 5)
        let drawTo = CGPoint(x: max(6, min(45, sourceImage.width - 1)),
                             y: max(6, min(35, sourceImage.height - 1)))
        _ = editor._simulateDraw(tool: .rectangle, from: drawFrom, to: drawTo)
        XCTAssertEqual(editor.document.objects.count, 1,
            "draw 后 document 应含 1 个真实 AnnotationObject（RectangleObject）")

        let rendered = await editor._simulateConfirm()
        guard let compositePNG = rendered else {
            XCTFail("真实 AnnotationRenderer.render 应产出合成 PNG（返回 nil）"); return
        }
        XCTAssertGreaterThan(compositePNG.count, 500, "合成 PNG 非空")

        // 合成 PNG 重新 decode：必须有效且尺寸 == 源图（标注叠加不改尺寸）
        guard let provider2 = CGDataProvider(data: compositePNG as CFData),
              let composite = CGImage(
                pngDataProviderSource: provider2, decode: nil,
                shouldInterpolate: true, intent: .defaultIntent
              ) else {
            XCTFail("合成 PNG 解码失败（CGImage 创建返回 nil）"); return
        }
        XCTAssertEqual(composite.width, sourceImage.width,
            "合成图 width 应 == 源图（标注叠加不改尺寸）")
        XCTAssertEqual(composite.height, sourceImage.height,
            "合成图 height 应 == 源图（标注叠加不改尺寸）")
    }

    // MARK: - Helpers

    /// 取主屏左下角一块真实可捕获矩形（全局 points 坐标，留 10pt 内边距避开边缘）。
    private func realScreenRect() -> CGRect {
        let screen = NSScreen.main!
        let f = screen.frame
        return CGRect(
            x: f.origin.x + 10,
            y: f.origin.y + 10,
            width: min(200, max(50, f.width - 20)),
            height: min(150, max(50, f.height - 20))
        )
    }

    /// 无显示器（CI/headless）或测试进程无屏幕录制授权 → 跳过（不阻塞）。
    /// test env 通常已授权（终端继承屏幕录制），见 test_SC2_permissionDenied 失败原因（request 返回 true）。
    private func throwIfNoDisplayOrTCC() throws {
        guard NSScreen.main != nil else {
            throw XCTSkip("无显示器（CI / headless），跳过真机捕获")
        }
        guard ScreenRecordingPermission.isGrantedSync() else {
            throw XCTSkip("测试进程无屏幕录制授权（终端授权后重跑）")
        }
    }
}
