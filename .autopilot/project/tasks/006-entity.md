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
func addCat(info: SessionInfo) {
    let cat = CatSprite(sessionId: info.sessionId)
    cat.configure(color: info.color, label: info.label)
    addEntity(cat)
}
```

### FoodManager 适配

```swift
// Before
func notifyIdleCats(about food: FoodSprite) {
    guard let idleCats = scene?.idleCats() else { return }
    for cat in idleCats { cat.walkToFood(food) { ... } }
}

// After
func notifyIdleEntities(about food: FoodSprite) {
    guard let entities = scene?.idleEntities() else { return }
    for entity in entities {
        guard let foodEntity = entity as? FoodInteractable else { continue }
        foodEntity.walkToFood(food) { ... }
    }
}
```

### 测试迁移
- `JumpExitTests` 中的 `CatSprite` 类型保持（测试仍然测试具体猫行为）
- 但如果 `exitScene` 签名中 `obstacles` 参数类型从 `CatSprite` 变为 `EntityProtocol`，测试中的类型构造需要更新
- `nearbyObstacles` 闭包返回类型从 `[(cat: CatSprite, x: CGFloat)]` 变为 `[(x: CGFloat, entity: any EntityProtocol)]`

### 目录移动
将文件移动到新目录结构：
```bash
mkdir -p Sources/ClaudeCodeBuddy/Entity/Cat/States
mkdir -p Sources/ClaudeCodeBuddy/Entity/Components
mv Sources/ClaudeCodeBuddy/Scene/CatSprite.swift Sources/ClaudeCodeBuddy/Entity/Cat/
mv Sources/ClaudeCodeBuddy/Scene/CatConstants.swift Sources/ClaudeCodeBuddy/Entity/Cat/
mv Sources/ClaudeCodeBuddy/Scene/States/* Sources/ClaudeCodeBuddy/Entity/Cat/States/
mv Sources/ClaudeCodeBuddy/Scene/Components/* Sources/ClaudeCodeBuddy/Entity/Components/
```

## 验收标准
- [ ] `swift build` 编译通过
- [ ] `swift test` 所有测试通过
- [ ] BuddyScene 中不再直接引用 `CatSprite` 类型（除 `addCat` 便捷方法）
- [ ] `EntityProtocol` 定义完整，足以让 BuddyScene 不 downcast 管理实体
- [ ] FoodManager 通过 `FoodInteractable` 协议与实体交互
- [ ] 文件已移到新目录结构
