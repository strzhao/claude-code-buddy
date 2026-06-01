# smoothTurn 必须检查 display link 可用性

<!-- tags: spritekit, animation, skaction, testing, display-link -->
**Scenario**: `smoothTurn` 使用 `SKAction.customAction(withDuration:actionBlock:)` 渐进改变 xScale 实现方向翻转，但测试环境无 display link，SKAction 从不执行，导致 xScale 永远不变、测试失败。
**Lesson**: SKAction 的执行依赖 `SKView.displayLink` 驱动 `update(_:for:)` 回调。测试环境（无 scene/view）中 `node.run(action)` 会入队但不执行。任何基于 SKAction 的视觉增强必须检查 `containerNode.scene?.view != nil`，不可用时回退到即时赋值。同理，`SKAction.waitForDuration` 在无 display link 时也永远不完成。
**Evidence**: FacingDirectionTests 5 个测试失败——smoothTurn 的 customAction 从不触发 actionBlock，xScale 保持初始值。添加 `let hasDisplayLink = containerNode.scene?.view != nil` 检查后回退到 instant xScale。
