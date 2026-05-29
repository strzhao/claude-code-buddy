import SwiftUI

/// 底部状态栏（C5 契约）：根据 LauncherStage 动态显示执行状态文案
/// .idle 时返回 EmptyView，不占高度
struct LauncherStatusFooter: View {
    let stage: LauncherStage
    let pluginName: String?

    var body: some View {
        // 运行中状态已由输入框右侧 pulse dots 表达，footer 仅在错误态显示
        // （narrowing/routing 极短不显眼，calling/streaming 与 pulse dots 重复占空间）
        switch stage {
        case .error:
            footerRow("执行失败", color: Color(nsColor: .systemRed))
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func footerRow(_ text: String, color: Color) -> some View {
        HStack {
            Text(text)
                .font(LauncherTheme.statusFooter)
                .foregroundStyle(color)
                .padding(.horizontal, LauncherConstants.inputPaddingH)
            Spacer()
        }
        .frame(height: LauncherConstants.statusFooterHeight)
    }
}
