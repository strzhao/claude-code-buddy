# SpriteKit 物理碰撞掩码与 SKAction.moveTo 不兼容

<!-- tags: spritekit, physics, collision, skaction, movement -->
**Scenario**: 多只猫设置了 `collisionBitMask = .cat`，但实际移动用 `SKAction.moveTo(x:)` 直接设位置，绕过物理引擎
**Lesson**: `SKAction.moveTo/moveBy` 直接修改节点 position，不经过物理引擎的碰撞检测。如果需要实体间防重叠，必须在 update 循环中用代码实现（如弹簧阻尼软分离），而非依赖 SpriteKit 物理碰撞。物理碰撞只在纯物理驱动（施加力/速度）时有效。
**Evidence**: CatSprite.collisionBitMask 设了 .cat 但猫咪仍然穿越重叠。改用 applySoftSeparation() 帧更新推力后解决。
