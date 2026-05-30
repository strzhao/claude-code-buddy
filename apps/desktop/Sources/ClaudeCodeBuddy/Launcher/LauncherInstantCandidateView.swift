import SwiftUI

/// 内置插件即时候选列表（task 011）。
/// 渲染 LauncherAction 候选行（带图标），沿用 Raycast 视觉语言。
/// 与 LauncherCandidateView（外部 CLI 插件候选）分时显示，互不混排。
struct LauncherInstantCandidateView: View {
    let actions: [LauncherAction]
    let selectedIndex: Int

    var body: some View {
        if !actions.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                // 顶部分隔线（统一使用系统 separatorColor）
                Color(nsColor: .separatorColor)
                    .frame(height: 1)

                ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                    LauncherActionRow(
                        action: action,
                        isSelected: index == selectedIndex
                    )
                }
            }
        }
    }
}
