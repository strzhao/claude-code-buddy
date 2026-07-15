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
    /// C-SCROLL-TO-SELECTION（B1 fallback）：selectedIndex 用 @Binding（onChange(of: @Binding) 可靠触发）。
    @Binding var selectedIndex: Int
    /// C-ANCHOR-MINIMAL：追踪可视区首行 index，条件式 minimal-scroll（仅越可视边界才滚，.top/.bottom 整行对齐无半 cell）。
    @State private var firstVisibleRow: Int = 0
    /// 点击某行 → 触发选中（C5 回调）
    let onSelect: (LauncherCandidate) -> Void

    var body: some View {
        if !candidates.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                // 顶部分隔线（C-SEPARATOR-OUTSIDE-SCROLL/I2：留 ScrollView 外层，滚动时固定不随内容滚走）
                Color(nsColor: .separatorColor)
                    .frame(height: 1)

                // C-SCROLL-TO-SELECTION / C-VIEWPORT-THRESHOLD：
                // >8 封顶 8 行 + ScrollViewReader 自动滚选中行；≤8 全展示 scrollTo 为 no-op。
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                                LauncherPluginCandidateRow(
                                    candidate: candidate,
                                    isSelected: index == selectedIndex
                                )
                                .id(index)   // C-ROW-ID：稳定 index id 支持 scrollTo
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
                    // C-HEIGHT-CONSISTENCY：严格等于 panelHeight 对该区计高公式
                    .frame(height: CGFloat(min(candidates.count, LauncherConstants.candidateVisibleMax)) * LauncherConstants.candidateRowHeight)
                    .scrollIndicators(.hidden)   // Raycast 风格无可见滚动条
                    // C-SCROLL-TO-SELECTION + C-ANCHOR-MINIMAL：条件式 minimal-scroll（修 .center 半 cell 抖动）。
                    // 仅选中越过可视边界才滚；.top/.bottom 整行对齐无半 cell；可视内移动不滚（无抖动）。≤T 全展示不滚。
                    // onChange(of: @Binding) 可靠触发（B1 fallback）。
                    .onChange(of: selectedIndex) { _, new in
                        guard new >= 0 else { return }
                        let visibleMax = LauncherConstants.candidateVisibleMax
                        guard candidates.count > visibleMax else { return }
                        if new < firstVisibleRow {
                            firstVisibleRow = new
                            proxy.scrollTo(new, anchor: .top)
                        } else if new >= firstVisibleRow + visibleMax {
                            firstVisibleRow = max(0, new - visibleMax + 1)
                            proxy.scrollTo(new, anchor: .bottom)
                        }
                    }
                    .onChange(of: candidates.count) { _, _ in
                        firstVisibleRow = 0   // 新查询结果（候选数变），重置可视窗口
                    }
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
