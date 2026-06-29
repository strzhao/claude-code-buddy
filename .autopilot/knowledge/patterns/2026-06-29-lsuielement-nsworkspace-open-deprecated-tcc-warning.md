### [2026-06-29] LSUIElement app 调用废弃 NSWorkspace.open(url) 触发 TCC 隐私安全警告
<!-- tags: lsuielement, nsworkspace, openapplication, tcc, privacy, deprecated-api, app-launcher, accessory, open-configuration -->

**Scenario**: LSUIElement/accessory app 通过 NSWorkspace 启动外部 app 时，使用废弃的同步 `open(_:)` API 会触发 macOS「隐私与安全」弹窗提示（告知已阻止修改 Mac 上的 App）。实际 app 仍然可以正常打开（TCC 对「启动」的拦截力度低于 AppleEvents「控制」），但弹窗让用户困惑。

**Lesson**: LSUIElement app 调用 NSWorkspace 启动外部 app 时，必须使用现代 `openApplication(at:configuration:completionHandler:)` API 并传入 `NSWorkspace.OpenConfiguration`（至少设置 `activates = true`），而非废弃的无参数 `open(_:)` API。废弃 API 不带结构化 intention metadata，macOS TCC 无法区分「用户主动打开 app」和「后台程序暗中修改系统」，将其标记为可疑行为（恶意软件经典 pattern）弹出安全警告。现代 API 通过 `OpenConfiguration` 声明行为意图（activates / promptsUserIfNeeded / allowsRunningBoard），系统能据此做更合理的 TCC 判断。

**Evidence**: Buddy（LSUIElement app）通过 Launcher 内置 AppLauncherPlugin 打开本机 app 时，`NSWorkspaceAppLauncher.launch(_:)` 原实现调 `NSWorkspace.shared.open(url)`（macOS 10.x 遗留 API），触发 TCC 隐私警告。改为 `NSWorkspace.shared.openApplication(at: url, configuration: config)`（对齐 AppDelegate.restartApp() 已有正确写法）后警告消失。`Info.plist:23` 声明 `LSUIElement = true` 是根因（accessory policy），废弃 API 放大（不带 OpenConfiguration）。注意：仅 Launcher 自动启动 AppLauncherPlugin 受 LSUIElement 后台进程 TCC 影响；用户手工点击触发的 NSWorkspace.open（如 AboutSettings 打开浏览器链接）发生在事件响应链上，不受此影响。
