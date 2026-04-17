# Rocket Morph Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 ClaudeCodeBuddy 重构为可在猫 / 火箭两种形态间热切换，Phase 1 实现抽象层 + 火箭纯状态可视化 MVP。

**Architecture:** 薄 `SessionEntity` 协议 + `CatEntity` / `RocketEntity` 并列，两套状态机完全解耦，只共享 `SessionEvent` 通用事件。`EntityModeStore` 单一真相源 + Combine publisher 驱动热切换。EventBus 新增 `sceneExpansionRequested` 让火箭状态请求 `BuddyWindow` 向上临时扩展。

**Tech Stack:** Swift 5.9 / SpriteKit / GameplayKit / Combine / AppKit / XCTest / shell acceptance

**Spec:** `docs/superpowers/specs/2026-04-17-rocket-refactor-design.md` (commit `028b528`)

---

## File Structure

### 新建文件

```
Sources/ClaudeCodeBuddy/Entity/
├── SessionEntity.swift                      # 新薄协议（替代 EntityProtocol）
├── EntityInputEvent.swift                   # 新事件枚举（不叫 SessionEvent，避免与现有 struct 冲突）
├── EntityMode.swift                         # enum { .cat, .rocket }
├── EntityModeStore.swift                    # 单例 + 持久化 + Combine publisher
├── EntityFactory.swift                      # make(mode:sessionId:color:label:) -> SessionEntity
└── Rocket/
    ├── RocketEntity.swift
    ├── RocketConstants.swift
    ├── RocketSpriteLoader.swift             # 资源加载 + 占位精灵 fallback
    ├── States/
    │   ├── RocketState.swift                 # enum
    │   ├── RocketBaseState.swift             # GKState 基类
    │   ├── RocketOnPadState.swift
    │   ├── RocketSystemsCheckState.swift
    │   ├── RocketCruisingState.swift
    │   ├── RocketAbortStandbyState.swift
    │   ├── RocketPropulsiveLandingState.swift
    │   └── RocketLiftoffState.swift
    └── RocketComponents/
        ├── ExhaustComponent.swift
        ├── WarningLightComponent.swift
        └── PadComponent.swift
```

### 改名 / 移动

```
Sources/ClaudeCodeBuddy/Entity/
├── EntityProtocol.swift      → 删除（内容被 SessionEntity.swift 替代）
├── EntityState.swift         → 保留不动（仍被 HookMessage/SessionInfo 使用）
└── Cat/
    ├── CatSprite.swift       → CatEntity.swift (class CatSprite → class CatEntity)
    └── CatComponents/        ← 原 Entity/Components/ 移入

Sources/ClaudeCodeBuddy/Event/
└── BuddyEvent.swift          → 内 struct SessionEvent 改名 SessionLifecycleEvent
```

### 改动（不改名）

```
Sources/ClaudeCodeBuddy/
├── Event/EventBus.swift                         # 新增 sceneExpansionRequested, entityModeChanged
├── Scene/BuddyScene.swift                        # cats: [String: CatSprite] → entities: [String: SessionEntity]
├── Scene/SceneControlling.swift                 # 接口适度改 generic（CatState 参数保留，向下转型使用）
├── Session/SessionManager.swift                 # 走 EntityFactory + 订阅 EntityModeStore
├── Window/BuddyWindow.swift                      # 增加 expandHeight(by:duration:) API
├── Window/DockTracker.swift                      # 新增暂停贴边修正标志
├── MenuBar/SessionPopoverController.swift       # 顶部加 Morph 分段控件
└── App/AppDelegate.swift                         # 启动时初始化 EntityModeStore
Sources/BuddyCLI/main.swift                       # 新增 morph subcommand
```

### 新增资源

```
Sources/ClaudeCodeBuddy/Assets/Sprites/Rocket/   # Step 6 填充，Step 3 空/占位
Scripts/generate-rocket-sprites-v2.swift          # Step 6，重写生成器
```

### 新增测试

```
Tests/BuddyCoreTests/
├── EntityInputEventTests.swift
├── EntityModeStoreTests.swift
├── EntityFactoryTests.swift
├── RocketEntityTests.swift
├── RocketStateTransitionTests.swift
├── SceneExpansionEventTests.swift
└── HotSwitchIntegrationTests.swift

tests/acceptance/
└── test-rocket-morph.sh
```

---

## Global Conventions

- **工作目录**：`/Users/lilei03/claude/ClaudeCodeBuddy/claude-code-buddy`
- **每个 Task 的提交**：feat/refactor/test/fix + 简短中文描述
- **每次小步后跑**：`make lint` + `swift test`（或 `swift test --filter <pattern>` 限定新增测试快速反馈）
- **注意**：测试位于 `Tests/BuddyCoreTests/`（macOS 大小写不敏感，历史上既有 `tests/` 也有 `Tests/`，`Package.swift` 声明的是 `Tests/`）
- **SwiftLint / SwiftFormat**：提交前运行 `make lint-fix && make format`

---

# Step 1 · 抽象层骨架

**目标**：把 `CatSprite` 改名为 `CatEntity` 并实现事件驱动接口，引入 `SessionEntity` 薄协议和 `EntityInputEvent` 枚举。**行为零变化**，所有现有测试通过。

**Merge 点**：v0.6.1 行为完全一致，但内部接口已就位。

---

### Task 1.1: 重命名现有 SessionEvent struct 避免冲突

`Event/BuddyEvent.swift` 现有一个 `struct SessionEvent` 用于 EventBus 的 sessionStarted/sessionEnded 广播。我们要新增一个 `SessionEvent` 枚举——名字冲突。把老的改名为 `SessionLifecycleEvent`。

**Files:**
- Modify: `Sources/ClaudeCodeBuddy/Event/BuddyEvent.swift:4-7`
- Modify: `Sources/ClaudeCodeBuddy/Event/EventBus.swift:7-8`
- Modify: `Tests/BuddyCoreTests/EventBusTests.swift`（扫 `SessionEvent` 引用）

- [ ] **Step 1: Grep 现有引用全量排查**

```bash
cd /Users/lilei03/claude/ClaudeCodeBuddy/claude-code-buddy
grep -rn "SessionEvent" Sources/ Tests/ --include="*.swift"
```

记录所有出现位置，核对不会误伤。

- [ ] **Step 2: 改 struct 名**

`Sources/ClaudeCodeBuddy/Event/BuddyEvent.swift:4-7`，将：

```swift
struct SessionEvent {
    let sessionId: String
    let info: SessionInfo
}
```

改为：

```swift
struct SessionLifecycleEvent {
    let sessionId: String
    let info: SessionInfo
}
```

- [ ] **Step 3: 改 EventBus 泛型参数**

`Sources/ClaudeCodeBuddy/Event/EventBus.swift:7-8`：

```swift
let sessionStarted = PassthroughSubject<SessionLifecycleEvent, Never>()
let sessionEnded = PassthroughSubject<SessionLifecycleEvent, Never>()
```

- [ ] **Step 4: 扫测试文件引用并替换**

```bash
grep -l "SessionEvent" Tests/BuddyCoreTests/*.swift
```

所有出现 `SessionEvent(` 构造、`PassthroughSubject<SessionEvent` 的地方改为 `SessionLifecycleEvent`。

- [ ] **Step 5: 编译验证**

```bash
swift build 2>&1 | grep -E "error|warning" | head -30
```

预期：0 errors。

- [ ] **Step 6: 测试验证**

```bash
swift test 2>&1 | tail -20
```

预期：所有测试通过。

- [ ] **Step 7: Commit**

```bash
git add Sources/ClaudeCodeBuddy/Event/BuddyEvent.swift \
        Sources/ClaudeCodeBuddy/Event/EventBus.swift \
        Tests/BuddyCoreTests/
git commit -m "refactor(event): SessionEvent struct 改名为 SessionLifecycleEvent

为 Phase 1 新 SessionEvent 枚举腾出名字。改动是纯重命名，语义不变。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 1.2: 新建 EntityInputEvent 枚举（TDD）

**注**：虽然 spec 里叫 `SessionEvent`，但为了与 `HookEvent` 和刚改名后的 `SessionLifecycleEvent` 在语义上清楚区分，新枚举命名为 **`EntityInputEvent`**（"给 Entity 的输入事件"）。这是对 spec 的一次命名微调，原因是在现有 event 命名空间里 `SessionEvent` 已被占用且冲突风险高；如严格按 spec，后续可以全局 rename。

**Files:**
- Create: `Sources/ClaudeCodeBuddy/Entity/EntityInputEvent.swift`
- Create: `Tests/BuddyCoreTests/EntityInputEventTests.swift`

- [ ] **Step 1: Write the failing test**

`Tests/BuddyCoreTests/EntityInputEventTests.swift`：

```swift
import XCTest
@testable import BuddyCore

final class EntityInputEventTests: XCTestCase {

    func testFromHookEvent_sessionStart() {
        let e = EntityInputEvent.from(hookEvent: .sessionStart, tool: nil, description: nil)
        if case .sessionStart = e { return }
        XCTFail("expected .sessionStart, got \(e)")
    }

    func testFromHookEvent_thinking() {
        let e = EntityInputEvent.from(hookEvent: .thinking, tool: nil, description: nil)
        if case .thinking = e { return }
        XCTFail("expected .thinking, got \(e)")
    }

    func testFromHookEvent_toolStart_withTool() {
        let e = EntityInputEvent.from(hookEvent: .toolStart, tool: "Read", description: "Reading file")
        if case .toolStart(let name, let desc) = e {
            XCTAssertEqual(name, "Read")
            XCTAssertEqual(desc, "Reading file")
            return
        }
        XCTFail("expected .toolStart, got \(e)")
    }

    func testFromHookEvent_permissionRequest_carriesDescription() {
        let e = EntityInputEvent.from(hookEvent: .permissionRequest, tool: "Bash", description: "rm -rf /")
        if case .permissionRequest(let desc) = e {
            XCTAssertEqual(desc, "rm -rf /")
            return
        }
        XCTFail("expected .permissionRequest, got \(e)")
    }

    func testFromHookEvent_taskComplete() {
        let e = EntityInputEvent.from(hookEvent: .taskComplete, tool: nil, description: nil)
        if case .taskComplete = e { return }
        XCTFail("expected .taskComplete, got \(e)")
    }

