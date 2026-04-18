# 修复航天飞机降落时外储罐视觉遮挡 — 设计文档

## 根因
`Scripts/generate-rocket-sprites-v2.swift` 的 `drawShuttleBody` 绘制 ET 时：
- ET body：`pxS(ctx, 19, baseY + 4, 10, 35, etOrange)` 占 35 行
- ET nose 顶点：`baseY + 42`

ET 顶部像素 y = `46 + yOff`，画布高度 48（y ∈ [0,47]），所以 `yOff > 1` 即裁切。

| 帧 | yOff | ET 顶 y | 裁切行数 |
|---|---|---|---|
| `shuttle_landing_a` | 6 | 52 | 5 |
| `shuttle_landing_b` | 3 | 49 | 2 |
| `shuttle_landing_c` | 0 | 46 | 0 |

其他 kind 车身更矮（classic 鼻锥顶 baseY+32），即使 yOff=8 也不裁，只有 shuttle 中招。

## 方案
降低 `shuttle_landing_a/b` 的 yOff 到不裁切的区间：

- `shuttle_landing_a`: yOff `6 → 1`（ET 顶 y=47，压线但完整）
- `shuttle_landing_b`: yOff `3 → 0`（与 landing_c 同位）

场景级 `RocketPropulsiveLandingState.didEnterConventional` 的 `SKAction.moveTo(y: groundY, duration: Landing.totalDuration)` 已经把整个 containerNode 从 currentY 动画到 groundY，精灵内部 yOff 只是锦上添花的帧内微位移，降低不影响降落观感。

## Scope
严格限定在 landing 三帧；liftoff_a/b（yOff=4/8，同样裁切）和 cruise_a/b（yOff=2，临界裁切 1 行）不在本次范围内。
