---
id: "005-interaction"
depends_on: ["004-movement"]
---

# 005: 提取 InteractionComponent + LabelComponent

## 目标
将受惊反应、hover/click 处理提取到 InteractionComponent；将名字标签、警报徽标提取到 LabelComponent。

## 架构上下文
受惊反应 (`playFrightReaction`) 有 3 个重载（awayFromX、ExitDirection、CatSprite），合计约 120 行。标签管理（`configure`、`showLabel`、`updateLabel`、`alertOverlay`）约 80 行。提取后 CatSprite 应该已经精简到约 300-400 行。

## 输入
- `Sources/ClaudeCodeBuddy/Scene/CatSprite.swift`（004 产出后的版本）
- `Tests/BuddyCoreTests/JumpExitTests.swift`

## 输出
新文件：
- `Sources/ClaudeCodeBuddy/Scene/Components/InteractionComponent.swift`
- `Sources/ClaudeCodeBuddy/Scene/Components/LabelComponent.swift`
修改文件：
- `CatSprite.swift`
- 相关 GKState 子类（CatPermissionRequestState 使用标签/badge）

## 实现要点

### InteractionComponent 公共 API

```swift
class InteractionComponent {
    unowned let containerNode: SKNode
    unowned let spriteNode: SKSpriteNode
    let animationComponent: AnimationComponent

    /// 受惊反应：远离跳跃者
    func playFrightReaction(awayFromX jumperX: CGFloat, currentState: CatState,
                            sceneWidth: CGFloat, onComplete: @escaping () -> Void)

    /// 受惊反应：按退出方向
    func playFrightReaction(frightenedBy direction: ExitDirection, ...)

    /// hover 缩放
    func applyHoverScale()
    func removeHoverScale()

    /// 朝向控制
    func applyFacingDirection(facingRight: Bool)
}
```

### LabelComponent 公共 API

```swift
class LabelComponent {
    unowned let node: SKSpriteNode

    /// 配置名字标签和颜色
    func configure(color: SessionColor, label: String)

    /// 更新标签文字
    func updateLabel(_ text: String)

    /// 显示/隐藏警报徽标（permissionRequest 状态）
    func showAlertBadge(text: String)
    func hideAlertBadge()

    /// 显示/隐藏 tab name（debug 模式）
    func showTabName(_ name: String)
    func hideTabName()

    /// 恢复标签颜色到 session 颜色
    func restoreLabelColor()
}
```

### CatSprite 变更
```swift
class CatSprite {
    let interactionComponent: InteractionComponent
    let labelComponent: LabelComponent

    // 公共方法委托
    func playFrightReaction(awayFromX jumperX: CGFloat) {
        interactionComponent.playFrightReaction(awayFromX: jumperX, ...)
    }

    func configure(color: SessionColor, label: String) {
        labelComponent.configure(color: color, label: label)
    }
}
```

### 受惊反应的状态恢复
`playFrightReaction` 完成后需要恢复到当前状态的动画。当前代码在 completion 中调用 `applyState(currentState)`。重构后改为：`interactionComponent` 的 onComplete 回调中，调用 `stateMachine.currentState` 的某个 `resume` 方法。

具体方案：在 completion 中直接重新进入当前状态 `stateMachine.enter(type(of: stateMachine.currentState!))` —— GKStateMachine 允许重新进入相同状态。

### 测试影响
JumpExitTests 中多个测试调用 `cat.playFrightReaction(awayFromX:)`。由于 CatSprite 保留公共方法签名（委托给 InteractionComponent），测试代码不需要修改。

## 验收标准
- [ ] `swift build` 编译通过
- [ ] `swift test --filter JumpExitTests` 全部 14 条通过
- [ ] CatSprite 中 `playFrightReaction` 相关的私有逻辑已移入 InteractionComponent
- [ ] 标签创建/更新/badge 逻辑已移入 LabelComponent
- [ ] CatSprite 总行数 < 500 行