    func testFromHookEvent_sessionEnd() {
        let e = EntityInputEvent.from(hookEvent: .sessionEnd, tool: nil, description: nil)
        if case .sessionEnd = e { return }
        XCTFail("expected .sessionEnd, got \(e)")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
swift test --filter EntityInputEventTests 2>&1 | tail -10
```

Expected: compile error `cannot find 'EntityInputEvent'`.

- [ ] **Step 3: Create the enum**

`Sources/ClaudeCodeBuddy/Entity/EntityInputEvent.swift`：

```swift
import Foundation

/// Generic input event passed to any SessionEntity.
/// Each entity (CatEntity / RocketEntity) translates these into its own state machine.
/// Decoupled from HookEvent (network layer) and EntityState (display layer).
enum EntityInputEvent {
    case sessionStart
    case thinking
    case toolStart(name: String?, description: String?)
    case toolEnd(name: String?)
    case permissionRequest(description: String?)
    case taskComplete
    case sessionEnd
    case hoverEnter
    case hoverExit
    case externalCommand(String)   // phase 2 扩展位（如 "rud"）

    /// Convert a HookEvent + optional payload into an EntityInputEvent.
    /// set_label / idle are not translated here (handled separately by SessionManager).
    static func from(hookEvent: HookEvent, tool: String?, description: String?) -> EntityInputEvent {
        switch hookEvent {
        case .sessionStart: return .sessionStart
        case .thinking:     return .thinking
        case .toolStart:    return .toolStart(name: tool, description: description)
        case .toolEnd:      return .toolEnd(name: tool)
        case .permissionRequest: return .permissionRequest(description: description)
        case .taskComplete: return .taskComplete
        case .sessionEnd:   return .sessionEnd
        case .idle:         return .thinking  // fallback; SessionManager normally filters this out
        case .setLabel:     return .thinking  // unreachable in practice
        }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
swift test --filter EntityInputEventTests 2>&1 | tail -10
```

Expected: `Test Suite 'EntityInputEventTests' passed`.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeCodeBuddy/Entity/EntityInputEvent.swift \
        Tests/BuddyCoreTests/EntityInputEventTests.swift
git commit -m "feat(entity): 新增 EntityInputEvent 通用事件枚举

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 1.3: 新建 SessionEntity 薄协议

原 `EntityProtocol` 保留 `CatState` / `switchState` 等猫味方法，不够薄。新建 `SessionEntity` 协议，老协议后续删除。

**Files:**
- Create: `Sources/ClaudeCodeBuddy/Entity/SessionEntity.swift`

- [ ] **Step 1: Create protocol**

`Sources/ClaudeCodeBuddy/Entity/SessionEntity.swift`：

```swift
import SpriteKit

/// The abstraction boundary between SessionManager/BuddyScene and concrete entities
/// (CatEntity, RocketEntity). Must NOT contain form-specific vocabulary (cat/rocket/paw/fuel).
/// Protocol body kept under ~30 lines on purpose — keep it thin.
protocol SessionEntity: AnyObject {
    var sessionId: String { get }
    var containerNode: SKNode { get }
    var sessionColor: SessionColor? { get }
    var isDebug: Bool { get }

    /// Configure color + visible label after creation.
    func configure(color: SessionColor, labelText: String)
    /// Update the visible label.
    func updateLabel(_ newLabel: String)
    /// Called when the entity joins the scene.
    func enterScene(sceneSize: CGSize, activityBounds: ClosedRange<CGFloat>?)
    /// Animate away and invoke completion when fully removed.
    func exitScene(sceneWidth: CGFloat, completion: @escaping () -> Void)
    /// Propagate scene size changes.
    func updateSceneSize(_ size: CGSize)
    /// Hover feedback.
    func applyHoverScale()
    func removeHoverScale()
    /// Single entry point for all state-transition input.
    func handle(event: EntityInputEvent)
}
```

- [ ] **Step 2: Build to verify syntax**

```bash
swift build 2>&1 | grep -E "error" | head -10
```

Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/ClaudeCodeBuddy/Entity/SessionEntity.swift
git commit -m "feat(entity): 新增 SessionEntity 薄协议（≤30 行骨架）

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 1.4: 将 Components/ 下沉至 Cat/CatComponents/

**Files:**
- Move: `Sources/ClaudeCodeBuddy/Entity/Components/*.swift` → `Sources/ClaudeCodeBuddy/Entity/Cat/CatComponents/`
- Modify: `Sources/ClaudeCodeBuddy/Entity/Cat/CatSprite.swift`（若有显式 Components/ 路径注释）

- [ ] **Step 1: Move the directory**

```bash
cd /Users/lilei03/claude/ClaudeCodeBuddy/claude-code-buddy
mkdir -p Sources/ClaudeCodeBuddy/Entity/Cat/CatComponents
git mv Sources/ClaudeCodeBuddy/Entity/Components/*.swift \
       Sources/ClaudeCodeBuddy/Entity/Cat/CatComponents/
rmdir Sources/ClaudeCodeBuddy/Entity/Components
```

- [ ] **Step 2: 校验引用未损坏（Swift 以模块而非文件路径解析）**

```bash
swift build 2>&1 | grep -E "error" | head
```

Expected: no errors（Swift 不关心文件路径，类名不变，编译应通过）。

- [ ] **Step 3: 更新 CLAUDE.md 架构图**

`CLAUDE.md:19-24` 的目录说明改为：

```
│   ├── Entity/         # 实体抽象层
│   │   ├── SessionEntity.swift      # 薄抽象协议
│   │   ├── EntityInputEvent.swift   # 通用事件枚举
│   │   ├── EntityState.swift        # （display 层枚举，保留）
│   │   ├── Cat/                     # 猫实体
│   │   │   ├── CatSprite.swift
│   │   │   ├── CatConstants.swift
│   │   │   ├── States/
│   │   │   └── CatComponents/       # 猫专属组件
```

- [ ] **Step 4: Test**

```bash
swift test 2>&1 | tail -5
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeCodeBuddy/Entity/ CLAUDE.md
git commit -m "refactor(entity): Components/ 下沉至 Cat/CatComponents/

对应 C 完全解耦方案——组件属于具体形态，不做跨形态共享。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 1.5: CatSprite 类改名为 CatEntity（文件 + 类）

**Files:**
- Rename: `Sources/ClaudeCodeBuddy/Entity/Cat/CatSprite.swift` → `CatEntity.swift`
- Modify: all files referencing `CatSprite`（见 Task 1.0 中已扫描的 17+9 个文件）

- [ ] **Step 1: 精确扫描所有 CatSprite 出现**

```bash
cd /Users/lilei03/claude/ClaudeCodeBuddy/claude-code-buddy
grep -rln "CatSprite" Sources/ Tests/ tests/ --include="*.swift" --include="*.sh" --include="*.md" > /tmp/catsprite-refs.txt
cat /tmp/catsprite-refs.txt
```

记录清单备查。

- [ ] **Step 2: 文件重命名**

```bash
git mv Sources/ClaudeCodeBuddy/Entity/Cat/CatSprite.swift \
       Sources/ClaudeCodeBuddy/Entity/Cat/CatEntity.swift
```

- [ ] **Step 3: 类定义改名**

编辑 `Sources/ClaudeCodeBuddy/Entity/Cat/CatEntity.swift`，把 `class CatSprite` 全局替换为 `class CatEntity`：

```bash
sed -i '' 's/class CatSprite/class CatEntity/g' Sources/ClaudeCodeBuddy/Entity/Cat/CatEntity.swift
sed -i '' 's/extension CatSprite/extension CatEntity/g' Sources/ClaudeCodeBuddy/Entity/Cat/CatEntity.swift
```

（注：Edit 工具更安全，但此处纯粹 token 替换，sed 足够。）

- [ ] **Step 4: 更新所有引用**

对每个在 `/tmp/catsprite-refs.txt` 的文件：

```bash
while read f; do
  [ -f "$f" ] && sed -i '' 's/CatSprite/CatEntity/g' "$f"
done < /tmp/catsprite-refs.txt
```

但 **`Sources/ClaudeCodeBuddy/Entity/EntityProtocol.swift`** 的注释提及 "CatSprite conforms to this protocol" 改为 "CatEntity conforms to this protocol"（保留，因为协议本身 Task 1.8 才删）。

- [ ] **Step 5: Build**

```bash
swift build 2>&1 | grep -E "error" | head
```

Expected: no errors.

- [ ] **Step 6: Test**

```bash
swift test 2>&1 | tail -5
```

Expected: all pass。若 test 内有字符串字面量含 `"CatSprite"`（例如 `cat.node.name?.hasPrefix("catSprite_")`——注意这是下划线小写的 node name prefix），**不要改**。核查 `sed` 没误伤字符串字面量：

```bash
grep -n "CatSprite" Sources/ClaudeCodeBuddy/Entity/Cat/CatEntity.swift
```

`node.name = "catSprite_\(sessionId)"` 这行保留（SpriteKit 节点命名习惯，向后兼容 QueryHandler 可能的查询）。

- [ ] **Step 7: Commit**

```bash
git add -A Sources/ Tests/ tests/
git commit -m "refactor(entity): CatSprite 类改名为 CatEntity

对应 B 方案抽象层 + 命名中性化。节点 name 前缀 catSprite_ 保留
以维持 QueryHandler 和 acceptance 测试兼容性。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 1.6: CatEntity 实现 SessionEntity 协议 + handle(event:) 方法（TDD）

**Files:**
- Modify: `Sources/ClaudeCodeBuddy/Entity/Cat/CatEntity.swift`
- Create: `Tests/BuddyCoreTests/CatEntityEventTests.swift`

- [ ] **Step 1: Write failing test for event handling**

`Tests/BuddyCoreTests/CatEntityEventTests.swift`：

```swift
import XCTest
@testable import BuddyCore

final class CatEntityEventTests: XCTestCase {

    func testHandleThinking_entersThinkingState() {
        let cat = CatEntity(sessionId: "test-thinking")
        cat.handle(event: .thinking)
        XCTAssertEqual(cat.currentState, .thinking)
    }

    func testHandleToolStart_entersToolUseState() {
        let cat = CatEntity(sessionId: "test-tool")
        cat.handle(event: .toolStart(name: "Read", description: "x"))
        XCTAssertEqual(cat.currentState, .toolUse)
    }

    func testHandlePermissionRequest_entersPermissionState() {
        let cat = CatEntity(sessionId: "test-perm")
        cat.handle(event: .permissionRequest(description: "risky"))
        XCTAssertEqual(cat.currentState, .permissionRequest)
    }

    func testHandleTaskComplete_entersTaskCompleteState() {
        let cat = CatEntity(sessionId: "test-done")
        cat.handle(event: .taskComplete)
        XCTAssertEqual(cat.currentState, .taskComplete)
    }

    func testHandleHoverEnter_appliesHoverScale() {
        let cat = CatEntity(sessionId: "test-hover")
        cat.handle(event: .hoverEnter)
        // InteractionComponent mutates node.xScale/yScale; spot-check
        XCTAssertNotEqual(cat.node.yScale, 1.0, "hover should scale")
    }

    func testHandleHoverExit_restoresScale() {
        let cat = CatEntity(sessionId: "test-hover2")
        cat.handle(event: .hoverEnter)
        cat.handle(event: .hoverExit)
        XCTAssertEqual(cat.node.yScale, 1.0, accuracy: 0.01)
    }

    func testIsDebug_trueForDebugPrefix() {
        let cat = CatEntity(sessionId: "debug-A")
        XCTAssertTrue(cat.isDebug)
    }

    func testIsDebug_falseForRegular() {
        let cat = CatEntity(sessionId: "abc-123")
        XCTAssertFalse(cat.isDebug)
    }
}
```

- [ ] **Step 2: Run test to see failures**

```bash
swift test --filter CatEntityEventTests 2>&1 | tail -15
```

Expected: compile error on `handle(event:)` 和 `isDebug`（目前 CatEntity 只有 `isDebugCat`，且没有 `handle`）。

- [ ] **Step 3: Add isDebug property + handle(event:) method**

在 `Sources/ClaudeCodeBuddy/Entity/Cat/CatEntity.swift` 的 class 体内（放在 `var isDebugCat: Bool { sessionId.hasPrefix("debug-") }` 紧邻处）：

```swift
/// SessionEntity protocol conformance — generic name.
var isDebug: Bool { sessionId.hasPrefix("debug-") }

// MARK: - Event Handling (SessionEntity)

func handle(event: EntityInputEvent) {
    switch event {
    case .sessionStart:
        // Enter scene already handled by enterScene(); no-op here
        break
    case .thinking:
        switchState(to: .thinking)
    case .toolStart(_, let desc):
        switchState(to: .toolUse, toolDescription: desc)
    case .toolEnd:
        switchState(to: .thinking)
    case .permissionRequest(let desc):
        switchState(to: .permissionRequest, toolDescription: desc)
    case .taskComplete:
        switchState(to: .taskComplete)
    case .sessionEnd:
        // SessionManager handles the scene removal; no-op on the entity
        break
    case .hoverEnter:
        applyHoverScale()
    case .hoverExit:
        removeHoverScale()
    case .externalCommand:
        // phase 2 扩展点；猫 phase 1 不响应
        break
    }
}
```

- [ ] **Step 4: Test pass**

```bash
swift test --filter CatEntityEventTests 2>&1 | tail -10
```

Expected: pass.

- [ ] **Step 5: CatEntity 显式声明实现 SessionEntity**

在 `CatEntity.swift` 底部，和现有 `extension CatEntity: EntityProtocol {}` 并列：

```swift
extension CatEntity: SessionEntity {}
```

（老的 EntityProtocol 暂留，Task 1.8 删。）

- [ ] **Step 6: Test & Commit**

```bash
swift test 2>&1 | tail -5
```

```bash
git add Sources/ClaudeCodeBuddy/Entity/Cat/CatEntity.swift \
        Tests/BuddyCoreTests/CatEntityEventTests.swift
git commit -m "feat(entity): CatEntity 实现 SessionEntity + handle(event:)

所有事件统一走 handle(event:)，保留 switchState 作为内部实现细节。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 1.7: SessionManager 通过 EntityInputEvent 与 scene 通信（预备阶段）

**本 Task 的目标**：不替换 `updateCatState` 调用，只新增一个事件转换辅助函数，把 hook event 转成 EntityInputEvent 并留日志。真正切换由 Task 2.x + 4.x 完成。

**Files:**
- Modify: `Sources/ClaudeCodeBuddy/Session/SessionManager.swift`

- [ ] **Step 1: 在 handle(message:) 中并行生成 EntityInputEvent**

在 `handle(message:)` 的 `if let entityState = message.entityState { ... }` 块之前新增：

```swift
// Build the generic EntityInputEvent for future dispatch via EntityFactory.
// Currently only used for debug logging; actual dispatch happens in Step 4.
let _entityInput = EntityInputEvent.from(
    hookEvent: message.event,
    tool: message.tool,
    description: message.description
)
_ = _entityInput  // silence unused warning; real usage in Step 4
```

- [ ] **Step 2: Build**

```bash
swift build 2>&1 | grep -E "error|warning" | head
```

Expected: no errors; possibly a "never used" warning on `_entityInput`——with `_ = _entityInput` it's silenced.

- [ ] **Step 3: Test**

```bash
swift test 2>&1 | tail -5
```

Expected: all pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/ClaudeCodeBuddy/Session/SessionManager.swift
git commit -m "refactor(session): 预接入 EntityInputEvent 转换（暂不使用）

为 Step 4 热切换管道铺路。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 1.8: 删除旧 EntityProtocol.swift

**Files:**
- Delete: `Sources/ClaudeCodeBuddy/Entity/EntityProtocol.swift`
- Modify: 任何 `import`/`: EntityProtocol` 引用（grep 后处理）

- [ ] **Step 1: Find remaining EntityProtocol refs**

```bash
grep -rn "EntityProtocol" Sources/ Tests/ --include="*.swift"
```

- [ ] **Step 2: 替换所有 `: EntityProtocol` 为 `: SessionEntity`**

对每个文件（预期数量少，以 grep 结果为准）：

```bash
# 示例
grep -l "EntityProtocol" Sources/**/*.swift Tests/**/*.swift | xargs sed -i '' 's/EntityProtocol/SessionEntity/g'
```

- [ ] **Step 3: 删除 EntityProtocol.swift**

```bash
git rm Sources/ClaudeCodeBuddy/Entity/EntityProtocol.swift
```

- [ ] **Step 4: CatEntity 的 `extension CatEntity: EntityProtocol {}` 删除**

因为 Step 6 已经加了 `extension CatEntity: SessionEntity {}`，把老的 protocol 扩展删掉。grep 核实：

```bash
grep -n "EntityProtocol\|extension.*Protocol" Sources/ClaudeCodeBuddy/Entity/Cat/CatEntity.swift
```

如有残留，手动移除。

- [ ] **Step 5: Build + Test**

```bash
swift build 2>&1 | grep -E "error" | head
swift test 2>&1 | tail -5
```

Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "refactor(entity): 删除旧 EntityProtocol，全量迁移到 SessionEntity

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 1.9: Step 1 全量验证 + Merge 点

- [ ] **Step 1: Lint / format**

```bash
make lint-fix && make format
```

- [ ] **Step 2: 全量测试**

```bash
swift test 2>&1 | tail -10
```

Expected: `All tests passed`.

- [ ] **Step 3: Acceptance 验收**

```bash
bash tests/acceptance/run-all.sh 2>&1 | tail -20
```

Expected: all pass（行为未变）。

- [ ] **Step 4: 手动验证**

```bash
make run
# 另一窗口
buddy session start --id debug-step1 --cwd /tmp
buddy emit thinking --id debug-step1
buddy emit tool_start --id debug-step1 --tool Read
buddy emit task_complete --id debug-step1
buddy session end --id debug-step1
```

Expected：猫 Dock 可见，状态转换视觉正确。结束后 app 保留运行以便下一步。

- [ ] **Step 5: Step 1 总结提交**

无代码改动，只 tag 工作量验证点：

```bash
git tag -a step-1-abstraction-done -m "Step 1 complete: abstraction skeleton in place"
```

**✅ Step 1 Merge 点**：CatEntity 类成型，SessionEntity 协议就位，EntityInputEvent 可用，行为零变化。

---

# Step 2 · EntityMode 基础设施

**目标**：引入 `.cat`/`.rocket` 模式枚举 + 持久化 + Combine publisher，`EntityFactory` 能按 mode 产出 Entity（暂时只有 `.cat` 可用）。

**Merge 点**：设置文件已就位但无人使用，行为与 Step 1 完全一致。

---

### Task 2.1: EntityMode 枚举（TDD）

**Files:**
- Create: `Sources/ClaudeCodeBuddy/Entity/EntityMode.swift`
- Create: `Tests/BuddyCoreTests/EntityModeTests.swift`

- [ ] **Step 1: Failing test**

`Tests/BuddyCoreTests/EntityModeTests.swift`：

```swift
import XCTest
@testable import BuddyCore

final class EntityModeTests: XCTestCase {

    func testRawValue_cat() {
        XCTAssertEqual(EntityMode.cat.rawValue, "cat")
    }

    func testRawValue_rocket() {
        XCTAssertEqual(EntityMode.rocket.rawValue, "rocket")
    }

    func testFromRawValue_valid() {
        XCTAssertEqual(EntityMode(rawValue: "cat"), .cat)
        XCTAssertEqual(EntityMode(rawValue: "rocket"), .rocket)
    }

    func testFromRawValue_invalid() {
        XCTAssertNil(EntityMode(rawValue: "fish"))
    }

    func testAllCases() {
        XCTAssertEqual(EntityMode.allCases.count, 2)
    }
}
```

- [ ] **Step 2: Run test → fail**

```bash
swift test --filter EntityModeTests
```

Expected: compile error.

- [ ] **Step 3: Implement**

`Sources/ClaudeCodeBuddy/Entity/EntityMode.swift`：

```swift
import Foundation

/// Global entity form. Only one mode active at any time (Q2 decision).
enum EntityMode: String, CaseIterable, Codable {
    case cat
    case rocket
}
```

- [ ] **Step 4: Test pass**

```bash
swift test --filter EntityModeTests
```

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeCodeBuddy/Entity/EntityMode.swift \
        Tests/BuddyCoreTests/EntityModeTests.swift
git commit -m "feat(entity): 新增 EntityMode 枚举（.cat / .rocket）

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2.2: EntityModeStore 持久化 + publisher（TDD）

**Files:**
- Create: `Sources/ClaudeCodeBuddy/Entity/EntityModeStore.swift`
- Create: `Tests/BuddyCoreTests/EntityModeStoreTests.swift`

- [ ] **Step 1: Failing tests**

`Tests/BuddyCoreTests/EntityModeStoreTests.swift`：

```swift
import XCTest
import Combine
@testable import BuddyCore

final class EntityModeStoreTests: XCTestCase {

    var tempDir: URL!
    var settingsPath: URL!
    var cancellables = Set<AnyCancellable>()

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("entity-mode-store-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir,
                                                 withIntermediateDirectories: true)
        settingsPath = tempDir.appendingPathComponent("settings.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        cancellables.removeAll()
        super.tearDown()
    }

    func testDefaultMode_isCat_whenNoFile() {
        let store = EntityModeStore(settingsURL: settingsPath)
        XCTAssertEqual(store.current, .cat)
    }

    func testSet_persistsAcrossInstances() {
        let s1 = EntityModeStore(settingsURL: settingsPath)
        s1.set(.rocket)
        let s2 = EntityModeStore(settingsURL: settingsPath)
        XCTAssertEqual(s2.current, .rocket)
    }

    func testSet_emitsViaPublisher() {
        let store = EntityModeStore(settingsURL: settingsPath)
        let exp = expectation(description: "publisher emits")
        var received: EntityMode?
        store.publisher
            .dropFirst()  // drop initial value
            .sink { mode in
                received = mode
                exp.fulfill()
            }
            .store(in: &cancellables)
        store.set(.rocket)
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(received, .rocket)
    }

    func testSet_sameMode_doesNotEmit() {
        let store = EntityModeStore(settingsURL: settingsPath)
        var emitCount = 0
        store.publisher
            .dropFirst()
            .sink { _ in emitCount += 1 }
            .store(in: &cancellables)
        store.set(.cat)  // same as default
        // Give Combine a tick
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(emitCount, 0)
    }

    func testCorruptedFile_fallsBackToCat() {
        try! "garbage{not json".write(to: settingsPath, atomically: true, encoding: .utf8)
        let store = EntityModeStore(settingsURL: settingsPath)
        XCTAssertEqual(store.current, .cat)
    }

    func testEnvVarOverride() {
        try! """
        {"entityMode":"cat"}
        """.write(to: settingsPath, atomically: true, encoding: .utf8)
        let store = EntityModeStore(settingsURL: settingsPath,
                                     envOverride: "rocket")
        XCTAssertEqual(store.current, .rocket)
    }

    func testInvalidEnvVar_isIgnored() {
        let store = EntityModeStore(settingsURL: settingsPath,
                                     envOverride: "fish")
        XCTAssertEqual(store.current, .cat)
    }
}
```

- [ ] **Step 2: Run test → fail**

```bash
swift test --filter EntityModeStoreTests
```

- [ ] **Step 3: Implement**

`Sources/ClaudeCodeBuddy/Entity/EntityModeStore.swift`：

```swift
import Foundation
import Combine

/// Single source of truth for the global EntityMode.
/// Persisted as JSON at ~/Library/Application Support/ClaudeCodeBuddy/settings.json.
/// Env var BUDDY_ENTITY (cat|rocket) overrides at init time for test automation.
final class EntityModeStore {

    static let shared = EntityModeStore()

    /// Emits current mode. CurrentValueSubject ensures new subscribers get the latest value immediately.
    let publisher: CurrentValueSubject<EntityMode, Never>

    private let settingsURL: URL
    private struct Payload: Codable { var entityMode: String }

    private init() {
        let url = Self.defaultSettingsURL()
        self.settingsURL = url
        let initial = Self.loadInitial(url: url,
                                       envOverride: ProcessInfo.processInfo.environment["BUDDY_ENTITY"])
        self.publisher = CurrentValueSubject(initial)
    }

    /// Test-only initializer.
    init(settingsURL: URL, envOverride: String? = nil) {
        self.settingsURL = settingsURL
        let initial = Self.loadInitial(url: settingsURL, envOverride: envOverride)
        self.publisher = CurrentValueSubject(initial)
    }

    var current: EntityMode { publisher.value }

    func set(_ mode: EntityMode) {
        guard publisher.value != mode else { return }
        persist(mode)
        publisher.send(mode)
    }

    // MARK: - Private

    private static func defaultSettingsURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("ClaudeCodeBuddy")
        try? FileManager.default.createDirectory(at: dir,
                                                 withIntermediateDirectories: true)
        return dir.appendingPathComponent("settings.json")
    }

    private static func loadInitial(url: URL, envOverride: String?) -> EntityMode {
        // Env var takes precedence when valid
        if let raw = envOverride, let mode = EntityMode(rawValue: raw) {
            return mode
        }
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let mode = EntityMode(rawValue: payload.entityMode)
        else {
            return .cat
        }
        return mode
    }

    private func persist(_ mode: EntityMode) {
        let payload = Payload(entityMode: mode.rawValue)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: settingsURL, options: .atomic)
    }
}
```

- [ ] **Step 4: Test pass**

```bash
swift test --filter EntityModeStoreTests
```

Expected: all 7 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeCodeBuddy/Entity/EntityModeStore.swift \
        Tests/BuddyCoreTests/EntityModeStoreTests.swift
git commit -m "feat(entity): EntityModeStore 持久化 + Combine publisher

支持 BUDDY_ENTITY env var 覆盖；文件损坏 fallback 到 .cat。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2.3: EntityFactory（TDD，仅支持 .cat）

**Files:**
- Create: `Sources/ClaudeCodeBuddy/Entity/EntityFactory.swift`
- Create: `Tests/BuddyCoreTests/EntityFactoryTests.swift`

- [ ] **Step 1: Failing test**

`Tests/BuddyCoreTests/EntityFactoryTests.swift`：

```swift
import XCTest
@testable import BuddyCore

final class EntityFactoryTests: XCTestCase {

    func testMake_catMode_returnsCatEntity() {
        let e = EntityFactory.make(mode: .cat, sessionId: "s1")
        XCTAssertTrue(e is CatEntity)
        XCTAssertEqual(e.sessionId, "s1")
    }

    func testMake_rocketMode_phase1_throwsOrFallsBack() {
        // Phase 1: RocketEntity 不存在，应 fallback 到 CatEntity 并 log warning
        let e = EntityFactory.make(mode: .rocket, sessionId: "s2")
        XCTAssertTrue(e is CatEntity, "Phase 1 rocket mode should fall back to CatEntity")
    }

    func testMake_preservesSessionId() {
        let e = EntityFactory.make(mode: .cat, sessionId: "abc-123")
        XCTAssertEqual(e.sessionId, "abc-123")
    }
}
```

- [ ] **Step 2: Run → fail**

```bash
swift test --filter EntityFactoryTests
```

- [ ] **Step 3: Implement（rocket fallback 到 cat）**

`Sources/ClaudeCodeBuddy/Entity/EntityFactory.swift`：

```swift
import Foundation

/// Factory for creating concrete SessionEntity instances based on EntityMode.
/// Phase 1: .rocket falls back to CatEntity since RocketEntity is not yet implemented.
/// Step 3 of plan will replace the fallback with a real RocketEntity.
enum EntityFactory {
    static func make(mode: EntityMode, sessionId: String) -> SessionEntity {
        switch mode {
        case .cat:
            return CatEntity(sessionId: sessionId)
        case .rocket:
            // TODO (Step 3): return RocketEntity(sessionId: sessionId)
            NSLog("[EntityFactory] .rocket not implemented yet; falling back to .cat")
            return CatEntity(sessionId: sessionId)
        }
    }
}
```

- [ ] **Step 4: Test pass**

```bash
swift test --filter EntityFactoryTests
```

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeCodeBuddy/Entity/EntityFactory.swift \
        Tests/BuddyCoreTests/EntityFactoryTests.swift
git commit -m "feat(entity): EntityFactory 支持 .cat；.rocket 暂 fallback

Step 3 补上 RocketEntity 实现后替换 fallback。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2.4: AppDelegate 初始化 EntityModeStore（不订阅）

**Files:**
- Modify: `Sources/ClaudeCodeBuddy/App/AppDelegate.swift`

- [ ] **Step 1: 在 applicationDidFinishLaunching 中触发单例初始化**

在 `AppDelegate` 里增加：

```swift
// Force EntityModeStore to load from disk / env var at startup.
// Observers subscribe later (Step 4).
_ = EntityModeStore.shared
NSLog("[AppDelegate] EntityMode at launch: \(EntityModeStore.shared.current.rawValue)")
```

放在 `applicationDidFinishLaunching(_:)` 的靠前位置（在 SessionManager 初始化之前）。

- [ ] **Step 2: Build + run**

```bash
swift build && swift run ClaudeCodeBuddy &
sleep 2
killall ClaudeCodeBuddy
```

查看 stderr 里是否有 `EntityMode at launch: cat`。

- [ ] **Step 3: Commit**

```bash
git add Sources/ClaudeCodeBuddy/App/AppDelegate.swift
git commit -m "chore(app): 启动时加载 EntityModeStore

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2.5: Step 2 合并点

- [ ] **Step 1: Full test suite + lint**

```bash
make lint-fix && make format && swift test 2>&1 | tail -5
```

- [ ] **Step 2: Tag**

```bash
git tag -a step-2-entitymode-infra-done -m "Step 2 complete: EntityMode infra ready"
```

**✅ Step 2 Merge 点**：`EntityMode` / `EntityModeStore` / `EntityFactory` 就位，`.rocket` 模式仍然走 cat。

---

# Step 3 · 火箭 Entity 最小可用版（占位精灵）

**目标**：完整实现 `RocketEntity` 和 6 个状态，但用 SF Symbol / 纯色矩形作占位精灵。`EntityFactory.make(.rocket)` 真实返回 RocketEntity。

**Merge 点**：`BUDDY_ENTITY=rocket` 启动能看到"火箭"（丑），状态切换正确。

---

### Task 3.1: RocketState 枚举 + RocketConstants

**Files:**
- Create: `Sources/ClaudeCodeBuddy/Entity/Rocket/States/RocketState.swift`
- Create: `Sources/ClaudeCodeBuddy/Entity/Rocket/RocketConstants.swift`

- [ ] **Step 1: Create RocketState.swift**

```swift
import Foundation

/// Independent state enum for RocketEntity.
/// Does NOT share identity with CatState (Q3 decision: fully decoupled).
enum RocketState: String, CaseIterable {
    case onPad
    case systemsCheck
    case cruising
    case abortStandby
    case propulsiveLanding
    case liftoff
}
```

- [ ] **Step 2: Create RocketConstants.swift**

```swift
import CoreGraphics

enum RocketConstants {

    enum Visual {
        static let spriteSize = CGSize(width: 48, height: 48)
        static let hitboxSize = CGSize(width: 40, height: 48)
        static let padHeight: CGFloat = 6
        static let tintFactor: CGFloat = 0.5
        static let groundY: CGFloat = 4
    }

    enum Physics {
        static let bodySize = CGSize(width: 28, height: 44)
        static let restitution: CGFloat = 0.0
        static let friction: CGFloat = 1.0
        static let linearDamping: CGFloat = 1.0
    }

    enum Cruising {
        /// How high above the pad the rocket lifts during cruising.
        static let hoverLift: CGFloat = 30
        static let hoverLiftDuration: TimeInterval = 0.4
        /// Random walk cadence in cruising.
        static let walkStepMin: CGFloat = 20
        static let walkStepMax: CGFloat = 80
        static let walkDurationMin: TimeInterval = 1.2
        static let walkDurationMax: TimeInterval = 2.2
    }

    enum Landing {
        /// Scene expansion during propulsive landing.
        static let sceneExpansion: CGFloat = 120
        static let totalDuration: TimeInterval = 1.2
    }

    enum Liftoff {
        static let sceneExpansion: CGFloat = 200
        static let totalDuration: TimeInterval = 0.8
    }

    enum WarningLight {
        static let blinkInterval: TimeInterval = 0.4
    }
}
```

- [ ] **Step 3: Build verify**

```bash
swift build 2>&1 | grep error | head
```

- [ ] **Step 4: Commit**

```bash
git add Sources/ClaudeCodeBuddy/Entity/Rocket/
git commit -m "feat(rocket): RocketState 枚举 + RocketConstants

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 3.2: EventBus 新增 sceneExpansionRequested + entityModeChanged 事件

**Files:**
- Modify: `Sources/ClaudeCodeBuddy/Event/BuddyEvent.swift`
- Modify: `Sources/ClaudeCodeBuddy/Event/EventBus.swift`
- Create: `Tests/BuddyCoreTests/SceneExpansionEventTests.swift`

- [ ] **Step 1: 新事件类型**

`Sources/ClaudeCodeBuddy/Event/BuddyEvent.swift` 追加：

```swift
/// Request to temporarily grow the Dock window upward (used by rocket dramatic states).
struct SceneExpansionRequest {
    let height: CGFloat
    let duration: TimeInterval
}

/// Broadcast when the global EntityMode changes (cat ↔ rocket).
struct EntityModeChangeEvent {
    let previous: EntityMode
    let next: EntityMode
}
```

- [ ] **Step 2: EventBus 挂载**

`Sources/ClaudeCodeBuddy/Event/EventBus.swift`：

```swift
let sceneExpansionRequested = PassthroughSubject<SceneExpansionRequest, Never>()
let entityModeChanged = PassthroughSubject<EntityModeChangeEvent, Never>()
```

- [ ] **Step 3: Write a smoke test**

`Tests/BuddyCoreTests/SceneExpansionEventTests.swift`：

```swift
import XCTest
import Combine
@testable import BuddyCore

final class SceneExpansionEventTests: XCTestCase {
    var cancellables = Set<AnyCancellable>()

    func testPublishReceive() {
        let exp = expectation(description: "receives")
        var received: SceneExpansionRequest?
        EventBus.shared.sceneExpansionRequested
            .sink { req in
                received = req
                exp.fulfill()
            }
            .store(in: &cancellables)
        EventBus.shared.sceneExpansionRequested.send(
            SceneExpansionRequest(height: 120, duration: 1.2)
        )
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(received?.height, 120)
        XCTAssertEqual(received?.duration, 1.2)
    }
}
```

- [ ] **Step 4: Test pass**

```bash
swift test --filter SceneExpansionEventTests
```

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeCodeBuddy/Event/ Tests/BuddyCoreTests/SceneExpansionEventTests.swift
git commit -m "feat(event): sceneExpansionRequested / entityModeChanged 事件

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 3.3: RocketSpriteLoader（占位精灵 fallback）

**Files:**
- Create: `Sources/ClaudeCodeBuddy/Entity/Rocket/RocketSpriteLoader.swift`

- [ ] **Step 1: Implement**

```swift
import SpriteKit
import AppKit

/// Loads rocket sprite textures. Step 6 will populate Assets/Sprites/Rocket/*.png.
/// Phase 1 returns SF Symbol "airplane" rendered to texture as a placeholder.
enum RocketSpriteLoader {

    static func placeholderTexture(size: CGSize = RocketConstants.Visual.spriteSize) -> SKTexture {
        let symbol = NSImage(systemSymbolName: "airplane",
                             accessibilityDescription: nil)
            ?? NSImage(size: size)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            symbol.draw(in: rect.insetBy(dx: 6, dy: 6))
            return true
        }
        let tex = SKTexture(image: image)
        tex.filteringMode = .nearest
        return tex
    }

    /// Returns (frames, fps) for a named animation. Phase 1 always returns the placeholder once.
    static func frames(for animation: String) -> (frames: [SKTexture], fps: Double) {
        return ([placeholderTexture()], 1.0)
    }
}
```

- [ ] **Step 2: Build verify**

```bash
swift build 2>&1 | grep error | head
```

- [ ] **Step 3: Commit**

```bash
git add Sources/ClaudeCodeBuddy/Entity/Rocket/RocketSpriteLoader.swift
git commit -m "feat(rocket): RocketSpriteLoader 占位精灵（SF Symbol airplane）

Step 6 会重写为真实像素资源。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 3.4: RocketEntity 骨架 + SessionEntity conformance（TDD）

**Files:**
- Create: `Sources/ClaudeCodeBuddy/Entity/Rocket/RocketEntity.swift`
- Create: `Tests/BuddyCoreTests/RocketEntityTests.swift`

- [ ] **Step 1: Failing tests**

`Tests/BuddyCoreTests/RocketEntityTests.swift`：

```swift
import XCTest
@testable import BuddyCore

final class RocketEntityTests: XCTestCase {

    func testInit_hasSessionId() {
        let r = RocketEntity(sessionId: "r1")
        XCTAssertEqual(r.sessionId, "r1")
    }

    func testInit_containerNodeSetup() {
        let r = RocketEntity(sessionId: "r2")
        XCTAssertEqual(r.containerNode.name, "rocket_r2")
    }

    func testIsDebug_true() {
        let r = RocketEntity(sessionId: "debug-X")
        XCTAssertTrue(r.isDebug)
    }

    func testConfigureColor() {
        let r = RocketEntity(sessionId: "r3")
        r.configure(color: .red, labelText: "test")
        XCTAssertEqual(r.sessionColor, .red)
    }

    func testInitialState_onPad() {
        let r = RocketEntity(sessionId: "r4")
        XCTAssertEqual(r.currentState, .onPad)
    }
}
```

- [ ] **Step 2: Run → fail**

```bash
swift test --filter RocketEntityTests
```

- [ ] **Step 3: Implement (minimal)**

`Sources/ClaudeCodeBuddy/Entity/Rocket/RocketEntity.swift`：

```swift
import SpriteKit
import GameplayKit

/// Rocket-form SessionEntity. Completely decoupled from CatEntity (Q3 decision).
/// Phase 1: state visualization only, zero interactions.
final class RocketEntity {

    // MARK: - Properties

    let sessionId: String
    let containerNode = SKNode()
    let node: SKSpriteNode
    private(set) var sessionColor: SessionColor?
    private(set) var stateMachine: GKStateMachine!

    /// Convenience accessor for the current RocketState. Returns .onPad before init.
    var currentState: RocketState {
        switch stateMachine?.currentState {
        case is RocketOnPadState:              return .onPad
        case is RocketSystemsCheckState:       return .systemsCheck
        case is RocketCruisingState:           return .cruising
        case is RocketAbortStandbyState:       return .abortStandby
        case is RocketPropulsiveLandingState:  return .propulsiveLanding
        case is RocketLiftoffState:            return .liftoff
        default:                                return .onPad
        }
    }

    // MARK: - Init

    init(sessionId: String) {
        self.sessionId = sessionId

        node = SKSpriteNode(texture: RocketSpriteLoader.placeholderTexture(),
                            size: RocketConstants.Visual.spriteSize)
        node.name = "rocketSprite_\(sessionId)"
        containerNode.name = "rocket_\(sessionId)"
        containerNode.addChild(node)

        setupPhysics()

        let states: [GKState] = [
            RocketOnPadState(entity: self),
            RocketSystemsCheckState(entity: self),
            RocketCruisingState(entity: self),
            RocketAbortStandbyState(entity: self),
            RocketPropulsiveLandingState(entity: self),
            RocketLiftoffState(entity: self)
        ]
        stateMachine = GKStateMachine(states: states)
        stateMachine.enter(RocketOnPadState.self)
    }

    // MARK: - Physics

    private func setupPhysics() {
        let body = SKPhysicsBody(rectangleOf: RocketConstants.Physics.bodySize)
        body.allowsRotation = false
        body.categoryBitMask = PhysicsCategory.cat  // Reuse bitmask; rename to generic if needed
        body.collisionBitMask = PhysicsCategory.cat | PhysicsCategory.ground
        body.contactTestBitMask = PhysicsCategory.ground
        body.restitution = RocketConstants.Physics.restitution
        body.friction = RocketConstants.Physics.friction
        body.linearDamping = RocketConstants.Physics.linearDamping
        containerNode.physicsBody = body
    }
}

// MARK: - SessionEntity conformance (skeleton — filled in Task 3.5+)

extension RocketEntity: SessionEntity {

    var isDebug: Bool { sessionId.hasPrefix("debug-") }

    func configure(color: SessionColor, labelText: String) {
        sessionColor = color
        node.color = color.nsColor
        node.colorBlendFactor = RocketConstants.Visual.tintFactor
        // Label rendering delegated to a later task (3.7)
    }

    func updateLabel(_ newLabel: String) {
        // Phase 1 rocket: no-op label (added in Task 3.7)
    }

    func enterScene(sceneSize: CGSize, activityBounds: ClosedRange<CGFloat>?) {
        containerNode.position = CGPoint(x: containerNode.position.x,
                                         y: RocketConstants.Visual.groundY)
        stateMachine.enter(RocketOnPadState.self)
    }

    func exitScene(sceneWidth: CGFloat, completion: @escaping () -> Void) {
        // Phase 1 simple fade-out; Liftoff state handles fancy exit
        let fade = SKAction.fadeOut(withDuration: 0.2)
        let done = SKAction.run { completion() }
        containerNode.run(SKAction.sequence([fade, done]))
    }

    func updateSceneSize(_ size: CGSize) {
        // Rocket phase 1 doesn't care; cruising clamps to bounds via state
    }

    func applyHoverScale() {
        node.setScale(1.1)
    }

    func removeHoverScale() {
        node.setScale(1.0)
    }

    func handle(event: EntityInputEvent) {
        switch event {
        case .sessionStart:            stateMachine.enter(RocketOnPadState.self)
        case .thinking:                stateMachine.enter(RocketSystemsCheckState.self)
        case .toolStart:               stateMachine.enter(RocketCruisingState.self)
        case .toolEnd:                 stateMachine.enter(RocketOnPadState.self)
        case .permissionRequest:       stateMachine.enter(RocketAbortStandbyState.self)
        case .taskComplete:            stateMachine.enter(RocketPropulsiveLandingState.self)
        case .sessionEnd:              stateMachine.enter(RocketLiftoffState.self)
        case .hoverEnter:              applyHoverScale()
        case .hoverExit:                removeHoverScale()
        case .externalCommand:         break   // phase 2
        }
    }
}
```

- [ ] **Step 4: Stub the 6 state classes so compile passes**

Create these 6 files, each with minimal stubs (filled in Task 3.5):

`Sources/ClaudeCodeBuddy/Entity/Rocket/States/RocketBaseState.swift`：

```swift
import GameplayKit

class RocketBaseState: GKState {
    unowned let entity: RocketEntity
    init(entity: RocketEntity) { self.entity = entity }
}
```

`Sources/ClaudeCodeBuddy/Entity/Rocket/States/RocketOnPadState.swift`：

```swift
import GameplayKit

final class RocketOnPadState: RocketBaseState {
    override func isValidNextState(_ stateClass: AnyClass) -> Bool { true }
    override func didEnter(from previousState: GKState?) { /* Task 3.5 */ }
    override func willExit(to nextState: GKState) { entity.containerNode.removeAllActions() }
}
```

其余 `RocketSystemsCheckState` / `RocketCruisingState` / `RocketAbortStandbyState` / `RocketPropulsiveLandingState` / `RocketLiftoffState` 按同样模板 stub——区别仅类名和文件名。每个文件 ~10 行。

- [ ] **Step 5: Run test → pass**

```bash
swift test --filter RocketEntityTests
```

- [ ] **Step 6: Commit**

```bash
git add Sources/ClaudeCodeBuddy/Entity/Rocket/ \
        Tests/BuddyCoreTests/RocketEntityTests.swift
git commit -m "feat(rocket): RocketEntity + 6 状态骨架，SessionEntity 协议实现

状态内部行为留在 Task 3.5 实现；当前可正确 transition 但无视觉效果。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 3.5: 填充 6 个 RocketState 的 didEnter 行为（TDD）

**Files:**
- Modify: 6 个 RocketState 文件
- Create: `Tests/BuddyCoreTests/RocketStateTransitionTests.swift`

- [ ] **Step 1: Failing tests**

`Tests/BuddyCoreTests/RocketStateTransitionTests.swift`：

```swift
import XCTest
import Combine
@testable import BuddyCore

final class RocketStateTransitionTests: XCTestCase {
    var cancellables = Set<AnyCancellable>()

