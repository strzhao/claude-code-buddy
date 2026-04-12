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
brief_file: "/Users/stringzhao/workspace_sync/personal_projects/claude-code-buddy/.autopilot/project/tasks/006-entity.md"
next_task: ""
auto_approve: false
task_dir: "/Users/stringzhao/workspace_sync/personal_projects/claude-code-buddy/.autopilot/requirements/20260412-006-entity"
session_id: 7cbae9bb-b5f3-4e2c-bd7e-02a63bef2766
started_at: "2026-04-12T13:33:17Z"
---

## 目标
---
id: "006-entity"
depends_on: ["005-interaction"]
---

# 006: EntityProtocol + EntityState + BuddyScene/FoodManager 重构 + 测试迁移

## 目标
1. 定义 `EntityProtocol` 协议和 `EntityState` 通用状态枚举
2. 让 `CatSprite` 遵循 `EntityProtocol`
3. 重构 `BuddyScene` 使用 `EntityProtocol` 代替具体 `CatSprite` 类型
4. 适配 `FoodManager` 使用 `EntityProtocol`
5. 迁移测试代码适配新接口

## 架构上下文
这是从"猫专用"到"通用实体"的关键抽象步骤。完成后，BuddyScene 不再依赖具体 CatSprite 类型，未来添加新实体类型只需实现 EntityProtocol。

## 输入
- `Sources/ClaudeCodeBuddy/Scene/CatSprite.swift`（005 产出，~400-500 行）
- `Sources/ClaudeCodeBuddy/Scene/BuddyScene.swift`（255 行）
- `Sources/ClaudeCodeBuddy/Scene/FoodManager.swift`（160 行）
- `Tests/BuddyCoreTests/JumpExitTests.swift`

## 输出
新文件：
- `Sources/ClaudeCodeBuddy/Entity/EntityProtocol.swift`
- `Sources/ClaudeCodeBuddy/Entity/EntityState.swift`
修改文件：
- `CatSprite.swift` —— 添加 `EntityProtocol` 遵循
- `BuddyScene.swift` —— `cats: [String: CatSprite]` → `entities: [String: any EntityProtocol]`
- `FoodManager.swift` —— `idleCats()` → `idleEntities()`
- `JumpExitTests.swift` —— 适配新接口

## 实现要点

### EntityProtocol 定义

```swift
import SpriteKit

protocol EntityProtocol: AnyObject {
    var sessionId: String { get }
    var containerNode: SKNode { get }
    var currentStateIdentifier: EntityState { get }

    func switchState(to state: EntityState, context: StateContext?)
    func enterScene(sceneSize: CGSize)
    func exitScene(sceneWidth: CGFloat, obstacles: [(CGFloat, any EntityProtocol)],
                   onJumpOver: ((any EntityProtocol) -> Void)?, completion: @escaping () -> Void)

    func applyHoverScale()
    func removeHoverScale()
    func updateSceneSize(_ size: CGSize)
    func playFrightReaction(awayFromX jumperX: CGFloat)

    var onFoodAbandoned: ((String) -> Void)? { get set }
}

/// 可选：食物交互能力
protocol FoodInteractable: EntityProtocol {
    var currentTargetFood: FoodSprite? { get set }
    func walkToFood(_ food: FoodSprite, onArrival: @escaping () -> Void)
    func startEating(_ food: FoodSprite, completion: @escaping () -> Void)
}
```

### EntityState 定义

```swift
enum EntityState: String, CaseIterable, Sendable {
    case idle              = "idle"
    case thinking          = "thinking"
    case toolUse           = "tool_use"
    case permissionRequest = "waiting"
    case eating            = "eating"
}
```

### StateContext（可选传递额外信息）

```swift
struct StateContext {
    var toolDescription: String?
}
```

### BuddyScene 重构

```swift
// Before
private var cats: [String: CatSprite] = [:]
func addCat(info: SessionInfo) { ... }
func catAtPoint(_ point: CGPoint) -> String? { ... }

// After
private var entities: [String: any EntityProtocol] = [:]
func addEntity(_ entity: any EntityProtocol) { ... }
func entityAtPoint(_ point: CGPoint) -> String? { ... }

// 保留 addCat 作为便捷方法


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
- [2026-04-12T13:33:17Z] autopilot 初始化（brief 模式），任务: 006-entity.md
