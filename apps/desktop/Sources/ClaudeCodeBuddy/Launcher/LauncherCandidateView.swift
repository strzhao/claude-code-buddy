import SwiftUI

/// 路由候选列表视图（V2 视觉升级：sage 半透明选中态 + SF Symbol 指示符 + 左侧 Capsule 竖条）
/// 仅在 candidates 非空时显示（设计规约）
///
/// 方案 B（C7）：恢复为 command 路由区渲染器，新增 onSelect 回调（点击触发 submit）。
/// 参数类型 [PluginManifest] 不变；不改 instant/pluginCandidates 渲染器。
struct LauncherCandidateView: View {
    let candidates: [PluginManifest]
    let selectedIndex: Int
    /// C7：点击某行 → 触发选中回调（command 路由区点击 submit）
    var onSelect: ((PluginManifest) -> Void)?

    var body: some View {
        if !candidates.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                // 顶部分隔线（统一使用系统 separatorColor）
                Color(nsColor: .separatorColor)
                    .frame(height: 1)

                ForEach(Array(candidates.enumerated()), id: \.offset) { index, candidate in
                    candidateRow(candidate: candidate, index: index)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onSelect?(candidate)
                        }
                        .accessibilityElement()
                        .accessibilityLabel(rowLabel(candidate))
                        .accessibilityAddTraits(.isButton)
                }
            }
        }
    }

    /// AX label（C7：command 候选行可达）
    private func rowLabel(_ c: PluginManifest) -> String {
        [c.name, c.description].joined(separator: " ")
    }

    @ViewBuilder
    private func candidateRow(candidate: PluginManifest, index: Int) -> some View {
        let isSelected = index == selectedIndex
        ZStack(alignment: .leading) {
            // 选中行半透明背景（C2 契约，alpha < 0.25）
            (isSelected ? LauncherTheme.selectionTint : Color.clear)

            HStack(spacing: 0) {
                // 左侧 3pt 宽实色 sage 圆角竖条（C3 契约）
                if isSelected {
                    Capsule()
                        .fill(LauncherTheme.selectionIndicator)
                        .frame(width: 3, height: 32)
                        .padding(.leading, 8)
                } else {
                    // 未选中：留 3+8=11pt 空白占位，保持布局一致
                    Spacer()
                        .frame(width: 11)
                }

                // SF Symbol 指示符：选中行显示 chevron.right.fill，未选中不显示
                if isSelected {
                    Image(systemName: "chevron.right.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(LauncherTheme.primary)
                        .frame(width: 16)
                        .padding(.leading, 4)
                } else {
                    Spacer()
                        .frame(width: 20)
                }

                // plugin 名（14pt medium rounded，原 10pt monospaced 太小）
                Text(candidate.name)
                    .font(LauncherTheme.candidateName)
                    .foregroundStyle(LauncherTheme.ink)

                // 间距
                Spacer()
                    .frame(width: 8)

                // 描述
                Text(candidate.description)
                    .font(LauncherTheme.candidateDesc)
                    .foregroundStyle(LauncherTheme.smoke)
                    .lineLimit(1)

                Spacer()
            }
            .padding(.trailing, LauncherConstants.inputPaddingH)
            .frame(height: LauncherConstants.candidateRowHeight)
        }
    }
}
