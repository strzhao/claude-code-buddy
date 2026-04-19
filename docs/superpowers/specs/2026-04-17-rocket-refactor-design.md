# Rocket Morph — Deep Refactor Design

把 ClaudeCodeBuddy 从"只有一只猫"重构为"可在猫 / 火箭两种形态间热切换"。Phase 1 建立薄抽象层 + 火箭形态的纯状态可视化 MVP（零交互），Phase 2+ 再扩展火箭专属交互。

## Goals

- 抽象出 `SessionEntity` 薄协议，让 `CatEntity` 与 `RocketEntity` 互不相识。
- 猫的现有业务逻辑零改动（只改名、移包路径、适配协议）。
- 用户可通过 **menubar popover** 或 **`buddy morph` CLI** 随时热切换，无需重启，session 身份 / 颜色 / 标签 / 当前状态全部保留。
- 火箭形态拥有独立的状态机与视觉语言（不迁就猫的六态语义）。
- 关键戏剧状态（着陆 / 升空）允许窗口向上临时扩展，不干扰 DockTracker 贴边逻辑。

## Non-Goals（Phase 1 明确不做）

- 火箭专属交互：投喂 / 载荷 / RUD / 群体编队。
- 运行时单 session 变形（同一 session 中途换形态）。
- 火箭响应环境系统（天气 / 时段）—— Phase 1 给空实现。
- 火箭精灵的手绘美术打磨（Step 6 给能用的版本，后续独立 PR）。

## Decisions（Brainstorm 锁定）

| # | 决策 |
|---|---|
| Q1 | 抽 `Entity` 多态层，`CatEntity` / `RocketEntity` 并列 |
| Q2 | 全局切换，同时只存在一种形态 |
| Q3 | 状态机完全解耦，只共享输入事件 |
| Q4 | Dock 水平带 + 关键状态窗口可向上扩展 |
| Q5 | Phase 1 火箭只做状态可视化，零交互 |
| Q6 | menubar 开关 + `buddy morph` 命令，均热切换 |
| Q7 | 火箭精灵完全重新设计，老 commit 仅作参考 |

---

## 1. 架构分层

### 1.1 `SessionEntity` 协议（薄骨架）

```
sessionId: String
containerNode: SKNode
sessionColor: SessionColor?
isDebug: Bool                 // debug-* 前缀判断（通用逻辑）
enterScene(size, bounds)
exitScene(completion)
applyHoverScale() / removeHoverScale()
updateSceneSize(_ size)
handle(event: SessionEvent)   // 唯一的行为入口，事件驱动
```

**从协议中剥离**：`currentState` / `switchState(to:)` / `playFrightReaction` / `walkToFood` / `startEating` —— 这些是猫的私事，对外不暴露。

### 1.2 `SessionEvent` 通用事件

```
sessionStart
thinking
toolStart(name, desc)
toolEnd(name)
permissionRequest(desc)
taskComplete
sessionEnd
hoverEnter / hoverExit
externalCommand(String)       // Phase 2 扩展位（如 "rud"、"deliver-cargo"）
```

每种 Entity 在 `handle(event:)` 内部自行翻译到自己的状态机，**不共享状态枚举**。

### 1.3 目录结构

```
Entity/
├── SessionEntity.swift           # 新协议（原 EntityProtocol 改名瘦身）
├── SessionEvent.swift
├── EntityMode.swift              # .cat / .rocket
├── EntityFactory.swift
├── EntityModeStore.swift         # 持久化 + Combine publisher
├── Cat/
│   ├── CatEntity.swift           # 原 CatSprite 改名
│   ├── CatConstants.swift
│   ├── States/…
│   └── CatComponents/            # 原顶层 Components/ 下沉至此
└── Rocket/
    ├── RocketEntity.swift
    ├── RocketConstants.swift
    ├── States/…
    └── RocketComponents/
```

**关键约束**：`Components/` 不作为两形态共享目录 —— 火箭的运动 / 动画模型与猫差异大，共享会让抽象层被迫"畏手畏脚"。

---

## 2. 全局切换机制

### 2.1 `EntityModeStore`（单一真相源）

- 持久化位置：`~/Library/Application Support/ClaudeCodeBuddy/settings.json`
- Schema：`{ "entityMode": "cat" | "rocket" }`
- 单 key，首次启动默认 `cat`
- 文件损坏时 fallback 到 `.cat` 并输出 warning 日志，不崩
- 暴露 Combine `publisher` 供订阅者响应变化

