import Foundation

/// 插件候选输出通道的候选项值类型（BUDDY_OUTPUT_CANDIDATES 通用通道）。
///
/// 契约（state.md ## 契约规约 C2）：
///   - `id`：候选项稳定标识（UI 唯一键，同一次返回内唯一即可）
///   - `title`：主标题（用户可见，UI 行首）
///   - `subtitle`：可选副标题（状态/描述，UI 行次）
///   - `selection`：选中后回传插件的标识字符串
///
/// **安全红线（C2/C5）**：`selection` 仅作标识字符串，**禁含 shell 命令 / 路径**。
/// 执行权始终留在插件——launcher 收到 selection 后通过 `submitWithCandidate` 重入插件，
/// **绝不**直接执行 selection 字段携带的任何命令。
///
/// `Codable/Equatable/Identifiable`：JSON 解码（BUDDY_OUTPUT_CANDIDATES 数组元素）+
/// 单测相等比较 + SwiftUI ForEach id:\.id。
struct LauncherCandidate: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let selection: String
}
