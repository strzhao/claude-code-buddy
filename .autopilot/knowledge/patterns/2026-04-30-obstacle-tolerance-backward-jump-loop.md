# 障碍物路径检测容差向后延伸导致屏幕边缘跳跃死循环

<!-- tags: spritekit, jump, obstacle, tolerance, boundary, movement, loop -->
**Scenario**: `buildJumpActions` 的障碍物路径过滤器使用 `fromX ± tolerance`（24px）作为起始边界。当 `adjustTargetAwayFromOtherCats` 已将猫咪引导远离障碍物后，容差仍捕获身后的障碍物，触发不必要的跳跃。跳跃的 approach walk 推猫咪出边界 → 边界恢复拉回 → resume 重启 random walk → 同样的跳跃再次发生 → 无限循环。猫咪卡在右边不断原地跳跃。
**Lesson**: 路径检测容差只应向行进方向延伸，不应向后方延伸。`adjustTargetAwayFromOtherCats` 已确保目标不穿越障碍物，后方容差是冗余且有害的。修复模式：`fromX - tolerance` → `fromX`（goingRight），`fromX + tolerance` → `fromX`（goingLeft），使用 `>=`/`<=` 保留起点位置的障碍物。
**Evidence**: 用户报告 base-account 猫咪卡在右边原地跳跃。根因是容差向后 24px 检测到身后障碍物，触发跳跃 → 出界 → 恢复 → 重启的循环。
