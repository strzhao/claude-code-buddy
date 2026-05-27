import SwiftUI

/// 路由候选列表视图（task 005 新增）
/// 仅在 candidates 非空时显示（设计规约）
struct LauncherCandidateView: View {
    let candidates: [PluginManifest]
    let selectedIndex: Int

    var body: some View {
        if !candidates.isEmpty, selectedIndex < candidates.count {
            let selected = candidates[selectedIndex]
            HStack(spacing: 6) {
                Image(systemName: "puzzlepiece.fill")
                    .foregroundStyle(.tint)
                    .font(.system(size: 11))
                Text(selected.name)
                    .font(.system(size: 11, weight: .medium))
                Text("·")
                    .foregroundStyle(.secondary)
                Text(selected.description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(.regularMaterial)
        }
    }
}
