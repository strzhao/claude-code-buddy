# isTransitioningOut 恢复策略采用时间戳超时而非 action 存在性检查

<!-- tags: state-machine, transition, timeout, spritekit -->

**决策**: `switchState` 的 `isTransitioningOut` 安全阀使用 `CACurrentMediaTime()` 记录过渡开始时间，超时阈值 3x handoffDuration（0.45s）后强制重置。

**否决**: 检查 `node.action(forKey: pendingDispatchKey) == nil` 来判断 dispatch 是否被杀死。

**理由**:
- action 存在性检查依赖 SpriteKit 内部调度时序，正常过渡期间某帧可能临时检测不到 action（false positive）
- 时间戳方案不依赖框架内部行为，逻辑清晰且易于测试
- 3x 余量（0.45s vs 0.15s 标准过渡）确保正常过渡不会被误判

**影响文件**: CatSprite.swift

**约束**: 任何修改 `handoffDuration` 的变更都需同步评估超时阈值。