    func testThinking_entersSystemsCheck() {
        let r = RocketEntity(sessionId: "t1")
        r.handle(event: .thinking)
        XCTAssertEqual(r.currentState, .systemsCheck)
    }

    func testToolStart_entersCruising() {
        let r = RocketEntity(sessionId: "t2")
        r.handle(event: .toolStart(name: "Read", description: nil))
        XCTAssertEqual(r.currentState, .cruising)
    }

    func testPermissionRequest_entersAbortStandby() {
        let r = RocketEntity(sessionId: "t3")
        r.handle(event: .permissionRequest(description: "x"))
        XCTAssertEqual(r.currentState, .abortStandby)
    }

    func testTaskComplete_entersPropulsiveLanding() {
        let r = RocketEntity(sessionId: "t4")
        r.handle(event: .taskComplete)
        XCTAssertEqual(r.currentState, .propulsiveLanding)
    }

    func testPropulsiveLanding_emitsSceneExpansionRequest() {
        let r = RocketEntity(sessionId: "t5")
        let exp = expectation(description: "emits expansion")
        var receivedHeight: CGFloat?
        EventBus.shared.sceneExpansionRequested
            .sink { req in
                receivedHeight = req.height
                exp.fulfill()
            }
            .store(in: &cancellables)
        r.handle(event: .taskComplete)
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(receivedHeight, RocketConstants.Landing.sceneExpansion)
    }

