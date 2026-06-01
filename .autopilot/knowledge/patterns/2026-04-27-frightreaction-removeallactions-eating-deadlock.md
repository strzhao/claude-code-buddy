# playFrightReaction 的 removeAllActions 杀死 eating 动画导致永久卡死

<!-- tags: spritekit, state-machine, eating, fright, race-condition, removeAllActions, isTransitioningOut -->
**Scenario**: `playFrightReaction()` 第 62 行调用 `entity.node.removeAllActions()` 无差别清除所有 action，包括 eating 动画的 `done` 回调（唯一能触发 `switchState(.idle)` 的路径）。更严重的是，如果 `switchState` 的 `dispatch` SKAction 也被杀死，`isTransitioningOut` 永远为 true，阻止所有后续状态转换。4 只猫同时卡死。
**Lesson**: `removeAllActions()` 是破坏性操作，必须在调用前保护关键状态。修复：fright 前检查 eating 状态并释放食物资源 + `isTransitioningOut` 添加时间戳超时安全阀（3x handoffDuration）。通用规则：任何 `removeAllActions()` 调用前，检查是否有依赖 SKAction 完成的逻辑回调，如有则提前执行或保护。
**Evidence**: 用户报告 4 只猫同时卡死在 eating 状态。`buddy inspect` 显示 cat.state="eating" 但 session.state="thinking"，发事件无法唤醒。根因分析确认是 fright 连锁反应打断了 eating 动画和 state transition dispatch。
