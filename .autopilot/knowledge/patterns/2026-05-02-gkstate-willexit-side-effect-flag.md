# 外部修改 GKState 生命周期检查的标志位，绕过状态机 willExit 副作用决策

<!-- tags: spritekit, gkstate, statemachine, willexit, side-effect, permission, flag -->
**Scenario**: `BuddyScene.updateCatState` 在调用 `switchState` 之前提前设置 `cat.permissionAcknowledged = true`（auto-acknowledge 优化），导致 `CatPermissionRequestState.willExit` 中的 `if !entity.permissionAcknowledged { addPersistentBadge() }` 永远不触发，持久徽章功能被完全消除。
**Lesson**: GKState 的 `willExit`/`didEnter` 是状态转换副作用（徽章、动画复位、资源释放）的唯一权威来源。外部代码不应提前修改状态机内部在生命周期方法中检查的标志位。如果需要在外部干预某些行为，应通过状态机自身暴露的方法（如 `acknowledgePermission` 在 permissionRequest 状态下才设标志）而非绕过状态机。通用规则：grep 所有 GKState 子类中的 `if !entity.xxx` 检查条件，确认没有任何外部代码提前修改对应标志。
**Evidence**: 用户报告 request 后从未见过持久感叹号。根因确认 auto-acknowledge 在 `willExit` 检查前提前置 true。修复：删除 `updateCatState` 中 6 行 auto-acknowledge 块，让 `willExit` 成为唯一决策点。
