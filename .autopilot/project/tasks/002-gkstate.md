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
    }

    init(sessionId: String) {
        // ... existing init ...
        let states = [
            CatIdleState(entity: self),
            CatThinkingState(entity: self),
            CatToolUseState(entity: self),
            CatPermissionRequestState(entity: self),
            CatEatingState(entity: self)
        ]
        stateMachine = GKStateMachine(states: states)
    }

    func switchState(to newState: CatState, toolDescription: String? = nil) {
        let stateClass: AnyClass = switch newState {
        case .idle: CatIdleState.self
        case .thinking: CatThinkingState.self
        case .toolUse: CatToolUseState.self
        case .permissionRequest: CatPermissionRequestState.self
        case .eating: CatEatingState.self
        }
        stateMachine.enter(stateClass)
    }
}
```

### CatIdleState 特殊处理
- 包含内部 `IdleSubState` 枚举和子状态循环（`startIdleLoop`/`pickNextIdleSubState`/`runIdleSubState`）
- 这是最复杂的状态，约 150 行

### CatEatingState 进入机制
- `startEating(_:completion:)` 开头改用 `stateMachine.enter(CatEatingState.self)` 代替直接赋值
- `CatEatingState.didEnter(from:)` 负责初始化，具体动画仍由 `startEating` 的后续流程驱动

### 需要暴露给 GKState 的 CatSprite 方法
GKState 子类需要访问的 CatSprite 属性/方法（暂时标为 internal，后续由组件化进一步封装）：
- `node: SKSpriteNode`
- `containerNode: SKNode`
- `animations: [String: [SKTexture]]`
- `facingRight`, `originX`, `sceneWidth`
- `sessionColor`, `sessionTintFactor`
- `labelNode`, `shadowLabelNode`, `alertOverlayNode`
- 动画播放辅助方法（从 applyState 中提取）
- `startRandomWalk()`, `startIdleLoop()` 等（移入对应 GKState）

## 验收标准
- [ ] `swift build` 编译通过
- [ ] `swift test --filter JumpExitTests` 全部 14 条通过
- [ ] 所有 5 种状态通过 socket 消息触发时行为与重构前一致
- [ ] `CatSprite.switchState` 不再包含 switch/case 行为逻辑（仅做 stateClass 映射 + enter）
- [ ] `CatSprite.applyState` 方法已删除
- [ ] `.eating` 状态通过 `stateMachine.enter()` 进入，不再直接赋值 `currentState`
