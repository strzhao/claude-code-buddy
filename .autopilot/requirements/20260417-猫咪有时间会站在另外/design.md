## 设计文档

**目标**：消除多猫重叠/卡住现象，让猫咪保持自然间距。

**技术方案**：
1. **软分离算法**（BuddyScene.update）：每帧检测猫对 X 距离 < 52px，用弹簧阻尼推力分离（nudgeMag = min(overlap * 0.1, 0.5)）
2. **生成位置避让**（addCat）：最多尝试 10 次随机位置，选最远点
3. **随机游走目标避让**（doRandomWalkStep）：目标距猫 < 52px 时外推
4. **惊吓方向智能选择**（playFrightReaction）：检查逃跑方向是否有猫
5. **清理无效物理掩码**：移除 collisionBitMask 中的 .cat

**文件影响**：CatConstants.swift, BuddyScene.swift, MovementComponent.swift, InteractionComponent.swift, CatSprite.swift
