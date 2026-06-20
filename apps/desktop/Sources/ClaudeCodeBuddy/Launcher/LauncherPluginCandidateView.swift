import SwiftUI

/// command/stdin mode 插件候选输出通道的候选列表（C1/C5）。
///
/// 渲染 `AgentEvent.candidates` 收集的 `[LauncherCandidate]`，每行显示 title + subtitle，
/// ↑↓ 导航 + Enter 选中触发 `submitWithCandidate` 回调。沿用 Raycast 视觉语言（对称
/// LauncherInstantCandidateView），与 instant 候选分时显示。
///
/// 场景1/2/3：qzh 查询返回 stop/start 候选；用户选中 → 回调执行（执行权留插件，C5）。
struct LauncherPluginCandidateView: View {
    let candidates: [LauncherCandidate]
    let selectedIndex: Int
    /// 点击某行 → 触发选中（C5 回调）
    let onSelect: (LauncherCandidate) -> Void

    var body: some View {
        if !candidates.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                // 顶部分隔线（统一使用系统 separatorColor）
                Color(nsColor: .separatorColor)
                    .frame(height: 1)

                ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                    LauncherPluginCandidateRow(
                        candidate: candidate,
                        isSelected: index == selectedIndex
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onSelect(candidate)
                    }
                    .accessibilityElement()
                    .accessibilityLabel(rowLabel(candidate))
                    .accessibilityAddTraits(.isButton)
                }
            }
        }
    }

    /// AX label（场景1.P1/2.P3/3.P3：状态项 / 打开 / 关闭 节点可达）
    private func rowLabel(_ c: LauncherCandidate) -> String {
        [c.title, c.subtitle].compactMap { $0 }.joined(separator: " ")
    }
}

/// 单行候选（title + 可选 subtitle，选中态 sage 高亮）。
struct LauncherPluginCandidateRow: View {
    let candidate: LauncherCandidate
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(candidate.title)
                .font(LauncherTheme.bodyText)
                .foregroundStyle(LauncherTheme.ink)
            if let sub = candidate.subtitle {
                Text(sub)
                    .font(LauncherTheme.footerMono)
                    .foregroundStyle(LauncherTheme.smoke)
            }
            Spacer()
        }
        .padding(.horizontal, LauncherConstants.inputPaddingH)
        .frame(height: LauncherConstants.candidateRowHeight)
        .background(isSelected ? LauncherTheme.primary.opacity(0.18) : Color.clear)
    }
}
