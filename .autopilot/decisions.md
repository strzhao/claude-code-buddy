# 架构决策

## 2026-04-27: isTransitioningOut 恢复策略采用时间戳超时而非 action 存在性检查

**决策**: `switchState` 的 `isTransitioningOut` 安全阀使用 `CACurrentMediaTime()` 记录过渡开始时间，超时阈值 3x handoffDuration（0.45s）后强制重置。

**否决**: 检查 `node.action(forKey: pendingDispatchKey) == nil` 来判断 dispatch 是否被杀死。

**理由**:
- action 存在性检查依赖 SpriteKit 内部调度时序，正常过渡期间某帧可能临时检测不到 action（false positive）
- 时间戳方案不依赖框架内部行为，逻辑清晰且易于测试
- 3x 余量（0.45s vs 0.15s 标准过渡）确保正常过渡不会被误判

**影响文件**: CatSprite.swift

**约束**: 任何修改 `handoffDuration` 的变更都需同步评估超时阈值。

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

## 2026-04-19: 皮肤颜色变体采用 manifest variants 数组而非独立皮肤包

**决策**: 在 SkinPackManifest 中新增可选 `variants: [SkinVariant]?` 数组，每个变体有独立的 `sprite_prefix`，共享其他 manifest 字段（animation_names、canvas_size、food 等）。

**否决**: 每种颜色作为独立皮肤包上传（如 pixel-dog-red、pixel-dog-blue）。

**理由**:
- 12 种颜色 × 独立皮肤包 = 皮肤市场极度膨胀，用户体验差
- 变体间只有 spritePrefix 不同，其他配置完全相同，冗余度极高
- manifest 级变体让用户在选择皮肤后自然选择颜色，交互更直观
- 默认"随机"变体增加趣味性（每次启动随机选色）

**影响文件**: SkinPackManifest.swift, SkinPack.swift, SkinPackManager.swift, SkinCardItem.swift, SkinGalleryViewController.swift, web types.ts/validation.ts

**约束**: 变体只能覆盖 spritePrefix、previewImage、bedNames。animation_names 等结构性字段必须全变体共享。

## 2026-04-19: Settings 面板点击事件通过 Panel.sendEvent 而非 NSCollectionView 选择

**决策**: 在 SettingsPanel（NSPanel 子类）的 sendEvent(_:) 中拦截 mouseUp 事件，通过 collectionView.indexPathForItem(at:) 坐标计算找到目标 item，直接调用 gallery 的处理方法。NSCollectionView.isSelectable 设为 false。

**否决**:
- Strategy A: NSCollectionView.isSelectable=true + didSelectItemsAt delegate
- Strategy B: NSClickGestureRecognizer
- Strategy C: 自定义 NSView.mouseUp override

**理由**:
- 本 app 是 LSUIElement menubar agent（无 Dock 图标），NSApp.isActive 始终 false
- NSCollectionView 选择和手势识别器都依赖 key window，在未激活 app 中不可靠
- sendEvent 是 NSWindow 事件分发的最底层入口，不依赖 window/app 激活状态

**影响文件**: SettingsWindowController.swift, SkinGalleryViewController.swift

**约束**: 任何需要在 Settings 面板中处理点击的新控件，都应通过 SettingsPanel.sendEvent → Gallery.handleClickAt 链路，不要依赖 NSCollectionView 的选择机制。

## 2026-04-23: AnimationTransitionManager 采用每猫实例而非单例

**决策**: AnimationTransitionManager 由每只 CatSprite 在 init 中创建并持有（`unowned` 引用 node/containerNode/personality），不做全局单例。

**否决**: 全局单例 AnimationTransitionManager，接受 node 引用参数。

**理由**:
- 单例持有 `unowned` 引用多只猫的 node，生命周期管理复杂（猫移除时需手动清理）
- 每猫实例天然隔离状态，无需管理共享 action key 命名空间
- 实例创建成本极低（仅存储引用 + personality 值），8 只猫 8 个实例无性能问题
- 与 DragComponent、InteractionComponent 等现有组件模式一致（每实体独立实例）

