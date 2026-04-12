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
brief_file: "/Users/stringzhao/workspace_sync/personal_projects/claude-code-buddy/.autopilot/project/tasks/001-constants.md"
next_task: ""
auto_approve: false
task_dir: "/Users/stringzhao/workspace_sync/personal_projects/claude-code-buddy/.autopilot/requirements/20260412-001-constants"
session_id: 
started_at: "2026-04-12T12:20:33Z"
---

## 目标
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
将 CatSprite.swift 中 100+ 处硬编码魔数提取为 `CatConstants` 枚举命名空间中的命名常量。不改变任何行为逻辑。

### 技术方案
- 新建 `Sources/ClaudeCodeBuddy/Scene/CatConstants.swift`
- 按功能分组为 7 个嵌套 enum namespace：Movement、Jump、Animation、Physics、Fright、Idle、Visual
- CatSprite.swift 中的魔数全部替换为常量引用
- `CatSprite.hitboxSize`、`hoverScale`、`hoverDuration` 等已有 static let 移入 CatConstants，CatSprite 保留代理属性
- BuddyScene.swift 中的 `48`（ground Y、spawn margin）也统一使用 CatConstants

### 文件影响范围

| 文件 | 操作 | 说明 |
|------|------|------|
| Scene/CatConstants.swift | 新建 | 所有猫相关常量 |
| Scene/CatSprite.swift | 修改 | 魔数替换为常量引用 |
| Scene/BuddyScene.swift | 修改 | 共享常量（groundY、spawnMargin） |

### 风险评估
- 风险极低：纯机械性替换，不改变逻辑
- 缓解：每个分类替换后立即 `swift build` 验证

## 实现计划

### 测试策略
- `swift build` 编译通过
- `swift test` 所有测试通过（含 14 个 JumpExitTests）
- 行为无变化（纯重构）

### 任务列表
- [ ] 创建 CatConstants.swift，定义 7 个 namespace（Movement/Jump/Animation/Physics/Fright/Idle/Visual）
- [ ] 替换 CatSprite.swift 中的 Movement 常量（walkSpeed、range、margin 等）
- [ ] 替换 CatSprite.swift 中的 Jump 常量（arcHeight、arcDuration、approachOffset 等）
- [ ] 替换 CatSprite.swift 中的 Animation 常量（各 timePerFrame、durations）
- [ ] 替换 CatSprite.swift 中的 Physics 常量（bodySize、restitution、friction）
- [ ] 替换 CatSprite.swift 中的 Fright 常量（fleeDistance、reboundFactor、durations）
- [ ] 替换 CatSprite.swift 中的 Idle 常量（weights、durations、counts）
- [ ] 替换 CatSprite.swift 中的 Visual 常量（sizes、scales、colors、font sizes）
- [ ] 更新 BuddyScene.swift 使用 CatConstants 共享常量
- [ ] `swift build && swift test` 验证

## 红队验收测试
(待 implement 阶段填充)

## QA 报告

### Wave 1 — Tier 1 检查
| 检查项 | 结果 | 证据 |
|--------|------|------|
| `swift build` | ✅ | Build complete! (0.38s) |
| `swift test` | ✅ | 72 tests, 0 failures |
| `swift test --filter JumpExitTests` | ✅ | 29 tests, 0 failures |

### Wave 1.5 — 功能验证
| 检查项 | 结果 | 证据 |
|--------|------|------|
| CatConstants.swift 按功能分组 | ✅ | 8 个 namespace: Movement/Jump/Animation/Physics/Fright/Idle/Visual/Scene |
| CatSprite.swift 无未命名魔数 | ✅ | grep 验证：剩余数字仅为 0/1/-1.0/1.0（初始化值）、frames[0]（索引）、Bezier 系数（2） |
| BuddyScene.swift 共享常量 | ✅ | gravity/groundFriction/maxCats/spawnMargin/groundY 均使用 CatConstants |
| hitboxSize 向后兼容 | ✅ | CatSprite.hitboxSize 保留为 static let，引用 CatConstants.Visual.hitboxSize |

### 结论：全部 ✅，推进到 merge

## 变更日志
- [2026-04-12T12:20:33Z] autopilot 初始化（brief 模式），任务: 001-constants.md
- [2026-04-12T12:45:00Z] 设计完成：100+ 魔数审计完毕，7 个 namespace 分组确定，auto-approve 推进到 implement
- [2026-04-12T12:50:00Z] 实现完成：CatConstants.swift 创建（8 个 namespace，~70 常量），CatSprite.swift + BuddyScene.swift 所有魔数已替换。72 tests passed。
