# switchState 渐进式 Handoff 需要 display link 降级路径

<!-- tags: spritekit, state-machine, transition, testing, display-link -->
**Scenario**: `switchState()` 从即时 `removeAllActions()` 改为 0.15s handoff 窗口（加速旧动画 → dispatch 清理 → 进入新状态），但测试环境无 display link，SKAction 不执行，`isTransitioningOut` 永远为 true。
**Lesson**: 任何依赖 SKAction 时序的行为逻辑，必须检查 `containerNode.scene?.view != nil`（display link 可用性），不可用时回退到即时路径。这与 `smoothTurn` 的降级模式一致（patterns.md [2026-04-23]）。通用规则：SKAction 是视觉增强手段，不是逻辑保证——逻辑路径必须有不依赖 SKAction 的 fallback。
**Evidence**: 测试中 `switchState` 的 dispatch SKAction 从不执行，`isTransitioningOut` 保持 true，后续所有 switchState 调用被队列吞噬。添加 `hasDisplayLink` 检查后走即时路径，427 测试全部通过。
