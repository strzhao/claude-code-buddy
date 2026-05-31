---
name: swiftui-material-vs-nsvisualeffectview-injection
description: NSVisualEffectView 作为 NSHostingView subview 时被 SwiftUI 渲染层覆盖不可见；macOS 12+ 优先用 SwiftUI .ultraThinMaterial 实现毛玻璃，绑定 SwiftUI 渲染管线天然合成正确
metadata:
  type: pattern
---

# 浮窗毛玻璃：SwiftUI .ultraThinMaterial 优于手动注入 NSVisualEffectView

## 背景

LSUIElement launcher 浮窗（NSPanel + NSHostingController + SwiftUI body）想加 Apple HIG 风毛玻璃。直觉做法是注入 `NSVisualEffectView`：

```swift
// ❌ 看起来对，实际不可见
func installVisualEffect() {
    guard let contentView = contentView else { return }
    let vfx = NSVisualEffectView()
    vfx.material = .popover
    vfx.blendingMode = .behindWindow
    vfx.wantsLayer = true
    vfx.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(vfx, positioned: .below, relativeTo: contentView.subviews.first)
    // ... 4 个 anchor constraint
}
```

结果：毛玻璃完全不显示，panel 看起来是纯透明 + 内容直接飘在桌面上。改 material（`.hudWindow → .popover → .menu`）+ blendingMode（`.behindWindow → .withinWindow`）+ panelTint 多轮调试均无效。

## 为什么不可见

`contentView` 是 `NSHostingController.view`（`NSHostingView<RootView>` 实例）。NSHostingView 内的 SwiftUI 内容通过其 **render layer / display tree** 绘制，与 AppKit 的 `subviews` hierarchy **不在同一渲染路径**。`addSubview(vfx, positioned: .below, ...)` 把 vfx 加到 AppKit subview 链最底层，但 SwiftUI 内容是覆盖在整个 NSHostingView 表面绘制的（即使 SwiftUI body 不显式 `.background()`），vfx 被完全压住，**永远不可见**。

进一步证据：把 panel 拖到不同桌面位置，没有毛玻璃模糊感（如果 vfx 真在工作应能看到背景模糊变化）。

## 正确做法：SwiftUI 原生 Material

macOS 12+ / iOS 15+ 引入 `Material` 类型，是 SwiftUI 原生 vibrancy API（底层仍是 `NSVisualEffectView`）：

```swift
// ✅ 在 SwiftUI 渲染管线内合成，永远可见
.background(
    RoundedRectangle(cornerRadius: 16)
        .fill(.ultraThinMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(LauncherTheme.innerHighlight, lineWidth: 1)
        )
)
```

材质等级（按透明度从高到低）：`.ultraThinMaterial` / `.thinMaterial` / `.regularMaterial` / `.thickMaterial` / `.ultraThickMaterial`。launcher 浮窗用 `.ultraThinMaterial` 既透气又能感知背后桌面色。

优势：
- 圆角天然跟随 `RoundedRectangle`，不需要手动 layer mask
- 自适应 light/dark mode（macOS Material 内置 vibrancy 配色）
- 在 SwiftUI body 内声明，跟随 view frame 自动 resize
- 不需要管 `addSubview` 时序、不需要 contentView didSet 重入

## 兼容性

- macOS 14 target 完全支持
- 如需保留 NSVisualEffectView 注入做某些场景兜底（如 light mode 下增强 vibrancy），可以二者并存——但要明白 SwiftUI Material 是**主毛玻璃**，注入的 vfx 仅是结构性补充

## 判别标准

| 场景 | 选 |
|------|---|
| 容器本身是 SwiftUI view（含 NSHostingController 包裹的 SwiftUI body） | **SwiftUI Material** |
| 容器是纯 AppKit view（NSWindow.contentView 没有 hosting controller） | NSVisualEffectView 注入 |
| 既有 AppKit 又有 SwiftUI 子层，且 SwiftUI 在 vfx 上方 | NSVisualEffectView + 确保 SwiftUI 子层有透明 background |

