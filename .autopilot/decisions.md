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
