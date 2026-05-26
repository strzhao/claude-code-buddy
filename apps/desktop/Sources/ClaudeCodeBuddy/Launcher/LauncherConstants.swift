import Foundation

enum LauncherConstants {
    static let windowWidth: CGFloat = 600
    static let windowMinHeight: CGFloat = 80
    static let windowMaxHeight: CGFloat = 600
    static let windowYRatio: CGFloat = 0.3       // 屏幕高度 30% 处（视觉黄金分割）
    static let maxQueryLength: Int = 8000
    static let hotkeyProbeTimeoutMs: Int = 1000
    static let hotkeyProbeCompletedKey = "launcher.hotkeyProbeCompleted"

    // 配置目录与文件路径（task 002 追加）
    static let buddyDir: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".buddy")
    static let launcherConfigPath: URL = buddyDir.appendingPathComponent("launcher.json")
    static let encryptedSecretsPath: URL = buddyDir.appendingPathComponent("launcher-secrets.enc")

    // Provider HTTP（task 002 追加）
    static let httpTimeoutSec: TimeInterval = 120
    static let minAPIKeyLength: Int = 8

    // Keychain（task 002 追加）
    static let keychainService = "claude-code-buddy.launcher"
}
