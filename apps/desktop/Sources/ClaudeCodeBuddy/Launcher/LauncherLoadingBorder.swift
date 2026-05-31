import SwiftUI

/// loading 态边框单彗星流光（取代旧的 `LauncherPulseDots` + "正在处理" 文案）。
///
/// 沿面板圆角边框「周长弧长」匀速跑一道带渐变拖尾的彗星：流光叠在面板既有
/// `innerHighlight` 边框线上流动，覆盖即提亮、离开即回落 —— 整圈始终只有「一条」边框线。
///
/// 设计要点：
/// - **周长弧长参数化**（`RoundedRectPerimeter`）：把圆角矩形展开成 `弧长 s → (x,y)`，
///   头部 `s_head(t) = P · frac(t/T)` 匀速前进。⚠️ 刻意不用 `AngularGradient`/conic：
///   宽扁矩形按「角度」上色会同时点亮上、下两条边，看起来像有两道光。
/// - **单次 stroke + 沿线 linearGradient**：彗星是一条连续 `Path`，一次描边，渐变负责
///   头亮→尾透。多段独立 stroke + round cap 互相叠加会在接缝处变亮，看起来像一串珠子。
/// - **测试冻结铁律**（见 apps/desktop/CLAUDE.md 坑 2）：`RuntimeEnvironment.isRunningTests`
///   下渲染静态首帧，绝不启动 `TimelineView(.animation)` 逐帧循环，否则 host 进测试窗口后
///   残留会把 CFRunLoop 拖入 100% CPU 空转（swift test 偶发挂死数小时的根因）。
/// - **reduce-motion**：不流动，退化为静态首帧。
struct LauncherLoadingBorder: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // 流光参数（用户实机确认定档：粗/亮/带发光 — "效果不错"那版）
    private let period: Double = 2.0            // T：一圈周期（秒）
    private let tailFraction: CGFloat = 0.32    // 尾长 = tailFraction × 周长
    private let maxAlpha: Double = 1.0          // αmax（峰值不透明度）
    private let lineWidth: CGFloat = 2.5        // 线宽
    private let glowRadius: CGFloat = 6         // 发光半径，0=无
    private let cornerRadius: CGFloat = LauncherTheme.panelCornerRadius

    var body: some View {
        Group {
            if RuntimeEnvironment.isRunningTests || reduceMotion {
                // 测试 / reduce-motion：静态首帧，不启动逐帧循环
                Canvas { context, size in
                    var ctx = context
                    draw(into: &ctx, size: size, t: 0, animate: false)
                }
            } else {
                TimelineView(.animation) { timeline in
                    Canvas { context, size in
                        var ctx = context
                        let t = timeline.date.timeIntervalSinceReferenceDate
                        draw(into: &ctx, size: size, t: t, animate: true)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func draw(into ctx: inout GraphicsContext, size: CGSize, t: Double, animate: Bool) {
        // inset 对齐既有 innerHighlight strokeBorder（lineWidth 1 → 半宽 0.5；这里取彗星半宽，
        // 使彗星居中盖在那条线上，sub-pixel 误差不会产生可见双线）
        let inset = lineWidth / 2
        let perimeter = RoundedRectPerimeter(size: size,
                                             radius: cornerRadius - inset,
                                             inset: inset)
        let total = perimeter.length
        guard total > 0 else { return }

        let head = animate ? total * CGFloat(frac(t / period)) : 0
        let tail = total * tailFraction

        // 彗星：从头部向尾部回采样成一条连续 Path
        let sampleCount = 90
        var comet = Path()
        let headPoint = perimeter.point(at: head)
        comet.move(to: headPoint)
        for i in 1...sampleCount {
            let s = head - tail * CGFloat(i) / CGFloat(sampleCount)
            comet.addLine(to: perimeter.point(at: s))
        }
        let tailPoint = perimeter.point(at: head - tail)

        // 沿线渐变：头 αmax → 中 0.4αmax → 尾 0（连续淡出，无珠子）
        let shading = GraphicsContext.Shading.linearGradient(
            Gradient(stops: [
                .init(color: LauncherTheme.primary.opacity(maxAlpha), location: 0),
                .init(color: LauncherTheme.primary.opacity(maxAlpha * 0.4), location: 0.5),
                .init(color: LauncherTheme.primary.opacity(0), location: 1)
            ]),
            startPoint: headPoint,
            endPoint: tailPoint
        )
        if glowRadius > 0 {
            ctx.addFilter(.shadow(color: LauncherTheme.primary.opacity(maxAlpha * 0.7),
                                  radius: glowRadius))
        }
        ctx.stroke(comet,
                   with: shading,
                   style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
    }

    private func frac(_ x: Double) -> Double { x - floor(x) }
}

// MARK: - 圆角矩形周长参数化

/// 把圆角矩形边框展开为「弧长 s → 点(x,y)」，供沿边框匀速运动使用。
/// 周长 P = 2(w+h) − 8r + 2πr（四直边 + 四个 1/4 圆弧）。
private struct RoundedRectPerimeter {
    let length: CGFloat
    private let segments: [Segment]

    private struct Segment {
        let len: CGFloat
        let at: (CGFloat) -> CGPoint   // u∈[0,1] → 点
    }

    init(size: CGSize, radius: CGFloat, inset: CGFloat) {
        let w = size.width - 2 * inset
        let h = size.height - 2 * inset
        let r = max(0, min(radius, min(w, h) / 2))
        let xL = inset, xR = inset + w, yT = inset, yB = inset + h

        func line(_ a: CGPoint, _ b: CGPoint) -> Segment {
            Segment(len: hypot(b.x - a.x, b.y - a.y)) { u in
                CGPoint(x: a.x + (b.x - a.x) * u, y: a.y + (b.y - a.y) * u)
            }
        }
        func arc(_ c: CGPoint, _ a0: CGFloat, _ a1: CGFloat) -> Segment {
            Segment(len: abs(a1 - a0) * r) { u in
                let a = a0 + (a1 - a0) * u
                return CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
            }
        }

        // 顺时针：上边 → 右上弧 → 右边 → 右下弧 → 下边 → 左下弧 → 左边 → 左上弧
        segments = [
            line(CGPoint(x: xL + r, y: yT), CGPoint(x: xR - r, y: yT)),
            arc(CGPoint(x: xR - r, y: yT + r), -.pi / 2, 0),
            line(CGPoint(x: xR, y: yT + r), CGPoint(x: xR, y: yB - r)),
            arc(CGPoint(x: xR - r, y: yB - r), 0, .pi / 2),
            line(CGPoint(x: xR - r, y: yB), CGPoint(x: xL + r, y: yB)),
            arc(CGPoint(x: xL + r, y: yB - r), .pi / 2, .pi),
            line(CGPoint(x: xL, y: yB - r), CGPoint(x: xL, y: yT + r)),
            arc(CGPoint(x: xL + r, y: yT + r), .pi, .pi * 1.5)
        ]
        length = segments.reduce(0) { $0 + $1.len }
    }

    /// 弧长 s（可超出 [0,P) / 为负，自动绕回）→ 边框上的点
    func point(at s: CGFloat) -> CGPoint {
        guard length > 0 else { return .zero }
        var rem = s.truncatingRemainder(dividingBy: length)
        if rem < 0 { rem += length }
        for seg in segments {
            if rem <= seg.len { return seg.at(seg.len == 0 ? 0 : rem / seg.len) }
            rem -= seg.len
        }
        return segments.first?.at(0) ?? .zero
    }
}
