# 设计文档：本地推送通知

## 目标
使用 UNUserNotificationCenter 发送本地推送通知，覆盖 permissionRequest 和 taskComplete 两个事件。点击通知后自动激活终端并 acknowledge permission。

## 技术方案
- 新建 `NotificationManager` singleton（遵循 SoundManager 模式）
- 订阅 `EventBus.shared.stateChanged`，过滤 `.permissionRequest` 和 `.taskComplete`
- NotificationManager 自身作为 `UNUserNotificationCenterDelegate`
- `willPresent` 返回 `.banner`（LSUIElement app 始终被视为前台，需显式展示）
- 通知标识符：`perm-{sessionId}`（permission）、`task-{sessionId}`（task complete 替换）
- 通过 `onNotificationClicked` 回调通知 AppDelegate 处理点击（acknowledge + terminal activation）
- 首次启动 `requestAuthorization(options: [.alert, .sound])`，拒绝时静默降级

## 关键发现
- LSUIElement app 需要 `completionHandler(.banner)` 才能在前台显示通知
- 未签名 app 无法获得通知授权，需 `codesign --force --deep --sign -` 签名
