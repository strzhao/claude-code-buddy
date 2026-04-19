# QA 报告

## Wave 1 — 证据

**1. 脚本改动（1 处，符合 scope）**
`Scripts/generate-rocket-sprites-v2.swift:851-861`：
- `shuttle_landing_a`: `yOff: 6 → 1`（drawShuttleBody + drawShuttleFlame）
- `shuttle_landing_b`: `yOff: 3 → 0`（drawShuttleBody + drawShuttleFlame）
- 追加 4 行注释说明 yOff ≤ 1 约束的根因

**2. 精灵重生成（diff 范围精准）**
```
 Scripts/generate-rocket-sprites-v2.swift                | 12 ++++++++----
 .../Assets/Sprites/Rocket/rocket_shuttle_landing_a.png  | Bin 642 -> 676 bytes
 .../Assets/Sprites/Rocket/rocket_shuttle_landing_b.png  | Bin 668 -> 679 bytes
 3 files changed, 8 insertions(+), 4 deletions(-)
```
只有预期的 2 个 PNG + 脚本本体，其他 shuttle 帧和其他 kind 都未变。

**3. 视觉验证（Read PNG 输出）**
- `rocket_shuttle_landing_a.png`：ET 橙色鼻锥三角形完整可见，与 onpad_a / landing_c 形状一致
- `rocket_shuttle_landing_b.png`：同上，ET 完整

**4. 编译通过**
`make build` → `Build complete! (0.33s)`

**5. 单元测试全绿**
`make test` → `Executed 416 tests, with 0 failures (0 unexpected) in 43.192 seconds`

## 结论
✅ 实现按 scope 完成，静态证据充分。运行时验证（scenario B — `buddy showcase shuttle` 后触发 task_complete 观察降落动画）由用户 review 时确认。
