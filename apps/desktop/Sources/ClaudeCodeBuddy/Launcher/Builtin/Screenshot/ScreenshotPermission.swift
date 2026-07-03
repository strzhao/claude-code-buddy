import AppKit
import CoreGraphics
import Foundation

/// Screen Recording 权限检测 + 引导（macOS 14+）。
///
/// 项目首次引入 Screen Recording TCC。设计原则（契约 ACC-SCREENSHOT-4 / C-NO-CRASH）：
/// - preflight：`CGPreflightScreenCaptureAccess`（不弹窗，仅查询）；
/// - request：`CGRequestScreenCaptureAccess`（首次弹一次系统授权对话框）；
/// - 未授权 → 友好降级 + BuddyLogger 记录，**绝不崩**；
/// - 引导跳系统设置由调用方按需触发（`openSystemSettings()`），不在此处主动弹。
enum ScreenRecordingPermission {

    enum Status: String {
        case granted
        case denied
        case unknown   // 查询失败 / API 不可用
    }

    /// 同步授权检查（不弹窗）。perform 闭包（同步签名）用此判断是否 present overlay。
    /// macOS 14+ 用 `CGPreflightScreenCaptureAccess`；老系统返回 false（调用方降级处理）。
    @MainActor
    static func isGrantedSync() -> Bool {
        if #available(macOS 14.0, *) {
            return CGPreflightScreenCaptureAccess()
        }
        return false
    }

    /// 当前授权状态（不弹窗，纯查询）。
    /// macOS 14+ 用 `CGPreflightScreenCaptureAccess`；老系统返回 `.unknown`（不阻塞生产路径降级处理）。
    @MainActor
    static func status() async -> Status {
        // CGPreflightScreenCaptureAccess / CGRequestScreenCaptureAccess 仅 macOS 14+
        if #available(macOS 14.0, *) {
            // preflight：true = 已授权；false = 未授权 / 未决定 / 被拒（无法区分后两者）
            if CGPreflightScreenCaptureAccess() {
                return .granted
            }
            // preflight=false 时不在此处自动弹窗（避免后台静默弹），
            // 由 ScreenshotPlugin.perform 显式调用 requestIfNeeded。
            return .denied
        }
        return .unknown
    }

    /// 请求授权（首次会弹系统对话框；已授权 / 已拒不再弹）。
    /// 返回 true 表示已授权，false 表示仍被拒 / API 不可用。
    @MainActor
    static func requestIfNeeded() async -> Bool {
        if #available(macOS 14.0, *) {
            // 已授权直接返回
            if CGPreflightScreenCaptureAccess() { return true }
            // CGRequestScreenCaptureAccess 会异步弹窗并立即返回 false（用户点完设置后才生效）；
            // 这里触发一次系统授权提示，实际结果下次 status() 复查。
            _ = CGRequestScreenCaptureAccess()
            // 授权对话框是异步的，API 立即返回。返回 preflight 当前状态（通常仍是 false）。
            return CGPreflightScreenCaptureAccess()
        }
        return false
    }

    /// 引导用户跳「系统设置 → 隐私与安全 → 屏幕录制」（macOS 14+ URL scheme）。
    @MainActor
    static func openSystemSettings() {
        let url: URL?
        if #available(macOS 14.0, *) {
            // macOS 14+ 的隐私设置 URL scheme
            url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        } else {
            url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")
        }
        guard let url = url else { return }
        NSWorkspace.shared.open(url)
        BuddyLogger.shared.info(
            "screenshot 引导跳转系统设置（屏幕录制权限）",
            subsystem: "builtin"
        )
    }
}