    func testLiftoff_emitsLargerExpansion() {
        let r = RocketEntity(sessionId: "t6")
        let exp = expectation(description: "emits larger expansion")
        var receivedHeight: CGFloat?
        EventBus.shared.sceneExpansionRequested
            .sink { req in
                if req.height >= RocketConstants.Liftoff.sceneExpansion {
                    receivedHeight = req.height
                    exp.fulfill()
                }
            }
            .store(in: &cancellables)
        r.handle(event: .sessionEnd)
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(receivedHeight, RocketConstants.Liftoff.sceneExpansion)
    }
}
```

- [ ] **Step 2: Run → fail（部分 pass：currentState 已能切换；expansion 未发送）**

```bash
swift test --filter RocketStateTransitionTests
```

- [ ] **Step 3: Fill RocketPropulsiveLandingState.didEnter**

```swift
import GameplayKit

final class RocketPropulsiveLandingState: RocketBaseState {
    override func isValidNextState(_ stateClass: AnyClass) -> Bool { true }

    override func didEnter(from previousState: GKState?) {
        EventBus.shared.sceneExpansionRequested.send(
            SceneExpansionRequest(
                height: RocketConstants.Landing.sceneExpansion,
                duration: RocketConstants.Landing.totalDuration
            )
        )
        // Visual: descent animation from top of expansion down to pad
        let descend = SKAction.moveBy(x: 0,
                                       y: -RocketConstants.Landing.sceneExpansion,
                                       duration: RocketConstants.Landing.totalDuration)
        descend.timingMode = .easeIn
        let settle = SKAction.run { [weak entity] in
            entity?.stateMachine.enter(RocketOnPadState.self)
        }
        entity.containerNode.run(SKAction.sequence([descend, settle]),
                                  withKey: "propulsiveLanding")
    }

