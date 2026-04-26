**根因**：`walkToFood()` 调用 `face(towardX:)` 启动 smoothTurn 后，`node.removeAllActions()` 杀死 smoothTurn 但未 snap xScale。猫咪背对食物时 xScale 冻结在旧值，导致反着跑。`walkBackIntoBounds()` 有同类隐患（smoothTurn 未取消，0.2s 延迟）。

**方案**：在两处路径中添加 smoothTurn 取消 + `applyFacingDirection()` snap，与已修复的 `doRandomWalkStep()` 模式保持一致。
