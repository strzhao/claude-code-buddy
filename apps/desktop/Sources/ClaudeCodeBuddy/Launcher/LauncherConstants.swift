import Foundation

enum LauncherConstants {
    static let windowWidth: CGFloat = 600
    static let windowMinHeight: CGFloat = 80
    static let windowMaxHeight: CGFloat = 600
    static let windowYRatio: CGFloat = 0.3       // 屏幕高度 30% 处（视觉黄金分割）
    static let maxQueryLength: Int = 8000
    static let hotkeyProbeTimeoutMs: Int = 1000
    static let hotkeyProbeCompletedKey = "launcher.hotkeyProbeCompleted"
}
