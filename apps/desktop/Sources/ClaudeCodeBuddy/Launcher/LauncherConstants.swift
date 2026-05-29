import Foundation

enum LauncherConstants {
    static let windowWidth: CGFloat = 720
    static let windowMinHeight: CGFloat = 64    // retry 2: 与 inputHeight 对齐，idle 状态无底部空白，TextField 自然垂直居中
    static let windowMaxHeight: CGFloat = 534
    static let windowYRatio: CGFloat = 0.3       // 屏幕高度 30% 处（视觉黄金分割）
    static let maxQueryLength: Int = 8000
    static let hotkeyProbeTimeoutMs: Int = 1000
    static let hotkeyProbeCompletedKey = "launcher.hotkeyProbeCompleted"

    // 输入区尺寸（task 007 追加，UI 重设计）
    static let inputHeight: CGFloat = 64
    static let inputFontSize: CGFloat = 22
    static let inputPaddingH: CGFloat = 20
    static let inputPaddingV: CGFloat = 16
    static let candidateRowHeight: CGFloat = 44
    static let outputMaxHeight: CGFloat = 400
    static let statusFooterHeight: CGFloat = 22

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

    // Router（task 005 追加）
    static let routerMaxCandidates: Int = 5
}
