# 边界恢复中断 action 序列后需显式恢复被丢失的副作用

<!-- tags: spritekit, skaction, boundary-recovery, sequenc, interrupt, physics, isdynamic -->
**Scenario**: `walkBackIntoBounds` 通过 `removeAction(forKey: "randomWalk")` 取消跳跃序列，但跳跃序列末尾的 `enablePhysics` SKAction（恢复 `isDynamic = true`）也随之丢失，导致 `isDynamic` 永久 false。
**Lesson**: 任何通过 cancel action key 中断 SKAction 序列的操作，需检查序列中是否有"恢复/清理"类型的尾部 action（如 `isDynamic` 恢复、动画重置、标志位复位），这些副作用在 cancel 时不会自动执行。修复模式：在 cancel 处显式补回丢失的副作用。通用检查：grep `removeAction(forKey:")` 的调用点，对比被移除序列的尾部 `SKAction.run` 块，确认关键状态恢复不丢失。
**Evidence**: 死循环根因之二——跳跃被中断后 isDynamic=false，猫咪物理被冻结。QA 验证 walkBackIntoBounds 中补回 `isDynamic = true` 后修复。
