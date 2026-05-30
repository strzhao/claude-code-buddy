<!-- tags: macos, screen-lock, lock, private-api, login-framework, saclockscreenimmediate, dlopen, dlsym, tcc, applescript, accessibility-permission, launcher, builtin-plugin, system-command, seam, screenlocking, unsafebitcast, defer-dlclose -->

# macOS 锁屏：login.framework 私有 API `SACLockScreenImmediate`（dlopen/dlsym，零 TCC 权限）优于 AppleScript ⌃⌘Q

## 背景
launcher 新增「锁屏」系统命令（`SystemCommandPlugin`，第二个 [[2026-05-30 launcher 内置插件]] BuiltinPlugin）。macOS 上「立即锁屏」有多条路径，权限/可靠性差异大：

| 方案 | 机制 | 权限 | 问题 |
|------|------|------|------|
| **私有 API（选用）** | `SACLockScreenImmediate()` from login.framework | **无需任何 TCC** | 私有符号，理论跨版本失效风险 |
| AppleScript ⌃⌘Q | `osascript` keystroke control+command q | **需「辅助功能」TCC**（首次弹窗，未授权静默失败） | 依赖键位绑定，可被用户改键 |
| `pmset displaysleepnow` | 睡眠显示器 | 无 | **只睡显示器，仅当开了「睡眠后立即要求密码」才等价锁屏** → 语义不达标 |

## 解决（生产实现）
`dlopen` 私有框架 → `dlsym` 取符号 → `unsafeBitCast` 到 C 函数指针调用，三条失败路径全显式抛错，`defer { dlclose }` 防泄漏：
```swift
func lock() throws {
    let path = "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login"
    guard let handle = dlopen(path, RTLD_LAZY) else { throw LauncherError.systemCommandFailed("锁定屏幕") }
    defer { dlclose(handle) }
    guard let sym = dlsym(handle, "SACLockScreenImmediate") else { throw LauncherError.systemCommandFailed("锁定屏幕") }
    typealias LockFn = @convention(c) () -> Int32
    let fn = unsafeBitCast(sym, to: LockFn.self)
    guard fn() == 0 else { throw LauncherError.systemCommandFailed("锁定屏幕") }
}
```
非沙盒 + ad-hoc 签名的 LSUIElement app 可直接调用，无需任何 entitlement/权限弹窗。真机实测：dlopen+dlsym 解析成功（符号地址 0x…66cc），Enter 触发 macOS 立即进入锁屏/登录界面。

## Lesson
- macOS「立即锁屏」**首选私有 API `SACLockScreenImmediate`**：唯一能「无权限 + 即时 + 真锁屏」的手段；AppleScript ⌃⌘Q 的辅助功能授权摩擦使它只配做降级后备，`pmset` 语义根本不达标。
- 调私有 framework 用 **运行时 dlopen/dlsym 而非链接**，符号缺失时优雅降级而非 crash；私有 API 的跨版本风险必须靠 **实现期真机冒烟验证**（autopilot「先验证再实现」）兜底，本类「真锁屏副作用」自动化测试无法求值（会锁住 CI/会话）→ 设计为 real-process 人工冒烟 + det-machine 验证「调用注入的 seam（spy.callCount==1）」。
- 系统动作执行统一走可注入 seam 协议（`ScreenLocking { func lock() throws }`，仿 `AppLaunching`），测试注入 mock/抛错 stub，绝不真锁屏；失败 throw 中文 `LauncherError`，由 LauncherManager 既有 catch 呈现，不静默吞错。
- 扩展提醒：`BuiltinPluginRegistry` 的默认插件列表有 **init 与 reset 两个构造点**，新插件两处都要注册——只改 init 会让 `reset()` 后（测试 setUp 常调）候选消失成 flaky（plan-reviewer 抓到的隐患）。