### 2.2 热切换路径

```
┌─ menubar popover 的 Morph 分段控件 ─┐
│                                      ├──► EntityModeStore.set(.rocket)
└─ CLI: buddy morph rocket ───────────┘           │
                                                   ▼
                                   EntityModeStore.publisher.send(.rocket)
                                                   │
                              ┌────────────────────┼────────────────────┐
                              ▼                    ▼                    ▼
                       SessionManager         BuddyScene          StatusBar 图标
                       (迁移所有活跃         (过场动画)          (跟随 mode 换图)
                        session 的 Entity)
```

### 2.3 过渡动画语法

1. **旧形态下场** ~400ms：猫向屏幕外跑（复用 `exitScene`） / 火箭垂直升空。
2. **中间态** ~100ms：空白 + 可选过场粒子。
3. **新形态入场** ~400ms：按 session 列表逐个 `EntityFactory.make()` + `enterScene`，并按最后一次事件**回放到当前状态**。

**不变量**：SessionManager 持有 `[sessionId: SessionEntity]` + 每个 session 的 `lastEvent`。切换期间会话元数据（id / color / label / lastEvent）保留，只替换外壳。

### 2.4 CLI 命令（新增）

```
buddy morph <cat|rocket>           # 切换形态（热）
buddy morph                        # 查询当前形态（输出 JSON）
buddy morph --on-next-launch cat   # 只改设置，不触发热切换
```

### 2.5 Menubar 入口

SessionPopoverController 顶部新增分段控件：`Morph: [🐱 Cat] [🚀 Rocket]`。点击立即切换，与 CLI 等价。

StatusBar 图标随 `EntityMode` 切换（猫剪影 / 火箭剪影）。

### 2.6 边界情况

- 切换中有 session 处于 `permissionRequest` → 新形态入场后立即进入 `AbortStandby`（或猫版的 `CatPermissionRequestState`），告警不丢。
- 切换期间 hover 状态：由 BuddyScene 托管，下场时自动清理。
- 热切换动画进行中又点一次：**第二次入队**，等第一次跑完再执行（简单、可观察）。
- 热切换窗口内收到新 hook 事件：SessionManager **队列化**，过渡完成后按序重放。

---

## 3. 火箭状态机（Phase 1 最小可用集）

### 3.1 状态集

| 状态 | 输入事件 | 视觉语法 | 窗口扩展？ |
|---|---|---|---|
| **OnPad** | `sessionStart` / idle / `toolEnd` 回落后 | 立在发射架上，舱灯慢闪，脚下偶尔喷白色冷凝水蒸气 | ❌ |
| **SystemsCheck** | `thinking` | 仍在架上，舱灯高频闪烁（绿→黄→绿），底部引擎预热微光 | ❌ |
| **Cruising** | `toolStart` | 点火升空 30px，在 Dock 条内悬停 + 随机水平位移，底部持续喷焰；`toolEnd` 后缓落回架 | ❌（常规高度内微浮） |
| **AbortStandby** | `permissionRequest` | 立即冻结，顶部红色频闪警示灯，舱侧弹工具描述 banner | ❌ |
| **PropulsiveLanding** | `taskComplete` | 窗口扩展 +120px，火箭从扩展区顶部垂直缓降，四柱支架展开，触地扬尘，窗口恢复，沉淀为 OnPad | ✅ +120px / ~1.2s |
| **Liftoff** | `sessionEnd` | 窗口扩展 +200px，火箭垂直加速升空带拖尾烟雾冲出视野，窗口恢复 | ✅ +200px / ~0.8s |

### 3.2 发射架所属

`PadComponent` 作为 `RocketEntity.containerNode` 的子节点，**不是**场景共享元素。多 session 每只火箭自带发射架；离场时架随火箭消失，场景无残骸；不需要 `BedManager` 式协调器。

### 3.3 状态机驱动

沿用 GameplayKit `GKStateMachine`。`RocketState` 枚举与 `RocketOn*State` 子类完全独立，不继承、不复用 `CatState`。`RocketEntity.handle(event:)` 内部 switch 翻译事件到状态类。

### 3.4 窗口扩展 —— EventBus 解耦

`RocketEntity` 不持有 `BuddyWindow` 引用。状态 didEnter 时发布事件：

