<!-- tags: spritekit, cpu, performance, fps, preferredframespersecond, ispaused, nstrackingarea, global-monitor, mouse-events, skview, optimization -->

# SpriteKit CPU 优化三件套：FPS 限制 + 暂停控制 + NSTrackingArea

## 问题

macOS SpriteKit 桌面应用的 3 个 CPU 高占用根因：

1. **SKView 无帧率上限**：`preferredFramesPerSecond` 默认 0（不限制），ProMotion 显示器 120fps 持续渲染，即使场景空无一物
2. **全局鼠标监听**：`addGlobalMonitorForEvents(matching: [.mouseMoved])` 在每次鼠标像素移动时触发（全局、跨应用），每次做 screen→window→view→scene 坐标链转换 + hit test
3. **场景从不暂停**：`isPaused` 默认为 false，0 猫/全 idle/窗口在其他 Space 时仍满帧运行

基线 CPU：5-15%（0 猫），峰值 20-40%（8 猫活跃 + 鼠标移动）。

## 修复

### 1. 限制 FPS
```swift
skView.preferredFramesPerSecond = 30  // 像素猫 30fps 完全够用
```

### 2. 用 NSTrackingArea 替换全局监听
```swift
// 创建 SKView 子类
final class BuddySKView: SKView {
    override func updateTrackingAreas() {
        trackingAreas.forEach { removeTrackingArea($0) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
    }
}
```
- 坐标转换链缩短：`event.locationInWindow` 替代 `NSEvent.mouseLocation`（省 screen→window 转换）
- 仅在窗口内触发，不再全局响应

### 3. 暂停逻辑
```swift
// 初始暂停（启动时无猫）
skView.isPaused = true

// 会话数变化：无猫且鼠标不在窗口内 → 暂停
skView.isPaused = (count == 0 && !isMouseInside)

// 鼠标进入 → 恢复渲染
skView.isPaused = false

// 鼠标离开 → 无猫则暂停
skView.isPaused = !hasCats
```

`isPaused = true` 停止整个 SpriteKit 渲染管线（display link + 物理引擎 + SKAction），CPU 降至接近 0%。

## 关键注意

- `isPaused` 修改必须在主线程（SpriteKit 要求）
- NSTrackingArea 的 `updateTrackingAreas()` 要先移除旧的再添加（避免子视图变化时残留）
- 会话数变化回调（来自 socket）需经 `DispatchQueue.main.async` 确保主线程
- C2 契约缺口：`onSessionCountChanged(count=0)` 必须检查鼠标是否在窗口内，否则鼠标 hover 窗口时最后一只猫被移除会导致误暂停

## 效果

| 场景 | 修复前 | 修复后 |
|------|--------|--------|
| 0 猫 + 鼠标不在窗口 | 5-10% CPU | <0.5% CPU |
| 3-4 猫 idle | 8-15% CPU | 2-4% CPU |
| 8 猫全活跃 | 20-40% CPU | 8-15% CPU |
