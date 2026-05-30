---
name: swiftui-frame-nshosting-controller-resize
description: SwiftUI root view 缺 explicit frame 时 NSHostingController 把 NSPanel resize 到 ~40×40 内容最小尺寸；snapshot 测试用复制粘贴 Preview wrapper + assertSnapshot(size:) 会掩盖此 bug
metadata:
  type: pattern
---

# SwiftUI 缺 .frame 让 NSHostingController 把 panel 缩到内容最小尺寸

## 现象

`LauncherWindow` (NSPanel) init 时 contentRect=720×90，但召唤后实际显示 ~40×40 的小面板，里面文字 placeholder/border/shadow 都看不见。所有 ZStack 子视图渲染了，但 panel content frame 被裁剪到几乎不可见。

## 根因

```swift
// 蓝队首版（有 bug）
var body: some View {
    ZStack(alignment: .top) {
        RoundedRectangle(cornerRadius: 14).fill(canvas)  // 内层依靠 ZStack 框
            .overlay(strokeBorder)
            .shadow(...)
        VStack(spacing: 0) {                              // 没有 .frame
            TextField("Ask...", text: $query)             // intrinsic ~width=0 + padding
                .padding(.horizontal, 20).padding(.vertical, 16)
            ...
        }
    }
    // 没有 .frame
}
```

SwiftUI 推断：
- TextField 空字符串 intrinsic width = 0
- VStack alignment .leading 无 frame → 收缩到 child intrinsic = padding 总和 ≈ 40 宽
- ZStack 包裹 → 跟 child 最大 = 40×40
- RoundedRectangle 没有 frame 也跟着收缩到 40×40

NSHostingController 默认 `sizingOptions = .preferredContentSize`，**会把 NSWindow content frame resize 成 SwiftUI root view intrinsic size**。结果 panel.contentRect 被覆盖为 40×40，init 时设的 720×90 失效。

## 修复

```swift
var body: some View {
    VStack(alignment: .leading, spacing: 0) {
        TextField("Ask...", text: $query)
            .padding(...)
            .frame(maxWidth: .infinity, alignment: .leading)  // 撑满 VStack 宽
        ...
    }
    .frame(                                                    // ⭐ 显式 root frame
        width: LauncherConstants.windowWidth,
        height: LauncherInputView.panelHeight(...),
        alignment: .top
    )
    .background(                                               // 改 .background modifier
        RoundedRectangle(cornerRadius: 14).fill(canvas)
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(borderPixel, lineWidth: 2))
    )
    .shadow(color: shadowPixel, radius: 0, x: 4, y: 4)
}
```

关键点：
1. **root view 必须有 explicit `.frame(width:, height:)`** — 即使 NSPanel init 时设了 contentRect 也不够，hosting controller 会按 SwiftUI intrinsic 反向覆盖
2. **背景 RoundedRectangle 放 `.background` modifier 而不是 ZStack 底层** — `.background` 自动跟随 view 的 frame 形状，无需独立 frame 约束
3. **TextField 加 `.frame(maxWidth: .infinity)`** 让内容撑满 VStack，避免被推断为 intrinsic 0 宽

## Snapshot 测试为什么没发现

snapshot 测试自带一个 `LauncherInputViewPreview` wrapper（与生产 view body 复制粘贴的并行实现），hosting controller 通过：

```swift
hostingController.view.frame = NSRect(x: 0, y: 0, width: 720, height: 90)
assertSnapshot(of: hostingController, as: .image(size: CGSize(width: 720, height: 90)))
```

`assertSnapshot(size:)` 强制截图尺寸为 720×90，**无视 SwiftUI root view 实际推断的 intrinsic size**，所以 snapshot 测试通过但生产 panel 实际尺寸是 40×40。

qa-reviewer 在 design 阶段曾标记此风险（"Preview 是与生产代码并行的复制粘贴实现，body 若不同步会测非预期状态"），但没作为 BLOCKER。这次 user 实跑 `make run` + ⌃Space 视觉发现才暴露。

## Lesson

- **SwiftUI root view 在 NSHostingController 嵌入 NSPanel 时必须有 explicit frame**。NSPanel init 时设的 contentRect 不是真理，会被 SwiftUI intrinsic 覆盖。
- **snapshot 测试用复制粘贴 wrapper + `assertSnapshot(size:)` 不能验证 SwiftUI layout 自适应** — 它只验证渲染像素，无法验证 hosting controller 的 panel size 推断行为。补救：用 `XCTAssertEqual(hostingController.view.intrinsicContentSize, ...)` 或直接断言 NSPanel.frame.size。
- **重构 ZStack 为 VStack + `.background` modifier** 比让 background 和 content 都在 ZStack 内更稳，因为 `.background` 形状自动 follow view frame，无独立 frame 约束需求。

## Related

- [[2026-05-26 LSUIElement app 中的浮窗输入框用 NSPanel + nonactivatingPanel + NSApp.activate]]
- [[swiftui-nspanel-dynamic-color-bridge]]
