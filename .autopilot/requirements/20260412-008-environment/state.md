---
active: true
phase: "done"
gate: ""
iteration: 1
max_iterations: 30
max_retries: 3
retry_count: 0
mode: "single"
plan_mode: ""
brief_file: "/Users/stringzhao/workspace_sync/personal_projects/claude-code-buddy/.autopilot/project/tasks/008-environment.md"
next_task: ""
auto_approve: false
task_dir: "/Users/stringzhao/workspace_sync/personal_projects/claude-code-buddy/.autopilot/requirements/20260412-008-environment"
session_id: 7cbae9bb-b5f3-4e2c-bd7e-02a63bef2766
started_at: "2026-04-12T13:47:17Z"
---

## 目标
---
id: "008-environment"
depends_on: ["007-eventbus"]
---

# 008: Environment/Weather 框架 + EnvironmentResponder

## 目标
搭建环境/天气系统的协议框架和基础管理器。本次不实现具体天气效果（如雨、雪粒子），仅建立可扩展的架构骨架，使未来添加天气效果时不需要改动已有实体代码。

## 架构上下文
这是整个重构的最后一步，建立在 EventBus 之上。环境变化通过 EventBus 广播，所有实现 `EnvironmentResponder` 协议的实体自动收到通知并做出反应。

## 输入
- `Sources/ClaudeCodeBuddy/Event/EventBus.swift`（007 产出）
- `Sources/ClaudeCodeBuddy/Entity/EntityProtocol.swift`（006 产出）

## 输出
新文件：
```
Sources/ClaudeCodeBuddy/Environment/
├── EnvironmentResponder.swift   # 协议：实体响应环境变化
├── WeatherState.swift           # 天气状态枚举
├── TimeOfDay.swift              # 时段枚举
└── SceneEnvironment.swift       # 环境管理器
```
修改文件：
- `CatSprite.swift` —— 添加 `EnvironmentResponder` 遵循
- `BuddyScene.swift` —— 集成 SceneEnvironment
- `EventBus.swift` —— 确认 weatherChanged 和 timeOfDayChanged subject 已就绪

## 实现要点

### WeatherState

```swift
enum WeatherState: String, CaseIterable {
    case clear      // 晴天（默认）
    case cloudy     // 多云
    case rain       // 雨
    case snow       // 雪
    case wind       // 风

    /// 对实体行为的影响描述
    var behaviorModifier: BehaviorModifier {
        switch self {
        case .clear: return BehaviorModifier()
        case .rain: return BehaviorModifier(walkSpeedMultiplier: 0.7, idleSleepWeightBoost: 0.15)
        case .snow: return BehaviorModifier(walkSpeedMultiplier: 0.5, idleSleepWeightBoost: 0.25)
        case .wind: return BehaviorModifier(walkSpeedMultiplier: 1.2)
        case .cloudy: return BehaviorModifier(idleSleepWeightBoost: 0.05)
        }
    }
}

struct BehaviorModifier {
    var walkSpeedMultiplier: CGFloat = 1.0
    var idleSleepWeightBoost: Double = 0.0
    // 未来扩展：jumpHeightMultiplier, foodSpawnRateMultiplier, etc.
}
```

### TimeOfDay

```swift
enum TimeOfDay: String, CaseIterable {
    case morning    // 6:00 - 12:00
    case afternoon  // 12:00 - 18:00
    case evening    // 18:00 - 22:00
    case night      // 22:00 - 6:00

    static var current: TimeOfDay {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 6..<12: return .morning
        case 12..<18: return .afternoon
        case 18..<22: return .evening
        default: return .night
        }
    }
}
```

### EnvironmentResponder 协议

```swift
protocol EnvironmentResponder: AnyObject {
    /// 天气变化时调用
    func onWeatherChanged(_ weather: WeatherState)

    /// 时段变化时调用
    func onTimeOfDayChanged(_ time: TimeOfDay)
}

// 提供默认空实现，实体可选择性响应
extension EnvironmentResponder {
    func onWeatherChanged(_ weather: WeatherState) {}
    func onTimeOfDayChanged(_ time: TimeOfDay) {}
}
```


--- 架构设计摘要 ---
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


## 设计文档
(待 design 阶段填充)

## 实现计划
(待 design 阶段填充)

## 红队验收测试
(待 implement 阶段填充)

## QA 报告
(待 qa 阶段填充)

## 变更日志
- [2026-04-12T13:47:17Z] autopilot 初始化（brief 模式），任务: 008-environment.md
