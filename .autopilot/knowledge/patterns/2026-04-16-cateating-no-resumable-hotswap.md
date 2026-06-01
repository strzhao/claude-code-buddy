# CatEatingState 未实现 ResumableState，热替换需特殊处理

<!-- tags: spritekit, state-machine, hotswap, eating, resumable -->
**Scenario**: 设计皮肤热替换机制时，计划对所有活跃猫调用 `(stateMachine.currentState as? ResumableState)?.resume()` 重启动画
**Lesson**: 6 个 GKState 中，CatEatingState 是唯一不实现 ResumableState 的状态。热替换（或任何需要 `resume()` 的机制）必须对 eating 状态做特殊处理：跳过 resume，让 eating 动画自然完成，完成后的 `switchState(to: .idle)` 会自动使用新纹理。在 `reloadSkin()` 中需要先 `node.removeAllActions()` 清理旧动画帧引用，再 `loadTextures()`，最后才 `resume()`——顺序不能错。
**Evidence**: Plan Review 发现 CatEatingState.swift:4 仅 `final class CatEatingState: GKState`，无 ResumableState 协议。Grep 确认 5 个状态实现 ResumableState，eating 缺席。
