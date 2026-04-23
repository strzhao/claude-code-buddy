# Brainstorm: 支持本地 Push 通知

## Q&A 摘要

### Q1: 哪些事件触发通知？
- **Permission Request** (核心) — 用户切走窗口后容易错过
- **Task Complete** — 方便用户及时查看结果

### Q2: 通知主要目的？
- **不错过权限请求** — 核心场景是用户在看浏览器时，Claude Code 等待授权能及时响应

### Q3: 点击通知后的行为？
- **跳转到终端** — 激活 Ghostty 窗口 → 切换到对应 tab → 自动 acknowledge permission

### Q4: 通知频率？
- **每次都推送** — 同 session 的 task_complete 会替换为最新状态，不节流

### Q5: 实现方案？
- **UNUserNotificationCenter** — 现代 API，未来兼容，支持通知中心历史和交互按钮
- 否决：NSUserNotification (已废弃)、AppleScript osascript (体验差)

## 技术决策

- 使用 `UserNotifications` 框架
- 新建 `NotificationManager` 订阅 EventBus
- 点击通知回调 → 激活终端 + acknowledge permission
- Info.plist 无需额外 entitlement（UNUserNotificationCenter 不需要特殊 entitlement）
