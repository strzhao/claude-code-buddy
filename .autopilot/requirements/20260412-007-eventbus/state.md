---
active: true
phase: "implement"
gate: ""
iteration: 1
max_iterations: 30
max_retries: 3
retry_count: 0
mode: "single"
plan_mode: ""
brief_file: "/Users/stringzhao/workspace_sync/personal_projects/claude-code-buddy/.autopilot/project/tasks/007-eventbus.md"
next_task: ""
auto_approve: false
task_dir: "/Users/stringzhao/workspace_sync/personal_projects/claude-code-buddy/.autopilot/requirements/20260412-007-eventbus"
session_id: 
started_at: "2026-04-12T13:38:44Z"
---

## 目标
---
id: "007-eventbus"
depends_on: ["006-entity"]
---

# 007: Combine EventBus + 解耦 HookMessage/SessionManager/SessionRowView

## 目标
1. 创建基于 Combine 的类型安全 EventBus
2. 解耦 `HookMessage` 与 `CatState`（Network 层不再引用 Scene 层类型）
3. 解耦 `SessionManager` 与 `BuddyScene`（通过 EventBus 通信代替直接方法调用）
4. 将 `SessionInfo.state` 从 `CatState` 改为 `EntityState`
5. 更新 `SessionRowView` 使用 `EntityState`

## 架构上下文
当前 `CatState` 从 Scene 层泄漏到 Network（HookMessage.catState）和 Session（SessionInfo.state）层。SessionManager 直接持有 BuddyScene 引用并调用其方法。完成后，各层通过 EventBus 松耦合通信。

## 输入
- `Sources/ClaudeCodeBuddy/Network/HookMessage.swift`（56 行）
- `Sources/ClaudeCodeBuddy/Session/SessionManager.swift`（248 行）
- `Sources/ClaudeCodeBuddy/Session/SessionInfo.swift`（13 行）
- `Sources/ClaudeCodeBuddy/MenuBar/SessionRowView.swift`
- `Sources/ClaudeCodeBuddy/App/AppDelegate.swift`（164 行）

## 输出
新文件：
- `Sources/ClaudeCodeBuddy/Event/EventBus.swift`
- `Sources/ClaudeCodeBuddy/Event/BuddyEvent.swift`
修改文件：
- `HookMessage.swift` —— `catState` 改为返回 `EntityState`
- `SessionManager.swift` —— 通过 EventBus 发布事件，移除 BuddyScene 直接引用
- `SessionInfo.swift` —— `state: CatState` → `state: EntityState`
- `SessionRowView.swift` —— switch 从 `CatState` 改为 `EntityState`
- `AppDelegate.swift` —— 设置 EventBus 订阅

## 实现要点

### EventBus 设计

```swift
import Combine

final class EventBus {
    static let shared = EventBus()

    // 会话事件
    let sessionStarted = PassthroughSubject<SessionEvent, Never>()
    let sessionEnded = PassthroughSubject<SessionEvent, Never>()
    let stateChanged = PassthroughSubject<StateChangeEvent, Never>()
    let labelChanged = PassthroughSubject<LabelChangeEvent, Never>()

    // 食物事件
    let foodSpawnRequested = PassthroughSubject<FoodSpawnEvent, Never>()

    // 环境事件（008 使用）
    let weatherChanged = PassthroughSubject<WeatherEvent, Never>()

    private init() {}
}
```

### BuddyEvent 类型

```swift
struct SessionEvent {
    let sessionId: String
    let info: SessionInfo
}

struct StateChangeEvent {
    let sessionId: String
    let newState: EntityState
    let context: StateContext?
}

struct LabelChangeEvent {
    let sessionId: String
    let newLabel: String
}

struct FoodSpawnEvent {
    let nearX: CGFloat
}
```

### HookMessage 解耦

```swift
// Before (HookMessage.swift)
var catState: CatState? { ... }  // 返回 Scene 层类型

// After
var entityState: EntityState? {
    switch event {
    case .thinking: return .thinking
    case .toolStart: return .toolUse
    case .toolEnd: return .thinking
    case .idle: return .idle
    case .permissionRequest: return .permissionRequest
    default: return nil


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
- [2026-04-12T13:38:44Z] autopilot 初始化（brief 模式），任务: 007-eventbus.md
