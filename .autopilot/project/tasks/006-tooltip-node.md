---
id: "006-tooltip-node"
depends_on: ["005-mouse-tracker"]
---

## 目标

创建 TooltipNode 作为 SpriteKit 悬停提示，显示会话详细信息。

## 架构上下文

使用 SKNode 子树实现（非 NSPopover），避免窗口焦点问题。通过 MouseTracker 的 onHover 回调触发显示/隐藏。

## 关键实现细节

### TooltipNode (`Sources/ClaudeCodeBuddy/Scene/TooltipNode.swift`)

SKNode 子树，包含：
- 背景：圆角矩形 `SKShapeNode`（半透明黑色背景）
- 颜色点 + 标签 + 状态徽章
- cwd 路径（等宽字体）
- PID + 最后活动时间
- 底部提示："点击跳转到终端窗口"

```swift
class TooltipNode: SKNode {
    private let backgroundNode: SKShapeNode
    private let labelText: SKLabelNode
    private let cwdText: SKLabelNode
    private let stateText: SKLabelNode
    private let pidText: SKLabelNode
    private let hintText: SKLabelNode
    
    func show(info: SessionInfo, at position: CGPoint)
    func hide()
    func update(info: SessionInfo)
}
```

**动画：**
- 显示：`SKAction.fadeIn(withDuration: 0.15)`
- 隐藏：`SKAction.fadeOut(withDuration: 0.15)`

**定位：**
- 显示在猫上方，避免超出屏幕边界
- 自动调整位置以保持在场景可见区域内

### BuddyScene 变更

```swift
private var tooltipNode: TooltipNode?

func showTooltip(for sessionId: String) {
    // 从 SessionManager 获取 SessionInfo（通过新增的查询接口或回调中缓存的数据）
    // 定位到猫上方
    // 调用 tooltipNode.show(info:at:)
}

func hideTooltip() {
    tooltipNode?.hide()
}
```

**数据来源：** BuddyScene 需要能查询 SessionInfo。方案：SessionManager 通过 `onSessionsChanged` 回调将最新数据推送给 BuddyScene 缓存。

## 输入/输出契约

**输入来自 005：** onHover 回调提供 sessionId

**数据来源：** SessionInfo 通过 BuddyScene 缓存（来自 SessionManager.onSessionsChanged）

## 验收标准

- [ ] `swift build` 编译通过
- [ ] 鼠标悬停猫时显示提示框
- [ ] 提示框包含标签、cwd、PID、状态、最后活动时间
- [ ] 提示框在鼠标离开时隐藏
- [ ] 提示框有淡入淡出动画
- [ ] 提示框不超出屏幕边界
- [ ] 提示框不影响底层窗口交互
