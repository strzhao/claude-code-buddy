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
    }
}
```

### SessionManager 解耦

```swift
// Before
var scene: BuddyScene?  // 直接引用
func handle(message: HookMessage) {
    // ...
    scene?.updateCatState(sessionId: id, state: state, toolDescription: desc)
}

// After
private var cancellables = Set<AnyCancellable>()

func handle(message: HookMessage) {
    // ...
    if let state = message.entityState {
        EventBus.shared.stateChanged.send(StateChangeEvent(
            sessionId: id, newState: state, context: StateContext(toolDescription: desc)
        ))
    }
}
```

### AppDelegate 订阅设置

```swift
// 在 AppDelegate 中连接 EventBus → BuddyScene
EventBus.shared.stateChanged
    .receive(on: RunLoop.main)
    .sink { [weak self] event in
        self?.scene.updateEntityState(sessionId: event.sessionId,
                                       state: event.newState,
                                       context: event.context)
    }
    .store(in: &cancellables)
```

### SessionRowView 更新

```swift
// Before
switch session.state {
case .idle: ...
case .thinking: ...
// CatState cases

// After
switch session.state {
case .idle: ...
case .thinking: ...
// EntityState cases (same case names)
```

### 验证解耦成功

```bash
# Network 层不应引用 CatState
grep -r "CatState" Sources/ClaudeCodeBuddy/Network/  # 应为空

# Session 层不应引用 CatState
grep -r "CatState" Sources/ClaudeCodeBuddy/Session/  # 应为空

# CatState 应只存在于 Entity/Cat/ 内部
grep -rn "CatState" Sources/ClaudeCodeBuddy/ | grep -v "Entity/Cat/"  # 应为空
```

## 验收标准
- [ ] `swift build` 编译通过
- [ ] `swift test` 所有测试通过
- [ ] `grep -r "CatState" Sources/ClaudeCodeBuddy/Network/` 返回空
- [ ] `grep -r "CatState" Sources/ClaudeCodeBuddy/Session/` 返回空
- [ ] SessionManager 不再持有 BuddyScene 直接引用
- [ ] SessionRowView 使用 EntityState
- [ ] EventBus 事件在主线程投递
