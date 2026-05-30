import SwiftUI

/// 执行中 3 点脉冲动画（task 008 / C8 契约）
/// 用 TimelineView(.animation) 时间驱动每帧重算 sin，3 个圆点错开 1/3 周期形成"波浪"
struct LauncherPulseDots: View {
    private let period: Double = 0.9
    private let dotSize: CGFloat = 4
    private let dotSpacing: CGFloat = 5
    private let scaleMin: CGFloat = 1.0
    private let scaleMax: CGFloat = 1.4

    var body: some View {
        if RuntimeEnvironment.isRunningTests {
            // 测试/headless：渲染静态首帧，不启动 TimelineView(.animation) 的逐帧循环。
            // 否则动画视图 host 进测试窗口后会残留，后续测试泵 RunLoop 时导致
            // CFRunLoop 无限空转（swift test 偶发挂死数小时的根因）。
            dotsRow(t: 0)
        } else {
            TimelineView(.animation) { context in
                dotsRow(t: context.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    @ViewBuilder
    private func dotsRow(t: Double) -> some View {
        HStack(spacing: dotSpacing) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(LauncherTheme.primary)
                    .frame(width: dotSize, height: dotSize)
                    .scaleEffect(dotScale(t: t, index: index))
            }
        }
    }

    private func dotScale(t: Double, index: Int) -> CGFloat {
        let phase = (t / period) * 2 * .pi
        let offset = Double(index) * (2 * .pi / 3)
        let value = sin(phase - offset)
        let normalized = (value + 1.0) / 2.0
        return scaleMin + (scaleMax - scaleMin) * CGFloat(normalized)
    }
}
