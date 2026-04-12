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
brief_file: "/Users/stringzhao/workspace_sync/personal_projects/claude-code-buddy/.autopilot/project/tasks/003-animation.md"
next_task: ""
auto_approve: false
task_dir: "/Users/stringzhao/workspace_sync/personal_projects/claude-code-buddy/.autopilot/requirements/20260412-003-animation"
session_id: 
started_at: "2026-04-12T13:03:53Z"
---

## 目标
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
将纹理加载、帧动画播放、呼吸效果从 CatSprite 提取到独立的 AnimationComponent，成为所有帧动画操作的单一入口。

### 技术方案
- 新建 `Sources/ClaudeCodeBuddy/Scene/Components/AnimationComponent.swift`
- AnimationComponent 持有 `unowned let node: SKSpriteNode`，拥有 `animations` 字典
- 提供 `play()`、`playTransition()`、`startBreathing()`、`stopAll()` 等 API
- CatSprite 添加 `let animationComponent: AnimationComponent`
- 所有 GKState 子类改用 `entity.animationComponent.play(...)` 代替直接构造 SKAction.animate
- `loadTextures()` 方法移入 AnimationComponent
- CatSprite 的 `animations` 字典删除，改为通过 `animationComponent.animations` 访问
- `textures(for:)` 辅助方法移入 AnimationComponent
- `startBreathing()` 移入 AnimationComponent

### 文件影响范围

| 文件 | 操作 | 说明 |
|------|------|------|
| Scene/Components/AnimationComponent.swift | 新建 | 动画组件 |
| Scene/CatSprite.swift | 修改 | 添加 animationComponent，删除动画相关方法 |
| Scene/States/CatIdleState.swift | 修改 | 使用 animationComponent |
| Scene/States/CatThinkingState.swift | 修改 | 使用 animationComponent |
| Scene/States/CatToolUseState.swift | 修改 | 使用 animationComponent |
| Scene/States/CatPermissionRequestState.swift | 修改 | 使用 animationComponent |
| Scene/States/CatEatingState.swift | 修改 | 使用 animationComponent |

## 实现计划

### 任务列表
- [ ] 创建 Scene/Components/ 目录
- [ ] 实现 AnimationComponent.swift（loadTextures、play、playTransition、startBreathing、stopAll、textures(for:)）
- [ ] 修改 CatSprite.swift：添加 animationComponent，删除 loadTextures/animations/textures(for:)/startBreathing
- [ ] 修改所有 GKState 子类：使用 entity.animationComponent 代替直接 SKAction.animate
- [ ] `swift build && swift test` 验证

## 红队验收测试
(待 implement 阶段填充)

## QA 报告

### Tier 1
| 检查项 | 结果 | 证据 |
|--------|------|------|
| `swift build` | ✅ | Build complete! (0.38s) |
| `swift test` | ✅ | 72 tests, 0 failures |

### Tier 2 — 功能验证
| 检查项 | 结果 |
|--------|------|
| AnimationComponent.swift 创建 | ✅ |
| loadTextures/animations/textures(for:)/startBreathing 从 CatSprite 移除 | ✅ |
| 所有 GKState 子类使用 animationComponent | ✅ |

### 结论：全部 ✅

## 变更日志
- [2026-04-12T13:03:53Z] autopilot 初始化（brief 模式），任务: 003-animation.md
