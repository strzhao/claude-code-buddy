# SKAction.wait 在子节点上可能永远不触发（release build 特有）

<!-- tags: spritekit, skaction, wait, async, gcd, dispatch, release-build, state-machine, deadlock -->
**Scenario**: `switchState` 用 `SKAction.sequence([wait(0.15s), run { stateMachine.enter() }])` 在 node 上调度状态转换。debug build 正常，但 release build（.app bundle）中 SKAction.wait 永远不触发，状态机卡死，猫咪永远无法进入 toolUse/thinking 等状态。
**Lesson**: SKAction.wait(forDuration:) 在特定条件下（release build、子节点上、与其他 action 组合）可能静默失败。关键逻辑（状态转换、回调链、调度）不能依赖 SKAction 时序。修复：`DispatchQueue.main.asyncAfter(deadline: .now() + delay) { ... }`。这是比 `[2026-04-23] smoothTurn` 和 `[2026-04-26] switchState handoff` 更严重的问题——那两个只影响测试环境（无 display link），但 SKAction.wait 即使在有 display link 的 UI 环境中也可能不触发。通用规则：所有 SKAction.wait → GCD asyncAfter，SKAction.sequence(wait+run) → GCD asyncAfter 嵌套。
**Evidence**: 用户报告猫咪出现后自动跑到最右边原地跳跃。排查发现所有 debug 猫 emit tool_start 后 state 始终为 idle——SKAction.wait 永远不触发，CatToolUseState.didEnter 从不执行。替换为 GCD 后状态转换立即正常。
