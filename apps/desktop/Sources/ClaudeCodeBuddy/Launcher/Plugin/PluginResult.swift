import Foundation

struct PluginResult: Equatable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
    let durationMs: Int
    let stdoutTruncated: Bool   // 是否被 1 MiB 截断
}
