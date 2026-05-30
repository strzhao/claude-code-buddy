### [2026-05-29] SwiftUI 循环动画作用于派生函数值（如 sin）必须用 TimelineView(.animation)，withAnimation+repeatForever 不循环

<!-- tags: swiftui, animation, withanimation, repeatforever, timelineview, derived-value, scaleeffect, sin, pulse, launcher, periodic-animation -->

**Scenario**: 写 launcher 输入栏的 3 点脉冲动画（C8 视觉契约），第 1 版用 `@State var phase: CGFloat = 0` + `.onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: false)) { phase = 3.0 } }`，每个圆点 `.scaleEffect(sin((phase - offset) * .pi / 1.5))` 想做依次放大的"波浪"。结果 release build 中 3 个圆点显示但完全静止，用户验收 ❌。

**Lesson**: `withAnimation { trigger = N } + .repeatForever` 模式只对"单一可动画属性的单次或往复插值"有效——它把 `trigger` 从旧值插值到新值（0→3.0），`.repeatForever(autoreverses: false)` 让这个**单次插值**循环重放（每次都从 3.0 重新插到 3.0，无变化）。`scaleEffect(sin(phase))` 是派生函数值，SwiftUI 看到的是 scaleEffect 的标量被设了一次（基于 phase 最终值 3.0 的 sin），动画结束后停在那。**循环动画 + 派生函数值必须用 `TimelineView(.animation)` 时间驱动**：

```swift
TimelineView(.animation) { context in
    let t = context.date.timeIntervalSinceReferenceDate
    HStack {
        ForEach(0..<3, id: \.self) { i in
            Circle().scaleEffect(scale(t: t, index: i))
        }
    }
}

private func scale(t: Double, index: Int) -> CGFloat {
    let phase = (t / period) * 2 * .pi
    let offset = Double(index) * (2 * .pi / 3)   // 错开 1/3 周期
    return 1.0 + 0.2 * (sin(phase - offset) + 1.0)
}
```

TimelineView(.animation) 由系统按帧率（typically 60Hz）触发 body 重计算，闭包内基于 `context.date` 每帧重算派生值，scaleEffect 自然连续变化。**判别标准**：动画值是某属性的**单次插值**用 withAnimation，动画值是**时间的连续函数**用 TimelineView。autoreverses 模式（如脉冲红点 1.0↔1.4）withAnimation 仍 OK（值只在两端切换，无派生函数）；但任何 sin/cos/复杂时序都应该 TimelineView。

**Evidence**: task 008 LauncherPulseDots.swift 第 1 版 onAppear+withAnimation 静止 → 用户报告 → autopilot Tier 1.5 ⚠️ 升级 ❌ → auto-fix 重写为 TimelineView(.animation) 时间驱动 → 第 2 轮启动 pid 54230 用户验收 ✅。
