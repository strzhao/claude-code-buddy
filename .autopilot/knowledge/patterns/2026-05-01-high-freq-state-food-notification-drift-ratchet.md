# 高频状态转换 + 食物通知触发 = 系统性漂移棘轮

<!-- tags: spritekit, food, state-machine, ratchet, drift, notification, tooluse, idle, cooldown -->
**Scenario**: Claude Code 会话每分钟触发多次 `tool_start`/`tool_end`，每次状态转换都调用 `notifyCatAboutLandedFood`。食物存活 60s，猫以 100 px/s 走向 300px 内的食物。进食后回到 idle，下一次 toolUse 进入时 `originX` 锚定到当前位置，随机行走从食物位置开始 → 形成"食物→进食→idle→toolUse→再次食物通知→..."棘轮循环，导致猫咪系统性向右侧（食物多落在右侧）漂移。
**Lesson**: 高频外部事件触发状态转换时，禁止在每次转换都执行吸引力检查（食物/兴趣点）。修复模式（三层防御）：(1) 仅在最低频状态（idle）触发，排除 thinking/toolUse；(2) 冷却期（5s）防止同状态快速重入；(3) 距离上限 + 仅通知最近目标，防止广播拉取所有实体聚集。通用检查：grep 所有状态转换回调中的"兴趣点/目标/通知"类调用，确认有频次限制。
**Evidence**: 单猫 30s 内向右漂移 865px（~29 px/s），修复后猫能从右边缘向左逃离（t=50s x=1723），不再永久卡住。QA 场景验证通过。
