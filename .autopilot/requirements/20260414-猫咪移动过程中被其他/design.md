# 设计文档：猫咪随机行走跳跃修复

## 根因

随机行走跳跃缺少 `containerNode.physicsBody?.isDynamic = false`，导致 SpriteKit 物理引擎与 SKAction.moveTo / customAction 冲突。Exit scene 跳跃（MovementComponent.swift:259）已正确禁用 physics，但随机行走跳跃遗漏了。

## 方案

在 `MovementComponent.doRandomWalkStep()` 的跳跃分支中，用 `SKAction.run` 包装 `isDynamic = false / true`，复用 exit scene 已验证的模式。

## 影响文件

- `MovementComponent.swift` — 在跳跃序列前后添加 physics toggle
- `JumpComponent.swift` — 文档注释补充 caller 职责说明

## 风险

低 — `switchState` 安全网（CatSprite.swift:264）在状态切换时恢复 `isDynamic = true`

## 边缘案例

1. 状态变化中断跳跃 → switchState 安全网恢复 physics
2. 多障碍物连续跳跃 → 单个 disable/enable 包裹整个序列
3. 被跳过猫咪的 fright reaction → 独立管理 physics
4. 无障碍物正常行走 → 不触碰 physics
