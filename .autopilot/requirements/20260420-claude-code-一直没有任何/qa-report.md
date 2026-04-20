# QA 报告

## Wave 1 — 静态验证
| 检查项 | 结果 | 证据 |
|--------|------|------|
| 编译 (`make build`) | PASS | Build complete! (0.43s) |
| 单元测试 (`swift test`) | PASS | 401 tests, 0 failures |
| Lint (`make lint`) | PASS | 0 violations in 59 files |

## Wave 1.5 — 验收测试
| 场景 | 结果 |
|------|------|
| 进程存活时猫咪不消失 | PASS |
| 进程死亡后 30min 超时删除 | PASS |
| 无 PID 会话超时删除 | PASS |
| 5min idle 阈值独立 | PASS |
| hooks.json 包含 UserPromptSubmit | PASS |
| 多会话独立超时 | PASS |
