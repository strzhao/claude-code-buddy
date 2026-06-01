# 拖拽采用 DragComponent 组件而非新增 GKState

<!-- tags: architecture, drag, component, state-machine -->

**决策**: 新增 DragComponent（类比 InteractionComponent），通过 isDragging/isLanding/isOccupied 三态管理拖拽生命周期，不在 GKStateMachine 中新增 CatDraggedState。

**否决**: 新增第 7 个 GKState (CatDraggedState)，需修改所有 6 个现有状态的 isValidNextState。

**理由**:
- 拖拽是物理交互（暂停→恢复），不是业务状态——与 InteractionComponent 的 fright reaction 模式一致
- 不触动现有 6 个 GKState 的转换矩阵，降低回归风险
- isOccupied 统一暴露 isDragging||isLanding，让 BuddyScene.update/switchState/playFrightReaction 等多处消费方用单一检查覆盖整个拖拽+落体周期

**影响文件**: DragComponent.swift(新建), CatSprite.swift, MouseTracker.swift, BuddyScene.swift, AppDelegate.swift, InteractionComponent.swift, CatConstants.swift

**约束**: 新增物理交互行为（如抛掷、弹射）应优先考虑组件模式而非新 GKState。isDragOccupied 的所有消费点在扩展时需同步检查。
