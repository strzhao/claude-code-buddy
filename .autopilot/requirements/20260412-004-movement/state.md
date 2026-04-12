---
active: true
phase: "merge"
gate: ""
iteration: 1
max_iterations: 30
max_retries: 3
retry_count: 0
mode: "single"
plan_mode: ""
brief_file: "/Users/stringzhao/workspace_sync/personal_projects/claude-code-buddy/.autopilot/project/tasks/004-movement.md"
next_task: ""
auto_approve: false
task_dir: "/Users/stringzhao/workspace_sync/personal_projects/claude-code-buddy/.autopilot/requirements/20260412-004-movement"
session_id: 
started_at: "2026-04-12T13:14:24Z"
---

## 目标
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

### 目标
将移动逻辑（随机游走、食物走路、退出走路）提取到 MovementComponent，将两处重复的跳跃弧线逻辑统一到 JumpComponent（消除 ~220 行重复代码），封装 GCD fallback。

### 技术方案

**MovementComponent**：
- 持有 `unowned let containerNode: SKNode`、`unowned let spriteNode: SKSpriteNode`、AnimationComponent 引用
- 提供 `startRandomWalk()`、`doRandomWalkStep()`、`walkToFood()`、`exitScene()`（两个重载）
- 内部使用 JumpComponent 处理跳跃

**JumpComponent**：
- 统一 `buildJumpActions` 和 `exitScene(obstacles:)` 中的 Bezier 弧线逻辑（~220 行重复 → 单一实现）
- 封装 GCD fallback 到内部，暴露 `hasDisplayLink` 检测
- 提供 `buildJumpSequence()` 统一 API

**CatSprite 变更**：
- 添加 `movementComponent` 和 `jumpComponent` 属性
- 删除 `startRandomWalk()`、`doRandomWalkStep()`、`buildJumpActions()`、`walkToFood()`、`exitScene()`（两个重载）
- 保留公共方法签名作为委托（测试兼容）

### 文件影响范围

| 文件 | 操作 | 说明 |
|------|------|------|
| Scene/Components/MovementComponent.swift | 新建 | 移动逻辑 |
| Scene/Components/JumpComponent.swift | 新建 | 统一跳跃弧线 + GCD fallback |
| Scene/CatSprite.swift | 修改 | 删除移动/跳跃方法，添加组件引用 |
| Scene/States/CatToolUseState.swift | 修改 | 调用 movementComponent.startRandomWalk() |

### 风险评估
- **高风险**：29 个 JumpExitTests 直接测试 CatSprite.exitScene 和 playFrightReaction → **缓解**：CatSprite 保留公共方法签名，内部委托给组件
- **中风险**：GCD fallback 时序敏感 → **缓解**：保持完全相同的延迟计算逻辑

## 实现计划

### 任务列表
- [ ] 实现 JumpComponent.swift（统一 Bezier 弧线 + GCD fallback）
- [ ] 实现 MovementComponent.swift（随机游走、食物走路、退出走路）
- [ ] 修改 CatSprite.swift：添加组件引用，删除移动/跳跃私有方法，保留公共委托方法
- [ ] 修改 CatToolUseState.swift：使用 movementComponent
- [ ] `swift build && swift test` 验证（重点 29 个 JumpExitTests）

## 红队验收测试
(待 implement 阶段填充)

## QA 报告

### Tier 1
| 检查项 | 结果 | 证据 |
|--------|------|------|
| `swift build` | ✅ | Build complete! (0.40s) |
| JumpExitTests | ✅ | 29 tests, 0 failures |

### 结论：全部 ✅

## 变更日志
- [2026-04-12T13:14:24Z] autopilot 初始化（brief 模式），任务: 004-movement.md