**影响文件**: AnimationTransitionManager.swift(新建), CatSprite.swift

**约束**: AnimationTransitionManager 只通过 `unowned` 引用外部节点，不拥有任何节点。新增强化动画方法时必须保持在 0.15-0.3s 范围内以避免状态切换冲突。

## 2026-04-23: CatPersonality 随机生成不持久化

**决策**: 每只猫在 init 时通过 `CatPersonality.random()` 随机生成性格参数，不持久化到磁盘。每次 app 重启所有猫获得新性格。

**否决**: 将性格参数写入 UserDefaults 或文件持久化，重启后恢复。

**理由**:
- 持久化增加复杂度（需关联 session_id、处理清理），收益仅为"猫的性格跨重启一致"
- 桌面宠物的乐趣之一是不可预测性，每次随机反而增加趣味
- 测试用 `CatPersonality.balanced` 固定值，不受随机影响

**影响文件**: CatPersonality.swift(新建), CatSprite.swift

**约束**: 如果未来需要"记住猫的性格"，添加 `Codable` 一行即可序列化。当前不预留序列化接口。

## 2026-04-21: 拖拽采用 DragComponent 组件而非新增 GKState

**决策**: 新增 DragComponent（类比 InteractionComponent），通过 isDragging/isLanding/isOccupied 三态管理拖拽生命周期，不在 GKStateMachine 中新增 CatDraggedState。

**否决**: 新增第 7 个 GKState (CatDraggedState)，需修改所有 6 个现有状态的 isValidNextState。

**理由**:
- 拖拽是物理交互（暂停→恢复），不是业务状态——与 InteractionComponent 的 fright reaction 模式一致
- 不触动现有 6 个 GKState 的转换矩阵，降低回归风险
- isOccupied 统一暴露 isDragging||isLanding，让 BuddyScene.update/switchState/playFrightReaction 等多处消费方用单一检查覆盖整个拖拽+落体周期

**影响文件**: DragComponent.swift(新建), CatSprite.swift, MouseTracker.swift, BuddyScene.swift, AppDelegate.swift, InteractionComponent.swift, CatConstants.swift

**约束**: 新增物理交互行为（如抛掷、弹射）应优先考虑组件模式而非新 GKState。isDragOccupied 的所有消费点在扩展时需同步检查。

## 2026-04-16: SkinPack 资源解析采用 builtIn/local 分支而非统一 Bundle

**决策**: `SkinPack` 通过 `SkinSource` enum 区分两种资源解析路径：`builtIn(Bundle)` 走 `Bundle.url(forResource:withExtension:subdirectory:)` 且自动补 `"Assets/"` 前缀；`local(URL)` 走 `FileManager` 直接拼接 `baseURL + subdirectory + name.ext`。

**否决**: 让所有皮肤（含下载的）都创建 `Bundle(url:)` 实例。创建 Bundle 需要 `Info.plist` 且初始化可能失败，对用户下载的 .zip 解压目录不友好。

**理由**:
- SPM 内置资源通过 `.copy("Assets")` 放入 bundle，路径带 `Assets/` 前缀；下载皮肤的目录结构是 `Sprites/`、`Food/` 直接在根目录
- `SkinPack.url()` 方法签名与 `Bundle.url()` 一致，消费方调用方式不变，只需把 `ResourceBundle.bundle` 替换为 `skinPack`
- builtIn 路径覆盖了现有所有 `ResourceBundle.bundle.url(...)` 调用点（AnimationComponent、CatTaskCompleteState、BuddyScene、FoodSprite、MenuBarAnimator）

**影响文件**: Sources/ClaudeCodeBuddy/Skin/SkinPack.swift（新建），以及所有纹理加载调用点

**约束**: 新增纹理加载点时，必须通过 `SkinPackManager.shared.activeSkin.url(...)` 而非 `ResourceBundle.bundle.url(...)`。内置皮肤的 subdirectory 不要手动加 `"Assets/"` 前缀——SkinPack.url() 内部处理。
