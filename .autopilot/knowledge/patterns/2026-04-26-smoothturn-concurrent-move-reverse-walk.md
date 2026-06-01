# smoothTurn 动画与即时位移并发导致猫咪反向行走

<!-- tags: spritekit, animation, facing, movement, smoothturn, xscale -->
**Scenario**: `doRandomWalkStep()` 调用 `face(towardX:)` 触发 `smoothTurn`（0.2s 渐进 xScale 插值），但 `moveTo` 位移立即开始。0.2s 窗口内猫身体朝旧方向但脚往新方向跑。`walkStartSlowFactor` 放慢前两帧使不一致更明显。
**Lesson**: `smoothTurn` 适合状态转换等不涉及即时位移的场景。走路方向切换时必须 snap（取消 smoothTurn + 即时设置 xScale），因为 `moveTo` 在 containerNode 上立即生效，与 node 上的渐进动画存在不可调和的时序竞争。修复模式：`face(towardX:)` 后检查 `node.action(forKey: "smoothTurn") != nil`，若存在则 `removeAction` + `applyFacingDirection(animated: false)`。
**Evidence**: 用户报告猫咪反着跑。分析发现 smoothTurn(0.2s) 在 node 上插值 xScale，同时 moveTo 在 containerNode 上位移，两者并发。新增 `testRandomWalkFacingMatchesDirection` 验证 xScale 在走路时必须为 ±1.0。
**Recurrence [2026-04-26]**: `walkToFood()` 和 `walkBackIntoBounds()` 遗漏了同样的 snap 模式。`walkToFood` 中 `face()` 启动 smoothTurn 后 `node.removeAllActions()` 杀死它但未 snap xScale，导致间歇性反着跑（仅当猫背对食物时触发）。**Recurrence [2026-05-01]**: `walkToBed()` 同样遗漏 smoothTurn guard + snap，任务完成时猫背对床位则倒着走。修复后所有 walk 路径均已覆盖。**通用规则**：任何调用 `face()` 后需要立即移动的路径，必须检查并取消 smoothTurn + 即时 snap xScale。审查清单：grep `removeAllActions` + 检查前后是否有 `face()` 调用。
