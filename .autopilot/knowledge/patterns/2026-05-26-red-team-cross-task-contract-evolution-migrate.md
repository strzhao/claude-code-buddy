# 跨任务红队测试契约演进：上游 task 锁的过渡占位需迁移而非保留 XCTSkip

<!-- tags: red-team, acceptance-test, contract-evolution, cross-task, tdd, autopilot, sc-08, scope-control, brief-mode -->
**Scenario**: 项目模式下 task 001 brief 把 `LauncherManager.submit("hi") → "echo: hi"` 作为契约，红队据此写了 4 个 echo 字符串断言。task 002 brief 明确"重写 submit"接入 ProviderFactory.create + provider.send。task 002 实现后，task 001 锁的 echo 测试与 task 002 实现冲突——红队铁律是"绝对不允许修改红队测试"，但这是**跨任务的契约演进**，不是"蓝队削弱当前任务测试"。
**Lesson**: 区分两种场景：① **同任务**红队失败 → auto-fix 改实现（铁律不破） ② **上游任务**红队断言被下游 brief 明确演进 → **迁移**测试到新契约（不是删除）。迁移做法：保留语义部分（如 SC-08 "无状态" 仍成立）改断言形态（错误消息一致性替代 echo 字符匹配），文件顶加 `MARK: - 契约演进说明` 注释**明确记录 task X→Y 演进原因**，未来 reader 能追溯。**禁止用 XCTSkip("上游 task 已过时")** — soft skip 会让 CI 红绿信号失效。
**Evidence**: task 002 迁移 task 001 SC-08 测试（LauncherManagerAcceptanceTests + LauncherHotkeyAcceptanceTests 中 4 个 echo 测试 → 1 个无状态错误消息一致性测试 + 完整 MARK 注释）；qa-reviewer Section C 评 "SC-08 迁移注释质量高，future reader 友好"。
