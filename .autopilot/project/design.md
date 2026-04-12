# 行为架构重构 — 整体设计文档

## 背景

CatSprite 是一个 1242 行的巨石类，包含状态机、动画、移动、交互所有逻辑。需要渐进式重构为可扩展架构，支持未来的多动物类型、环境系统和天气系统。

## 目标架构

### 目录结构

```
Sources/ClaudeCodeBuddy/
├── Entity/                        # 实体抽象层
│   ├── EntityProtocol.swift
│   └── EntityState.swift
├── Entity/Components/             # 可复用组件
│   ├── AnimationComponent.swift
│   ├── MovementComponent.swift
│   ├── JumpComponent.swift
│   ├── InteractionComponent.swift
│   └── LabelComponent.swift
├── Entity/Cat/                    # 猫特化实现
│   ├── CatSprite.swift            # 精简后 ~300 行
│   ├── CatConstants.swift
│   └── States/
│       ├── CatIdleState.swift
│       ├── CatThinkingState.swift
│       ├── CatToolUseState.swift
│       ├── CatPermissionRequestState.swift
│       └── CatEatingState.swift
├── Environment/
│   ├── EnvironmentResponder.swift
│   ├── WeatherState.swift
│   └── SceneEnvironment.swift
├── Event/
│   ├── EventBus.swift
│   └── BuddyEvent.swift
└── ...
```

### 核心技术决策

| 决策 | 选择 | 理由 |
|------|------|------|
| 状态机 | GKStateMachine | Apple 原生、SpriteKit 集成、强制状态隔离 |
| 组件模式 | Swift Protocol + 组合 | 轻量，不用完整 ECS |
| 事件系统 | Combine | Apple 原生、类型安全 |
| 过渡动画 | didEnter 内启动，completion 触发稳态动画 | 解决同步 enter() 与异步 SKAction 冲突 |
| GCD fallback | 封装到 JumpComponent | 测试环境无 display link |

### 关键接口

```swift
protocol EntityProtocol: AnyObject {
    var sessionId: String { get }
    var containerNode: SKNode { get }
    var currentStateIdentifier: EntityState { get }
    func switchState(to state: EntityState, context: StateContext?)
    func enterScene(sceneSize: CGSize)
    func exitScene(sceneWidth: CGFloat, obstacles: [(CGFloat, EntityProtocol)],
                   onJumpOver: ((EntityProtocol) -> Void)?, completion: @escaping () -> Void)
    func applyHoverScale()
    func removeHoverScale()
    func updateSceneSize(_ size: CGSize)
    func playFrightReaction(awayFromX jumperX: CGFloat)
    var onFoodAbandoned: ((String) -> Void)? { get set }
}

enum EntityState: String, CaseIterable {
    case idle, thinking, toolUse, permissionRequest, eating
}

protocol EnvironmentResponder: AnyObject {
    func onWeatherChanged(_ weather: WeatherState)
    func onTimeOfDayChanged(_ time: TimeOfDay)
}
```

### 跨任务设计约束

- 组件通过 `unowned let entity` 持有宿主引用
- GKState 子类通过 `entity` 属性访问组件
- EntityProtocol 是 BuddyScene 管理实体的唯一接口，不能 downcast
- CatState enum 保留为猫内部类型，EntityState 用于跨层通信
- 现有 14 个 JumpExitTests 必须全部通过
- GKState.didEnter 负责过渡动画+稳态动画，willExit 负责清理
- CatEatingState 通过 stateMachine.enter() 进入，不再直接赋值
