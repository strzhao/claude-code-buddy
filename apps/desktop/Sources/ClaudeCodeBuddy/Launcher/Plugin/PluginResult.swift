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
    /// 候选输出通道（BUDDY_OUTPUT_CANDIDATES）：子进程写的候选 JSON 解码后的数组，nil 表示无候选。
    /// stdin + command mode 共享（非 command 专属）；向后兼容（现有调用点 candidates 默认 nil）。
    /// 失败降级 nil（候选可选，对称 image 通道），见 readCandidatesOutputSafely。
    let candidates: [LauncherCandidate]?

    init(
        stdout: String,
        stderr: String,
        exitCode: Int32,
        durationMs: Int,
        stdoutTruncated: Bool,
        actions: [LauncherActionButton] = [],
        image: Data? = nil,
        candidates: [LauncherCandidate]? = nil
    ) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.durationMs = durationMs
        self.stdoutTruncated = stdoutTruncated
        self.actions = actions
        self.image = image
        self.candidates = candidates
    }
}
