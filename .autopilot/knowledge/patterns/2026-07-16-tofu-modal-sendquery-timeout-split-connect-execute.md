# TOFU NSAlert modal 与 CLI sendQuery timeout 冲突 → 分 connect/execute 双超时

**日期**: 2026-07-16
**tags**: tofu, modal-runloop, sendquery, timeout, connect-vs-execute, cli, buddy-cli, socket, ipc, false-green, trust-reject, plan-reviewer, launcher

## Lesson（教训）
CLI 经 socket IPC 调 app 执行操作时，若 app 在 IPC handler 内弹 **modal**（TOFU `NSAlert.runModal` 阻塞主线程，见 `patterns/2026-06-27-modal-runloop-task-not-pump`），CLI 端 `sendQuery` 的**单一 timeout** 会在用户看到弹框前就超时退出（默认 2s）→ 用户根本来不及处理。更险的是：**timeout 退出与 trust 拒绝在 exit code 上不可区分**（都非 0）→ 验收谓词「未信任非零退出」对 timeout 也成立 → false-green（同类 `patterns/2026-06-23-autopilot-red-team-false-report`）。

## Choice（解法）
`sendQuery(_:connectTimeout:executeTimeout:)` 双参数：
- **connect 阶段**（socket 连接 + 首字节）短超时（2-5s）：app 未运行时快速失败（<10s，满足降级契约）。
- **execute 阶段**（action 已派发，完整响应，含 modal 等待）长超时（300s）：容 TOFU NSAlert 用户处理 + 慢插件。
- 向后兼容：现有调用仅传 `timeout:` → connectTimeout，executeTimeout 默认等值（语义不变）。
- 验收谓词加语义区分：`assert contains "trust"|"not trusted" AND NOT contains "timeout"|"超时"`。

## Why
modal runloop 不 pump，CLI 阻塞在 read 等响应；单 timeout 无法区分「app 没起来」（该快失败）vs「app 在等用户决定」（该慢等）。分阶段让两种语义各得其所。

## How to apply
任何 CLI→app IPC 且 app 侧 handler 可能触发 modal/长操作（TOFU 信任框、deps 安装确认框、NSAlert）的场景，sendQuery 都用双超时；connect 短 / execute 长。plan-reviewer 应把「timeout 与功能拒绝不可区分」列为 false-green 风险（置信度 95+）。

## 关联
- modal runloop 不 pump：`patterns/2026-06-27-modal-runloop-task-not-pump-installsync-bypass.md`
- 红队 false-report 风险：`patterns/2026-06-23-autopilot-red-team-false-report-verify-ls.md`
- 决策：`decisions/2026-07-16-plugin-cli-hub-buddy-tools-run-ai-manifest.md`（补强 1）
