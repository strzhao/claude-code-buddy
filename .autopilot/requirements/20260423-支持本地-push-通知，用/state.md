---
active: true
phase: "done"
gate: ""
iteration: 1
max_iterations: 30
max_retries: 3
retry_count: 0
mode: ""
plan_mode: "deep"
brief_file: ""
next_task: ""
auto_approve: false
knowledge_extracted: "skipped"
task_dir: "/Users/stringzhao/workspace_sync/personal_projects/claude-code-buddy/.claude/worktrees/notify/.autopilot/requirements/20260423-支持本地-push-通知，用"
session_id: 663b70c7-aee8-4a02-baf9-6baf5e8f4a69
started_at: "2026-04-23T15:21:21Z"
---

## 目标
支持本地 push 通知，用于关键的通知提醒

> 📚 项目知识库已存在: .autopilot/。design 阶段请先加载相关知识上下文。

## 设计文档
使用 UNUserNotificationCenter 发送本地推送通知，覆盖 permissionRequest 和 taskComplete 两个事件。
新建 NotificationManager singleton（遵循 SoundManager 模式），订阅 EventBus.stateChanged。
NotificationManager 自身作为 UNUserNotificationCenterDelegate，通过回调通知 AppDelegate 处理点击（acknowledge + terminal activation）。
前台时不额外显示通知横幅（猫咪视觉已覆盖）。通知标识符：perm-{sessionId}（permission）、task-{sessionId}（task complete 替换）。
首次启动请求授权，拒绝时静默降级。

## 实现计划
- [x] T1: 新建 NotificationManager.swift
- [x] T2: 修改 AppDelegate.swift 初始化 + 点击回调
- [x] T3: StateChangeEvent 添加 label 字段
- [x] T4: 编译验证 + 测试

## 红队验收测试
(待 implement 阶段填充)

## QA 报告

### Wave 1: 静态验证
- [x] `make build` — 编译通过 (5.78s)
- [x] `swift test --filter Snapshot` — 14 tests, 0 failures
- [x] `make lint` — 0 violations, 0 serious in 61 files

### Wave 1.5: E2E 验证（buddy CLI + 真实 app）
测试环境：ad-hoc 签名 + `open` 启动

**P0 场景：**
- [x] Permission Request 通知推送 — `buddy emit permission_request` → macOS 通知弹出，标题 "test"，内容 "Write config file"
- [x] Task Complete 通知推送 — `buddy emit task_complete` → macOS 通知弹出，标题 "test"，内容 "Task complete ✓"
- [x] LSUIElement 模式正常工作 — LSUIElement app 收到通知授权并弹出系统通知
- [x] 点击回调触发 — 点击通知后触发 AppleScript 终端激活（辅助功能弹框证明回调链完整）
- [x] acknowledge 逻辑 — `buddy click` 测试：`permission_acknowledged: false → true`

**P1 场景：**
- [x] 多 session 通知 — 各 session 独立通知，互不干扰（不同 sessionId 不同通知标识符）
- [x] 同 session task_complete 替换 — `task-{sessionId}` 标识符自动替换旧通知

**P2 场景：**
- [x] 授权拒绝降级 — 未签名 app 从命令行运行时 `UNErrorDomain error 1`，静默降级无崩溃
- [x] 通知内容包含 session label — `StateChangeEvent.label` 正确传递到通知标题

### 发现的问题（已修复）
1. `willPresent` 返回空集合导致 LSUIElement app 通知不显示 → 修改为 `.banner`
2. App 需要 ad-hoc 签名才能获得通知授权（`codesign --force --deep --sign -`）
3. `UNNotificationPresentationOptions.skip` 不存在 → 使用 `[]`，后改为 `.banner`

### 变更文件
| 文件 | 变更 |
|------|------|
| `Sources/ClaudeCodeBuddy/Notification/NotificationManager.swift` | 新建 |
| `Sources/ClaudeCodeBuddy/App/AppDelegate.swift` | 初始化 NotificationManager + 点击回调 |
| `Sources/ClaudeCodeBuddy/Event/BuddyEvent.swift` | StateChangeEvent 添加 label 字段 |
| `Sources/ClaudeCodeBuddy/Session/SessionManager.swift` | 传递 label 到 StateChangeEvent |
| `Tests/BuddyCoreTests/EventBusTests.swift` | 适配 label 参数 |

## 变更日志
- [2026-04-23T17:19:14Z] 用户批准验收，进入合并阶段
- [2026-04-23T15:21:21Z] autopilot 初始化，目标: 支持本地 push 通知，用于关键的通知提醒
- [2026-04-23T15:25:00Z] design 阶段完成：方案 UNUserNotificationCenter，审批通过
- [2026-04-23T15:30:00Z] implement 阶段完成：NotificationManager + AppDelegate + StateChangeEvent label，编译/lint/快照测试通过
- [2026-04-24T00:15:00Z] QA E2E 验证通过：通知推送 ✅、点击回调 ✅、编译/lint/快照测试 ✅
- [2026-04-24T00:45:00Z] merge 完成：代码提交 2cfc426 + autopilot 6b98a3f，产出物归档
