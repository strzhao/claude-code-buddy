### 目标
让猫咪状态更持久、更易识别，用户随时回到屏幕都能了解 Claude Code 的真实状态。

### Feature 1: 持久化 Permission 感叹号徽章
在 `LabelComponent` 中新增独立的「持久徽章」节点（`persistentBadgeNode`），与现有的 `alertOverlayNode`（动画徽章）分开管理。当 permission request 状态退出时，动画徽章消失，但持久徽章保留。持久徽章：小号红色圆(radius 7) + "!" + 慢呼吸脉冲(1.5s 周期)，位于猫咪右上角固定位置。仅在猫被移除或重新进入 permissionRequest 时清除。

### Feature 2: TaskComplete 状态常驻 Tab Name
猫走到床上开始睡觉后，显示 tabName 标签。在 `startSleepLoop()` 中调用 `showTabName()`。

### 修改文件
| 文件 | 操作 | 说明 |
|------|------|------|
| CatConstants.swift | 修改 | 新增 PersistentBadge 常量枚举 |
| LabelComponent.swift | 修改 | 新增 persistentBadgeNode、addPersistentBadge、removePersistentBadge、showTabName |
| CatSprite.swift | 修改 | 转发属性/方法 + applyFacingDirection counter-scale |
| CatPermissionRequestState.swift | 修改 | didEnter 清旧徽章 + willExit 创建持久徽章 |
| CatTaskCompleteState.swift | 修改 | startSleepLoop 末尾调用 showTabName |
| PersistentBadgeTests.swift | 新增 | 8 个单元测试 |
