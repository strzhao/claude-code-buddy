---
name: swiftui-border-comet-arc-length
description: SwiftUI 圆角边框跑马灯/流光用「周长弧长参数化 + 单次 stroke 沿线 linearGradient」，禁用 AngularGradient（按角度上色在宽扁矩形会同时点亮上下边成假双线），多段独立 stroke+round cap 会叠加成珠链
metadata:
  type: pattern
---

# SwiftUI 边框流光：周长弧长参数化（单彗星，无双线无珠子）

## 背景

launcher loading 态想在输入框圆角边框上跑一道"流光"（border-beam，Linear/Vercel 风），
要求：整圈**只有一道**连续光、克制不抢眼、跟随既有 1pt 边框路径。

## 三个会踩的坑（都实测复现过）

### 坑 1：AngularGradient / conic 旋转 → 宽扁矩形上出现"两道光"
直觉做法是 `AngularGradient(...).rotationEffect`。但 angular 是**按角度**上色，输入框是
640×64 的宽扁矩形：同一个角度射线会**同时穿过上边和下边**，于是上下边在对称位置一起变亮，
看起来像有 2~4 道流光在跑，不是一道。

### 坑 2：多段独立 stroke + round lineCap → "一串珠子"
把彗星拆成 N 段小线段、每段单独 `stroke`、各自半透明 + `lineCap=.round`：相邻段的圆头
互相**重叠**，半透明叠加在每个接缝处变亮 → 整条变成一串发光珠子，不连续。

### 坑 3（如果用 SwiftUI 内置）：动画永不停 → 测试 RunLoop 空转
见 [[swift-test-filter-skips-spritekit]] 与 apps/desktop/CLAUDE.md 坑 2。

## 正确做法：周长弧长参数化 + 单次连续 stroke + 沿线渐变

1. **把圆角矩形边框展开成「弧长 s → 点(x,y)」**（四直边 + 四个 1/4 圆弧顺序拼接）：
   周长 `P = 2(w+h) − 8r + 2πr`。彗星头部 `s_head(t) = P · frac(t/T)` 沿周长**匀速**前进——
   弧长参数化天然保证"一道光、且不受边长比例影响"（角度参数化做不到）。

2. **彗星是一条连续 `Path`**：从头部向尾部回采样 ~90 个点 `addLine` 连成一笔，**单次 `stroke`**。
   淡出交给 **`GraphicsContext.Shading.linearGradient`**（头 αmax → 中 0.4αmax → 尾 0），
   `startPoint=headPoint / endPoint=tailPoint`。单次 stroke 无接缝叠加 → 连续流光，无珠子。

3. **用 SwiftUI `Canvas`**（`TimelineView(.animation)` 驱动 t），不是 `AngularGradient`：

```swift
// 圆角矩形周长参数化：弧长 s → CGPoint（四直边+四 1/4 弧）
// segments[i].at(u): u∈[0,1]；point(at:s) 对 s 取模绕回后线性定位
let head = total * CGFloat(frac(t / period))
let tail = total * tailFraction           // 短尾 0.20~0.30·P
var comet = Path(); comet.move(to: perimeter.point(at: head))
for i in 1...90 { comet.addLine(to: perimeter.point(at: head - tail * CGFloat(i)/90)) }
ctx.stroke(comet,
  with: .linearGradient(Gradient(stops: [
     .init(color: tint.opacity(maxAlpha),     location: 0),
     .init(color: tint.opacity(maxAlpha*0.4), location: 0.5),
     .init(color: tint.opacity(0),            location: 1)]),
     startPoint: perimeter.point(at: head), endPoint: perimeter.point(at: head - tail)),
  style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
```

## 落地参数（用户实机调过的克制档）
- 周期 `T≈2.0~2.4s`、尾长 `0.20~0.32·P`、`αmax≈0.5~1.0`、线宽 `1.3~2.5pt`、可选 `.shadow` 发光。
- 彗星几何（cornerRadius/inset/lineWidth）对齐既有 `strokeBorder` 那条边框 → 流光叠在同一条线上流动，
  覆盖即提亮、离开即回落，整圈"一条线"（避免彗星与底边框错位成第二条线）。
- **测试冻结铁律**：`RuntimeEnvironment.isRunningTests || accessibilityReduceMotion` → 渲染静态首帧（t=0），
  不启 `TimelineView(.animation)` 逐帧循环。

## Lesson
- 边框跑马灯/流光首选**弧长参数化**而非角度（angular）——角度法在非正方形上必然多道光。
- 渐变拖尾用**一笔 Path + 沿线 gradient**，不要拆段叠加（叠加=珠链）。
- "看起来像有好几道光" → 怀疑 angular；"看起来一串珠子" → 怀疑多段 stroke 叠加。

## Related
- [[swiftui-material-vs-nsvisualeffectview-injection]]
- [[2026-05-29 SwiftUI 循环动画作用于派生函数值必须用 TimelineView(.animation)]]
- [[swiftui-nspanel-dynamic-color-bridge]]
