import AppKit
import CoreGraphics
import ScreenCaptureKit
import Foundation

/// 截屏捕获 seam 协议（C-CAPTURE-SEAM 契约）。
///
/// 生产实现封装原生 `SCScreenshotManager.captureImage`（macOS 14+），按物理像素捕获指定区域；
/// 测试注入 Mock（绝不触发真实 SCScreenshotManager / 真实 TCC 弹窗）。
///
/// 坐标系约定（C-RETINA-COORDS）：
/// - 入参 `rect` 是全局显示器坐标系下的逻辑坐标（points）；
/// - 实现内部按目标屏幕 `backingScaleFactor` 转 physical pixels 喂 `SCScreenshotManager`；
/// - 返回 PNG `Data`；失败抛 `LauncherError`（权限拒绝 / 捕获失败 / 空区域）。
protocol ScreenCapturing {
    /// 捕获指定矩形区域（全局 points 坐标系），返回 PNG `Data`。
    /// - Throws: `LauncherError`（权限拒绝 / 捕获失败 / 空区域），由调用方降级处理（不崩）。
    func captureArea(_ rect: CGRect) async throws -> Data
}

// MARK: - 生产实现（macOS 14+，原生 SCScreenshotManager）

/// 原生 `SCScreenshotManager` 封装：按目标显示器 `backingScaleFactor` 转 physical pixels，
/// 调 `captureImage(contentFilter:configuration:)` 拿 `CGImage` → PNG `Data`。
///
/// @MainActor：避免跨 actor 持有 CGImage/SCShareableContent 的 Sendable 风险，全程主线程编排。
@MainActor
struct SCScreenCapture: ScreenCapturing {

    func captureArea(_ rectInPoints: CGRect) async throws -> Data {
        // 空区域直接拒绝
        guard rectInPoints.width > 0, rectInPoints.height > 0 else {
            throw LauncherError.systemCommandFailed("截屏选区为空")
        }

        // 1. 权限 preflight：未授权抛错（不崩；调用方降级处理）
        guard await ScreenRecordingPermission.status() == .granted else {
            throw LauncherError.systemCommandFailed("屏幕录制权限未授予")
        }

        // 2. 找到选区所在显示器（取交集最大的那块），用于读 backingScaleFactor
        guard let targetDisplay = Self.displayContaining(rectInPoints) else {
            throw LauncherError.systemCommandFailed("未找到包含选区的显示器")
        }
        let scale = targetDisplay.backingScaleFactor  // 2.0 on Retina, 1.0 otherwise

        // 3. points → physical pixels
        let physicalRect = CGRect(
            x: rectInPoints.origin.x * scale,
            y: rectInPoints.origin.y * scale,
            width: rectInPoints.width * scale,
            height: rectInPoints.height * scale
        )

        // 4. 拿 SCShareableContent（仅目标显示器，避免全屏 capture 把所有屏一次性拉进来）
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false)
        } catch {
            BuddyLogger.shared.error(
                "screenshot 捕获失败：无法获取屏幕内容",
                subsystem: "builtin",
                meta: ["error": "\(error)"]
            )
            throw LauncherError.systemCommandFailed("无法获取屏幕内容")
        }

        guard let display = content.displays.first(where: { d in
            // SCDisplay.frame 在全局坐标系（points），与 NSScreen 一致
            d.frame.contains(rectInPoints.origin)
                || d.frame.intersects(rectInPoints)
        }) else {
            BuddyLogger.shared.error(
                "screenshot 捕获失败：未找到包含选区的显示器",
                subsystem: "builtin",
                meta: ["rect": "\(rectInPoints)"]
            )
            throw LauncherError.systemCommandFailed("未找到包含选区的显示器")
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        // SCScreenshotManager 用 width/height 决定输出尺寸；源裁剪由 captureImage 内部完成。
        // 这里把物理像素矩形作为 source rect + destination size 一起设置（源 = 目标，1:1 像素）。
        config.width = Int(physicalRect.width.rounded())
        config.height = Int(physicalRect.height.rounded())
        // sourceRect 在 display 自身坐标系（display.frame.origin 平移到 0,0），points。
        let sourceRectInDisplay = CGRect(
            x: physicalRect.origin.x - display.frame.origin.x * scale,
            y: physicalRect.origin.y - display.frame.origin.y * scale,
            width: physicalRect.width,
            height: physicalRect.height
        )
        config.sourceRect = sourceRectInDisplay

        // 5. captureImage（macOS 14+）
        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
        } catch {
            BuddyLogger.shared.error(
                "screenshot 捕获失败：captureImage 抛错",
                subsystem: "builtin",
                meta: ["error": "\(error)"]
            )
            throw LauncherError.systemCommandFailed("captureImage 失败")
        }

        // 6. CGImage → PNG Data
        guard let pngData = Self.pngData(from: image) else {
            BuddyLogger.shared.error(
                "screenshot 捕获失败：CGImage → PNG 转换失败",
                subsystem: "builtin",
                meta: ["cgImageWidth": image.width, "cgImageHeight": image.height]
            )
            throw LauncherError.systemCommandFailed("CGImage → PNG 转换失败")
        }

        BuddyLogger.shared.info(
            "screenshot 捕获成功",
            subsystem: "builtin",
            meta: [
                "ptW": rectInPoints.width, "ptH": rectInPoints.height,
                "scale": scale,
                "bytes": pngData.count
            ]
        )
        return pngData
    }

    // MARK: - Helpers

    /// 找到包含 `rect`（取交集最大）的 NSScreen；找不到返回 main screen 或 nil。
    private static func displayContaining(_ rect: CGRect) -> NSScreen? {
        let screens = NSScreen.screens
        // 取与 rect 交集面积最大的屏
        var best: NSScreen?
        var bestArea: CGFloat = 0
        for screen in screens {
            let intersection = screen.frame.intersection(rect)
            if !intersection.isNull {
                let area = intersection.width * intersection.height
                if area > bestArea {
                    bestArea = area
                    best = screen
                }
            }
        }
        return best ?? NSScreen.main
    }

    /// CGImage → PNG `Data`（用 NSBitmapImageRep）。
    private static func pngData(from image: CGImage) -> Data? {
        let bitmapRep = NSBitmapImageRep(cgImage: image)
        return bitmapRep.representation(
            using: .png,
            properties: [:]
        )
    }
}

// MARK: - 测试 Mock

/// 测试用 `ScreenCapturing` Mock（C-CAPTURE-SEAM）。
/// 记录最后一次入参的 rect，可配置返回值（默认返回固定 PNG 字节，不真捕获）。
@MainActor
final class MockScreenCapturing: ScreenCapturing {
    /// 上次调用入参（用于断言 Retina 坐标 / 选区正确性）。
    private(set) var lastCaptureRect: CGRect?
    /// 调用次数。
    private(set) var callCount: Int = 0
    /// 可配置返回值；默认返回固定 PNG 字节（非 nil，模拟捕获成功）。
    var stubbedData: Data = Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,  // PNG signature
    ])
    /// 是否模拟抛错（权限拒绝等）。非 nil 时抛该错误。
    var stubbedError: Error?

    func captureArea(_ rectInPoints: CGRect) async throws -> Data {
        lastCaptureRect = rectInPoints
        callCount += 1
        if let error = stubbedError {
            throw error
        }
        return stubbedData
    }
}
