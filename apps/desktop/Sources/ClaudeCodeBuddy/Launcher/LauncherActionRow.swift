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
                // 图标槽位 24x24（D1 渲染优先级：icon(NSImage) → iconEmoji(Text) → SF Symbol fallback）
                if let nsImage = action.icon {
                    Image(nsImage: nsImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 24, height: 24)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                } else if let emoji = action.iconEmoji {
                    // 插件候选 emoji 图标（C-ICON-FIELD）：Text 渲染，居中于 24×24 槽位
                    // 超长 icon 值防溢出：单行 + 自适应缩放
                    Text(emoji)
                        .font(.system(size: 17))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .frame(width: 24, height: 24)
                } else if action.pluginId == "app-launcher" {
                    // app 行 fallback（现状不变，C-NO-REGRESS①）
                    Image(systemName: "app.dashed")
                        .font(.system(size: 20))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.85) : LauncherTheme.smoke)
                        .frame(width: 24, height: 24)
                } else {
                    // 插件候选统一 SF Symbol fallback（D1：全插件一致 puzzlepiece，场景6.P1）
                    Image(systemName: "puzzlepiece")
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