    override func willExit(to nextState: GKState) {
        entity.containerNode.removeAction(forKey: "propulsiveLanding")
    }
}
```

- [ ] **Step 4: Fill RocketLiftoffState.didEnter**

```swift
final class RocketLiftoffState: RocketBaseState {
    override func isValidNextState(_ stateClass: AnyClass) -> Bool { true }

    override func didEnter(from previousState: GKState?) {
        EventBus.shared.sceneExpansionRequested.send(
            SceneExpansionRequest(
                height: RocketConstants.Liftoff.sceneExpansion,
                duration: RocketConstants.Liftoff.totalDuration
            )
        )
        let ascend = SKAction.moveBy(x: 0,
                                      y: RocketConstants.Liftoff.sceneExpansion,
                                      duration: RocketConstants.Liftoff.totalDuration)
        ascend.timingMode = .easeOut
        let fade = SKAction.fadeOut(withDuration: 0.3)
        entity.containerNode.run(SKAction.group([ascend, fade]),
                                  withKey: "liftoff")
    }

    override func willExit(to nextState: GKState) {
        entity.containerNode.removeAction(forKey: "liftoff")
    }
}
```

- [ ] **Step 5: Fill RocketOnPadState / SystemsCheck / Cruising / AbortStandby**

```swift
// RocketOnPadState
final class RocketOnPadState: RocketBaseState {
    override func isValidNextState(_ stateClass: AnyClass) -> Bool { true }
    override func didEnter(from previousState: GKState?) {
        entity.node.run(SKAction.repeatForever(
            SKAction.sequence([
                SKAction.fadeAlpha(to: 0.9, duration: 0.6),
                SKAction.fadeAlpha(to: 1.0, duration: 0.6)
            ])
        ), withKey: "onPad")
    }
    override func willExit(to nextState: GKState) {
        entity.node.removeAction(forKey: "onPad")
        entity.node.alpha = 1.0
    }
}

// RocketSystemsCheckState (faster blink)
final class RocketSystemsCheckState: RocketBaseState {
    override func isValidNextState(_ stateClass: AnyClass) -> Bool { true }
    override func didEnter(from previousState: GKState?) {
        entity.node.run(SKAction.repeatForever(
            SKAction.sequence([
                SKAction.fadeAlpha(to: 0.7, duration: 0.2),
                SKAction.fadeAlpha(to: 1.0, duration: 0.2)
            ])
        ), withKey: "systemsCheck")
    }
    override func willExit(to nextState: GKState) {
        entity.node.removeAction(forKey: "systemsCheck")
        entity.node.alpha = 1.0
    }
}

// RocketCruisingState (horizontal drift within activity bounds)
final class RocketCruisingState: RocketBaseState {
    override func isValidNextState(_ stateClass: AnyClass) -> Bool { true }
    override func didEnter(from previousState: GKState?) {
        // Lift up
        let lift = SKAction.moveBy(x: 0,
                                    y: RocketConstants.Cruising.hoverLift,
                                    duration: RocketConstants.Cruising.hoverLiftDuration)
        lift.timingMode = .easeOut
        let drift = SKAction.repeatForever(
            SKAction.sequence([
                SKAction.moveBy(
                    x: CGFloat.random(in: -RocketConstants.Cruising.walkStepMax...RocketConstants.Cruising.walkStepMax),
                    y: 0,
                    duration: Double.random(in: RocketConstants.Cruising.walkDurationMin...RocketConstants.Cruising.walkDurationMax)
                )
            ])
        )
        entity.containerNode.run(SKAction.sequence([lift, drift]),
                                  withKey: "cruising")
    }
    override func willExit(to nextState: GKState) {
        entity.containerNode.removeAction(forKey: "cruising")
        // Drop back to ground level when leaving cruising (unless another state explicitly manages pos)
        if !(nextState is RocketLiftoffState || nextState is RocketPropulsiveLandingState) {
            let drop = SKAction.moveTo(y: RocketConstants.Visual.groundY,
                                        duration: 0.3)
            entity.containerNode.run(drop)
        }
    }
}

// RocketAbortStandbyState (freeze + red tint)
final class RocketAbortStandbyState: RocketBaseState {
    override func isValidNextState(_ stateClass: AnyClass) -> Bool { true }
    override func didEnter(from previousState: GKState?) {
        entity.containerNode.removeAllActions()
        // Simple red strobe via color blend factor flicker
        entity.node.color = .systemRed
        let strobe = SKAction.repeatForever(
            SKAction.sequence([
                SKAction.fadeAlpha(to: 0.6, duration: 0.25),
                SKAction.fadeAlpha(to: 1.0, duration: 0.25)
            ])
        )
        entity.node.run(strobe, withKey: "abort")
    }
    override func willExit(to nextState: GKState) {
        entity.node.removeAction(forKey: "abort")
        entity.node.color = entity.sessionColor?.nsColor ?? .white
        entity.node.alpha = 1.0
    }
}
```

- [ ] **Step 6: Test pass**

```bash
swift test --filter RocketStateTransitionTests
```

Expected: all 6 tests pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/ClaudeCodeBuddy/Entity/Rocket/ \
        Tests/BuddyCoreTests/RocketStateTransitionTests.swift
git commit -m "feat(rocket): 6 状态实现（占位视觉）+ EventBus 扩展请求

PropulsiveLanding / Liftoff 发布 sceneExpansionRequested；
其他状态用透明度闪烁 / 简单位移占位，Step 6 换精灵。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 3.6: EntityFactory 切换到真实 RocketEntity

**Files:**
- Modify: `Sources/ClaudeCodeBuddy/Entity/EntityFactory.swift`
- Modify: `Tests/BuddyCoreTests/EntityFactoryTests.swift`

- [ ] **Step 1: 更新 factory**

`Sources/ClaudeCodeBuddy/Entity/EntityFactory.swift`：

```swift
enum EntityFactory {
    static func make(mode: EntityMode, sessionId: String) -> SessionEntity {
        switch mode {
        case .cat:    return CatEntity(sessionId: sessionId)
        case .rocket: return RocketEntity(sessionId: sessionId)
        }
    }
}
```

- [ ] **Step 2: 更新 test 断言**

`Tests/BuddyCoreTests/EntityFactoryTests.swift` 的 `testMake_rocketMode_phase1_throwsOrFallsBack` 改为：

```swift
func testMake_rocketMode_returnsRocketEntity() {
    let e = EntityFactory.make(mode: .rocket, sessionId: "r")
    XCTAssertTrue(e is RocketEntity)
    XCTAssertEqual(e.sessionId, "r")
}
```

- [ ] **Step 3: Test pass**

```bash
swift test --filter EntityFactoryTests
```

- [ ] **Step 4: Commit**

```bash
git add Sources/ClaudeCodeBuddy/Entity/EntityFactory.swift \
        Tests/BuddyCoreTests/EntityFactoryTests.swift
git commit -m "feat(entity): EntityFactory 正式产出 RocketEntity

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 3.7: Step 3 验证 + 手动 smoke test

- [ ] **Step 1: 测试通过**

```bash
swift test 2>&1 | tail -5
```

- [ ] **Step 2: 手动 rocket mode smoke**

```bash
make build
BUDDY_ENTITY=rocket swift run ClaudeCodeBuddy &
sleep 3
buddy session start --id debug-rocket-1 --cwd /tmp
sleep 1
buddy emit thinking --id debug-rocket-1
sleep 2
buddy emit tool_start --id debug-rocket-1 --tool Read
sleep 2
buddy emit task_complete --id debug-rocket-1
sleep 3
buddy session end --id debug-rocket-1
sleep 2
killall ClaudeCodeBuddy
```

人眼验证 Dock 区是否出现"airplane SF Symbol"并经历状态变化（会很丑，但应可见）。

- [ ] **Step 3: Tag**

```bash
git tag -a step-3-rocket-mvp-done -m "Step 3 complete: rocket MVP with placeholder sprites"
```

**✅ Step 3 Merge 点**：`BUDDY_ENTITY=rocket` 启动，火箭占位精灵可见，状态转换正确。

---

# Step 4 · 热切换管道

**目标**：SessionManager 订阅 `EntityModeStore.publisher`，接收到切换时把所有活跃 session 的 entity 下场 → 以新 mode 重建 → 回放状态。`buddy morph` CLI 命令接入。

**Merge 点**：CLI / （稍后的）menubar 切换皆可热切换，状态无丢失。

---

### Task 4.1: BuddyScene 支持 SessionEntity 替换

**Files:**
- Modify: `Sources/ClaudeCodeBuddy/Scene/BuddyScene.swift`
- Modify: `Sources/ClaudeCodeBuddy/Scene/SceneControlling.swift`

- [ ] **Step 1: BuddyScene cats dict 改为 entities**

`BuddyScene.swift:20`：

```swift
// 原
private var cats: [String: CatEntity] = [:]
// 改为
private var entities: [String: SessionEntity] = [:]
```

全文 `self.cats` → `self.entities`（grep 核对）。需要访问 CatEntity 独有成员（食物走路 / bed）的地方，**向下转型**：

```swift
guard let cat = entities[sessionId] as? CatEntity else { return }
// ... cat-specific behaviors
```

- [ ] **Step 2: SceneControlling 协议新增 Entity 系列方法（与老方法并存）**

`SceneControlling` 协议**新增**（老的 `addCat / removeCat / updateCatState` 等**保留不动**——现有测试仍在用）：

```swift
protocol SceneControlling: AnyObject {
    // ... existing members unchanged

    // MARK: - New Entity API (Step 4 新增)
    func addEntity(info: SessionInfo, mode: EntityMode)
    func removeEntity(sessionId: String)
    func replaceAllEntities(with mode: EntityMode, infos: [SessionInfo],
                             lastEvents: [String: EntityInputEvent],
                             completion: @escaping () -> Void)
}
```

`BuddyScene` 同时实现新老两套；老的 `addCat(info:)` 内部直接委托给 `addEntity(info: info, mode: .cat)`——保持现有调用点（例如 `SessionManager` 里的 `scene.addCat(info:)`）在 Step 4 尚未改造前仍可工作。真正的切换到 `addEntity` 调用发生在 Task 4.2。

**MockScene** 在 Task 4.2 的测试片段里实现新方法；老 `addCat` / `removeCat` 桩保持原样。

- [ ] **Step 3: BuddyScene 实现 addEntity**

```swift
func addEntity(info: SessionInfo, mode: EntityMode) {
    let entity = EntityFactory.make(mode: mode, sessionId: info.sessionId)
    entity.configure(color: info.color, labelText: info.label)
    entities[info.sessionId] = entity
    addChild(entity.containerNode)
    entity.enterScene(sceneSize: size, activityBounds: activityBounds)
    // Position at random x within bounds, mirroring old addCat logic
    let minX = activityBounds.lowerBound
    let maxX = activityBounds.upperBound
    entity.containerNode.position = CGPoint(
        x: CGFloat.random(in: minX...maxX),
        y: 0
    )
}

func removeEntity(sessionId: String) {
    guard let entity = entities[sessionId] else { return }
    entity.exitScene(sceneWidth: size.width) { [weak self] in
        entity.containerNode.removeFromParent()
        self?.entities.removeValue(forKey: sessionId)
    }
}
```

- [ ] **Step 4: Implement replaceAllEntities (hot-switch core)**

```swift
func replaceAllEntities(with mode: EntityMode,
                        infos: [SessionInfo],
                        lastEvents: [String: EntityInputEvent],
                        completion: @escaping () -> Void) {
    // Step 1: graceful exit all current
    let group = DispatchGroup()
    for (sid, entity) in entities {
        group.enter()
        entity.exitScene(sceneWidth: size.width) {
            entity.containerNode.removeFromParent()
            group.leave()
        }
        _ = sid
    }
    group.notify(queue: .main) { [weak self] in
        guard let self = self else { return }
        self.entities.removeAll()
        // Step 2: spawn new entities in new mode
        for info in infos {
            self.addEntity(info: info, mode: mode)
            // Replay last known event so state is restored
            if let e = lastEvents[info.sessionId] {
                self.entities[info.sessionId]?.handle(event: e)
            }
        }
        completion()
    }
}
```

- [ ] **Step 5: Build + test**

```bash
swift build 2>&1 | grep error | head
swift test 2>&1 | tail -10
```

Expected: all pass (existing tests should still work via the compatibility shim).

- [ ] **Step 6: Commit**

```bash
git add Sources/ClaudeCodeBuddy/Scene/
git commit -m "refactor(scene): BuddyScene 存储 SessionEntity dict + replaceAllEntities API

addCat / removeCat 作为兼容 alias 保留；新 API addEntity / removeEntity /
replaceAllEntities 服务于热切换。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 4.2: SessionManager 订阅 EntityModeStore + 缓存 lastEvent

**Files:**
- Modify: `Sources/ClaudeCodeBuddy/Session/SessionManager.swift`
- Create: `Tests/BuddyCoreTests/HotSwitchIntegrationTests.swift`

- [ ] **Step 1: Write integration test**

`Tests/BuddyCoreTests/HotSwitchIntegrationTests.swift`：

```swift
import XCTest
import Combine
@testable import BuddyCore

final class HotSwitchIntegrationTests: XCTestCase {
    var cancellables = Set<AnyCancellable>()

