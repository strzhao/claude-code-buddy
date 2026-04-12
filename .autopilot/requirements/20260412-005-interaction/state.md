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
brief_file: "/Users/stringzhao/workspace_sync/personal_projects/claude-code-buddy/.autopilot/project/tasks/005-interaction.md"
next_task: ""
auto_approve: false
task_dir: "/Users/stringzhao/workspace_sync/personal_projects/claude-code-buddy/.autopilot/requirements/20260412-005-interaction"
session_id: 7cbae9bb-b5f3-4e2c-bd7e-02a63bef2766
started_at: "2026-04-12T13:26:17Z"
---

## 目标
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
- [2026-04-12T13:26:17Z] autopilot 初始化（brief 模式），任务: 005-interaction.md
