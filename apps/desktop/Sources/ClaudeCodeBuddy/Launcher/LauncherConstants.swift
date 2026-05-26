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

    // Plugin 运行时（task 004 追加）
    static let launcherPluginsDir: URL = buddyDir.appendingPathComponent("launcher-plugins")
    static let pluginDefaultTimeoutSec: Int = 30
    static let pluginMaxTimeoutSec: Int = 120
    static let pluginMaxStdoutBytes: Int = 1024 * 1024         // 1 MiB
    static let pluginMaxStderrBytes: Int = 100 * 1024           // 100 KiB
    static let pluginSigkillGraceSec: Int = 5                   // SIGTERM 后等待秒数
    static let pluginRequiredPathMaxCount: Int = 10
    /// PATH 注入前缀（覆盖在 ProcessInfo.processInfo.environment["PATH"] 之前）
    static let pluginPathPrefixes: [String] = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "\(NSHomeDirectory())/.local/bin"
    ]
}
