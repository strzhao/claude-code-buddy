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
brief_file: "/Users/stringzhao/workspace_sync/personal_projects/claude-code-buddy/.autopilot/project/tasks/002-gkstate.md"
next_task: ""
auto_approve: false
task_dir: "/Users/stringzhao/workspace_sync/personal_projects/claude-code-buddy/.autopilot/requirements/20260412-002-gkstate"
session_id: 
started_at: "2026-04-12T12:44:05Z"
---

## 目标
---
id: "002-gkstate"
depends_on: ["001-constants"]
---

# 002: GKStateMachine + 5 个 GKState 子类

## 目标
用 GameplayKit 的 GKStateMachine 替代当前的 `CatState` enum + `switchState`/`applyState` 手写状态机。每个状态成为独立的 GKState 子类文件。

## 架构上下文
这是核心重构步骤。当前 CatSprite 的状态逻辑散布在 `switchState(to:)`、`transitionAnimation(from:to:)`、`applyState(_:)` 以及各状态的启动方法中（`startIdleLoop`、`startRandomWalk` 等），合计约 500 行。GKStateMachine 强制每个状态的逻辑自包含。

### GKStateMachine 与 SKAction 的协调方案

GKStateMachine 的 `enter()` 是同步的，但状态切换需要异步过渡动画。采用**方案 A**：

```
enter(CatThinkingState.self)
  → CatThinkingState.didEnter(from:)
    → 检测 from 类型决定过渡动画
    → 有过渡：播放过渡帧 → completion 回调启动稳态动画
    → 无过渡：直接启动稳态动画
```

## 输入
- `Sources/ClaudeCodeBuddy/Scene/CatSprite.swift` —— 状态相关逻辑
- `Sources/ClaudeCodeBuddy/Scene/CatConstants.swift`（001 产出）

## 输出
新建目录和文件：
```
Sources/ClaudeCodeBuddy/Scene/States/
├── CatIdleState.swift              # idle + IdleSubState 子状态机
├── CatThinkingState.swift          # thinking：paw 动画 + 摇摆
├── CatToolUseState.swift           # toolUse：随机游走
├── CatPermissionRequestState.swift # permissionRequest：scared + 红色 + 跳动
├── CatEatingState.swift            # eating：进食动画
```
修改文件：
- `CatSprite.swift` —— 添加 `stateMachine: GKStateMachine`，重写 `switchState` 为 `stateMachine.enter()`

## 实现要点

### GKState 子类模板

```swift
import GameplayKit

class CatThinkingState: GKState {
    unowned let entity: CatSprite

    init(entity: CatSprite) {
        self.entity = entity
        super.init()
    }

    override func isValidNextState(_ stateClass: AnyClass) -> Bool {
        // 从 thinking 可以转到：idle, toolUse, permissionRequest
        return stateClass is CatIdleState.Type
            || stateClass is CatToolUseState.Type
            || stateClass is CatPermissionRequestState.Type
    }

    override func didEnter(from previousState: GKState?) {
        // 过渡动画
        if previousState is CatIdleState {
            entity.animPlay("idle-b", loop: false) { [weak self] in
                self?.startThinkingLoop()
            }
        } else {
            startThinkingLoop()
        }
    }

    override func willExit(to nextState: GKState) {
        entity.node.removeAction(forKey: "animation")
        entity.node.removeAction(forKey: "stateEffect")
        entity.node.removeAction(forKey: "breathing")
    }

    private func startThinkingLoop() { ... }
}
```

### CatSprite 变更

