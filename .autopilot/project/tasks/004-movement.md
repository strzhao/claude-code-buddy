---
id: "004-movement"
depends_on: ["003-animation"]
---

# 004: 提取 MovementComponent + JumpComponent（含 GCD fallback 封装）

## 目标
1. 将移动逻辑（随机游走、食物走路、退出走路）提取到 MovementComponent
2. 将两处重复的跳跃弧线逻辑统一到 JumpComponent（消除 ~220 行重复代码）
3. 将 GCD fallback（测试环境无 display link 时的替代执行路径）封装到 JumpComponent 内部

## 架构上下文
当前跳跃逻辑完整重复两份：
- `buildJumpActions(from:to:goingRight:onJumpOver:)` —— 随机游走时跳过障碍
- `exitScene(sceneWidth:obstacles:onJumpOver:completion:)` 内联的跳跃序列 —— 退出时跳过障碍

两者都构建相同的 Bezier 弧线、播放相同的跳跃帧、触发相同的受惊回调。GCD fallback 也各自实现。

## 输入
- `Sources/ClaudeCodeBuddy/Scene/CatSprite.swift`（003 产出后的版本）
- `Tests/BuddyCoreTests/JumpExitTests.swift`（14 个测试用例）

## 输出
新文件：
- `Sources/ClaudeCodeBuddy/Scene/Components/MovementComponent.swift`
- `Sources/ClaudeCodeBuddy/Scene/Components/JumpComponent.swift`
修改文件：
- `CatSprite.swift`
- `CatToolUseState.swift`（随机游走调用）
- `Tests/BuddyCoreTests/JumpExitTests.swift`（测试签名可能需要更新）

## 实现要点

### JumpComponent 公共 API

```swift
class JumpComponent {
    unowned let containerNode: SKNode
    unowned let spriteNode: SKSpriteNode
    let animationComponent: AnimationComponent

    init(containerNode: SKNode, spriteNode: SKSpriteNode, animationComponent: AnimationComponent)

    /// 构建跳过障碍物的 SKAction 序列（统一实现）
    /// - Parameters:
    ///   - from: 起始 X
    ///   - to: 目标 X
    ///   - obstacles: 路径上的障碍物 (x, entity)
    ///   - walkSpeed: 移动速度
    ///   - onJumpOver: 每次跳过障碍时的回调
    ///   - completion: 完成回调
    /// - Returns: (spriteActions: SKAction, containerActions: SKAction)
    func buildJumpSequence(
        from startX: CGFloat, to endX: CGFloat,
        obstacles: [(x: CGFloat, entity: EntityProtocol)],  // 暂用 CatSprite 类型，006 改为 EntityProtocol
        walkSpeed: CGFloat,
        onJumpOver: ((EntityProtocol) -> Void)?,
        completion: @escaping () -> Void
    ) -> (spriteActions: SKAction, containerActions: SKAction)

    /// GCD fallback 执行（测试环境使用）
    func scheduleGCDFallback(
        obstacles: [(x: CGFloat, entity: EntityProtocol)],
        totalDuration: TimeInterval,
        onJumpOver: ((EntityProtocol) -> Void)?,
        completion: @escaping () -> Void
    )
}
```

### GCD fallback 封装策略

当前 GCD fallback 分散在两处，每处 3-5 个 `DispatchQueue.main.asyncAfter` 块。封装策略：

```swift
/// 在 JumpComponent 内部
private var hasDisplayLink: Bool {
    containerNode.scene?.view != nil
}

func executeJumpSequence(...) {
    if hasDisplayLink {
        // 正常 SKAction 路径
        containerNode.run(containerActions, withKey: "jumpSequence")
        spriteNode.run(spriteActions, withKey: "jumpAnimation")
    } else {
        // GCD fallback 路径（用于测试）
        scheduleGCDFallback(...)
    }
}
```

### MovementComponent 公共 API

```swift
class MovementComponent {
    unowned let containerNode: SKNode
    unowned let spriteNode: SKSpriteNode
    let jumpComponent: JumpComponent

    /// 开始随机游走（toolUse 状态）
    func startRandomWalk(origin: CGFloat, range: CGFloat, speed: ClosedRange<CGFloat>,
                         nearbyObstacles: () -> [(x: CGFloat, entity: CatSprite)],
                         onJumpOver: ((CatSprite) -> Void)?)

    /// 走向食物
    func walkToFood(at x: CGFloat, speed: CGFloat, completion: @escaping () -> Void)

    /// 走向屏幕边缘退出
    func walkToExit(direction: ExitDirection, speed: CGFloat,
                    obstacles: [(x: CGFloat, entity: CatSprite)],
                    onJumpOver: ((CatSprite) -> Void)?,
                    completion: @escaping () -> Void)

    /// 停止所有移动
    func stop()
}
```

### 测试迁移
14 个 JumpExitTests 当前直接调用 `CatSprite.exitScene` 和 `CatSprite.playFrightReaction`。这些公共方法签名暂时保持不变（CatSprite 委托给 MovementComponent），测试不需要大改。如果内部实现导致测试断言顺序变化，需要同步调整。

## 验收标准
- [ ] `swift build` 编译通过
- [ ] `swift test --filter JumpExitTests` 全部 14 条通过
- [ ] 跳跃弧线代码只存在一处（JumpComponent 内），搜索 `bezier` 或 `arcHeight` 只命中一个文件
- [ ] GCD fallback 代码封装在 JumpComponent 内，CatSprite 中不再有 `DispatchQueue.main.asyncAfter` 用于跳跃
- [ ] `doRandomWalkStep` 和 `exitScene` 内联的跳跃逻辑已删除