```
EventBus.publish(.sceneExpansionRequested(height: 120, duration: 1.2))
                                    │
                                    ▼
BuddyWindow.subscribe { req ->
    animate NSWindow frame (height += req.height, y -= req.height)
    schedule restore after req.duration
}
```

好处：
- 猫版不订阅此事件，对猫完全透明。
- 火箭任何状态可按需请求扩展，不受固定表格约束。
- 测试可用 mock EventBus 断言"火箭请求了扩展"，无需真实 NSWindow。

### 3.5 状态迁移图

```
              sessionStart
                  │
                  ▼
 ┌──────────► OnPad ◄────────────┐
 │             │                  │
 │     thinking│                  │ toolEnd（落回）
 │             ▼                  │
 │       SystemsCheck             │
 │             │                  │
 │    toolStart│                  │
 │             ▼                  │
 │          Cruising ─────────────┘
 │
 │    permissionRequest（任意态可进）
 │             │
 │             ▼
 │       AbortStandby
 │             │
 │      （事件消解后回到触发前的状态）
 │
 │    taskComplete
 │             │
 │             ▼
 │    PropulsiveLanding ──► OnPad（定沉）
 │
 │    sessionEnd（任意态可进）
 │             │
 │             ▼
 │        Liftoff ──► Entity 销毁
```

### 3.6 Phase 2+ 保留的扩展位

- `RUDState`：`externalCommand("rud")` 触发，爆炸 → 碎片 → 重组回 OnPad。
- `CargoDeliveryState`：火箭专属版"投喂"，空投载荷。
- 多火箭群体机动。

---

## 4. 数据流 + 重构范围 + 兼容性

### 4.1 端到端事件流

```
Claude Code hook
  ↓ (Unix socket JSON)
SocketServer.onMessage
  ↓
SessionManager.handleMessage
  ↓ (按 sessionId 路由)
  ├─ 无 Entity → EntityFactory.make(mode: current, sessionId, color, label)
  │                         │
  │                         ▼
  │               CatEntity 或 RocketEntity
  └─ 已有 Entity → 复用
  ↓
Entity.handle(event: SessionEvent.toolStart(name, desc))
  ↓ (形态内部翻译)
  ├─ CatEntity: stateMachine.enter(CatToolUseState.self)
  └─ RocketEntity: stateMachine.enter(RocketCruisingState.self)
                        │
                        ▼
         （可能 EventBus.publish(.sceneExpansionRequested)）
                        │
                        ▼
                  BuddyWindow 响应
```

`SessionManager` 不再 import `CatEntity` / `RocketEntity` 具体类，只通过 `SessionEntity` 协议 + `SessionEvent` 通信。

### 4.2 必须动的文件

| 文件 | 改动 |
|---|---|
| `EntityProtocol.swift` | 改名 `SessionEntity.swift`，瘦身 |
| `EntityState.swift` | **删除**（每 entity 自管） |
| `CatSprite.swift` | 改名 `CatEntity.swift`，新增 `handle(event:)`；内部保留 `switchState` / `currentState`；对外仅暴露协议 |
| `Entity/Components/` 整个目录 | 下沉到 `Entity/Cat/CatComponents/` |
| `Scene/BuddyScene.swift` | 引用 `SessionEntity`；猫专属行为（食物追踪 / 猫窝）向下转型到 `CatEntity` 使用 |
| `Session/SessionManager.swift` | 调 `EntityFactory.make()`；订阅 `EntityModeStore.publisher` |
| `MenuBar/SessionPopoverController.swift` | 顶部加 Morph 分段控件 |
| `Sources/BuddyCLI/` | 新增 `morph` subcommand |

### 4.3 完全不动的部分

- `CatConstants.swift` / `CatIdleState.swift` / `AnimationComponent.swift`（仅改包路径）
- `FoodManager.swift` / `FoodSprite.swift`（猫专属，向下转型后使用）
- `Environment/*`（`EnvironmentResponder` 协议仍成立；火箭 Phase 1 给空响应）
- `Network/` / 大部分 `Window/`（Window 仅新增扩展动画入口）
- `Terminal/GhosttyAdapter.swift`

### 4.4 新增火箭侧文件清单