    func testModeChange_triggersReplaceAll() {
        let scene = MockScene()
        let manager = SessionManager(scene: scene)
        let testStore = EntityModeStore(settingsURL: URL(fileURLWithPath: "/tmp/test-hotswitch-\(UUID().uuidString).json"))
        manager.bind(modeStore: testStore)

        // Create a session
        let msg = HookMessage(sessionId: "s1", event: .sessionStart, tool: nil,
                              timestamp: 0, cwd: "/tmp", label: nil, pid: nil,
                              terminalId: nil, description: nil)
        manager.handle(message: msg)

        // Request mode change
        testStore.set(.rocket)

        // Give event loop time to process
        let exp = expectation(description: "replaceAllCalled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if scene.replaceAllCalled { exp.fulfill() }
        }
        wait(for: [exp], timeout: 2.0)
        XCTAssertTrue(scene.replaceAllCalled)
        XCTAssertEqual(scene.lastReplacementMode, .rocket)
    }

    func testModeChange_preservesSessionIds() {
        let scene = MockScene()
        let manager = SessionManager(scene: scene)
        let testStore = EntityModeStore(settingsURL: URL(fileURLWithPath: "/tmp/test-hotswitch-2-\(UUID().uuidString).json"))
        manager.bind(modeStore: testStore)

        for id in ["s1", "s2", "s3"] {
            manager.handle(message: HookMessage(sessionId: id, event: .sessionStart,
                                                 tool: nil, timestamp: 0, cwd: "/tmp",
                                                 label: nil, pid: nil, terminalId: nil,
                                                 description: nil))
        }
        testStore.set(.rocket)

        let exp = expectation(description: "replaceAllWithAll")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if scene.lastReplacementSessionIds.count == 3 { exp.fulfill() }
        }
        wait(for: [exp], timeout: 2.0)
        XCTAssertEqual(Set(scene.lastReplacementSessionIds), ["s1", "s2", "s3"])
    }
}
```

Update `MockScene.swift` to record these invocations:

```swift
class MockScene: SceneControlling {
    // ... existing properties
    var replaceAllCalled = false
    var lastReplacementMode: EntityMode?
    var lastReplacementSessionIds: [String] = []

    func addEntity(info: SessionInfo, mode: EntityMode) { /* track */ }
    func removeEntity(sessionId: String) { /* track */ }

    func replaceAllEntities(with mode: EntityMode, infos: [SessionInfo],
                             lastEvents: [String: EntityInputEvent],
                             completion: @escaping () -> Void) {
        replaceAllCalled = true
        lastReplacementMode = mode
        lastReplacementSessionIds = infos.map(\.sessionId)
        DispatchQueue.main.async { completion() }
    }
}
```

（依据 MockScene 现有 CatState / addCat 桩，适配即可。）

- [ ] **Step 2: Implement SessionManager.bind(modeStore:) + lastEvent tracking**

新增属性：

```swift
private var modeStoreCancellable: AnyCancellable?
private var lastEvents: [String: EntityInputEvent] = [:]
private var currentMode: EntityMode = .cat

func bind(modeStore: EntityModeStore) {
    currentMode = modeStore.current
    modeStoreCancellable = modeStore.publisher
        .dropFirst()
        .receive(on: RunLoop.main)
        .sink { [weak self] newMode in
            self?.performHotSwitch(to: newMode)
        }
}

private func performHotSwitch(to newMode: EntityMode) {
    let prev = currentMode
    currentMode = newMode
    let infos = Array(sessions.values)
    scene.replaceAllEntities(
        with: newMode,
        infos: infos,
        lastEvents: lastEvents
    ) {
        EventBus.shared.entityModeChanged.send(
            EntityModeChangeEvent(previous: prev, next: newMode)
        )
    }
}
```

在 `handle(message:)` 中：

```swift
// After building _entityInput, cache it
lastEvents[sessionId] = _entityInput
```

在 sessionEnd case 里清理：

```swift
lastEvents.removeValue(forKey: sessionId)
```

- [ ] **Step 3: AppDelegate 调 bind**

`AppDelegate.applicationDidFinishLaunching` 的 SessionManager 初始化后：

```swift
sessionManager.bind(modeStore: EntityModeStore.shared)
```

- [ ] **Step 4: Run the integration tests**

```bash
swift test --filter HotSwitchIntegrationTests
```

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeCodeBuddy/Session/SessionManager.swift \
        Sources/ClaudeCodeBuddy/App/AppDelegate.swift \
        Tests/BuddyCoreTests/HotSwitchIntegrationTests.swift \
        Tests/BuddyCoreTests/MockScene.swift
git commit -m "feat(session): SessionManager 订阅 EntityModeStore 并编排热切换

缓存每个 session 的 lastEvent；切换时按事件回放到新形态的对应状态。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 4.3: 热切换期间事件队列化（避免丢事件）

**Files:**
- Modify: `Sources/ClaudeCodeBuddy/Session/SessionManager.swift`

- [ ] **Step 1: Add transitionInProgress flag + queue**

```swift
private var isTransitioning = false
private var queuedMessages: [HookMessage] = []

// 在 handle(message:) 的最开头：
if isTransitioning {
    queuedMessages.append(message)
    return
}
```

在 `performHotSwitch` 中：

```swift
private func performHotSwitch(to newMode: EntityMode) {
    isTransitioning = true
    // ... existing replaceAll call
    scene.replaceAllEntities(...) { [weak self] in
        guard let self = self else { return }
        self.isTransitioning = false
        let q = self.queuedMessages
        self.queuedMessages.removeAll()
        for m in q { self.handle(message: m) }
        // emit event
    }
}
```

- [ ] **Step 2: Write a test for queueing**

`HotSwitchIntegrationTests.swift` 追加：

```swift
func testEventsDuringTransition_areReplayed() {
    let scene = MockScene()
    let manager = SessionManager(scene: scene)
    let store = EntityModeStore(settingsURL: URL(fileURLWithPath: "/tmp/hs-queue-\(UUID().uuidString).json"))
    manager.bind(modeStore: store)

    // Set a replaceAll that blocks until we signal
    let blockSema = DispatchSemaphore(value: 0)
    scene.replaceAllBlock = {
        blockSema.wait()
    }
    store.set(.rocket)

    // While transition pending, send a new hook message
    let msg = HookMessage(sessionId: "new-during-transition", event: .sessionStart,
                           tool: nil, timestamp: 0, cwd: "/tmp", label: nil,
                           pid: nil, terminalId: nil, description: nil)
    manager.handle(message: msg)

    XCTAssertTrue(manager.sessions["new-during-transition"] == nil,
                  "event should be queued, not processed")

    // Release transition
    blockSema.signal()
    let done = expectation(description: "queue drained")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        if manager.sessions["new-during-transition"] != nil { done.fulfill() }
    }
    wait(for: [done], timeout: 2.0)
}
```

（`MockScene` 需要 `replaceAllBlock` 钩子，能在 completion 调用前阻塞。）

- [ ] **Step 3: Test pass**

```bash
swift test --filter HotSwitchIntegrationTests.testEventsDuringTransition_areReplayed
```

- [ ] **Step 4: Commit**

```bash
git add Sources/ClaudeCodeBuddy/Session/SessionManager.swift \
        Tests/BuddyCoreTests/HotSwitchIntegrationTests.swift \
        Tests/BuddyCoreTests/MockScene.swift
git commit -m "feat(session): 热切换期间事件队列化，过渡后按序重放

避免切换动画窗口期内丢失 hook 事件。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 4.4: buddy morph CLI 命令

**Files:**
- Modify: `Sources/BuddyCLI/main.swift`
- Modify: `Sources/ClaudeCodeBuddy/Network/HookMessage.swift` (add `morph` event)
- Modify: `Sources/ClaudeCodeBuddy/Session/SessionManager.swift` (handle new event)

- [ ] **Step 1: 新增 HookEvent case**

`HookMessage.swift`：

```swift
enum HookEvent: String, Codable {
    // ... existing
    case morph = "morph"
}
```

- [ ] **Step 2: HookMessage 支持 mode 字段**

```swift
struct HookMessage: Codable {
    // ... existing
    let mode: String?
}
```

对应更新 CodingKeys（`mode` 映射自己）。

- [ ] **Step 3: SessionManager 处理 morph**

在 `handle(message:)` 的 switch 里新增：

```swift
case .morph:
    if let raw = message.mode, let mode = EntityMode(rawValue: raw) {
        EntityModeStore.shared.set(mode)
    }
    return
```

- [ ] **Step 4: BuddyCLI main.swift 新增 morph 子命令**

在 CLI 的命令分发位置新增（现有结构可 grep `case "session":` 找到）：

```swift
case "morph":
    try handleMorph(args: Array(args.dropFirst(2)))
```

实现：

```swift
func handleMorph(args: [String]) throws {
    if args.isEmpty {
        // Query current mode — read settings.json directly (CLI doesn't have IPC for this yet)
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        let url = base.appendingPathComponent("ClaudeCodeBuddy/settings.json")
        if let data = try? Data(contentsOf: url),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let mode = obj["entityMode"] as? String {
            print(#"{"mode":"\#(mode)"}"#)
        } else {
            print(#"{"mode":"cat"}"#)
        }
        return
    }

    let target = args[0]
    guard ["cat", "rocket"].contains(target) else {
        throw CLIError.invalidArgs("morph 参数必须是 cat 或 rocket，收到: \(target)")
    }

    // Send via socket so running app picks it up (triggers hot-switch)
    let msg = BuddyMessage(
        sessionId: "",
        event: "morph",
        tool: nil,
        timestamp: Date().timeIntervalSince1970,
        cwd: nil,
        label: nil,
        pid: nil,
        terminalId: nil,
        description: nil,
        mode: target
    )
    try sendMessage(msg)
    print(#"{"mode":"\#(target)","status":"requested"}"#)
}
```

