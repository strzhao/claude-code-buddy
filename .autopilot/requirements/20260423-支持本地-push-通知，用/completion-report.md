# 完成报告：本地推送通知

## 概要
为 Claude Code Buddy 添加 macOS 系统推送通知，确保用户切换到其他应用时不错过权限请求。

## 变更范围
5 个文件（1 新建 + 4 修改），变更量极小（+14/-3 行）

## 新增组件
- `NotificationManager` — singleton，订阅 EventBus，发送 UNUserNotificationCenter 通知

## 验证结果
- 编译 ✅、14 快照测试 ✅、0 lint 违规 ✅
- E2E 验证：通知推送 ✅、点击回调 ✅、acknowledge 逻辑 ✅

## 注意事项
- App 需要签名才能获得通知授权（ad-hoc 签名即可）
- LSUIElement app 的 `willPresent` 必须返回 `.banner`
