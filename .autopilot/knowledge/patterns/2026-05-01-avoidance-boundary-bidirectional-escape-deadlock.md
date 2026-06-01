# 避让/排斥逻辑在边界处需双向逃离路径，否则形成死锁

<!-- tags: spritekit, avoidance, boundary, deadlock, movement, adjusttarget, escape -->
**Scenario**: `adjustTargetAwayFromOtherCats` 检测到路径穿越障碍物时，将目标重定向到障碍物远离自己的一侧。当猫在右边缘（x=1850）试图向左走，路径被 x=1800 的猫挡住 → 重定向到 x=1800+52=1852 → 被边界 clamp 回 ~1852 → 无法向左逃离右边缘集群。同理，`dist < minDist` 的近距离排斥也可能将目标推回障碍物方向。
**Lesson**: 任何基于"推离障碍物"的避让/排斥逻辑在边界附近必须检查结果是否越界。越界时不能仅 clamp（会形成死锁），应反向放置目标（障碍物另一侧）。修复模式：`if redirected > boundary { redirected = obstacle - margin }`，为边缘实体保留双向逃离路径。通用规则：grep 所有 `max(boundary, min(boundary, ...))` 的 clamp 模式，检查是否可能形成 clamp→死锁循环。
**Evidence**: 用户报告"所有猫咪创建后都跑到最右边且无法逃离"，单只猫也有问题。根因 2 确认 adjustTarget 在边界处形成单向死锁。修复后多猫场景中猫位置范围 x=950-1872，出现双向移动。
