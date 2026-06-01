# 活动边界采用逻辑约束而非窗口裁剪

<!-- tags: window, bounds, dock -->

**决策**: Strategy B — 窗口保持全屏宽度，通过 `activityBounds: ClosedRange<CGFloat>` 逻辑约束猫咪活动范围

**否决**: Strategy A — 将 BuddyWindow 缩窄到仅覆盖 Dock 图标区域

**理由**: 
- `exitScene()` 动画需要猫咪走到 `sceneWidth + 48` 或 `-48`，窗口裁剪会导致退出动画被截断
- TooltipNode 和 permissionRequest 标签可能延伸到图标区域之外
- BuddyWindow 作为渲染面应保持全屏，活动边界是逻辑层面的约束

**影响文件**: DockTracker, DockIconBoundsProvider, BuddyScene, CatSprite (Entity/Cat/), MovementComponent, InteractionComponent, FoodManager, AppDelegate