`BuddyMessage` 结构体要加 `mode: String?` 属性。

- [ ] **Step 5: 手动验证**

```bash
swift build && make run &
sleep 3
buddy session start --id debug-morph-test --cwd /tmp
sleep 1
buddy morph rocket
sleep 3  # 观察猫变火箭
buddy morph cat
sleep 3  # 观察火箭变猫
buddy morph  # 应输出 {"mode":"cat"}
killall ClaudeCodeBuddy
```

- [ ] **Step 6: Commit**

```bash
git add Sources/BuddyCLI/ Sources/ClaudeCodeBuddy/Network/ \
        Sources/ClaudeCodeBuddy/Session/
git commit -m "feat(cli): buddy morph 命令支持热切换猫/火箭形态

morph 通过 socket 走现有通道，落到 SessionManager 触发 EntityModeStore.set。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 4.5: Step 4 验证

- [ ] **Step 1: 全量测试 + lint**

```bash
make lint-fix && swift test 2>&1 | tail -10
```

- [ ] **Step 2: 10 次切换内存稳定性**

```bash
make run &
sleep 3
buddy session start --id debug-mem --cwd /tmp
for i in $(seq 1 10); do
    buddy morph rocket; sleep 1
    buddy morph cat; sleep 1
done
ps -o rss -p $(pgrep ClaudeCodeBuddy) | tail -1
buddy session end --id debug-mem
killall ClaudeCodeBuddy
```

记录切换前后 `rss` 值对比，差异应 ≤ 5 MB（5120 KB）。

- [ ] **Step 3: Tag**

```bash
git tag -a step-4-hot-switch-done -m "Step 4 complete: hot-switch via CLI works"
```

**✅ Step 4 Merge 点**：`buddy morph` 命令可热切换，10 次切换内存稳定。

---

# Step 5 · 窗口纵向扩展

**目标**：`BuddyWindow.expandHeight(by:duration:)` 响应 `sceneExpansionRequested`；`DockTracker` 提供暂停贴边修正 API；火箭 PropulsiveLanding / Liftoff 真正扩展窗口。

**Merge 点**：肉眼可见火箭从扩展区垂直降下 / 升起。

---

### Task 5.1: DockTracker 暂停修正 API

**Files:**
- Modify: `Sources/ClaudeCodeBuddy/Window/DockTracker.swift`

- [ ] **Step 1: Add suspension flag**

```swift
class DockTracker {
    /// When true, consumers (AppDelegate) should not reposition the window.
    /// Used during SceneExpansion animations to avoid jitter.
    private(set) var isSuspended = false

    func suspendRepositioning() { isSuspended = true }
    func resumeRepositioning() { isSuspended = false }
    // ... rest unchanged
}
```

- [ ] **Step 2: AppDelegate 使用**

找到 `AppDelegate` 中定期更新窗口位置的逻辑（grep `buddyWindowFrame` 或 `setFrame`）。在 frame 更新前检查：

```swift
guard !dockTracker.isSuspended else { return }
```

- [ ] **Step 3: Build + test**

```bash
swift build && swift test 2>&1 | tail -5
```

- [ ] **Step 4: Commit**

```bash
git add Sources/ClaudeCodeBuddy/Window/DockTracker.swift \
        Sources/ClaudeCodeBuddy/App/AppDelegate.swift
git commit -m "feat(window): DockTracker 支持暂停/恢复贴边修正

窗口纵向扩展动画期间暂停，避免与 Dock 追踪打架。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 5.2: BuddyWindow 扩展动画 API

**Files:**
- Modify: `Sources/ClaudeCodeBuddy/Window/BuddyWindow.swift`

- [ ] **Step 1: Add API**

```swift
class BuddyWindow: NSWindow {
    // ... existing

    /// Temporarily grow the window upward by `delta` pts for `duration` seconds,
    /// then animate back to the original frame.
    /// Anchored to the bottom (Dock top). Caller is responsible for suspending DockTracker.
    func expandHeightTemporarily(by delta: CGFloat, duration: TimeInterval) {
        let original = self.frame
        let expanded = NSRect(
            x: original.origin.x,
            y: original.origin.y,  // bottom stays pinned
            width: original.size.width,
            height: original.size.height + delta
        )
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration / 2
            ctx.allowsImplicitAnimation = true
            self.setFrame(expanded, display: true, animate: true)
        }, completionHandler: { [weak self] in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = duration / 2
                ctx.allowsImplicitAnimation = true
                self?.setFrame(original, display: true, animate: true)
            })
        })
    }
}
```

- [ ] **Step 2: AppDelegate 订阅 sceneExpansionRequested**

```swift
EventBus.shared.sceneExpansionRequested
    .receive(on: RunLoop.main)
    .sink { [weak self] req in
        guard let self = self else { return }
        self.dockTracker.suspendRepositioning()
        self.window.expandHeightTemporarily(by: req.height, duration: req.duration)
        DispatchQueue.main.asyncAfter(deadline: .now() + req.duration + 0.1) {
            self.dockTracker.resumeRepositioning()
        }
    }
    .store(in: &cancellables)
```

（`cancellables: Set<AnyCancellable>` 属性加到 AppDelegate 上，若未存在。）

- [ ] **Step 3: Manual verification**

```bash
make run &
sleep 3
buddy session start --id debug-expand --cwd /tmp
buddy morph rocket
sleep 2
buddy emit task_complete --id debug-expand
# 观察 Dock 上方窗口短暂向上扩展后恢复
sleep 4
buddy session end --id debug-expand
# 观察 Liftoff 动画（应扩展更高）
sleep 2
killall ClaudeCodeBuddy
```

- [ ] **Step 4: Commit**

```bash
git add Sources/ClaudeCodeBuddy/Window/BuddyWindow.swift \
        Sources/ClaudeCodeBuddy/App/AppDelegate.swift
git commit -m "feat(window): BuddyWindow.expandHeightTemporarily + AppDelegate 订阅

PropulsiveLanding / Liftoff 事件触发窗口动态扩展。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 5.3: Step 5 合并点

- [ ] **Step 1: Full tests**

```bash
swift test 2>&1 | tail -5
```

- [ ] **Step 2: Tag**

```bash
git tag -a step-5-window-expansion-done -m "Step 5 complete: window can expand for rocket drama"
```

**✅ Step 5 Merge 点**：火箭关键状态触发窗口可视扩展。

---

# Step 6 · 火箭精灵资源（完全重画）

**目标**：按 Phase 1 六个状态设计最小像素画集，替换占位精灵。time-box 3 天；超期降级发 v0.7.0-beta。

**Merge 点**：视觉上像火箭不像纸飞机。

---

### Task 6.1: 生成器脚本 v2 骨架

**Files:**
- Create: `Scripts/generate-rocket-sprites-v2.swift`

> **设计注**：老 commit `8d74ff4` 的生成器可参考但不复用命名；v2 输出到 `Assets/Sprites/Rocket/rocket_*.png`。如果你有像素画师资源或更偏好手绘，本 Task 可跳过——直接把手绘 PNG 放到同目录。

- [ ] **Step 1: 创建脚本**

```swift
#!/usr/bin/env swift
// generate-rocket-sprites-v2.swift
// Generates 48x48 rocket sprites for Phase 1 RocketStates.
// Usage: swift Scripts/generate-rocket-sprites-v2.swift

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let outputDir = "Sources/ClaudeCodeBuddy/Assets/Sprites/Rocket"

// ---- Core drawing helpers (port from老 commit with new naming) ----

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1.0) -> CGColor {
    CGColor(red: r/255, green: g/255, blue: b/255, alpha: a)
}

// Rocket palette (F9-ish white/black/red)
let rocketWhite = rgb(235, 235, 240)
let rocketRed = rgb(210, 60, 60)
let rocketBlack = rgb(30, 30, 35)
let padGray = rgb(100, 100, 110)
let flameOrange = rgb(255, 150, 50)
let flameYellow = rgb(255, 230, 80)
let warningRed = rgb(255, 40, 40)

// ---- Frame generators ----
// rocket_onpad_a.png   — standing on pad, lights normal
// rocket_onpad_b.png   — standing on pad, lights dim (for blink)
// rocket_systems_a..d  — blink sequence (4 frames)
// rocket_cruise_a..b   — flame active (2-frame loop)
// rocket_abort_a..b    — warning light red/off
// rocket_landing_a..c  — legs deployed mid-descent
// rocket_liftoff_a..b  — full flame, no pad visible

// (Body: 重用 rocketBody() 绘制函数，参数化高度、翻转、灯光状态)

func ensureDir(_ p: String) {
    try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
}

ensureDir(outputDir)

// ... generator bodies to implement ...

print("Generated rocket sprites to \(outputDir)")
```

- [ ] **Step 2: 逐个实现帧生成函数**

此为子任务的容器。每个关键帧一个小 helper（rocketBody / rocketPad / flameSmall / flameLarge / warningLight）。实施时参考老 commit 的 `Scripts/generate-rocket-sprites.swift`，但：

- **文件名前缀** 全部改为 `rocket_` + 状态语义名（不是老 commit 的 `cat_`）
- **尺寸** 固定 48x48
- **动画命名约定**：`<state>_<frame_letter>.png`，例如 `rocket_onpad_a.png`, `rocket_cruise_b.png`

最低目标帧数：
- onpad: 2 帧
- systems: 4 帧
- cruise: 2 帧
- abort: 2 帧
- landing: 3 帧
- liftoff: 2 帧

**合计 ~15 帧**，time-box 3 天做完。

- [ ] **Step 3: 运行生成器**

```bash
swift Scripts/generate-rocket-sprites-v2.swift
ls Sources/ClaudeCodeBuddy/Assets/Sprites/Rocket/
```

预期看到 15 个 PNG 文件。

- [ ] **Step 4: Commit**

```bash
git add Scripts/generate-rocket-sprites-v2.swift \
        Sources/ClaudeCodeBuddy/Assets/Sprites/Rocket/
git commit -m "feat(rocket): 生成器 v2 + 15 帧 Phase 1 火箭精灵

覆盖 onpad/systems/cruise/abort/landing/liftoff 六状态关键帧。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 6.2: RocketSpriteLoader 从磁盘加载真实帧

**Files:**
- Modify: `Sources/ClaudeCodeBuddy/Entity/Rocket/RocketSpriteLoader.swift`

- [ ] **Step 1: Replace placeholder**

```swift
enum RocketSpriteLoader {

    private static var cache: [String: [SKTexture]] = [:]

    static func frames(for animation: String) -> (frames: [SKTexture], fps: Double) {
        if let cached = cache[animation] { return (cached, defaultFPS(for: animation)) }

        let bundle = ResourceBundle.bundle
        let prefix = "rocket_\(animation)_"
        let frames: [SKTexture] = ["a", "b", "c", "d"].compactMap { letter in
            guard let url = bundle.url(forResource: prefix + letter, withExtension: "png",
                                        subdirectory: "Assets/Sprites/Rocket"),
                  let img = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateImageAtIndex(img, 0, nil) else { return nil }
            let tex = SKTexture(cgImage: cg)
            tex.filteringMode = .nearest
            return tex
        }
        guard !frames.isEmpty else {
            return ([placeholderTexture()], 1.0)  // fallback
        }
        cache[animation] = frames
        return (frames, defaultFPS(for: animation))
    }

    static func placeholderTexture() -> SKTexture {
        let size = RocketConstants.Visual.spriteSize
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        let tex = SKTexture(image: image)
        tex.filteringMode = .nearest
        return tex
    }

    private static func defaultFPS(for anim: String) -> Double {
        switch anim {
        case "systems": return 4.0
        case "cruise":  return 5.0
        case "liftoff": return 8.0
        default:         return 2.0
        }
    }
}
```

- [ ] **Step 2: RocketState didEnter 用真实帧**

每个状态 `didEnter` 里，将 `SKAction.fadeAlpha` 占位替换为真实帧动画：

```swift
// 示例 RocketOnPadState
override func didEnter(from previousState: GKState?) {
    let (frames, fps) = RocketSpriteLoader.frames(for: "onpad")
    guard frames.count > 1 else { return }
    let loop = SKAction.repeatForever(
        SKAction.animate(with: frames, timePerFrame: 1.0 / fps)
    )
    entity.node.run(loop, withKey: "onPad")
}
```

其余状态类似修改。

- [ ] **Step 3: 手动验证所有状态**

```bash
make run &
sleep 3
buddy morph rocket
buddy session start --id debug-v2 --cwd /tmp
for evt in thinking tool_start tool_end task_complete; do
    buddy emit $evt --id debug-v2
    sleep 3
done
buddy session end --id debug-v2
sleep 2
killall ClaudeCodeBuddy
```

- [ ] **Step 4: Commit**

