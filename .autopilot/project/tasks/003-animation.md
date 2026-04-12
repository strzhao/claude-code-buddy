---
id: "003-animation"
depends_on: ["002-gkstate"]
---

# 003: 提取 AnimationComponent

## 目标
将纹理加载、帧动画播放、呼吸效果、过渡动画等逻辑从 CatSprite 提取到独立的 AnimationComponent 中。

## 架构上下文
当前动画逻辑散布在 CatSprite 的多个位置：`loadTextures`（L138-163）、各 GKState 的 `didEnter` 中直接操作 `SKAction.animate`、`startBreathing` 等。提取后，AnimationComponent 成为所有帧动画操作的单一入口。

## 输入
- `Sources/ClaudeCodeBuddy/Scene/CatSprite.swift`（002 产出后的版本）
- `Sources/ClaudeCodeBuddy/Scene/States/*.swift`（002 产出）

## 输出
- 新文件：`Sources/ClaudeCodeBuddy/Scene/Components/AnimationComponent.swift`
- 修改文件：`CatSprite.swift`、各 GKState 子类

## 实现要点

### AnimationComponent 公共 API

```swift
class AnimationComponent {
    unowned let node: SKSpriteNode

    /// 已加载的动画帧字典
    private(set) var animations: [String: [SKTexture]] = [:]

    init(node: SKSpriteNode)

    /// 从 bundle 加载纹理（prefix: "cat" → cat-idle-a-1.png ...）
    func loadTextures(prefix: String, bundle: Bundle)

    /// 播放动画帧序列
    func play(_ name: String, loop: Bool, timePerFrame: TimeInterval, key: String, completion: (() -> Void)?)

    /// 播放过渡动画（from→to 状态间的特殊帧）
    func playTransition(animName: String, timePerFrame: TimeInterval, completion: @escaping () -> Void)

    /// 呼吸缩放效果
    func startBreathing(scaleRange: ClosedRange<CGFloat>, duration: TimeInterval)

    /// 停止指定 action key
    func stopAction(forKey key: String)

    /// 停止所有动画
    func stopAll()

    /// 检查是否有指定动画帧
    func hasAnimation(_ name: String) -> Bool
}
```

### 从 CatSprite 提取的方法
- `loadTextures()` → `animationComponent.loadTextures(prefix: "cat", bundle: .module)`
- 各 GKState 中直接构造 `SKAction.animate(with:...)` 的代码 → `animationComponent.play(...)`
- 呼吸效果代码 → `animationComponent.startBreathing(...)`

### CatSprite 变更
```swift
class CatSprite {
    let animationComponent: AnimationComponent

    init(sessionId: String) {
        // ...
        animationComponent = AnimationComponent(node: node)
        animationComponent.loadTextures(prefix: "cat", bundle: .module)
        // ...
    }
}
```

### GKState 子类变更
```swift
// Before (in state):
let frames = entity.animations["paw"]!
entity.node.run(SKAction.repeatForever(SKAction.animate(with: frames, timePerFrame: 0.15)), withKey: "animation")

// After:
entity.animationComponent.play("paw", loop: true, timePerFrame: 0.15, key: "animation", completion: nil)
```

## 验收标准
- [ ] `swift build` 编译通过
- [ ] `swift test` 所有测试通过
- [ ] CatSprite 中不再直接操作 `SKAction.animate`（全部通过 animationComponent）
- [ ] `loadTextures` 方法已从 CatSprite 移除
- [ ] `animations` 字典已从 CatSprite 移入 AnimationComponent