```swift
import GameplayKit

class CatSprite {
    private(set) var stateMachine: GKStateMachine!

    // 保留 currentState 计算属性用于兼容
    var currentState: CatState {
        switch stateMachine.currentState {
        case is CatIdleState: return .idle
        case is CatThinkingState: return .thinking
        // ...
        }


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
用 GameplayKit GKStateMachine 替代当前 CatState enum + switchState/applyState 手写状态机。5 个状态各自成为独立 GKState 子类文件。

### 技术方案

**GKStateMachine 与 SKAction 过渡动画协调（方案 A）**：
- `didEnter(from:)` 检测前一状态类型，决定过渡动画
- 有过渡：播放过渡帧 → completion 回调启动稳态动画
- 无过渡：直接启动稳态动画
- `willExit(to:)` 清理本状态的 action keys

**CatSprite 变更**：
- 添加 `stateMachine: GKStateMachine`
- `currentState` 改为计算属性（从 stateMachine.currentState 映射到 CatState）
- `switchState(to:)` 改为映射 CatState → GKState 类型，调用 `stateMachine.enter()`
- 删除 `applyState()`、`transitionAnimation(from:to:)` 方法
- 需要暴露给 GKState 的属性标为 internal（去掉 private）

**GKState 子类需要访问的 CatSprite 成员**（标为 internal）：
- `node`, `containerNode`, `animations`, `sessionColor`, `sessionTintFactor`
- `facingRight`, `originX`, `sceneWidth`
- `labelNode`, `shadowLabelNode`, `alertOverlayNode`, `tabNameNode`, `tabNameShadowNode`, `tabName`
- `currentTargetFood`, `onFoodAbandoned`, `nearbyObstacles`
- `textures(for:)`, `applyFacingDirection()`, `showLabel()`, `hideLabel()`, `addAlertOverlay()`, `removeAlertOverlay()`
- `startBreathing()`, `playIdleAnimation()`, `scheduleNextIdleTransition()`

**状态转换表**：

| From | To | 过渡动画 |
|------|----|----------|
| idle → thinking | blink (idle-b) |
| permissionRequest → idle/thinking | jump |
| toolUse/thinking → idle | clean |
| eating → idle | clean |
| 其他 | 无 |

**isValidNextState 规则**：
- idle → thinking, toolUse, permissionRequest, eating
- thinking → idle, toolUse, permissionRequest
- toolUse → idle, thinking, permissionRequest
- permissionRequest → idle, thinking, toolUse
- eating → idle

### 文件影响范围

| 文件 | 操作 | 说明 |
|------|------|------|
| Scene/States/CatIdleState.swift | 新建 | idle + IdleSubState 子状态机 (~150 行) |
| Scene/States/CatThinkingState.swift | 新建 | paw 动画 + 摇摆 + 呼吸 (~60 行) |
| Scene/States/CatToolUseState.swift | 新建 | 随机游走启动 (~40 行) |
| Scene/States/CatPermissionRequestState.swift | 新建 | scared + 红色 + 跳动 + badge (~80 行) |
| Scene/States/CatEatingState.swift | 新建 | eating 占位（逻辑仍在 CatSprite.startEating）(~30 行) |
| Scene/CatSprite.swift | 修改 | 添加 stateMachine，删除 applyState/transitionAnimation，暴露内部属性 |

### 风险评估
- **风险**：GKState 子类需要访问大量 CatSprite 内部属性 → **缓解**：暂时标为 internal，后续由组件化进一步封装
- **风险**：startEating 绕过状态机 → **缓解**：本任务改为通过 stateMachine.enter() 进入，CatEatingState.didEnter 触发动画
- **风险**：idle 子状态机复杂（递归 SKAction 闭包链）→ **缓解**：完整移入 CatIdleState，保持逻辑不变

## 实现计划

### 测试策略
- `swift build` 编译通过
- `swift test` 所有 72 个测试通过（含 29 个 JumpExitTests）
- 行为无变化（状态机重构，外部接口不变）

### 任务列表
- [ ] 创建 Sources/ClaudeCodeBuddy/Scene/States/ 目录
- [ ] 实现 CatIdleState.swift（含 IdleSubState 子状态机：startIdleLoop/pickNextIdleSubState/runIdleSubState/playIdleAnimation/scheduleNextIdleTransition）
- [ ] 实现 CatThinkingState.swift（paw 动画 + 摇摆 + 呼吸）
- [ ] 实现 CatToolUseState.swift（startRandomWalk 启动）
- [ ] 实现 CatPermissionRequestState.swift（scared + 红色 + 跳动 + shake + label + badge）
- [ ] 实现 CatEatingState.swift（占位，配合 startEating 流程）
- [ ] 修改 CatSprite.swift：添加 GKStateMachine，重写 switchState，删除 applyState/transitionAnimation，暴露内部属性
- [ ] 修改 CatSprite.swift：startEating 改用 stateMachine.enter(CatEatingState.self)
- [ ] `swift build && swift test` 验证

## 红队验收测试
(待 implement 阶段填充)

## QA 报告

### Wave 1 — Tier 1 检查
| 检查项 | 结果 | 证据 |
|--------|------|------|
| `swift build` | ✅ | Build complete! (0.41s) |
| `swift test` | ✅ | 72 tests, 0 failures |
| `swift test --filter JumpExitTests` | ✅ | 29 tests, 0 failures |

### Wave 1.5 — 功能验证
| 检查项 | 结果 | 证据 |
|--------|------|------|
| 5 个 GKState 子类创建 | ✅ | CatIdleState/CatThinkingState/CatToolUseState/CatPermissionRequestState/CatEatingState + ResumableState |
| applyState/transitionAnimation 已删除 | ✅ | grep 验证：CatSprite 中无 applyState/transitionAnimation |
| stateMachine 正确集成 | ✅ | 9 处 stateMachine 引用 |
| CatSprite 行数减少 | ✅ | 1230 → 1036 行（减少 ~200 行） |
| startEating 使用 stateMachine.enter | ✅ | 不再直接赋值 currentState |
| playFrightReaction 使用 ResumableState | ✅ | recover 中调用 (state as? ResumableState)?.resume() |

### 结论：全部 ✅，推进到 merge

## 变更日志
- [2026-04-12T12:44:05Z] autopilot 初始化（brief 模式），任务: 002-gkstate.md
- [2026-04-12T13:00:00Z] 设计完成：GKStateMachine 方案 A，5 个 GKState 子类，auto-approve 推进到 implement