```bash
git add Sources/ClaudeCodeBuddy/Entity/Rocket/
git commit -m "feat(rocket): 六状态使用真实像素动画帧

RocketSpriteLoader 缓存 texture；失败时 fallback 占位。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 6.3: Step 6 合并点

- [ ] Tag

```bash
git tag -a step-6-rocket-art-done -m "Step 6 complete: rocket looks like a rocket"
```

**✅ Step 6 Merge 点**：火箭精灵替换到位，视觉合格。

---

# Step 7 · Menubar 集成

**目标**：`SessionPopoverController` 顶部加 Morph 分段控件；StatusBar 图标按 mode 切换。

**Merge 点**：menubar 切换与 CLI 等价。

---

### Task 7.1: SessionPopoverController Morph 分段控件

**Files:**
- Modify: `Sources/ClaudeCodeBuddy/MenuBar/SessionPopoverController.swift`

- [ ] **Step 1: Add NSSegmentedControl to top of popover**

```swift
// In loadView() or equivalent setup:
let morphSegment = NSSegmentedControl(labels: ["🐱 Cat", "🚀 Rocket"],
                                       trackingMode: .selectOne,
                                       target: self,
                                       action: #selector(morphChanged(_:)))
morphSegment.selectedSegment = EntityModeStore.shared.current == .cat ? 0 : 1
// add to top of stack view
```

```swift
@objc private func morphChanged(_ sender: NSSegmentedControl) {
    let mode: EntityMode = sender.selectedSegment == 0 ? .cat : .rocket
    EntityModeStore.shared.set(mode)
}
```

- [ ] **Step 2: Subscribe publisher to keep segment in sync (CLI changes update menubar)**

```swift
EntityModeStore.shared.publisher
    .receive(on: RunLoop.main)
    .sink { [weak morphSegment] mode in
        morphSegment?.selectedSegment = mode == .cat ? 0 : 1
    }
    .store(in: &cancellables)
```

- [ ] **Step 3: Manual test**

```bash
make run &
sleep 3
# Click menubar icon → popover shows Morph segment
# Click Rocket → see hot switch
# Click Cat → back
# Also: buddy morph rocket (CLI) → segment updates to Rocket
killall ClaudeCodeBuddy
```

- [ ] **Step 4: Commit**

```bash
git add Sources/ClaudeCodeBuddy/MenuBar/SessionPopoverController.swift
git commit -m "feat(menubar): popover 顶部新增 Morph 分段控件

点击即时热切换；订阅 publisher 与 CLI 双向同步。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 7.2: StatusBar 图标 mode-aware

**Files:**
- Modify: StatusBar 图标设置处（grep `statusItem` 在 `Sources/ClaudeCodeBuddy/App/` 或 `MenuBar/` 下）

- [ ] **Step 1: 按 mode 选图**

找到 `NSStatusItem` 的 `button.image` 设置位置，改为函数：

```swift
private func updateStatusBarIcon(for mode: EntityMode) {
    let symbolName = mode == .cat ? "cat.fill" : "airplane"
    statusItem.button?.image = NSImage(systemSymbolName: symbolName,
                                        accessibilityDescription: mode.rawValue)
}
```

启动时 + 订阅变化：

```swift
updateStatusBarIcon(for: EntityModeStore.shared.current)
EntityModeStore.shared.publisher
    .receive(on: RunLoop.main)
    .sink { [weak self] mode in self?.updateStatusBarIcon(for: mode) }
    .store(in: &cancellables)
```

- [ ] **Step 2: Commit**

```bash
git add Sources/ClaudeCodeBuddy/MenuBar/ Sources/ClaudeCodeBuddy/App/
git commit -m "feat(menubar): StatusBar 图标随 EntityMode 切换（cat.fill / airplane）

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 7.3: Step 7 合并点

- [ ] Tag

```bash
git tag -a step-7-menubar-done -m "Step 7 complete: menubar morph + icon"
```

**✅ Step 7 Merge 点**：menubar 完全集成。

---

# Step 8 · 收尾 release

**目标**：验收测试 / 文档 / autopilot 知识沉淀 / 版本号 + cask 同步。

**Merge 点**：`v0.7.0` release。

---

### Task 8.1: Acceptance shell 测试

**Files:**
- Create: `tests/acceptance/test-rocket-morph.sh`

- [ ] **Step 1: Write acceptance script**

```bash
#!/usr/bin/env bash
# test-rocket-morph.sh
# Verifies hot-switching and rocket state sequence.
set -euo pipefail

SOCKET="/tmp/claude-buddy.sock"
if [ ! -S "$SOCKET" ]; then
    echo "FAIL: buddy app not running"
    exit 1
fi

SID="debug-accept-$(date +%s)"

buddy session start --id "$SID" --cwd /tmp
sleep 1

# --- cat phase ---
buddy morph cat
sleep 2
buddy emit thinking --id "$SID"
sleep 1

# --- switch to rocket ---
buddy morph rocket
sleep 2

# state should be replayed; rocket should be in systemsCheck / onPad
buddy emit tool_start --id "$SID" --tool Read
sleep 2
buddy emit task_complete --id "$SID"
sleep 3  # propulsive landing animation
buddy emit tool_start --id "$SID" --tool Write
sleep 2

# --- switch back to cat mid-cruise ---
buddy morph cat
sleep 2

buddy session end --id "$SID"
sleep 1

echo "PASS: rocket morph acceptance"
```

- [ ] **Step 2: 给执行权限并加入 run-all**

```bash
chmod +x tests/acceptance/test-rocket-morph.sh
# 找到 tests/acceptance/run-all.sh，追加 test-rocket-morph.sh
```

- [ ] **Step 3: Commit**

```bash
git add tests/acceptance/test-rocket-morph.sh tests/acceptance/run-all.sh
git commit -m "test(acceptance): 新增 rocket morph 热切换验收脚本

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 8.2: buddy test 按 mode 跑

**Files:**
- Modify: `Sources/BuddyCLI/main.swift`

- [ ] **Step 1: buddy test 读当前 mode 并跑对应状态集**

在 `handleTest` 函数里：

```swift
// 读当前 mode
let mode = readCurrentModeFromSettings()  // 复用 handleMorph 中的读逻辑
let events: [String]
switch mode {
case "rocket":
    events = ["session_start", "thinking", "tool_start", "tool_end",
              "permission_request", "task_complete", "session_end"]
default:
    events = ["session_start", "thinking", "tool_start", "tool_end",
              "permission_request", "task_complete", "session_end"]
}
// Both modes drive the same events; the entities translate internally.
// But we can add mode-specific "external_command" cases later for phase 2.
```

（实际 events 列表对两种 mode 相同——这正是 C 解耦的好处。fn 读 mode 只是为了在输出文案里显示"Testing rocket mode"这类提示。）

- [ ] **Step 2: Commit**

```bash
git add Sources/BuddyCLI/main.swift
git commit -m "feat(cli): buddy test 输出当前 mode 信息

事件列表两 mode 相同（C 解耦带来的福利），仅打印提示。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 8.3: README + CLAUDE.md + autopilot 决策沉淀

**Files:**
- Modify: `README.md`
- Modify: `CLAUDE.md`
- Modify: `.autopilot/decisions.md`
- Modify: `.autopilot/patterns.md`

- [ ] **Step 1: README 新增 "形态切换" 一节**

在 "猫咪状态" 表格后追加：

```markdown
## 形态切换（New in v0.7.0）

ClaudeCodeBuddy 支持两种形态，随时热切换：

- 🐱 **Cat**（默认）— 像素猫咪，带食物、睡床、惊吓等丰富交互。
- 🚀 **Rocket** — 像素火箭，状态可视化为点火/巡航/告警/回收/升空。

切换方式（立即生效，无需重启）：

**状态栏**：点击菜单栏 Buddy 图标 → 顶部 `Morph: [🐱 Cat] [🚀 Rocket]` 分段控件。

**命令行**：

```
buddy morph rocket     # 切换到火箭
buddy morph cat        # 切回猫
buddy morph            # 查询当前形态
```

切换过程中会话身份、颜色、当前状态全部保留。
```

- [ ] **Step 2: CLAUDE.md 架构章节更新**

架构图块更新：

```
Entity/
├── SessionEntity.swift      # 薄骨架协议（Phase 1 引入）
├── EntityInputEvent.swift   # 通用事件枚举
├── EntityMode.swift         # .cat / .rocket
├── EntityModeStore.swift    # 持久化 + publisher
├── EntityFactory.swift
├── EntityState.swift        # display enum（保留）
├── Cat/
│   ├── CatEntity.swift      # 原 CatSprite 改名
│   ├── CatConstants.swift
│   ├── States/
│   └── CatComponents/       # 原 Components/ 下沉
└── Rocket/
    ├── RocketEntity.swift
    ├── RocketConstants.swift
    ├── RocketSpriteLoader.swift
    ├── States/
    └── RocketComponents/
```

"猫咪状态机" 章节改名为 "形态状态机"，增加 Rocket 6 状态描述。

- [ ] **Step 3: autopilot/decisions.md 记录架构决策**

追加：

```markdown
## 2026-04-17 · Phase 1 Rocket Morph — B + A + C + B + 方式1 + AC + C

- **抽象层**：引入 `SessionEntity` 薄协议（≤30 行），剥离所有形态专属概念
- **全局切换**：同时只存在一种形态；`EntityModeStore` 持久化 + Combine publisher
- **状态机解耦**：`CatState` 与 `RocketState` 独立枚举；只共享 `EntityInputEvent`
- **场景扩展**：通过 EventBus `sceneExpansionRequested` 解耦火箭与 BuddyWindow
- **零交互 Phase 1**：火箭不接收投喂 / 睡床 / 惊吓 / 跳跃；留 `externalCommand` 扩展位
- **双入口切换**：menubar 分段控件 + `buddy morph` CLI
- **资源重画**：老 commit 仅作参考，新版本精灵文件名前缀 `rocket_*`
```

- [ ] **Step 4: autopilot/patterns.md**

```markdown
## Pattern: 事件驱动 Entity（取代命令式 switchState）

**场景**：多态 Entity 需要对外统一接口，内部各自翻译到私有状态机。

**做法**：
1. 定义通用事件 enum（`EntityInputEvent`）
2. `SessionEntity` 协议只暴露 `handle(event:)`
3. 每个具体 Entity 内部 switch(event)，enter 自己的 GKState 子类

**好处**：协议薄、形态独立演化、Phase 2 加新事件不破坏已有调用。
```

- [ ] **Step 5: Commit**

```bash
git add README.md CLAUDE.md .autopilot/
git commit -m "docs: v0.7.0 形态切换文档 + autopilot 知识沉淀

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 8.4: 版本号 + Homebrew cask 同步

**Files:**
- Modify: `Sources/BuddyCLI/main.swift:7` (`private let appVersion = ...`)
- Modify: `plugin/plugin.json` 或等价 manifest
- Modify: `homebrew-claude-code-buddy/Casks/claude-code-buddy.rb`

- [ ] **Step 1: Bump CLI version**

`Sources/BuddyCLI/main.swift`：

```swift
private let appVersion = "0.7.0"
```

- [ ] **Step 2: 其他版本引用**

```bash
grep -rn "0.6.1" --include="*.json" --include="*.rb" --include="*.md" --include="*.yml"
```

逐个处理，排除 CHANGELOG/release notes 中的历史引用。

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "chore: bump to v0.7.0

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 8.5: Final verification + tag release

- [ ] **Step 1: 全量测试 + 验收**

```bash
make lint-fix && make format
swift test 2>&1 | tail -10
bash tests/acceptance/run-all.sh 2>&1 | tail -20
```

- [ ] **Step 2: Bundle + smoke**

```bash
make bundle
open ClaudeCodeBuddy.app
# 手动验证：
# - 默认猫模式
# - menubar 切换到 rocket，看到过渡
# - buddy morph cat 回到猫
# - 关闭
```

- [ ] **Step 3: Tag release**

```bash
git tag -a v0.7.0 -m "v0.7.0 — Phase 1 Rocket Morph

- Abstract SessionEntity layer
- Rocket form (state visualization only, zero interactions in Phase 1)
- Hot-switch via menubar + buddy morph CLI
- Window vertical expansion for dramatic rocket states
- Full cat behavior backward-compatible
"
```

- [ ] **Step 4: Push**

（此步骤由用户决定何时执行——不在 agent 自动范围）

```bash
# git push origin main
# git push origin v0.7.0
# GitHub Actions 会自动构建 Release 并同步 cask
```

**✅ Step 8 / Phase 1 Merge 点**：`v0.7.0` 可发布。

---

## Phase 1 全量验收清单

见 spec `docs/superpowers/specs/2026-04-17-rocket-refactor-design.md` 第 7 节。本计划执行完毕应通过：

- [ ] `buddy morph rocket` 后 1 秒内所有猫变火箭，session 身份 / 颜色 / 状态全保留
- [ ] Menubar 分段控件与 CLI 等价
- [ ] Claude Code 正常使用中切换不丢事件
- [ ] 火箭 `taskComplete` 触发窗口扩展 + 垂直着陆可见
- [ ] 火箭 `sessionEnd` 触发 Liftoff，拖尾冲出视野
- [ ] 火箭 `permissionRequest` 红色频闪可见
- [ ] Fresh install 默认 `cat`；老用户升级无感
- [ ] `swift test` 全绿，行覆盖率不下降
- [ ] SwiftLint 零警告
- [ ] 10 次热切换内存波动 ≤ 5MB
- [ ] `SessionEntity` 协议 ≤ 30 行，无形态专属词
- [ ] `SessionManager` 无 `CatEntity` / `RocketEntity` 具体类名（fallback 除外）
- [ ] `RocketEntity` 不引入 `Cat*` 头文件即可编译

---

## 术语对照速查

| Spec 术语 | 本计划实际名称 | 理由 |
|---|---|---|
| `SessionEvent` 事件枚举 | `EntityInputEvent` | `struct SessionEvent` 已占用名字 |
| `SessionEvent` 生命周期 struct | `SessionLifecycleEvent` | 老 struct 改名腾出新名字 |
| `EntityProtocol` | `SessionEntity` | spec 明确 |
| `CatSprite` | `CatEntity` | spec 明确 |
| `Entity/Components/` | `Entity/Cat/CatComponents/` | spec 明确 |

其余命名与 spec 一致。
