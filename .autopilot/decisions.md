# 架构决策

## 2026-04-13: 猫咪朝向系统集中化

**决策**: 将散落在 MovementComponent/InteractionComponent 中的 5 处方向设置逻辑统一为 `CatSprite.face(towardX:)` / `face(right:)` API，并用 `didSet` 自动同步视觉。

**理由**: 原来每个调用点独立维护 if/else 阈值判断 + `facingRight` 赋值 + `applyFacingDirection()` 调用，导致 3 个 bug（静止转向、tabName 镜像、逻辑不一致）。

**影响文件**: CatSprite.swift, MovementComponent.swift, InteractionComponent.swift

**约束**: 新增移动行为时，必须通过 `face(towardX:)` 或 `face(right:)` 设置方向，禁止直接赋值 `facingRight`。

## 2026-04-13: 活动边界采用逻辑约束而非窗口裁剪

**决策**: Strategy B — 窗口保持全屏宽度，通过 `activityBounds: ClosedRange<CGFloat>` 逻辑约束猫咪活动范围

**否决**: Strategy A — 将 BuddyWindow 缩窄到仅覆盖 Dock 图标区域

**理由**: 
- `exitScene()` 动画需要猫咪走到 `sceneWidth + 48` 或 `-48`，窗口裁剪会导致退出动画被截断
- TooltipNode 和 permissionRequest 标签可能延伸到图标区域之外
- BuddyWindow 作为渲染面应保持全屏，活动边界是逻辑层面的约束

**影响文件**: DockTracker, DockIconBoundsProvider, BuddyScene, CatSprite (Entity/Cat/), MovementComponent, InteractionComponent, FoodManager, AppDelegate

## 2026-04-14: CLI 工具不依赖 BuddyCore 而使用 Foundation-only

**决策**: 新增的 `buddy` CLI 工具使用 Foundation-only 实现（不依赖 BuddyCore library target），独立定义 `BuddyMessage: Encodable` 结构体匹配 HookMessage 的 wire format。

**否决**: 让 CLI target 依赖 BuddyCore 以复用 HookMessage/HookEvent 类型。

**理由**:
- BuddyCore 内部导入了 SpriteKit/GameplayKit，会让 CLI 二进制膨胀 5-10x（app 二进制 732KB vs CLI 仅需 ~100KB）
- CLI 只需要编码 JSON 发送到 socket，不需要解码或 GUI 功能
- 消息格式非常稳定（9 个事件类型），维护一个 ~30 行的 Encodable 结构体成本低

**影响文件**: Sources/BuddyCLI/main.swift, Package.swift

**约束**: 如果 HookMessage 新增字段，CLI 的 BuddyMessage 也需同步更新。

## 2026-04-16: 在现有 Unix domain socket 上扩展双向 query/response

**决策**: 在同一个 `/tmp/claude-buddy.sock` 上通过 `"action"` 字段区分查询消息和 Hook 消息，复用现有连接实现双向通信。

**否决**:
- Strategy A: 创建第二个 socket（如 `/tmp/claude-buddy-query.sock`）专门处理查询
- Strategy B: 通过共享文件（如 colors.json 扩展）暴露状态（数据过时，无实时性）

**理由**:
- SocketServer 已经跟踪 clientFD 和 per-client buffer，天然支持回写响应
- `"action"` 字段通过 `JSONSerialization.jsonObject` 检测，与 HookMessage 的 `JSONDecoder` 路径完全分离，不会冲突
- CLI 无需管理两个连接点，降低复杂度
- 未来新增查询类型只需在 QueryHandler 添加 switch case

**影响文件**: SocketServer.swift, QueryHandler.swift, SessionManager.swift, BuddyCLI/main.swift

**约束**: Hook 消息永远不应包含 `"action"` 字段。新增协议消息类型时必须保持这条分离规则。

## 2026-04-17: Phase 1 Rocket Morph — SessionEntity 抽象层

**决策**: 引入 `SessionEntity` 薄协议（≤30 行）作为 SessionManager / BuddyScene 与具体 Entity 的边界；`CatEntity`、`RocketEntity` 并列实现；全局只一种形态，通过 `EntityModeStore`（Combine publisher）切换。

**理由**:
- 协议零形态专属词（cat / rocket / paw / fuel），避免接口腐化
- `EntityInputEvent` 通用事件枚举；每个 Entity 内部翻译到自己的 GKStateMachine
- 热切换通过 `SceneControlling.replaceAllEntities` 统一编排：exit 全体 → 按新 mode 重建 → 回放 lastEvents
- `cats: [String: CatEntity]` 保留作为类型化视图（现有 cat-specific 代码不动）；新增 `entities: [String: SessionEntity]` 作为权威镜像

**影响文件**: SessionEntity.swift, EntityInputEvent.swift, EntityMode.swift, EntityModeStore.swift, EntityFactory.swift, RocketEntity.swift, RocketState 6 个子类, BuddyScene.swift, SessionManager.swift, SceneControlling.swift, AppDelegate.swift

**约束**:
- `SessionEntity` 协议必须保持 ≤30 行，禁止引入形态专属方法
- 新增事件先加到 `EntityInputEvent`，再让各 Entity 翻译
- Rocket 不引入 `Cat*` 头文件即可编译
- 全局只一种形态；不做"混合场景"
