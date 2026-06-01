# JumpComponent snapGround no-op 导致猫咪 y 坐标累积漂移飞出屏幕

<!-- tags: spritekit, physics, jump, y-coordinate, boundary-recovery, groundY -->
**Scenario**: `JumpComponent.buildLandingActions()` 中的 `snapGround` 写成 `self?.containerNode.position.y = self?.containerNode.position.y ?? 0`（把自己赋给自己），跳跃落地后 y 坐标未正确重置。若猫穿过地面碰撞体（thin edge tunneling），场景重力持续拉拽，无 y 轴恢复机制，猫自由落体至 y=-9M。
**Lesson**: SKAction.run 中给自身属性赋值时，必须确认右侧表达式确实会产生不同的值。边界恢复逻辑不能只检查 x 轴——SpriteKit 物理引擎的 y 轴异常同样需要检测和修正。修复模式：`isOutOfBounds()` 增加 y 轴检查 + `update()` 中 y 轴越界时即时 snap 到 groundY。
**Evidence**: 用户报告 6 只猫中只有 4 只可见。`buddy inspect` 显示 teal/seat 猫 y=-9,191,131。
