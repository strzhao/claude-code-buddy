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
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: dotSpacing) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(LauncherTheme.primary)
                        .frame(width: dotSize, height: dotSize)
                        .scaleEffect(dotScale(t: t, index: index))
                }
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
