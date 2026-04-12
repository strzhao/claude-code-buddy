---
id: "001-constants"
depends_on: []
---

# 001: 提取 CatConstants

## 目标
将 CatSprite.swift 中 50+ 处硬编码魔数提取为命名常量，组织到 `CatConstants` 枚举命名空间中。

## 架构上下文
这是整个重构的第一步。提取常量不改变任何行为逻辑，仅用命名常量替换魔数，为后续 GKState 子类和组件化提供可引用的常量。

## 输入
- `Sources/ClaudeCodeBuddy/Scene/CatSprite.swift`（1242 行）

## 输出
- 新文件：`Sources/ClaudeCodeBuddy/Scene/CatConstants.swift`
- 修改文件：`CatSprite.swift`（魔数替换为常量引用）

## 实现要点

### 常量分类（使用 enum namespace）

```swift
enum CatConstants {
    enum Movement {
        static let walkSpeedRange: ClosedRange<CGFloat> = 35...55
        static let foodWalkSpeed: CGFloat = 55
        static let exitWalkSpeed: CGFloat = 120
        static let randomWalkRange: CGFloat = 120
        // ...
    }
    enum Animation {
        static let jumpArcHeight: CGFloat = 50
        static let jumpDuration: TimeInterval = 0.30
        static let approachDistance: CGFloat = 20
        static let obstaclePathTolerance: CGFloat = 24
        // ...
    }
    enum Physics {
        static let bodySize = CGSize(width: 44, height: 44)
        static let restitution: CGFloat = 0.0
        static let friction: CGFloat = 0.8
        // ...
    }
    enum Fright {
        static let fleeDistance: CGFloat = 30
        static let reboundFactor: CGFloat = 0.5
        // ...
    }
    enum Idle {
        static let sleepWeight: Double = 0.7
        static let breatheWeight: Double = 0.1
        // ...
    }
    enum Visual {
        static let hitboxSize = CGSize(width: 48, height: 64)
        static let hoverScale: CGFloat = 1.25
        static let hoverDuration: TimeInterval = 0.15
        static let sessionTintFactor: CGFloat = 0.3
        // ...
    }
}
```

### 注意事项
- 仅做常量提取，不改变逻辑
- `CatSprite.hitboxSize` 已经是 static let，移到 CatConstants 后在 CatSprite 保留 typealias 或代理属性
- 在 CatSprite 中 BuddyScene 引用 `CatSprite.hitboxSize` 的地方也要更新

## 验收标准
- [ ] `swift build` 编译通过
- [ ] `swift test` 所有测试通过
- [ ] CatSprite.swift 中不再有未命名的数字常量（除 0、1 等显而易见的值）
- [ ] CatConstants.swift 按功能分组清晰
