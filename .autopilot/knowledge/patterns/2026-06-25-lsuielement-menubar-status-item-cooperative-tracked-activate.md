### [2026-06-25] LSUIElement menubar status item 点开窗口非 key：4 层根因链 + cooperative activate(from: tracked app)
<!-- tags: lsuielement, key-window, menubar, status-item, cooperative-activation, nspopover, activationpolicy, nsrunningapplication, accessory, regular, macos-14, accepts-first-mouse, sage-switch -->

**Scenario**: LSUIElement accessory app（菜单栏像素猫咪）从菜单栏 status item 点击打开「设置」窗口（标准 NSWindow），窗口绝大部分情况**非 key window**——无 active 外观（用户感知"无毛玻璃"）、自绘 SageSwitch 首击无反应。但有 2 种情况是 key：① CLI/socket 命令打开；② 非 key 时点窗口内按钮打开浏览器、切回后变 key。曾耗时半天未解决。

**Lesson（4 层叠加根因，缺一不可；每层都有日志铁证）**：

1. **`.accessory` 窗口无成为 key 的资格**（steipete 2025 花 5 小时排查结论）：macOS 不允许无 Dock 图标（`.accessory`）的 app 窗口成为 key window，再多 `makeKeyAndOrderFront` 也没用。→ 必须开窗时临时 `setActivationPolicy(.regular)`、关闭时切回 `.accessory`（`restoreActivationPolicy` 监听 `NSWindow.willCloseNotification`）。

2. **点 status item 让 app 自己成 frontmost 但 `isActive=false`**：menubar status item 点击后，`NSWorkspace.frontmostApplication` 变成 app 自己（如 `com.claudebuddy`），但 `NSApp.isActive` 仍 false——"frontmost 是自己、却没真激活"的死局。→ cooperative `activate(from:)` 若直接读 frontmost 会检测到 frontApp==自己而降级失败。**必须用「点 status item 之前用户真正在用的 app」做 yield**：注册 `NSWorkspace.didActivateApplicationNotification` 持续记录非自己的前台 app（`lastExternalFrontApp`），`activateApp()` 优先用它（`tracked ?? frontmost`）。日志关键标记：`yieldSource=tracked`。

3. **`popover.performClose` 动画干扰 activation**：menubar 流程是 `点 status item → popover 弹出 → 点设置 → performClose(异步动画) → showSettings`。showSettings 开始时 `popover.isShown` 仍 true（动画未结束），popover 关闭动画干扰 app activation 转换 → 切 .regular + activate 全失效。日志铁证：`popoverShown:true` 时 `isKeyWindow` 始终 false。→ 用 `popoverDidClose` 回调（动画完成后）再 `showSettings`（置 `pendingSettingsAfterPopoverClose` 标志）；并设 `popover.animates=false` 去掉动画让回调更快（用户确认动画不重要）。

4. **`NSApp.activate()`（macOS 14+ 无参新 API）是 cooperative "请求"、不保证成功**：官方原话 "doesn't guarantee app activation"，对 accessory app 经常 no-op。→ 改用 cooperative `NSRunningApplication.current.activate(from: yieldApp)`（macOS 14+ 官方唯一保证成功路径，要求 yieldApp 当前 active 且 receiver 能 active）。Ice 同款。

**解法（4 层逐一对应）**：
- ① `setActivationPolicy(.regular)` 开窗 / `.accessory` 关窗
- ② `trackExternalFrontApp`（didActivate 记录非自己 app）+ `activateApp()` 优先 `activate(from: lastExternalFrontApp)`
- ③ `onSettings` 置标志 + `performClose`；`popoverDidClose` 回调里才 `showSettings`；`popover.animates=false`
- ④ `activateApp()` cooperative `activate(from:)`，yieldApp 优先 tracked
- 兜底：delay 200ms 后二次 `activate + makeKeyAndOrderFront + orderFrontRegardless`（首次 policy 转换异步，可能慢）
- 治标 safety net：`SageSwitch.acceptsFirstMouse(for:) -> true`（即使窗口偶发非 key，首击也能到 `mouseDown`；Cocoa 官方机制：非 key 窗口第一次 mouseDown 被系统吞用于激活窗口）

**Evidence**（menubar 路径修复后日志铁证，连续 2 次稳定 key）：
```
showSettings [source:menubar] → cooperative activate(from:) frontApp=com.mitchellh.ghostty yieldSource=tracked
→ settings window didBecomeKey (33ms) → app didBecomeActive
→ 治本 delay 后 [isActive:true, isKeyWindow:true]
→ 关闭: 恢复 .accessory + didResignKey + didResignActive
```
对照实验（验证机制）：前台=`com.apple.universalcontrol`（系统服务，不 yield）→ 即使切 .regular 也不 key；前台=`com.apple.finder`（normal app）→ cooperative yield → 67ms didBecomeKey。

**测试限制**：自动化环境（CGEvent/osascript/程序化 `open -a`）对 cooperative activation 复现**不稳定**——程序化切前台不被系统当真实用户意图，同一代码一成一败。验证 menubar status item 路径必须**真实用户点击**（socket/notify 路径可 CLI 驱动，但 cooperative yield 依赖真实前台 app，且点 status item 后 frontmost 变 app 自己这个状态只有真实点击能复现）。这是 LSUIElement app 自动化验证的硬限制（见 [[2026-06-23-lsuielement-standard-nswindow-key-window-sendevent-fallback]] 已记录的同类限制）。

**不要走的路**：
- 别用 `NSApp.activate(ignoringOtherApps:)`（macOS 14+ 废弃，系统忽略 flag）
- 别指望光切 `.regular` 就够（policy 切换异步 + 仍需 cooperative yield；日志证实切了 policy 仍可能不 key）
- 别用 frontmost 做 yield 来源（menubar 点击后 frontmost 是 app 自己）
- 别在 popover 动画期间 activate（干扰 activation）
- 别靠 `ignoringOtherApps` 旧 API 兜底（14+ 被忽略，可靠性 ~85% 不如 cooperative）

**trade-off**：切 `.regular` 会让 Dock 短暂出现 app 图标（开/关设置时闪一下）——这是无 Dock 图标 menubar app 让窗口 key 的不可避免代价，Ice/VibeTunnel/steipete 等业界 menubar app 均接受。

**影响文件**：`AppDelegate.swift`（showSettings / restoreActivationPolicy / activateApp / trackExternalFrontApp / popoverDidClose / onSettings）、`SettingsWindowController.swift`（willClose 观察）、`Settings/Components/SageSwitch.swift`（acceptsFirstMouse）。

**关联**：
- [[2026-06-23-lsuielement-standard-nswindow-key-window-sendevent-fallback]]（前一轮：sendEvent 兜底，未解决 activation 根因；本轮在其基础上攻克 activation）
- [[2026-04-19-settings-panel-sendevent-not-nscollectionview]]（NSPanel 场景根教训）
- [[2026-04-19-lsuielement-nscollectionview-sendevent-click]]
- [[2026-05-29-lsuielement-launcher-restore-focus-on-hide]]（同类思路：记录 previousFrontApp 切回，可借鉴其 `DispatchQueue.main.async` 调 activate 的时序坑）