## Evidence

task 010 launcher UI 升级第 1-5 轮 retry：
- 第 1 轮：NSVisualEffectView 注入 + `.hudWindow` → 用户截图完全透明
- 第 2-4 轮：调整 material（popover/menu）+ blendingMode（behind/within）+ tint 兜底，反复未解决核心问题
- 第 5 轮：意识到 NSHostingView subview 路径不通，改用 `.ultraThinMaterial` → 毛玻璃立即生效

## Lesson

- **macOS 12+ SwiftUI 浮窗的毛玻璃首选 SwiftUI Material，不要手动注入 NSVisualEffectView**
- 调试 NSVisualEffectView 不可见时，不要先怀疑 material / tint / blendingMode；先确认 **vfx 是否在 SwiftUI 渲染管线正确层级**
- 多轮 material/alpha 调试无效是该问题的诊断信号

## Related

- [[2026-05-26 LSUIElement app 中的浮窗输入框用 NSPanel + nonactivatingPanel + NSApp.activate]]
- [[2026-05-28 SwiftUI 跨 NSPanel 桥接 light/dark 颜色用 NSColor(name:dynamicProvider:)]]
- [[swiftui-frame-nshosting-controller-resize]]

---

## ⚠️ 2026-05-31 修正：本结论在 hidesOnDeactivate 浮窗下不成立

上面"SwiftUI Material 优于 NSVisualEffectView"的结论**有反例**，已被实践推翻：

`.ultraThinMaterial` 的 light/dark 解析依赖 `@Environment(\.colorScheme)`。而该 environment 在
**NSPanel + `hidesOnDeactivate=true`** 浮窗里传播不可靠（同 [[swiftui-nspanel-dynamic-color-bridge]] 的根因）——
系统切到**浅色**时 material 仍可能停留深色，导致毛玻璃发灰、与跟随 `effectiveAppearance` 的颜色 token
（白色 surface）错配，**浅色模式整块渲染异常**（用户实测：结果区纯白方块、面板发灰）。

### 正确做法（本场景）：NSVisualEffectView 的 SwiftUI 包装

不是回到"手动 addSubview 注入"（那条路确实不通，上文成立），而是用 `NSViewRepresentable` 包装
`NSVisualEffectView`，**作为 SwiftUI `.background(...)` 使用**——既在 SwiftUI 渲染管线内正确合成
（不被覆盖），又由 AppKit 按 `effectiveAppearance` 求值（绕开不可靠的 colorScheme 传播）：

```swift
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .menu
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material; v.blendingMode = blendingMode; v.state = .active
        v.appearance = nil   // 跟随 effectiveAppearance，不锁 light/dark
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material; v.blendingMode = blendingMode; v.state = .active; v.appearance = nil
    }
}
// 用法：.background(VisualEffectBackground().clipShape(RoundedRectangle(cornerRadius: 16)))
```

### 判别标准（修订）

| 场景 | 选 |
|------|---|
| 普通窗口 / 不随系统主题动态隐藏的 SwiftUI 容器 | SwiftUI `.ultraThinMaterial`（仍最省事） |
| **NSPanel + hidesOnDeactivate / LSUIElement 浮窗** | **NSVisualEffectView 的 NSViewRepresentable 包装**（appearance=nil） |
| 纯 AppKit window（无 hosting controller） | 直接 NSVisualEffectView 注入 |

### Lesson（修订）

- "SwiftUI Material vs NSVisualEffectView" **没有普适胜者**：取决于窗口是否经历 colorScheme 传播不可靠的场景。
- LSUIElement / hidesOnDeactivate 浮窗里，**毛玻璃和颜色 token 都要走 AppKit effectiveAppearance**（Material 走 SwiftUI environment，会与 dynamic NSColor token 错配）。
- 多轮调 material/tint 无效 → 怀疑渲染层级（上文）；**浅深色之一坏掉** → 怀疑 colorScheme environment 传播（本修正）。