```
Entity/Rocket/
├── RocketEntity.swift              ~300 行
├── RocketConstants.swift           ~100 行
├── States/
│   ├── RocketOnPadState.swift
│   ├── RocketSystemsCheckState.swift
│   ├── RocketCruisingState.swift
│   ├── RocketAbortStandbyState.swift
│   ├── RocketPropulsiveLandingState.swift
│   └── RocketLiftoffState.swift
└── RocketComponents/
    ├── ExhaustComponent.swift       # 喷焰粒子
    ├── WarningLightComponent.swift  # 频闪灯
    └── PadComponent.swift           # 发射架子节点
```

精灵资源：`Sources/ClaudeCodeBuddy/Assets/Sprites/Rocket/rocket_*.png`，与猫的 `cat_*.png` 物理隔离。

### 4.5 共享基础设施

- `SessionColor` / `SessionInfo`：通用，不动。
- `EventBus` / `BuddyEvent`：扩展新增 `sceneExpansionRequested` / `entityModeChanged`。
- **不共享组件**：`hoverScale` 这类 3-5 行的视觉反馈，两形态各自在 `applyHoverScale` / `removeHoverScale` 里直接实现，不抽共享 helper —— 坚持 C 完全解耦的精神，避免共享目录引入隐性耦合。

### 4.6 兼容性

- **设置迁移**：v0.7.0 首次启动若无 `settings.json` → 默认 `cat`；老用户升级无感。
- **CLI 向后兼容**：现有所有 `buddy` 命令（`ping/status/session/emit/label/test`）完全不变，只增不改。
- **hook 协议不动**：`buddy-hook.sh` 与 socket JSON 格式零修改。
- **`BUDDY_ENTITY` env var**：启动时若设置，覆盖 `settings.json`，便于测试自动化。

### 4.7 测试策略

**单元测试**
- `EntityModeStore`：持久化读写、默认值 fallback、损坏文件恢复。
- `EntityFactory`：按 mode 产出正确类型。
- `RocketEntity.handle(event:)`：每个 `SessionEvent` 迁移到预期状态。
- `RocketPropulsiveLandingState.didEnter`：验证 EventBus 发出 `sceneExpansionRequested`。

**集成测试（XCTest + SpriteKit）**
- 热切换：创建 3 只猫 → 切火箭 → 验证场景节点数正确、session 数据未丢。
- 状态保持：切换时 permissionRequest session → 切换后进入 AbortStandby。
- 窗口扩展：触发 Liftoff → 断言 NSWindow frame 变化。

**验收测试（shell）**
- `tests/acceptance/test-rocket-morph.sh`：CLI 热切换 + buddy test 遍历火箭全状态。
- 更新 `buddy test --delay 2` 按当前 mode 跑对应状态集。

**手动 E2E**：`/buddy-e2e-test` 两种 mode 各跑一次全流程。

---

## 5. 实施阶段

每一步可独立验证、独立 merge。目标 release：`v0.7.0`。

### Step 1 · 抽象层骨架（纯重构，不改行为）

- 新建 `SessionEntity` 协议（瘦身版）
- 新建 `SessionEvent` 枚举
- `CatSprite` → `CatEntity` 改名 + 实现 `handle(event:)`
- `Components/` 下沉到 `Cat/CatComponents/`
- `SessionManager` 改走 `SessionEntity` 协议

**验证**：所有现有测试通过 + 手动跑 `buddy test`。
**Merge 点**：行为与 v0.6.1 完全一致。

### Step 2 · EntityMode 基础设施（只有 `.cat`）

- `EntityMode` / `EntityModeStore` / 持久化
- `EntityFactory`（暂只产 `CatEntity`）
- `BUDDY_ENTITY` env var 支持
- 单元测试覆盖

**Merge 点**：设置已就位但无人使用，行为不变。

### Step 3 · 火箭 Entity 最小可用版（占位精灵）

- `Entity/Rocket/` 目录骨架
- 6 个 `RocketState` 子类
- `RocketEntity` + `handle(event:)` 翻译逻辑
- 临时精灵：纯色矩形 + SF Symbol `paperplane.fill` 占位
- `EntityFactory` 支持 `.rocket`

**验证**：`BUDDY_ENTITY=rocket` 启动，手动发事件查看状态切换。
**Merge 点**：火箭能跑但丑。

### Step 4 · 热切换管道

