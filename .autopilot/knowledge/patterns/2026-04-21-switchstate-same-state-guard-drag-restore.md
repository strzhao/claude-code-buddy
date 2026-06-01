# switchState same-state guard 阻止拖拽后状态恢复

<!-- tags: spritekit, state-machine, drag, same-state, restore -->
**Scenario**: 拖拽猫咪时不改变 GKStateMachine 的 currentState，松手后 restoreState 调用 switchState(to: preState)，但 preState == currentState 触发 same-state guard 直接 return，导致动画不恢复、taskComplete 猫不回猫屋。
**Lesson**: GKStateMachine 的 same-state guard 会阻止任何"恢复到当前状态"的尝试。当某个机制（拖拽、暂停等）需要在不改变 GKState 的情况下中断并恢复时，恢复逻辑必须绕过 same-state guard：先 switchState(.idle) 强制触发 willExit/didEnter 生命周期，再 switchState(targetState)。对于简单状态（idle/thinking/toolUse）也可用 ResumableState.resume()，但 taskComplete 等需要完整 didEnter 流程（请求床位、走路）的状态必须走强制重入。
**Evidence**: 拖拽 taskComplete 猫松手后不回猫屋。修复：restoreState 检测 targetState == currentState 时先 switchState(.idle) 再切回。
