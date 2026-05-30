---
name: swiftui-nspanel-dynamic-color-bridge
description: SwiftUI Color 在 NSPanel + NSHostingController + hidesOnDeactivate 场景下用 Color(nsColor: NSColor(name:dynamicProvider:)) 比 @Environment(\.colorScheme) 更稳，appearance 切换不依赖 SwiftUI environment 传播链
metadata:
  type: pattern
---

# SwiftUI 跨 NSPanel 桥接 light/dark 颜色用 NSColor(name:dynamicProvider:)

## 背景

Launcher UI 重设计需要跟随 macOS 系统主题切换 light/dark：
- light: canvas #f7f6f1, primary sage #3a7d68, shadowPixel #1a1a18
- dark: canvas #0f0f0e, primary sage-light #52a688, shadowPixel #000000

最直觉的 SwiftUI 做法：

```swift
// ❌ 直觉但不稳
enum LauncherTheme {
    static func canvas(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x0f0f0e) : Color(hex: 0xf7f6f1)
    }
}

struct LauncherInputView: View {
    @Environment(\.colorScheme) var colorScheme
    var body: some View {
        Rectangle().fill(LauncherTheme.canvas(colorScheme))
    }
}
```

## 为什么 @Environment(\.colorScheme) 不可靠

`LauncherWindow` 是 NSPanel：
- `styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel]`
- `hidesOnDeactivate = true`
- 通过 NSHostingController 包装 SwiftUI view

macOS NSAppearance 传播链：
1. NSApp.effectiveAppearance（系统设置）
2. → NSWindow.effectiveAppearance
3. → NSHostingController 接收并转换为 SwiftUI Environment
4. → SwiftUI @Environment(\.colorScheme) 读取

问题：当 panel `hidesOnDeactivate=true` 隐藏时，系统主题切换不触发 `viewWillAppear` → NSHostingController 可能不立即更新 environment → 下次召唤显示时 @Environment(\.colorScheme) 仍可能是旧值（实测在某些 macOS 14 场景下复现）。

更广义的问题：SwiftUI environment 在 AppKit 桥接边界依赖手动 invalidate，不是 NSAppearance 系统级响应。

## 正确做法：NSColor(name:dynamicProvider:)

```swift
// ✅ dynamic NSColor 包装为 Color
enum LauncherTheme {
    static let canvas = Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 0x0f/255, green: 0x0f/255, blue: 0x0e/255, alpha: 1)
            : NSColor(srgbRed: 0xf7/255, green: 0xf6/255, blue: 0xf1/255, alpha: 1)
    })
    static let primary = Color(nsColor: NSColor(name: nil) { appearance in ... })
    // ... 其余颜色同理
}

struct LauncherInputView: View {
    var body: some View {
        Rectangle().fill(LauncherTheme.canvas)  // 不需要传 scheme，不需要 @Environment
    }
}
```

机制：
- `NSColor(name:dynamicProvider:)` 是 AppKit 原生 dynamic color，**closure 在每次渲染由 AppKit 按 NSView.effectiveAppearance 调用**
- 跳过 SwiftUI environment 传播链，直接挂载 AppKit 系统级 appearance 响应
- 系统主题切换时 AppKit 自动重绘所有 dynamic color，**无需依赖 hidesOnDeactivate 之后的 environment refresh**
- 子视图直接 `LauncherTheme.canvas` 用，**不再需要每个 view 手动 @Environment(\.colorScheme)**，消除传参冗余

## 测试 dynamic Color

```swift
func test_canvas_lightModeHex() {
    let nsColor = NSColor(LauncherTheme.canvas)
    NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
        let resolved = nsColor.usingColorSpace(.sRGB)!
        XCTAssertEqual(resolved.redComponent, 0xf7/255, accuracy: 0.01)
        XCTAssertEqual(resolved.greenComponent, 0xf6/255, accuracy: 0.01)
        XCTAssertEqual(resolved.blueComponent, 0xf1/255, accuracy: 0.01)
    }
}
```

关键技巧：
- `NSColor(swiftUIColor)` 转换是稳定的（dynamic 信息保留）
- `.performAsCurrentDrawingAppearance` 强制 closure 在指定 appearance 上下文执行
- `usingColorSpace(.sRGB)` 取 component 必须用 sRGB 否则色彩空间不一致

**实现注意**：NSColor 初始化必须用 `NSColor(srgbRed:...)` 而不是 `NSColor(red:...)`。后者用 calibrated RGB 色彩空间，`usingColorSpace(.sRGB)` 转换时会有微小漂移，测试 1/255 精度断言会偶发失败。

## 重要前提

- 项目最低 macOS target ≥ 10.15（NSColor(name:dynamicProvider:) API 引入时机）
- 本仓库 target macOS 14，完全兼容
- closure 由 NSColor 内部 cache，不会每次访问重建闭包（无内存泄漏）

## Lesson

- **SwiftUI/AppKit 桥接边界的 light/dark 颜色优先用 AppKit 原生 dynamic NSColor**，不要依赖 SwiftUI environment 传播链
- 这条经验同样适用于 NSPopover、NSWindow 嵌入 SwiftUI 等所有 LSUIElement / hidesOnDeactivate 场景
- 设计 token 用 `static let dynamicColor` 比 `static func(_ scheme:)` 更优雅 — 调用方零参数、零传递、零环境读取

## Related

- [[2026-05-26 LSUIElement app 中的浮窗输入框用 NSPanel + nonactivatingPanel + NSApp.activate]]
- [[swiftui-frame-nshosting-controller-resize]]
