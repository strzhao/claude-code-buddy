---
id: "005-mouse-tracker"
depends_on: ["003-visual-layer"]
---

## 目标

创建 MouseTracker 实现全局鼠标监控和 BuddyWindow 动态穿透切换，为悬停提示和点击激活提供基础。

## 架构上下文

BuddyWindow 当前 `ignoresMouseEvents = true`，完全穿透。需要在鼠标进入猫碰撞箱时切换为可交互，离开时恢复穿透。

## 关键实现细节

### MouseTracker (`Sources/ClaudeCodeBuddy/Window/MouseTracker.swift`)

```swift
class MouseTracker {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private weak var window: BuddyWindow?
    private weak var scene: BuddyScene?
    
    var onHover: ((String?) -> Void)?   // sessionId or nil
    var onClick: ((String) -> Void)?     // sessionId
    
    private var hoveredSessionId: String?
    private var leaveTimer: Timer?
}
```

**全局鼠标监控：**
```swift
globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
    self?.handleMouseMoved(event)
}
```

**碰撞检测：**
1. 将屏幕坐标转换为场景坐标
2. 遍历场景中每只猫的 node.position
3. 使用 CatSprite.hitboxSize (48x64) 进行碰撞测试
4. 鼠标进入碰撞箱 → `window.ignoresMouseEvents = false`
5. 鼠标离开所有碰撞箱 → 延迟 200ms 后 `window.ignoresMouseEvents = true`

**本地点击监控：**
```swift
localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
    self?.handleClick(event)
    return event
}
```

### BuddyWindow 变更

新增公开方法：
```swift
func setInteractive(_ interactive: Bool)  // 封装 ignoresMouseEvents 切换
```

### 重置保证

- `leaveTimer` 200ms 后重置
- 60s 超时检查中强制重置
- `NSApplication.didBecomeActiveNotification` / `didResignActiveNotification` 监听

### AppDelegate 变更

在 `setupWindow()` 或单独方法中创建 MouseTracker 并持有引用。

## 输入/输出契约

**输入来自 003：** CatSprite.hitboxSize 常量，BuddyScene 中猫的 node.position

**输出给 006：** `onHover(sessionId: String?)` 回调

**输出给 007：** `onClick(sessionId: String)` 回调

## 验收标准

- [ ] `swift build` 编译通过
- [ ] 鼠标在非猫区域时 ignoresMouseEvents = true（穿透）
- [ ] 鼠标进入猫碰撞箱时 ignoresMouseEvents = false
- [ ] 鼠标离开猫碰撞箱 200ms 后恢复 ignoresMouseEvents = true
- [ ] onHover 回调在进入/离开时正确触发
- [ ] 不需要 Accessibility 权限