- `EntityModeStore.publisher` → `SessionManager` 订阅
- 下场 / 入场过渡动画（先简单版，不含中间过场粒子）
- 状态快照 + 回放机制
- `buddy morph` CLI 命令

**验证**：边跑 `buddy test` 边 `buddy morph`，不崩、状态正确迁移。

### Step 5 · 窗口纵向扩展

- `EventBus` 新增 `sceneExpansionRequested`
- `BuddyWindow` 订阅 + 动画 frame 变化
- `RocketPropulsiveLandingState` / `RocketLiftoffState` 调用
- `DockTracker` 扩展期间暂停贴边修正

**验证**：火箭真正从扩展区垂直下降 / 升空。

### Step 6 · 火箭精灵资源（完全重画）

- 设计 6 状态关键帧（~25-30 张 PNG）
- `Scripts/generate-rocket-sprites-v2.swift` 重写生成器（或手绘 pixel art 直接入库）
- 替换 Step 3 的占位精灵

**Time-box**：3 天。超期先发 `v0.7.0-beta`（精灵稍糙）。

### Step 7 · Menubar 集成

- `SessionPopoverController` 加 Morph 分段控件
- StatusBar 图标随 mode 切换

**验证**：menubar 切换与 CLI 等价。

### Step 8 · 收尾

- `tests/acceptance/test-rocket-morph.sh`
- `buddy test` 支持按 mode 跑
- README 新增"形态切换"一节
- `.autopilot/decisions.md` 记录架构决策
- bump `v0.7.0` + cask 同步

**Merge 点**：Release。

---

## 6. 风险与对策

| 风险 | 概率 | 影响 | 对策 |
|---|---|---|---|
| 热切换时 SpriteKit 节点泄漏 | 中 | 内存爬坡 | Step 4 加 `DeallocationTests`，每次切换后断言节点引用计数归零 |
| 窗口扩展与 DockTracker 打架（抖动） | 中 | 视觉跳变 | Step 5 中 `DockTracker` 增加"暂停期"API，扩展期间不修正 |
| 热切换中收到新 hook 事件 | 高 | 事件丢失 | SessionManager 过渡窗口内队列化入站事件，完成后按序重放 |
| `EntityProtocol → SessionEntity` 改名导致 shell / 文档 break | 中 | CI 红 | Step 1 合并前 grep 全量扫描，文档 / 注释同步 |
| 占位精灵太丑被用户看到 | 低 | 口碑 | Step 3 至 Step 6 之间不 release，仅内部迭代 |
| 火箭精灵重画工作量超预期 | 中 | 发布延期 | Step 6 time-box 3 天，超期发 beta |
| Ghostty tab 标题文案对火箭语义违和 | 低 | 细节 | 保持文案中性，不带形态词 |

---

## 7. 验收标准

### 功能层（demo-able）

- [ ] `buddy morph rocket` 后 1 秒内所有猫变火箭，session 身份 / 颜色 / 状态全保留
- [ ] Menubar 分段控件与 CLI 等价
- [ ] Claude Code 正常使用中切换，不丢任何事件
- [ ] 火箭 `taskComplete` 触发窗口扩展 + 垂直着陆可见
- [ ] 火箭 `sessionEnd` 触发 Liftoff，拖尾冲出视野
- [ ] 火箭 `permissionRequest` 红色频闪 + banner 可见
- [ ] Fresh install 默认 `cat`；老用户升级无感

### 工程层

- [ ] `swift test` 全绿；行覆盖率不下降
- [ ] SwiftLint 零警告
- [ ] 10 次热切换前后 app 内存波动 ≤ 5MB
- [ ] `tests/acceptance/run-all.sh` 在两种 mode 下均通过

### 架构层（代码评审）

- [ ] `SessionEntity` 协议行数 ≤ 30；不含任何形态专属词（`cat` / `rocket` / `paw` / `fuel`）
- [ ] `SessionManager` 中不出现 `CatEntity` / `RocketEntity` 具体类名（必要 fallback 强转除外）
- [ ] `RocketEntity` 不引入任何 `Cat*` 头文件即可编译

---

## Out of Scope（Phase 2+）

- 火箭专属交互：投喂 / 载荷 / RUD / 群体编队
- 运行时单 session 变形
- 火箭响应环境系统
- 火箭精灵的手绘美术打磨（独立 PR）
- Menubar 图标 mode-aware 切换可独立 PR（避免 Step 7 过大）
