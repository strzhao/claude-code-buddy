import Foundation

struct PluginResult: Equatable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
    let durationMs: Int
    let stdoutTruncated: Bool   // 是否被 1 MiB 截断
    /// prompt mode 下模型通过 attach_action meta tool 声明的按钮（render-only）。
    /// stdin mode 始终为空。
    let actions: [LauncherActionButton]
    /// 图片输出通道（BUDDY_OUTPUT_IMAGE）：子进程写的 PNG Data，nil 表示无图片。
    /// stdin + command mode 共享；向后兼容（现有调用点 image 默认 nil）。
    let image: Data?

    init(
        stdout: String,
        stderr: String,
        exitCode: Int32,
        durationMs: Int,
        stdoutTruncated: Bool,
        actions: [LauncherActionButton] = [],
        image: Data? = nil
    ) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.durationMs = durationMs
        self.stdoutTruncated = stdoutTruncated
        self.actions = actions
        self.image = image
    }
}
