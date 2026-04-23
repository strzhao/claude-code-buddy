# QA 报告：本地推送通知

## Wave 1: 静态验证
- [x] `make build` — 编译通过
- [x] `swift test --filter Snapshot` — 14 tests, 0 failures
- [x] `make lint` — 0 violations, 0 serious in 61 files

## Wave 1.5: E2E 验证（buddy CLI + 真实 app）
测试环境：ad-hoc 签名 + `open` 启动

### P0 场景
- [x] Permission Request 通知推送
- [x] Task Complete 通知推送
- [x] LSUIElement 模式正常工作
- [x] 点击回调触发（辅助功能弹框证明回调链完整）
- [x] acknowledge 逻辑（`permission_acknowledged: false → true`）

### P1 场景
- [x] 多 session 通知互不干扰
- [x] 同 session task_complete 通知替换

### P2 场景
- [x] 授权拒绝静默降级
- [x] 通知内容包含 session label

## 发现并修复的问题
1. `willPresent` 返回空集合导致 LSUIElement app 通知不显示 → 改为 `.banner`
2. `UNNotificationPresentationOptions.skip` 不存在 → 改为 `.banner`
3. App 需要 ad-hoc 签名才能获得通知授权
