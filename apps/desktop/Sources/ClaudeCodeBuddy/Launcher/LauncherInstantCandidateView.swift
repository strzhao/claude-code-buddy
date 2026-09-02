import SwiftUI

/// 统一混排候选列表（task 011 → D6 单列表）。
/// 渲染 LauncherAction 候选行（带图标/emoji），沿用 Raycast 视觉语言；
/// app + 内置 + 社区插件候选混排于同一列表（C-UNIFIED-SCORE）。
struct LauncherInstantCandidateView: View {
    let actions: [LauncherAction]
    /// C-SCROLL-TO-SELECTION（B1 fallback）：selectedIndex 用 @Binding（onChange(of: @Binding) 可靠触发）。
    @Binding var selectedIndex: Int
    /// D5/D6：点击候选行回调（插件行 → 锁定；app/内置行 → 执行，由调用方分流）。nil = 无回调。
    var onRowTap: ((LauncherAction) -> Void)?
    /// C-ANCHOR-MINIMAL：追踪可视区首行 index，条件式 minimal-scroll（仅越可视边界才滚，.top/.bottom 整行对齐无半 cell）。
    @State private var firstVisibleRow: Int = 0

    var body: some View {
        if !actions.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                // 顶部分隔线（C-SEPARATOR-OUTSIDE-SCROLL/I2：留 ScrollView 外层，滚动时固定不随内容滚走）
                Color(nsColor: .separatorColor)
                    .frame(height: 1)

                // C-SCROLL-TO-SELECTION / C-VIEWPORT-THRESHOLD：
                // >8 封顶 8 行 + ScrollViewReader 自动滚选中行；≤8 全展示 scrollTo 为 no-op。
                // 注：instant 区受 builtinActionsLimit=8 截断（永不 >8），滚动路径对 instant inert，
                // candidateVisibleMax=8 对 instant 仅影响全展示（6-8 行原本被 5 裁，现全显）。
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                                LauncherActionRow(
                                    action: action,
                                    isSelected: index == selectedIndex
                                )
                                .id(index)   // C-ROW-ID：稳定 index id 支持 scrollTo
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    onRowTap?(action)
                                }
                                .accessibilityElement()
                                .accessibilityLabel(action.title)
                                .accessibilityAddTraits(.isButton)
                            }
                        }
                    }
                    // C-HEIGHT-CONSISTENCY：严格等于 panelHeight 对该区计高公式
                    .frame(height: CGFloat(min(actions.count, LauncherConstants.candidateVisibleMax)) * LauncherConstants.candidateRowHeight)
                    .scrollIndicators(.hidden)
                    // C-SCROLL-TO-SELECTION + C-ANCHOR-MINIMAL：条件式 minimal-scroll（修 .center 半 cell 抖动）。
                    // 仅选中越过可视边界才滚；.top/.bottom 整行对齐无半 cell；可视内移动不滚（无抖动）。≤T 全展示不滚。
                    // onChange(of: @Binding) 可靠触发（B1 fallback）。
                    // 注：instant 区受 builtinActionsLimit=8 截断（永不 >8），此 onChange 对 instant 实际 inert。
                    .onChange(of: selectedIndex) { _, new in
                        guard new >= 0 else { return }
                        let visibleMax = LauncherConstants.candidateVisibleMax
                        guard actions.count > visibleMax else { return }
                        if new < firstVisibleRow {
                            firstVisibleRow = new
                            proxy.scrollTo(new, anchor: .top)
                        } else if new >= firstVisibleRow + visibleMax {
                            firstVisibleRow = max(0, new - visibleMax + 1)
                            proxy.scrollTo(new, anchor: .bottom)
                        }
                    }
                    .onChange(of: actions.count) { _, _ in
                        firstVisibleRow = 0   // 新查询结果（候选数变），重置可视窗口
                    }
                }
            }
        }
    }
}
