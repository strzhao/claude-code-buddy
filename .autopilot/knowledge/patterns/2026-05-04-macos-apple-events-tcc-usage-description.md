# macOS 非沙盒 app 的 Apple Events TCC 权限仅需 NSAppleEventsUsageDescription

<!-- tags: macos, tcc, apple-events, applescript, permission, infoplist, codesign, nsscript -->
**Scenario**: ClaudeCodeBuddy（非沙盒、ad-hoc 签名、LSUIElement）通过 `NSAppleScript.executeAndReturnError()` 向 Ghostty 发送 Apple Events 时持续返回 -1743 (`errAEEventNotPermitted`)。根因是 Info.plist 缺少 `NSAppleEventsUsageDescription` 键，macOS TCC 直接拒绝且不弹权限对话框。影响范围：`GhosttyAdapter.activateTab`（点击猫切换 tab）和 `GhosttyAdapter.setTabTitle`（注入 tab 标题）全部静默失败。
**Lesson**: 
1. 非沙盒 macOS app 触发 Apple Events TCC 权限提示**仅需** Info.plist 中声明 `NSAppleEventsUsageDescription`。不需要 entitlements 文件，不需要 `codesign --entitlements`。
2. `com.apple.security.automation.apple-events` 是 App Sandbox entitlement，仅在 `com.apple.security.app-sandbox` 为 true 时生效。非沙盒 app 中添加此 entitlement 无效且误导。
3. 开发模式 `make run`（`.build/debug/` 裸跑二进制）无 `.app` bundle 上下文，launch services 不解析 Info.plist，TCC 无法关联权限。需通过 `make run-bundle`（.app + ad-hoc 签名）运行才能在开发中测试 Apple Events 功能。
4. Plan 审查（plan-reviewer agent）捕获了初版方案中不必要的 entitlements 步骤，避免了 scope creep — 验证了 autopilot 审查机制的价值。
**Evidence**: `/tmp/claude-buddy-click.log` 显示每次点击 `activateByTerminalId` 和 `activateByCwd` 均报 -1743。同一 AppleScript 从 Ghostty Terminal 内直接 `osascript` 执行正常（Terminal 进程有权限）。对比：App 进程（com.claudebuddy.ClaudeCodeBuddy）无 TCC 授权。
