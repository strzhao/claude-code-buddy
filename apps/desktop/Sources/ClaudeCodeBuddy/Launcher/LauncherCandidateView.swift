import SwiftUI

/// 路由候选列表视图（UI 重设计：44px row + sage 选中态 + 像素风格）
/// 仅在 candidates 非空时显示（设计规约）
struct LauncherCandidateView: View {
    let candidates: [PluginManifest]
    let selectedIndex: Int

    var body: some View {
        if !candidates.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                // 顶部分隔线
                LauncherTheme.borderPixel.opacity(0.4)
                    .frame(height: 1)

                ForEach(Array(candidates.enumerated()), id: \.offset) { index, candidate in
                    candidateRow(candidate: candidate, index: index)
                }
            }
        }
    }

    @ViewBuilder
    private func candidateRow(candidate: PluginManifest, index: Int) -> some View {
        let isSelected = index == selectedIndex
        // AI 推荐 badge：selectedIndex >= 0（非哨兵）且是当前 AI 选中行（C7 契约）
        let isAIPick = selectedIndex >= 0 && index == selectedIndex
        HStack(spacing: 8) {
            // 指示符：选中 ▶ / 未选 ◯
            Text(isSelected ? "\u{25B6}" : "\u{25EF}")
                .font(LauncherTheme.badgeMono)
                .foregroundStyle(isSelected ? LauncherTheme.selectedText : LauncherTheme.smoke)
                .frame(width: 16)

            // badge：plugin name uppercase
            Text(candidate.name.uppercased())
                .font(LauncherTheme.badgeMono)
                .foregroundStyle(isSelected ? LauncherTheme.selectedText : LauncherTheme.ink)

            // 描述
            Text(candidate.description)
                .font(LauncherTheme.candidateDesc)
                .foregroundStyle(isSelected ? LauncherTheme.selectedText : LauncherTheme.smoke)
                .lineLimit(1)

            Spacer()

            // AI 推荐标签（仅 AI 选中行显示；C7 契约）
            if isAIPick {
                Text("✨ AI")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(LauncherTheme.primary)
            }
        }
        .padding(.horizontal, LauncherConstants.inputPaddingH)
        .frame(height: LauncherConstants.candidateRowHeight)
        .background(isSelected ? LauncherTheme.primary : Color.clear)
    }
}
