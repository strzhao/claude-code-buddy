import SwiftUI
import AppKit

/// 内置插件候选行视图（Raycast / Apple HIG 视觉）。
/// 图标 24x24 + title + subtitle。选中态用简洁实色 pill 高亮（无边框/竖条/chevron）。
struct LauncherActionRow: View {
    let action: LauncherAction
    let isSelected: Bool

    var body: some View {
        ZStack(alignment: .leading) {
            // 选中行高亮：纯实色 sage 圆角 pill，内嵌留白，简洁突出（task 011 交互优化）
            if isSelected {
                RoundedRectangle(cornerRadius: 10)
                    .fill(LauncherTheme.instantSelectionFill)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
            }

            HStack(spacing: 10) {
                // App 图标 24x24
                if let nsImage = action.icon {
                    Image(nsImage: nsImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 24, height: 24)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                } else {
                    Image(systemName: "app.dashed")
                        .font(.system(size: 20))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.85) : LauncherTheme.smoke)
                        .frame(width: 24, height: 24)
                }

                // App 名（主标题）：选中态白字加粗，未选中态 ink
                Text(action.title)
                    .font(LauncherTheme.candidateName)
                    .fontWeight(isSelected ? .semibold : .medium)
                    .foregroundStyle(isSelected ? Color.white : LauncherTheme.ink)

                Spacer(minLength: 8)

                // 副标题（目录名 / 类别）
                if let subtitle = action.subtitle {
                    Text(subtitle)
                        .font(LauncherTheme.candidateDesc)
                        .foregroundStyle(isSelected ? Color.white.opacity(0.78) : LauncherTheme.smoke)
                        .lineLimit(1)
                }
            }
            .padding(.leading, 20)
            .padding(.trailing, LauncherConstants.inputPaddingH)
            .frame(height: LauncherConstants.candidateRowHeight)
        }
    }
}
