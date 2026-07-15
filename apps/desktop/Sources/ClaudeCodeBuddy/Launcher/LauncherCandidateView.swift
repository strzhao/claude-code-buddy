import SwiftUI

/// 路由候选列表视图（V2 视觉升级：sage 半透明选中态 + SF Symbol 指示符 + 左侧 Capsule 竖条）
/// 仅在 candidates 非空时显示（设计规约）
///
/// 方案 B（C7）：恢复为 command 路由区渲染器，新增 onSelect 回调（点击触发 submit）。
/// 参数类型 [PluginManifest] 不变；不改 instant/pluginCandidates 渲染器。
struct LauncherCandidateView: View {
    let candidates: [PluginManifest]
    /// C-SCROLL-TO-SELECTION（B1 fallback）：selectedIndex 用 @Binding。
    /// B1 dry-run 证明 onChange(of: let) / .task(id: let) 在 NSHostingView 下不触发——
    /// let 值变化不可观察。@Binding 让值变化在 view 实例生命周期内可观察，onChange 可靠触发 scrollTo。
    /// 生产调用点：Binding 指向 manager.$commandRouteSelectedIndex；非活动区传 .constant(-1)。
    @Binding var selectedIndex: Int
    /// C-ANCHOR-MINIMAL：追踪可视区首行 index，条件式 minimal-scroll（仅越可视边界才滚，.top/.bottom 整行对齐无半 cell）。
    @State private var firstVisibleRow: Int = 0
    /// C7：点击某行 → 触发选中回调（command 路由区点击 submit）
    var onSelect: ((PluginManifest) -> Void)?

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
                            ForEach(Array(candidates.enumerated()), id: \.offset) { index, candidate in
                                candidateRow(candidate: candidate, index: index)
                                    .id(index)   // C-ROW-ID：稳定 index id 支持 scrollTo
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
                    // C-HEIGHT-CONSISTENCY：严格等于 panelHeight 对该区计高公式
                    .frame(height: CGFloat(min(candidates.count, LauncherConstants.candidateVisibleMax)) * LauncherConstants.candidateRowHeight)
                    .scrollIndicators(.hidden)
                    // C-SCROLL-TO-SELECTION + C-ANCHOR-MINIMAL：条件式 minimal-scroll（修 .center 半 cell 抖动）。
                    // 仅选中越过可视边界才滚；.top/.bottom 整行对齐无半 cell；可视内移动不滚（无抖动）。≤T 全展示不滚。
                    // onChange(of: @Binding) 可靠触发（@Binding 值变化在 view 生命周期内可观察）。
                    .onChange(of: selectedIndex) { _, new in
                        LauncherScrollProbe.shared.recordFire(old: selectedIndex, new: new)
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

/// B1 dry-run 诊断 probe：记录 onChange(of: selectedIndex) 是否触发（测试专用，生产不读）。
/// 改造完成后若 onChange 路径可靠可删；若走 fallback 则保留作回归守护。
final class LauncherScrollProbe: ObservableObject {
    static let shared = LauncherScrollProbe()
    @Published var fireCount: Int = 0
    @Published var lastOld: Int = -99
    @Published var lastNew: Int = -99

    private init() {}

    func recordFire(old: Int, new: Int) {
        fireCount += 1
        lastOld = old
        lastNew = new
    }

    func reset() {
        fireCount = 0
        lastOld = -99
        lastNew = -99
    }
}
